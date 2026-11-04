"""Shared contract for the Basecamp Feedback app and Feedback Desk.

Payload schema, size limits, and the seal/open crypto (libsodium sealed box via PyNaCl).
The Feedback app (C/QML) reimplements seal() with libsodium crypto_box_seal; this is the
reference + the Desk side. Sealed boxes are interoperable across libsodium bindings.

Wire format: the Waku message payload is the raw sealed-box ciphertext (bytes). The Desk
gets it base64-wrapped inside delivery events (`messageReceived.payload` / store `payload`),
so it base64-decodes once to recover the ciphertext, then opens it.
"""
from __future__ import annotations
import json
from nacl.public import PrivateKey, PublicKey, SealedBox
from nacl.encoding import HexEncoder

# --- Size limits (reasonable caps: Waku message size, sealed-box, Discord 2000-char post, abuse) ---
LIMITS = {
    "title_max": 120,
    "message_max": 2000,
    "contact_max": 200,
    "answer_max": 1000,
    "max_answers": 10,
    "payload_max_bytes": 8192,   # hard cap on the decrypted JSON
}
TOPICS = ["app", "package-manager", "node", "wallet", "delivery", "messaging", "onboarding", "other"]


class FeedbackError(ValueError):
    pass


def _check_len(name: str, val: str, limit: int) -> None:
    if val is None:
        return
    if not isinstance(val, str):
        raise FeedbackError(f"{name} must be text")
    if len(val) > limit:
        raise FeedbackError(f"{name} too long: {len(val)} > {limit}")


def validate_payload(p: dict) -> dict:
    """Enforce the schema + size limits. Raises FeedbackError. Returns p on success."""
    if not isinstance(p, dict):
        raise FeedbackError("payload must be an object")
    kind = p.get("kind")
    if kind not in ("quick", "questionnaire"):
        raise FeedbackError(f"bad kind: {kind!r}")
    _check_len("title", p.get("title"), LIMITS["title_max"])
    _check_len("contact", p.get("contact"), LIMITS["contact_max"])
    topic = p.get("topic")
    if topic is not None and topic not in TOPICS:
        raise FeedbackError(f"unknown topic: {topic!r}")
    if kind == "quick":
        _check_len("message", p.get("message", ""), LIMITS["message_max"])
    else:  # questionnaire
        answers = p.get("answers")
        if not isinstance(answers, dict):
            raise FeedbackError("answers must be an object")
        if len(answers) > LIMITS["max_answers"]:
            raise FeedbackError(f"too many answers: {len(answers)} > {LIMITS['max_answers']}")
        for k, v in answers.items():
            if isinstance(v, int):
                continue  # rating
            _check_len(f"answers.{k}", v, LIMITS["answer_max"])
    return p


def payload_bytes(p: dict) -> bytes:
    """Validate + serialize compactly; also enforces the total-size cap."""
    validate_payload(p)
    b = json.dumps(p, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    if len(b) > LIMITS["payload_max_bytes"]:
        raise FeedbackError(f"payload too large: {len(b)} > {LIMITS['payload_max_bytes']} bytes")
    return b


# --- crypto: libsodium sealed box ---
def gen_keypair() -> tuple[str, str]:
    """Returns (public_hex, private_hex)."""
    sk = PrivateKey.generate()
    return (sk.public_key.encode(HexEncoder).decode(), sk.encode(HexEncoder).decode())


def seal(public_hex: str, p: dict) -> bytes:
    """App side: validate + size-check + seal to the Desk public key. Returns ciphertext bytes."""
    box = SealedBox(PublicKey(public_hex.encode(), HexEncoder))
    return box.encrypt(payload_bytes(p))


def open_sealed(private_hex: str, ciphertext: bytes) -> dict:
    """Desk side: open + enforce size cap (defense against a sender bypassing the UI)."""
    if len(ciphertext) > LIMITS["payload_max_bytes"] + 1024:  # ciphertext ~= plaintext + 48 bytes
        raise FeedbackError(f"ciphertext too large: {len(ciphertext)} bytes")
    box = SealedBox(PrivateKey(private_hex.encode(), HexEncoder))
    raw = box.decrypt(ciphertext)
    if len(raw) > LIMITS["payload_max_bytes"]:
        raise FeedbackError(f"decrypted payload too large: {len(raw)} bytes")
    return validate_payload(json.loads(raw))
