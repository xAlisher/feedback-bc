# Basecamp Feedback App — design spec

A native in-Basecamp feedback app for the testnet phase: a quick feedback form reachable from the
Basecamp shell, plus a short questionnaire, both built on the Logos delivery module. This is a draft
for discussion, not a final design.

Status: draft v0.2 (2026-11-04). Stack claims are grounded in the public `delivery_module` v0.3.0
contract and in live send and Store round-trips run against a Logos devnet node on 2026-11-04.

---

## Why native

A native app in the official repo is the cleanest in-Basecamp path. A web form (Typeform/CryptPad)
sends users off-platform, and third-party feedback apps cannot currently be linked from inside
Basecamp. A native app, built on delivery, is linkable from any Basecamp view and keeps feedback on
the Logos stack (which also dogfoods delivery during testnet).

## Architecture: two modules

| Module | Where | Role |
|---|---|---|
| **feedback_sender** | official repo (once tested) | the two forms + publish; linkable from the shell |
| **feedback_receiver** | separate repo / host | collect + store responses; also acts as the Store peer |

Both wrap `delivery_module` (Waku). The receiver's node doubles as the Store peer used for backfill,
so the receiving side owns the one always-on component.

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
- If feedback is the first or only delivery user, it creates the node on devnet and RLN is avoided.
- If another app (for example chat, which defaults to `logos.test`) already owns the node, feedback
  adopts that cluster and may land on an RLN fleet with no membership, so it cannot send.

Because standardizing every Basecamp onto one fleet is not expected near-term, the sender detects fit
and degrades gracefully (below), and the receiver covers the union of clusters users run on.

## Message payload and encryption (seal-to-receiver)

Responses are **anonymous and confidential**: each response is sealed to the receiver's public key.
Anonymity and confidentiality are different properties. A public Waku topic is readable by anyone, so
plaintext would broadcast the optional Contact field and make criticism publicly attributable. Sealing
to the receiver keeps the contact field and makes it safe.

- The sender bundles the receiver's static public key and seals each response with a libsodium sealed
  box (anonymous sender, recipient-only decryption). No sender key, no account. Only the receiver's
  private key decrypts.
- This composes with everything else: sealed bytes publish, store and backfill normally; the receiver
  decrypts after receiving or pulling.
- UI copy becomes "Only the Logos team can read your response", which encourages honest contact details
  and candid feedback.

Payload (sealed), anonymous JSON:

```
{ "v":1, "kind":"quick|questionnaire", "title"?, "topic"?,
  "message"|"answers":{...}, "contact"?, "build":"<auto>", "ts":<unix ms> }
```

For v1 this is one-way (no replies) and team-only. A two-way variant (private replies to an anonymous
submitter) is possible later with a per-submission ephemeral key, out of scope here.

## Transport mechanics (delivery_module)

- **Shared node, adopt-or-create.** Try `createNode(devnet cfg)`; on `Context already initialized`,
  probe `getNodeInfo("Version")`; an answer means another module owns the node, so adopt it.
- **Topics are per-app and live** (`subscribe`/`unsubscribe`, no restart). **Cluster is locked by the
  first caller**; the sender cannot switch it without `stop()`, which tears down other apps' node.
- `send(contentTopic, payload)` is non-ephemeral (retained for Store). Outcomes arrive as events:
  `messageQueued` (RLN budget wait, not a failure), `messagePropagated`, `messageSent` (success) or
  `messageError`. Correlate by `requestId`.
- Content topics are four segments, `/app/version/name/encoding`, for example
  `/logos-feedback/1/quick/json`.

## Cluster-fit detection and degraded mode

Because the sender adopts whatever node is live, it detects fit and degrades rather than failing or
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

## Receiver

- **Multi-cluster.** One delivery node per cluster in a short, curated list, covering the union of
  clusters users run on (edited as fleets change).
- **Live path.** Subscribe to the feedback topics, receive `messageReceived` (`source: live`), decrypt,
  append to a local store, dedup by `messageHash`.
- **Backfill path (verified).** `storeQuery` pulls history for anything missed while offline. Required
  query keys: `requestId`, `includeData`, `paginationForward`; plus optional `contentTopics`,
  `timeStart`/`timeEnd`. Note: not every peer serves Store, so query a vetted store peer or run our own
  store-enabled node (the receiver should be that node).
- Holds the receiver private key for decryption.

## What is verified

Run against a live Logos devnet node (delivery_module 0.3.0), 2026-11-04:

- **RLN-free send.** Preset `logos.dev`, node Connected, `rlnState: Disabled` (even with the RLN module
  loaded). `subscribe` then `send` produced `messageSent`, `messagePropagated` and `messageReceived`,
  with no `messageQueued` or `messageError` and no RLN budget activity. No membership needed.
- **Store backfill.** Three messages sent, then `storeQuery` returned all three (statusCode 200,
  `ephemeral:false`). One queried peer served Store; another failed to dial, hence the vetted-peer note.

## Open questions

1. Hosting the receiver (always-on node that is the Store peer and decryptor).
2. Devnet topic names for the quick form and the questionnaire.
3. Store retention window needed on the store node.

Decided: target devnet (`logos.dev`, RLN disabled, verified); seal-to-receiver encryption, team-only,
one-way for v1; no reliance on fleet standardization (receiver covers the union).
