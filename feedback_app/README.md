# Feedback app (sender) — build notes

The user-facing Basecamp module: the two forms (quick + questionnaire), seals each response to the
Feedback Desk, and sends over devnet via `delivery_module`. Official-repo-bound once tested.

Status: **scaffold.** The QML UI drafts and the contract are here; the compiled native core and the
`.lgx` build are the remaining work (issues #4, #7). Nothing here is render-verified yet.

## Architecture

A `ui_qml` module with a small **native core** (C++, libsodium) because sealing can't be done in pure
QML/JS:

- **QML UI** (`qml/`) — the two forms (Logos design system, mobile-ready at 390/700/1280). Collects
  fields, enforces the size limits in-input, calls the core to send.
- **Native core** — mirrors `feedback_desk/feedback_common.py` in C:
  - builds + validates the payload (same size limits),
  - `crypto_box_seal` to the Desk public key (`pubkey.txt`), then base64 (the wire contract:
    payload = `base64(ciphertext)`),
  - delivery **adopt-or-create** (try `createNode` devnet `logos.dev`; on `Context already
    initialized` adopt via `getNodeInfo`), then `send(topic, base64(ciphertext))`,
  - cluster-fit detection via `rlnState` + queue/retry degraded mode (#8).

The crypto + wire + transport are already proven end-to-end against the live Desk (see the repo
README's "What is verified"); the core just ports the proven `feedback_common` logic to C.

## Contract (shared with the Desk)

- Payload schema + size limits: see `feedback_desk/feedback_common.py` (title 120, message 2000,
  contact 200, answer 1000, ≤10 answers, 8 KB total).
- Seal target: `pubkey.txt` (the deployed Desk's X25519 public key).
- Topics (4-segment Waku): `/logos-feedback/1/quick/json`, `/logos-feedback/1/questionnaire/json`.
- Wire: `send` the bytes `base64(crypto_box_seal(payload_json))`.

## Build architecture — findings (2026-11-04, evidence-based)

Two viable paths were investigated; both de-risked:

**Proven:**
- **Delivery needs no C++.** `delivery-probe` (a pure-QML module) drives delivery entirely from QML via
  `logos.callModule("delivery_module", method, params)` and `logos.onModuleEvent(...)`. So createNode /
  start / rlnState / send / events are all reachable from QML/JS.
- **The seal works in JS and is wire-compatible with the Desk.** `tweetnacl` + `tweetnacl-sealedbox`
  (blake2b nonce + `nacl.box`, byte-identical to libsodium `crypto_box_seal`) sealed a payload that the
  Desk's PyNaCl `open_sealed` decrypted exactly. Interop proven in node.
- **Native path template exists.** `receiver-basecamp` is a working C++/QML Basecamp module doing
  libsodium crypto + delivery (async fire-and-forget `createNode` to avoid the ui-host deadlock,
  clusterId=2 config). It builds and ships.

**Option A — pure QML/JS module** (like delivery-probe): QML UI + vendored `tweetnacl`/blake2b/sealedbox
+ `logos.callModule` for delivery. No C++, no nix compile, packaged like delivery-probe.
- Open question: does Qt's QML V4 engine expose a **CSPRNG** (`crypto.getRandomValues`)? The sealed box's
  ephemeral key needs secure randomness; `Math.random` would weaken confidentiality. Couldn't verify with
  the standalone nix `qml` runtime (core-dumps on env); the real test is a one-screen probe inside Basecamp.

**Option B — native core** (templated on `receiver-basecamp`): C++ + libsodium `crypto_box_seal` (proper
CSPRNG) for the seal, delivery from C++ or QML, QML UI. Correct crypto, but a real nix/CMake/.rep build.

**Decision — RESOLVED (headless probe, 2026-11-04): Option B.** Ran a QML probe on a headless sway
(Qt 6.9.2): **`crypto` is undefined in the V4 JS engine** (`crypto is not defined`), so there is no
WebCrypto CSPRNG. A pure-JS sealed box would fall back to `Math.random` for the ephemeral key, which
weakens confidentiality — not acceptable for a payload carrying contact PII. So the seal goes native.

**Scope of the native core is minimal:** delivery stays in QML (`logos.callModule`, proven); only one
function needs C++/libsodium — `seal(pubHex, payloadJson) -> base64(crypto_box_seal)` (which brings
libsodium's CSPRNG). Templated on `receiver-basecamp`'s libsodium + `mkLogosQmlModule` build. The JS
seal interop stays useful as the cross-check oracle (tweetnacl ↔ libsodium are byte-identical).

## Build (remaining)

1. Resolve A-vs-B: probe `crypto.getRandomValues` inside Basecamp's QML (one small view).
2. Package the module: QML forms (drafts here) + delivery calls + seal (JS vendored, or native per B).
3. Enforce size limits in-input; wire to the Desk pubkey (`pubkey.txt`).
4. Build/package the `.lgx`; load in Basecamp; **render-verify** (390/700/1280) + a real send that lands
   on the live Desk (and posts to Discord).
