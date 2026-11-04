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


def ensure_node(cfg: dict) -> None:
    """Bring up the daemon + a devnet delivery node (adopt-or-create), wait until Connected.

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
        # Wire contract: the Feedback app sends base64(sealed-ciphertext) as the Waku payload
        # (keeps the payload text-safe). Delivery then base64-wraps the payload in events, so:
        wire = base64.b64decode(payload_b64)   # event wrapper -> the base64(ciphertext) text
        ciphertext = base64.b64decode(wire)    # wire -> raw sealed-box ciphertext
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
    print("[desk] bringing up devnet node…")
    ensure_node(cfg)
    for topic in cfg["topics"]:
        lc(cfg, "call", "delivery_module", "subscribe", topic)
    print("[desk] backfilling…")
    backfill(cfg, store)
    print("[desk] watching live…")
    watch_live(cfg, store)


if __name__ == "__main__":
    main()
