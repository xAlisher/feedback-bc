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

## Build (remaining)

1. Scaffold the module from the Basecamp module template (pin the SDK to the template rev).
2. Implement the native core (libsodium link) + expose `send(payloadJson)` / `state` to QML.
3. Wire the QML forms to the core; enforce limits in-input.
4. `mkLogosModule` / module builder → `.lgx`; load in Basecamp; **render-verify** the forms headlessly
   (390/700/1280) and run a real send → confirm it lands on the Desk.
