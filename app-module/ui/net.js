.pragma library
// Network logic for feedback_ui, kept out of Main.qml so it can be tested without a Basecamp
// (test/net.test.mjs). No Qt APIs in here.

// logos.test (cluster 2) WITHOUT the preset name: delivery_module turns its RLN send gate on for the
// preset NAME "logos.test" only (src/rln_presets.cpp), so we spell the network out instead.
// Mirrors logos-delivery's LogosTestConf; same set loam_core uses (nodeConfig(rln=false)). #2
var TESTNET_CLUSTER = 2
var ENTRY_NODES = [
    "/dns4/node-01.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmQ9X2xDfPG3uL77V9piYDhjq14JhKCtcmNYsTMKNqrKCj",
    "/dns4/node-02.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmB8NYprrfQrgWVzsJtYWkfjsXbmJEGNMG6othXsQ53BwG",
    "/dns4/node-01.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmF8WtwGPmeGHgYAX2277jHgy5cW9F7zsB8EqUjBZQAZQ3",
    "/dns4/node-02.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmUuXhUW9bdJpzN1kfDziFiUZo4bszTk66cvr7uuyCHXR7",
    "/dns4/node-01.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmL3oU95jh1BZHozn3uNhx8HEneirgr8M1jEAapzXGDqRF",
    "/dns4/node-02.ac-cn-hongkong-c.logos.test.status.im/tcp/30303/p2p/16Uiu2HAm28CoBZjpyxsanC8tQpbvZ7bZJnVYuB1EgFzb571qpWsV"
]

function nodeConfig() {
    return JSON.stringify({
        logLevel: "ERROR", mode: "Core", relay: true, tcpPort: 0, discv5UdpPort: 0,
        preset: "", clusterId: TESTNET_CLUSTER, numShardsInNetwork: 8, maxMessageSize: "150KiB",
        discv5Discovery: true, enableKadDiscovery: true, reliabilityEnabled: true,
        entryNodes: ENTRY_NODES
    })
}

// A module call's answer, as Main.qml's callMod returns it, in any shape a Basecamp build uses:
// {success, value, error}; that object under "result"; {"result": <bare value>}; a bare value; or
// {_raw} when it wasn't JSON. Returns {ok, value, error}. (0.3.2 and the newer builds differ.)
function isResultObj(o) { return o !== null && typeof o === "object" && ("success" in o || "value" in o || "error" in o) }
function unwrap(r) {
    if (r === null || r === undefined) return { ok: false, value: null, error: "no answer" }
    if (typeof r !== "object") return { ok: true, value: r, error: "" }
    if ("_raw" in r) return { ok: true, value: r._raw, error: "" }
    var x = r
    if (!isResultObj(x) && ("result" in x)) {
        if (isResultObj(x.result)) x = x.result
        else return { ok: true, value: x.result, error: "" }
    }
    if (!isResultObj(x)) return { ok: true, value: x, error: "" }
    var err = x.error ? String(x.error) : ""
    var ok = x.success === undefined ? !err : (x.success === true && !err)
    return { ok: ok, value: x.value !== undefined ? x.value : null, error: err }
}

// createNode refused because another module created the node first.
function isAlreadyInitialized(err) {
    return String(err || "").toLowerCase().indexOf("already initialized") >= 0
}

// ---- ENR -> cluster ----
// The ENR's "rs" (relay sharding) entry is a 2-byte cluster id, a 1-byte count, then 2-byte shards.
var B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function b64urlBytes(s) {
    s = String(s).replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "")
    var out = [], val = 0, bits = 0
    for (var i = 0; i < s.length; i++) {
        var c = B64.indexOf(s.charAt(i))
        if (c < 0) return null
        val = (val << 6) | c; bits += 6
        if (bits >= 8) { bits -= 8; out.push((val >> bits) & 0xff) }
    }
    return out
}
// Minimal RLP: returns [item, nextIndex]; item is a byte array or an array of items.
function rlp(d, i) {
    var p = d[i]
    if (p === undefined) throw "rlp: out of range"
    if (p < 0x80) return [[p], i + 1]
    if (p < 0xb8) { var l = p - 0x80; return [d.slice(i + 1, i + 1 + l), i + 1 + l] }
    if (p < 0xc0) { var ll = p - 0xb7, L = num(d.slice(i + 1, i + 1 + ll)), s = i + 1 + ll; return [d.slice(s, s + L), s + L] }
    var len, start
    if (p < 0xf8) { len = p - 0xc0; start = i + 1 }
    else { var ll2 = p - 0xf7; len = num(d.slice(i + 1, i + 1 + ll2)); start = i + 1 + ll2 }
    var items = [], j = start
    while (j < start + len) { var r = rlp(d, j); items.push(r[0]); j = r[1] }
    return [items, start + len]
}
function num(bytes) { var n = 0; for (var i = 0; i < bytes.length; i++) n = n * 256 + bytes[i]; return n }
function str(bytes) { var s = ""; for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]); return s }

// "enr:-K24…" -> cluster id, or -1 when it can't be read.
function clusterFromEnr(enr) {
    try {
        enr = String(enr || "")
        if (enr.indexOf("enr:") !== 0) return -1
        var bytes = b64urlBytes(enr.slice(4))
        if (!bytes) return -1
        var rec = rlp(bytes, 0)[0]
        for (var k = 2; k + 1 < rec.length; k += 2) {
            if (str(rec[k]) === "rs") { var rs = rec[k + 1]; return rs.length >= 2 ? num(rs.slice(0, 2)) : -1 }
        }
    } catch (e) {}
    return -1
}

// ---- rlnState -> gated? ----
// rlnState answers {state, message, …}: "Disabled" = no send gate. Anything else (Initializing,
// Ready, Failed) means the node was started RLN-on; "Ready" does not prove a membership. #4
function rlnStateName(v) {
    if (v && typeof v === "object") return String(v.state || "")
    return String(v || "")
}
function rlnGated(state) { return state !== "" && state !== "Disabled" }

// ---- the node, classified ----
// facts: {adopted, cluster, rln, unconfirmed}
//   adopted     : createNode said "already initialized" (another app owns the node's config)
//   cluster     : from the ENR (-1 unknown)
//   rln         : rlnState name ("" unknown)
//   confirmed   : delivery confirmed one of our sends on this node (so it does send, e.g. a membership)
//   noAnswer    : delivery hasn't answered a status call for a while (crashed, or never started)
// -> "ok" | "checking" | "wrongNetwork" | "rlnBlocked" | "unreachable"
// An RLN-gated node another app created is reported at once, before any send: without a membership
// (there is no self-serve one yet) every send would stall silently.
function classify(f) {
    if (f.noAnswer) return "unreachable"
    if (f.cluster === undefined || f.cluster < 0) return "checking"
    if (f.cluster !== TESTNET_CLUSTER) return "wrongNetwork"
    if (f.adopted) {
        if (f.rln === undefined || f.rln === "") return "checking"
        if (rlnGated(f.rln) && !f.confirmed) return "rlnBlocked"
    }
    return "ok"
}

function canSend(netState) { return netState === "ok" }

// The user restarted as we advised, and another app still started messaging first (#6).
// A Basecamp process creates its node once, with a fresh peer id; reopening Feedback in the same
// process sees the same node. So: advised on one node, blocked again on a different one = a loop,
// e.g. once Basecamp starts delivery at launch (logos-co/logos-basecamp#275).
function isLoop(advisedPeer, currentPeer) {
    return !!advisedPeer && !!currentPeer && advisedPeer !== currentPeer
}

// What we tell the user (null = nothing to say). afterRestart: restarting already didn't help.
function bannerText(netState, afterRestart) {
    if (netState === "wrongNetwork")
        return afterRestart
            ? "Messaging is on a different network again after a restart: another app starts it before Feedback can. Feedback can't send from this Basecamp for now. Your feedback is saved."
            : "Another app (for example Chat) started messaging on a different network, so Feedback can't reach the testnet. Close that app, quit Basecamp, start it again and open Feedback first. Your feedback is saved and will send then."
    if (netState === "unreachable")
        return "Messaging isn't answering. If another app (for example Chat) started it, it may have stopped. Close that app, quit Basecamp, start it again and open Feedback first. Your feedback is saved and will send then."
    if (netState === "rlnBlocked")
        return afterRestart
            ? "Messaging starts with RLN on again after a restart: another app starts it before Feedback can. Feedback can send once this Basecamp has an RLN membership. Your feedback is saved."
            : "Another app (for example Chat) started messaging with RLN on, and this Basecamp has no RLN membership, so Feedback can't send. Close that app, quit Basecamp, start it again and open Feedback first. Your feedback is saved and will send then."
    return null
}

// The status pill: checking until the node is classified, then the honest state (#4).
// -> {text, tone} with tone "neutral" | "success" | "warning" | "error"
function pill(netState, deliveryStatus) {
    if (netState === "wrongNetwork" || netState === "rlnBlocked" || netState === "unreachable") return { text: "Can't send", tone: "error" }
    if (netState !== "ok") return { text: "Checking delivery…", tone: "neutral" }
    var s = String(deliveryStatus || "")
    if (s.indexOf("Connected") >= 0 && s.indexOf("Disconnected") < 0) return { text: "Delivery connected", tone: "success" }
    return { text: "Delivery reconnecting…", tone: "warning" }
}
