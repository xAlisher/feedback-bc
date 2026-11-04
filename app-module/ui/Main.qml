// feedback_ui — send feedback on Basecamp. Two forms (quick + questionnaire); each response is
// sealed by feedback_core (crypto_box_seal to the Desk key) and published over devnet via
// delivery_module. Built with the Logos design system; responsive at 390 / 700 / 1280.
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.LocalStorage 2.15
import Logos.Controls
import Logos.Theme

Rectangle {
    id: root
    objectName: "feedbackRoot"
    width: 420; height: 760
    color: Theme.palette.background

    // ---- config ----
    readonly property string quickTopic: "/logos-feedback/1/quick/json"
    readonly property string questTopic: "/logos-feedback/1/questionnaire/json"
    readonly property var topics: ["app","package-manager","node","wallet","delivery","messaging","onboarding","other"]
    readonly property string appBuild: "0.1.0"
    readonly property string nodeCfg: JSON.stringify({
        logLevel:"ERROR", mode:"Core", preset:"logos.dev", relay:true, clusterId:2,
        tcpPort:0, discv5UdpPort:0,
        entryNodes:[
          "/dns4/node-01.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmQ9X2xDfPG3uL77V9piYDhjq14JhKCtcmNYsTMKNqrKCj",
          "/dns4/node-02.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmUuXhUW9bdJpzN1kfDziFiUZo4bszTk66cvr7uuyCHXR7"]
    })

    // ---- responsive ----
    readonly property bool compact: width < 600
    readonly property int formW: Math.min(width - 2 * Theme.spacing.xlarge, 560)

    // ---- state ----
    property string connState: "connecting"   // connecting | ready
    property string rlnState: "unknown"
    property int tab: 0                        // 0 quick, 1 questionnaire
    property bool sent: false
    property string note: ""
    property int qRating: 0
    property var pending: []
    property int pendingCount: 0

    function callMod(mod, method, params) {
        var raw = logos.callModule(mod, method, params || [])
        if (!raw || raw === "") return null
        try {
            var v = JSON.parse(raw)
            if (typeof v === "string") v = JSON.parse(v)  // host double-encodes a module's QString return
            return v
        } catch (e) { return { _raw: raw } }
    }

    // ---- delivery bring-up (adopt-or-create) ----
    function bringUp() {
        callMod("delivery_module", "createNode", [root.nodeCfg])  // "already initialized" -> adopt
        callMod("delivery_module", "start", [])
    }
    Timer {
        interval: 1500; running: true; repeat: true
        onTriggered: {
            var cs = callMod("delivery_module", "getConnectionStatus", [])
            var v = cs ? (cs.value || cs.result || "") : ""
            var rs = callMod("delivery_module", "rlnState", [])
            root.rlnState = rs && rs.value ? (rs.value.state || "unknown") : (rs && rs.state ? rs.state : "unknown")
            if (String(v).indexOf("Connected") >= 0) root.connState = "ready"
        }
    }
    Component.onCompleted: { bringUp(); loadQueue() }

    // ---- degraded-mode queue (local, persisted) + auto-retry ----
    function _db() {
        try { return LocalStorage.openDatabaseSync("feedback_ui_queue", "1.0", "feedback drafts", 200000) }
        catch (e) { return null }
    }
    function loadQueue() {
        var db = _db(); if (!db) return
        try { db.transaction(function(tx) {
            tx.executeSql("CREATE TABLE IF NOT EXISTS q(payload TEXT)")
            var rs = tx.executeSql("SELECT payload FROM q"); var arr = []
            for (var i = 0; i < rs.rows.length; i++) { try { arr.push(JSON.parse(rs.rows.item(i).payload)) } catch (e) {} }
            root.pending = arr; root.pendingCount = arr.length
        }) } catch (e) {}
    }
    function saveQueue() {
        var db = _db(); if (!db) return
        try { db.transaction(function(tx) {
            tx.executeSql("CREATE TABLE IF NOT EXISTS q(payload TEXT)"); tx.executeSql("DELETE FROM q")
            for (var i = 0; i < root.pending.length; i++) tx.executeSql("INSERT INTO q VALUES(?)", [JSON.stringify(root.pending[i])])
        }) } catch (e) {}
    }
    function trySend(payload) {
        if (root.connState !== "ready") return false
        var sealed = callMod("feedback_core", "seal", [JSON.stringify(payload)])
        if (!sealed || !sealed.ok) return false
        var topic = payload.kind === "questionnaire" ? root.questTopic : root.quickTopic
        var r = callMod("delivery_module", "send", [topic, sealed.ciphertext_b64])
        return !!(r && (r.value || r.result) && !(r.error))
    }
    function submit(payload) {
        payload.v = 1; payload.ts = Date.now(); payload.build = root.appBuild
        if (root.trySend(payload)) { root.sent = true; root.note = "" }
        else {
            root.pending.push(payload); root.pendingCount = root.pending.length; root.saveQueue()
            root.sent = true
            root.note = "Saved — will send when messaging is ready (" + root.pendingCount + " queued)."
        }
    }
    function flushQueue() {
        if (root.pending.length === 0 || root.connState !== "ready") return
        var still = []
        for (var i = 0; i < root.pending.length; i++) if (!root.trySend(root.pending[i])) still.push(root.pending[i])
        if (still.length !== root.pending.length) { root.pending = still; root.pendingCount = still.length; root.saveQueue() }
    }
    Timer { interval: 4000; running: true; repeat: true; onTriggered: root.flushQueue() }

    // ---- UI ----
    LogosScrollView {
        anchors.fill: parent
        contentWidth: availableWidth

        ColumnLayout {
            width: root.formW
            x: Math.max(Theme.spacing.xlarge, (root.width - width) / 2)
            y: Theme.spacing.xlarge
            spacing: Theme.spacing.large

            // header + status
            RowLayout {
                Layout.fillWidth: true; spacing: Theme.spacing.small
                LogosText { text: "Feedback"; font.pixelSize: 24; font.weight: Theme.typography.weightBold; Layout.fillWidth: true }
                Rectangle {
                    width: 9; height: 9; radius: 4.5; Layout.alignment: Qt.AlignVCenter
                    color: root.connState === "ready" ? Theme.palette.success : Theme.palette.textTertiary
                }
                LogosText { text: root.connState; color: Theme.palette.textTertiary; font.pixelSize: 12 }
            }

            // degraded banner
            Rectangle {
                Layout.fillWidth: true; radius: Theme.spacing.radiusSmall
                color: Theme.palette.surface; border.color: Theme.palette.primary; border.width: 1
                Layout.preferredHeight: bannerT.implicitHeight + 2 * Theme.spacing.small
                visible: root.pendingCount > 0
                LogosText {
                    id: bannerT; anchors.fill: parent; anchors.margins: Theme.spacing.small
                    wrapMode: Text.WordWrap; color: Theme.palette.primary; font.pixelSize: 12
                    text: "⏳ " + root.pendingCount + " saved — will send when messaging is ready."
                }
            }

            // tabs
            RowLayout {
                Layout.fillWidth: true; spacing: 0; visible: !root.sent
                Repeater {
                    model: ["Quick", "Questionnaire"]
                    LogosTabButton { text: modelData; checked: root.tab === index; Layout.fillWidth: true; onClicked: root.tab = index }
                }
            }

            // ---- Quick form ----
            ColumnLayout {
                Layout.fillWidth: true; spacing: Theme.spacing.medium
                visible: !root.sent && root.tab === 0
                LogosTextField { id: qTitle; Layout.fillWidth: true; placeholderText: "Title"
                    onTextChanged: if (text.length > 120) text = text.slice(0, 120) }
                LogosComboBox { id: qTopic; Layout.fillWidth: true; model: root.topics }
                LogosTextArea { id: qMsg; Layout.fillWidth: true; Layout.minimumHeight: 128
                    placeholderText: "What happened? What would you change?"
                    wrapMode: TextArea.Wrap
                    onTextChanged: if (text.length > 2000) text = text.slice(0, 2000) }
                LogosText { text: qMsg.text.length + " / 2000"; color: Theme.palette.textTertiary; font.pixelSize: 11; Layout.alignment: Qt.AlignRight }
                LogosTextField { id: qContact; Layout.fillWidth: true; placeholderText: "Contact (optional)"
                    onTextChanged: if (text.length > 200) text = text.slice(0, 200) }
                LogosText { text: "Only the Logos team can read your response."; color: Theme.palette.textTertiary; font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                LogosButton {
                    Layout.fillWidth: true; variant: LogosButton.Variant.Primary
                    text: "Send"
                    enabled: root.connState !== "connecting" && (qTitle.text.length > 0 || qMsg.text.length > 0)
                    onClicked: root.submit({ kind:"quick", title:qTitle.text, topic:root.topics[qTopic.currentIndex], message:qMsg.text, contact:qContact.text })
                }
            }

            // ---- Questionnaire ----
            ColumnLayout {
                Layout.fillWidth: true; spacing: Theme.spacing.large
                visible: !root.sent && root.tab === 1
                LogosText { text: "1. Rate Basecamp so far (1 poor – 5 great)"; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                RowLayout {
                    spacing: Theme.spacing.small
                    Repeater {
                        model: 5
                        LogosButton {
                            text: (index + 1); Layout.fillWidth: true
                            variant: root.qRating === index + 1 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
                            onClicked: root.qRating = index + 1
                        }
                    }
                }
                QQ { id: a2; prompt: "2. What has Basecamp been useful for?" }
                QQ { id: a3; prompt: "3. Which modules/apps are you most excited about?" }
                QQ { id: a4; prompt: "4. One thing you'd improve right now?" }
                LogosButton {
                    Layout.fillWidth: true; variant: LogosButton.Variant.Primary
                    text: "Submit"
                    enabled: root.connState !== "connecting" && root.qRating > 0
                    onClicked: root.submit({ kind:"questionnaire", answers:{ q1:root.qRating, q2:a2.answer, q3:a3.answer, q4:a4.answer } })
                }
            }

            // ---- confirmation ----
            ColumnLayout {
                Layout.fillWidth: true; spacing: Theme.spacing.medium; visible: root.sent
                LogosText { text: "Thanks — your feedback was sent."; font.pixelSize: 18 }
                LogosText { text: root.note; color: Theme.palette.textTertiary; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true; visible: root.note.length > 0 }
                LogosButton { text: "Send another"; variant: LogosButton.Variant.Secondary
                    onClicked: { qTitle.text=""; qMsg.text=""; qContact.text=""; root.qRating=0; a2.answer=""; a3.answer=""; a4.answer=""; root.note=""; root.sent=false } }
            }
        }
    }

    component QQ: ColumnLayout {
        id: qq
        property alias answer: ta.text
        property string prompt
        Layout.fillWidth: true; spacing: Theme.spacing.tiny
        LogosText { text: qq.prompt; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        LogosTextArea { id: ta; Layout.fillWidth: true; Layout.minimumHeight: 76; wrapMode: TextArea.Wrap
            onTextChanged: if (text.length > 1000) text = text.slice(0, 1000) }
    }
}
