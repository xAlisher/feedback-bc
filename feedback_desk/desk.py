#!/usr/bin/env python3
"""Feedback Desk — collector service (issues #10-#14).

Drives delivery_module via logosctl, receives sealed feedback on the testnet topics,
decrypts with the Desk private key, enforces size limits, stores locally with dedup,
backfills via storeQuery on startup, and bridges each response to a private Discord
channel webhook.

Wire format (production): the Waku payload is the raw sealed-box ciphertext; delivery
hands it to us base64-wrapped in events, so we base64-decode once then open_sealed().

A watchdog checks the delivery daemon every minute and exits the Desk when it is gone or stays
disconnected, so systemd (Restart=always) brings everything back and backfill recovers what was
missed (#20). A heartbeat line every 10 minutes tells a quiet Desk from a dead one.

Run: python3 desk.py config.json   (see config.example.json)
Secrets (private key file, webhook URL) come from config/host, never the repo.
"""
from __future__ import annotations
import base64
import json
import os
import subprocess
import sys
import threading
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


def ensure_node(cfg: dict) -> None:
    """Bring up the daemon + a testnet delivery node (adopt-or-create), wait until Connected.

    Readiness is confirmed by a successful `module load` (retried), not by the `status`
    subcommand, which can hang right after a daemon restart.
    """
    subprocess.Popen([cfg["logosctl"], "--config-dir", cfg["session_dir"], "-D"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(12):  # wait for the daemon to accept commands
        try:
            out = lc(cfg, "module", "load", "delivery_module", timeout=20)
        except subprocess.TimeoutExpired:
            out = ""
        if '"status":"ok"' in out or "loaded" in out:
            break
        time.sleep(3)
    cn = lc(cfg, "call", "delivery_module", "createNode", json.dumps(cfg["node_config"]), timeout=45)
    if "already initialized" in cn:
        print("[desk] adopting existing delivery node")
    lc(cfg, "call", "delivery_module", "start", timeout=20)
    for i in range(18):
        if '"value":"Connected"' in lc(cfg, "call", "delivery_module", "getConnectionStatus", timeout=15):
            print(f"[desk] node Connected ({i*5}s)")
            return
        time.sleep(5)
    print("[desk] warning: node not fully Connected; proceeding (PartiallyConnected may still work)")


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


def _open_payload(priv: str, payload_b64: str) -> dict:
    """Recover + open the sealed payload. Delivery base64-wraps the Waku payload in events/store;
    after undoing that wrapper the payload is either the raw ciphertext (C app sends bytes) or
    base64(ciphertext) (text-safe wire / CLI). The live and store paths differ by one base64 layer,
    so try opening at both depths and use whichever decrypts; a wrong depth simply fails to open.
    """
    def _b64(b):
        if isinstance(b, str):
            b = b.encode()
        return base64.b64decode(b + b"=" * (-len(b) % 4))  # tolerate missing padding
    candidates = []
    try:
        raw = _b64(payload_b64)      # undo the delivery event/store base64 wrapper
        candidates.append(raw)
        try:
            candidates.append(_b64(raw))  # wire = base64(ciphertext): one more layer
        except Exception:
            pass
    except Exception:
        pass
    last: Exception = fc.FeedbackError("no decodable ciphertext")
    for ct in candidates:
        try:
            return fc.open_sealed(priv, ct)
        except fc.FeedbackError:
            raise  # a size/validation failure is terminal, not a wrong-depth guess
        except Exception as e:
            last = e
    raise last


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
    # Discord 403s the default python-urllib User-Agent; set an explicit one.
    req = urllib.request.Request(url, data=data, headers={
        "Content-Type": "application/json",
        "User-Agent": "FeedbackDesk/1.0 (+https://github.com/xAlisher/feedback-bc)",
    })
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:  # a failed post must not drop the (already-stored) feedback
        print(f"[warn] discord post failed: {e}", file=sys.stderr)


def handle(cfg: dict, store: Store, mhash: str, topic: str, payload_b64: str, source: str) -> None:
    if not mhash or not store.is_new(mhash):
        return  # dedup: skip already-seen (prevents re-posting on backfill/restart)
    try:
        payload = _open_payload(cfg["_priv"], payload_b64)  # decrypt + size limits
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


def connection_status(cfg: dict) -> str:
    """delivery_module's connection status, or "" when the daemon or module doesn't answer."""
    try:
        out = lc(cfg, "call", "delivery_module", "getConnectionStatus", timeout=20)
    except subprocess.TimeoutExpired:
        return ""
    if "NO_DAEMON" in out:
        return ""
    try:
        res = json.loads(out)["result"]
        return str(res.get("value") or "") if res.get("success") else ""
    except Exception:
        return ""


def watchdog(cfg: dict, proc: subprocess.Popen, state: dict) -> None:
    """Kill the watch stream when the node is gone, so watch_live returns and the Desk exits (#20).

    The 2026-11-06 failure: the daemon died, `logosctl watch` hung instead of exiting, and the
    Desk sat deaf for five days. A dead daemon or module must end the process, not stall it.
    """
    every = int(cfg.get("watchdog_interval_s", 60))
    max_fail = int(cfg.get("watchdog_max_failures", 3))            # no answer: ~3 min
    max_disc = int(cfg.get("watchdog_max_disconnected", 15))       # answering but peerless: ~15 min
    beat_every = int(cfg.get("heartbeat_interval_s", 600))
    fails = disc = 0
    last_beat = time.time()
    while proc.poll() is None:
        time.sleep(every)
        status = connection_status(cfg)
        fails = 0 if status else fails + 1
        disc = disc + 1 if status == "Disconnected" else 0
        reason = ""
        if fails >= max_fail:
            reason = f"delivery not answering for {fails} checks"
        elif disc >= max_disc:
            reason = f"node Disconnected for {disc} checks"
        if reason:
            state["reason"] = reason
            print(f"[desk] watchdog: {reason}; exiting so systemd restarts the Desk", flush=True)
            proc.kill()
            return
        if time.time() - last_beat >= beat_every:
            last = state.get("last_msg")
            age = f"{int((time.time() - last) / 60)} min ago" if last else "none since start"
            print(f"[desk] heartbeat: delivery {status or 'no answer'}, last message {age}", flush=True)
            last_beat = time.time()


def watch_live(cfg: dict, store: Store) -> None:
    proc = subprocess.Popen([cfg["logosctl"], "--config-dir", cfg["session_dir"],
                             "watch", "delivery_module"], stdout=subprocess.PIPE, text=True)
    state: dict = {}
    threading.Thread(target=watchdog, args=(cfg, proc, state), daemon=True).start()
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
        state["last_msg"] = time.time()
        handle(cfg, store, ev.get("arg0", ""), topic, pb64 or "", "live")
    # The stream ended (the watchdog killed it, or logosctl exited): never keep running deaf.
    print(f"[desk] watch stream ended ({state.get('reason', 'logosctl watch exited')}); exiting", flush=True)
    sys.exit(1)


def main() -> None:
    cfg = load_config(sys.argv[1] if len(sys.argv) > 1 else "config.json")
    store = Store(cfg["store_file"], cfg["seen_file"])
    print("[desk] bringing up testnet node…", flush=True)
    ensure_node(cfg)
    for topic in cfg["topics"]:
        lc(cfg, "call", "delivery_module", "subscribe", topic)
    print("[desk] backfilling…")
    backfill(cfg, store)
    print("[desk] watching live…")
    watch_live(cfg, store)


if __name__ == "__main__":
    main()
