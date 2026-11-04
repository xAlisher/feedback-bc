#!/usr/bin/env python3
"""Feedback Desk — collector service (issues #10-#14).

Drives delivery_module via logosctl, receives sealed feedback on the devnet topics,
decrypts with the Desk private key, enforces size limits, stores locally with dedup,
backfills via storeQuery on startup, and bridges each response to a private Discord
channel webhook.

Wire format (production): the Waku payload is the raw sealed-box ciphertext; delivery
hands it to us base64-wrapped in events, so we base64-decode once then open_sealed().

Run: python3 desk.py config.json   (see config.example.json)
Secrets (private key file, webhook URL) come from config/host, never the repo.
"""
from __future__ import annotations
import base64
import json
import os
import subprocess
import sys
import time
import urllib.request

import feedback_common as fc


def load_config(path: str) -> dict:
    with open(path) as f:
        cfg = json.load(f)
    with open(cfg["private_key_file"]) as f:
        cfg["_priv"] = f.read().strip()
    return cfg


def lc(cfg: dict, *args: str, timeout: int = 40) -> str:
    cmd = [cfg["logosctl"], "--config-dir", cfg["session_dir"], *args]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout


class Store:
    """Append-only JSONL store + a persisted set of seen messageHashes (dedup)."""

    def __init__(self, path: str, seen_path: str):
        self.path, self.seen_path = path, seen_path
        self.seen: set[str] = set()
        if os.path.exists(seen_path):
            with open(seen_path) as f:
                self.seen = set(l.strip() for l in f if l.strip())

    def is_new(self, mhash: str) -> bool:
        return mhash not in self.seen

    def add(self, mhash: str, record: dict) -> None:
        with open(self.path, "a") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        self.seen.add(mhash)
        with open(self.seen_path, "a") as f:
            f.write(mhash + "\n")


def to_discord(cfg: dict, record: dict) -> None:
    url = cfg.get("discord_webhook")
    if not url:
        return  # bridge optional (e.g. local test)
    p = record["payload"]
    if p.get("kind") == "questionnaire":
        ans = p.get("answers", {})
        body = "\n".join(f"- **{k}**: {str(v)[:300]}" for k, v in ans.items())
        head = "**Questionnaire response**"
    else:
        head = f"**Feedback — {p.get('topic','?')}**: {p.get('title','') or '(no title)'}"
        body = str(p.get("message", ""))[:1500]
    contact = p.get("contact")
    msg = f"{head}\n{body}\n_build {p.get('build','?')}" + (f" · contact: {contact}" if contact else "") + "_"
    msg = msg[:1990]  # Discord 2000-char cap
    data = json.dumps({"content": msg}).encode()
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:  # a failed post must not drop the (already-stored) feedback
        print(f"[warn] discord post failed: {e}", file=sys.stderr)


def handle(cfg: dict, store: Store, mhash: str, topic: str, payload_b64: str, source: str) -> None:
    if not mhash or not store.is_new(mhash):
        return  # dedup: skip already-seen (prevents re-posting on backfill/restart)
    try:
        ciphertext = base64.b64decode(payload_b64)      # delivery event wrapping
        payload = fc.open_sealed(cfg["_priv"], ciphertext)  # decrypt + size limits
    except fc.FeedbackError as e:
        print(f"[skip] {mhash[:10]} limit/validation: {e}", file=sys.stderr)
        store.add(mhash, {"mhash": mhash, "skipped": str(e), "ts": time.time()})
        return
    except Exception as e:
        print(f"[skip] {mhash[:10]} undecryptable: {e}", file=sys.stderr)
        return
    record = {"mhash": mhash, "topic": topic, "source": source, "recv_ts": time.time(), "payload": payload}
    store.add(mhash, record)
    to_discord(cfg, record)
    print(f"[ok] {source} {mhash[:10]} kind={payload.get('kind')} topic={topic}")


def backfill(cfg: dict, store: Store) -> None:
    for topic in cfg["topics"]:
        q = {"requestId": f"desk-{int(time.time())}", "includeData": True,
             "paginationForward": True, "contentTopics": [topic]}
        out = lc(cfg, "call", "delivery_module", "storeQuery", json.dumps(q), cfg["store_peer"], "10000")
        try:
            resp = json.loads(json.loads(out)["result"]["value"])
        except Exception:
            print(f"[warn] storeQuery parse failed for {topic}", file=sys.stderr)
            continue
        for m in resp.get("messages", []):
            msg = m.get("message", {})
            handle(cfg, store, m.get("messageHash", ""), msg.get("contentTopic", topic),
                   msg.get("payload", ""), "history")


def watch_live(cfg: dict, store: Store) -> None:
    proc = subprocess.Popen([cfg["logosctl"], "--config-dir", cfg["session_dir"],
                             "watch", "delivery_module"], stdout=subprocess.PIPE, text=True)
    topics = set(cfg["topics"])
    for line in proc.stdout:
        line = line.strip()
        if '"messageReceived"' not in line:
            continue
        try:
            ev = json.loads(line)["data"]
        except Exception:
            continue
        topic = ev.get("arg1")
        if topic not in topics:
            continue
        payload = ev.get("arg2", {})
        pb64 = payload.get("_bytes") if isinstance(payload, dict) else None
        handle(cfg, store, ev.get("arg0", ""), topic, pb64 or "", "live")


def main() -> None:
    cfg = load_config(sys.argv[1] if len(sys.argv) > 1 else "config.json")
    store = Store(cfg["store_file"], cfg["seen_file"])
    for topic in cfg["topics"]:
        lc(cfg, "call", "delivery_module", "subscribe", topic)
    print("[desk] backfilling…")
    backfill(cfg, store)
    print("[desk] watching live…")
    watch_live(cfg, store)


if __name__ == "__main__":
    main()
