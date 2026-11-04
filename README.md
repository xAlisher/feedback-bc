# Basecamp Feedback App

A native in-Basecamp feedback app for the testnet phase: a quick feedback form reachable from the
Basecamp shell, plus a short questionnaire, both built on the Logos delivery module. It is **built,
published, and dogfoodable today** (see *Status* below); this document carries both the design rationale
and the current state, and is open to feedback on the approach.

Status: built and published (2026-11-04). Stack claims are grounded in the public `delivery_module`
v0.3.0 contract and in live send and Store round-trips run against a Logos devnet node on 2026-11-04.

Two apps:
- **Feedback** (`feedback`) — the user-facing app (the two forms), in the official repo.
- **Feedback Desk** (`feedback_desk`) — the collector that receives, decrypts and stores responses, in
  a separate repo on a host we run.

---

## Status: built and published (2026-11-04)

This spec is now implemented and dogfoodable. The app ships as two modules, **`feedback_ui`** (the two
forms) and **`feedback_core`** (the native libsodium seal), both published and **signed (xAlisher)** in
the catalog below. The Feedback Desk runs always-on and bridges to a private Discord channel.

**Basecamp home integration.** An experimental Basecamp build adds a **Share Feedback** tile to the home
screen: one click installs `feedback_ui` from the catalog if it is missing (signed install dialog), then
opens it with the Quick-report topic preset to `home`. (It also adds a **Customise / Appearance** tile
that opens Settings.)

**Install / try it (Linux x86-64):**
- Add this repository in Basecamp, Settings > Package Repositories: https://apps.alisher.xyz/logos-repo.json
- Then install **Feedback** from Applications, or click the Share Feedback tile.
- Experimental Basecamp build with the tile baked in:
  https://github.com/xAlisher/basecamp-experiments/releases/tag/basecamp-feedback-exp-0.1

**Verified end-to-end (2026-11-04):** install from the catalog, send a quick report, the Desk receives
it live over devnet, decrypts it, and posts it to the private Discord channel.

**Current send behavior.** `trySend` gates on connection readiness and treats a successful
`delivery_module.send` call as sent; drafts are queued locally (persisted) and auto-retried when the node
is not ready. Confirming on the `messagePropagated`/`messageSent` events (per *Transport mechanics*
below) is a planned hardening, not yet wired. The `home` topic is in both the app and the Desk allowlist
(`feedback_common.py TOPICS`); adding a Quick-report topic requires both sides or the Desk drops it.

---

## Why native

A native app in the official repo is the cleanest in-Basecamp path. A web form (Typeform/CryptPad)
sends users off-platform, and third-party feedback apps cannot currently be linked from inside
Basecamp. A native app, built on delivery, is linkable from any Basecamp view and keeps feedback on
the Logos stack (which also dogfoods delivery during testnet).

## Architecture: two modules

| Module | Where | Role |
|---|---|---|
| **feedback** | official repo (once tested) | the two forms + publish; linkable from the shell |
| **feedback_desk** | separate repo / host we run | receive + decrypt + store responses; also the Store peer |

Both wrap `delivery_module` (Waku). The Feedback Desk's node doubles as the Store peer used for
backfill, so the collecting side owns the one always-on component.

## Two surfaces

**A. Quick feedback form** — linked from the Basecamp shell, reachable from anywhere.
Fields: Title, Topic (dropdown), Message, Contact (optional), Send, then a confirmation.

**B. Questionnaire** — inside the Feedback app. Test version, four questions:
1. How would you rate Basecamp so far? (1 = poor to 5 = great)
2. What, if anything, has Basecamp been useful for so far?
3. Which modules or apps are you most excited about?
4. One thing you would improve right now?

Questions change with app updates, not remotely, to keep it simple. Both forms auto-fill an invisible
`build` field (app/module version) so every response is tied to a specific release.

## Fleet and RLN: devnet, and the passenger reality

**Target: the devnet fleet (preset `logos.dev`) to avoid RLN.** Verified: on that preset a node reports
`rlnState: Disabled`, and a node with no RLN membership sends a message that propagates and is
network-validated. No tokens, no mining. Testnet (`logos.test`) enables RLN, which needs a funded
membership; the feedback app avoids that by targeting devnet.

**The sender is a passenger, though.** `delivery_module` is one shared node per Basecamp: the first
module to call `createNode` picks the network for everyone, and a second `createNode` fails with
`Context already initialized`. So:
- If Feedback is the first or only delivery user, it creates the node on devnet and RLN is avoided.
- If another app (for example chat, which defaults to `logos.test`) already owns the node, Feedback
  adopts that cluster and may land on an RLN fleet with no membership, so it cannot send.

Because standardizing every Basecamp onto one fleet is not expected near-term, the Feedback app detects
fit and degrades gracefully (below), and the Feedback Desk covers the union of clusters users run on.

## Message payload and encryption (seal-to-Desk)

Responses are **anonymous and confidential**: each response is sealed to the Feedback Desk's public
key. Anonymity and confidentiality are different properties. A public Waku topic is readable by anyone,
so plaintext would broadcast the optional Contact field and make criticism publicly attributable.
Sealing to the Desk keeps the contact field and makes it safe.

- The Feedback app bundles the Desk's static public key and seals each response with a libsodium sealed
  box (anonymous sender, recipient-only decryption). No sender key, no account. Only the Desk's private
  key decrypts.
- This composes with everything else: sealed bytes publish, store and backfill normally; the Desk
  decrypts after receiving or pulling.
- UI copy becomes "Only the Logos team can read your response", which encourages honest contact details
  and candid feedback.

Payload (sealed), anonymous JSON:

```
{ "v":1, "kind":"quick|questionnaire", "title"?, "topic"?,
  "message"|"answers":{...}, "contact"?, "build":"<auto>", "ts":<unix ms> }
```

**Size limits** (Waku message size, the sealed box, Discord's 2000-char post, and abuse control):
title 120, message 2000, contact 200, each questionnaire answer 1000, at most 10 answers, and a hard
cap of 8192 bytes on the whole decrypted payload. The Feedback app enforces them in the UI and before
sealing; the Feedback Desk re-checks on decrypt (a sender could bypass the UI) and skips anything over.

**Wire format:** the Feedback app sends `base64(sealed-ciphertext)` as the Waku payload (keeps it
text-safe); delivery base64-wraps the payload again inside events, so the Desk base64-decodes twice
then opens the sealed box. Verified end-to-end: `desk.py` brought up a devnet node, backfilled a sealed
message via `storeQuery`, decrypted and stored it, and deduped a re-run.

For v1 this is one-way (no replies) and team-only. A two-way variant (private replies to an anonymous
submitter) is possible later with a per-submission ephemeral key, out of scope here.

## Keys and decryption (no recovery phrase for anyone)

The decryption key is an operator deployment key, not a wallet seed. No one types a recovery phrase.

- **Senders need no key.** A sealed box encrypts to the Desk's public key using a per-message ephemeral
  key the library generates; the sender holds nothing and stays anonymous. No seed, no account.
- **Feedback Desk holds one static X25519 keypair.** The public key is baked into the Feedback app at
  build time. The private key is a deployment secret on the Desk host.
- **Decryption is automatic and headless.** The Desk opens each sealed message in-process with its
  private key. No human tap, no phrase to type.
- **Recovery is a key backup.** The private key is 32 bytes of config, not a mnemonic. Rebuild the host,
  redeploy the same key, and past and future messages still decrypt. Lose it and messages sealed to it
  cannot be read.
- **Rotation.** Generate a new keypair and ship a Feedback app update carrying the new public key. Keep
  the old private key until old messages are drained.
- **Optional hardening (not v1).** Hold the private key in the Logos keystore/keycard so it never sits
  on disk. Trade-off: decryption then needs a keycard tap, which a headless always-on Desk cannot do,
  so v1 uses the deployment-key model.

## Who receives (Option A: one Desk, shared view)

The whole team receives via a shared view, decoupled from decryption. Decided: **one Feedback Desk
decrypts, then bridges each response into a private Discord channel** (a channel webhook) that the team
reads. "We both receive" means both are in that channel; it scales to the team for free.

- **Secrets on the Desk host** (never in any repo): the Desk private key + the Discord webhook URL.
- **Dedup by `messageHash`** so Store backfill on restart does not re-post old feedback into the channel.
- **Privacy boundary:** confidentiality now rests on that channel being locked down, and the optional
  Contact field (PII) lands in Discord, a centralized service. Acceptable as a testnet interim; a
  dashboard or a Logos-native destination can replace the bridge later.
- **Alternative, not now:** encrypt-to-many, so each recipient decrypts independently (wrap a content
  key per recipient public key). More build, and adding a teammate means a Feedback app update.

## Transport mechanics (delivery_module)

- **Shared node, adopt-or-create.** Try `createNode(devnet cfg)`; on `Context already initialized`,
  probe `getNodeInfo("Version")`; an answer means another module owns the node, so adopt it.
- **Topics are per-app and live** (`subscribe`/`unsubscribe`, no restart). **Cluster is locked by the
  first caller**; Feedback cannot switch it without `stop()`, which tears down other apps' node.
- `send(contentTopic, payload)` is non-ephemeral (retained for Store). Outcomes arrive as events:
  `messageQueued` (RLN budget wait, not a failure), `messagePropagated`, `messageSent` (success) or
  `messageError`. Correlate by `requestId`.
- Content topics are four segments, `/app/version/name/encoding`, for example
  `/logos-feedback/1/quick/json`.

## Cluster-fit detection and degraded mode

Because Feedback adopts whatever node is live, it detects fit and degrades rather than failing or
asking the user to close apps.

Fit signal is `rlnState()`:

| rlnState | Meaning | Feedback send |
|---|---|---|
| `Disabled` | preset has no RLN (the devnet target) | sends freely |
| `Ready` + funded membership | RLN on, has quota | works; sends queue for budget then propagate |
| `Ready`, no membership / `Failed` | RLN required, cannot prove | blocked, degraded mode |
| `Initializing` | RLN coming up | wait on `rlnStateChanged` |

A probe-send confirms the ground truth (`messageSent`/`messagePropagated` versus a stuck
`messageQueued` or `messageError`).

Degraded mode is a local queue with auto-retry, not a "close all apps" prompt (that is heavy and
non-deterministic, since first-caller-wins just re-rolls). On blocked: save the draft locally, show one
calm banner ("saved, will send when messaging allows"), and a background watcher flushes the queue when
`rlnStateChanged` reaches a sendable state.

## Feedback Desk

- **Multi-cluster.** One delivery node per cluster in a short, curated list, covering the union of
  clusters users run on (edited as fleets change).
- **Live path.** Subscribe to the feedback topics, receive `messageReceived` (`source: live`), decrypt
  with the Desk private key, append to a local store, dedup by `messageHash`, and post the decrypted
  response to the team's private Discord channel (webhook). Dedup prevents re-posting on backfill.
- **Backfill path (verified).** `storeQuery` pulls history for anything missed while offline. Required
  query keys: `requestId`, `includeData`, `paginationForward`; plus optional `contentTopics`,
  `timeStart`/`timeEnd`. Note: not every peer serves Store, so query a vetted store peer or run our own
  store-enabled node (the Feedback Desk should be that node).
- Holds the Desk private key for decryption; runs on an always-on host we operate.

## What is verified

Run against a live Logos devnet node (delivery_module 0.3.0), 2026-11-04:

- **RLN-free send.** Preset `logos.dev`, node Connected, `rlnState: Disabled` (even with the RLN module
  loaded). `subscribe` then `send` produced `messageSent`, `messagePropagated` and `messageReceived`,
  with no `messageQueued` or `messageError` and no RLN budget activity. No membership needed.
- **Store backfill.** Three messages sent, then `storeQuery` returned all three (statusCode 200,
  `ephemeral:false`). One queried peer served Store; another failed to dial, hence the vetted-peer note.
- **Full sealed loop.** A feedback payload sealed to the Desk public key, sent over devnet, retrieved
  via `storeQuery`, and decrypted with the Desk private key recovered the exact original payload, with
  the size limits enforced on open. The whole pipeline (seal, send, store, decrypt, validate) works.

## Implementation

- `feedback_desk/feedback_common.py` — shared contract: payload schema, size limits, and the
  seal/open crypto (libsodium sealed box). The Feedback app reimplements `seal` in C with the same
  primitive.
- `feedback_desk/desk.py` — the Desk service: drives delivery via logosctl, receives on the topics,
  decrypts, enforces limits, stores with dedup, backfills via `storeQuery`, bridges to a Discord
  webhook.
- `tools/gen_keys.py` — generates the Desk keypair (public key for the app, private key a host secret).
- Secrets (private key, webhook URL) are gitignored and live only on the Desk host.

## Open questions

1. Hosting the Feedback Desk (always-on node that is the Store peer and decryptor).
2. Devnet topic names for the quick form and the questionnaire.
3. Store retention window needed on the store node.

Decided: target devnet (`logos.dev`, RLN disabled, verified); seal-to-Desk encryption, team-only,
one-way for v1, operator deployment key (no recovery phrase); recipients = Option A (one Desk decrypts,
bridges to a private Discord channel; team reads there); no reliance on fleet standardization (Feedback
Desk covers the union).
