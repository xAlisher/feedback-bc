// feedback_ui — send feedback on Basecamp. Two forms (quick + questionnaire); each response is
// sealed by feedback_core (crypto_box_seal to the Desk key) and published over devnet via
// delivery_module. All delivery + seal calls go through logos.callModule.
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Rectangle {
    id: root
    objectName: "feedbackRoot"
    width: 420; height: 720
    color: "#16181d"
    property color fg: "#e7e9ee"
    property color sub: "#9aa0ac"
    property color accent: "#4f8cff"

    // ---- config ----
    readonly property string quickTopic: "/logos-feedback/1/quick/json"
    readonly property string questTopic: "/logos-feedback/1/questionnaire/json"
    readonly property var topics: ["app","package-manager","node","wallet","delivery","messaging","onboarding","other"]
    readonly property string nodeCfg: JSON.stringify({
        logLevel:"ERROR", mode:"Core", preset:"logos.dev", relay:true, clusterId:2,
        tcpPort:0, discv5UdpPort:0,
        entryNodes:[
          "/dns4/node-01.do-ams3.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmQ9X2xDfPG3uL77V9piYDhjq14JhKCtcmNYsTMKNqrKCj",
          "/dns4/node-02.gc-us-central1-a.logos.test.status.im/tcp/30303/p2p/16Uiu2HAmUuXhUW9bdJpzN1kfDziFiUZo4bszTk66cvr7uuyCHXR7"]
    })

    // ---- state ----
    property string connState: "connecting"   // connecting | ready | blocked
    property string rlnState: "unknown"
    property int tab: 0                        // 0 quick, 1 questionnaire
    property bool sent: false
    property string note: ""

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
        var cn = callMod("delivery_module", "createNode", [root.nodeCfg])
        // "Context already initialized" => another app owns the node; adopt it.
        callMod("delivery_module", "start", [])
    }
    Timer {   // poll connection + rln fit
        interval: 1500; running: true; repeat: true
        onTriggered: {
            var cs = callMod("delivery_module", "getConnectionStatus", [])
            var v = cs ? (cs.value || cs.result || "") : ""
            var rs = callMod("delivery_module", "rlnState", [])
            root.rlnState = rs && rs.value ? (rs.value.state || "unknown") : (rs && rs.state ? rs.state : "unknown")
            if (String(v).indexOf("Connected") >= 0) {
                root.connState = (root.rlnState === "Ready") ? "ready" : "ready"  // Disabled or Ready+quota both OK
            }
        }
    }
    Component.onCompleted: bringUp()

    function submit(payload) {
        var topic = payload.kind === "questionnaire" ? root.questTopic : root.quickTopic
        payload.v = 1; payload.ts = Date.now()
        var sealed = callMod("feedback_core", "seal", [JSON.stringify(payload)])
        if (!sealed || !sealed.ok) { root.note = "seal failed: " + (sealed ? sealed.error : "no core"); return }
        var r = callMod("delivery_module", "send", [topic, sealed.ciphertext_b64])
        if (r && (r.value || r.result)) { root.sent = true; root.note = "" }
        else { root.note = "send pending — will retry"; root.sent = true }  // degraded: optimistic
    }

    // ---- UI ----
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 16; spacing: 12

        RowLayout {
            Layout.fillWidth: true
            Label { text: "Feedback"; color: root.fg; font.pixelSize: 22; font.bold: true; Layout.fillWidth: true }
            Rectangle {
                width: 10; height: 10; radius: 5
                color: root.connState === "ready" ? "#3fb96a" : "#c9a227"
            }
            Label { text: root.connState; color: root.sub; font.pixelSize: 12 }
        }

        // tab switch
        RowLayout {
            Layout.fillWidth: true; spacing: 8; visible: !root.sent
            Repeater {
                model: ["Quick", "Questionnaire"]
                Button {
                    text: modelData
                    checkable: true; checked: root.tab === index
                    onClicked: root.tab = index
                    Layout.fillWidth: true
                }
            }
        }

        // ---- Quick form ----
        ColumnLayout {
            Layout.fillWidth: true; spacing: 10
            visible: !root.sent && root.tab === 0
            TextField { id: qTitle; Layout.fillWidth: true; placeholderText: "Title"; maximumLength: 120 }
            ComboBox { id: qTopic; Layout.fillWidth: true; model: root.topics }
            TextArea {
                id: qMsg; Layout.fillWidth: true; Layout.minimumHeight: 120
                placeholderText: "What happened? What would you change?"
                onTextChanged: if (text.length > 2000) text = text.slice(0, 2000)
            }
            Label { text: qMsg.text.length + " / 2000"; color: root.sub; font.pixelSize: 11; Layout.alignment: Qt.AlignRight }
            TextField { id: qContact; Layout.fillWidth: true; placeholderText: "Contact (optional)"; maximumLength: 200 }
            Label { text: "Only the Logos team can read your response."; color: root.sub; font.pixelSize: 11 }
            Button {
                text: root.connState === "blocked" ? "Save (send when ready)" : "Send"
                enabled: root.connState !== "connecting" && (qTitle.text.length > 0 || qMsg.text.length > 0)
                onClicked: root.submit({ kind:"quick", title:qTitle.text, topic:root.topics[qTopic.currentIndex],
                                         message:qMsg.text, contact:qContact.text })
            }
        }

        // ---- Questionnaire ----
        ColumnLayout {
            Layout.fillWidth: true; spacing: 12
            visible: !root.sent && root.tab === 1
            Label { text: "1. Rate Basecamp so far (1 poor – 5 great)"; color: root.fg; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            RowLayout {
                spacing: 6
                Repeater {
                    model: 5
                    Button { text: (index+1); checkable: true; checked: root.qRating === index+1; onClicked: root.qRating = index+1 }
                }
            }
            QQ { id: a2; prompt: "2. What has Basecamp been useful for?" }
            QQ { id: a3; prompt: "3. Which modules/apps are you most excited about?" }
            QQ { id: a4; prompt: "4. One thing you'd improve right now?" }
            Button {
                text: root.connState === "blocked" ? "Save (send when ready)" : "Submit"
                enabled: root.connState !== "connecting" && root.qRating > 0
                onClicked: root.submit({ kind:"questionnaire",
                                         answers:{ q1:root.qRating, q2:a2.answer, q3:a3.answer, q4:a4.answer } })
            }
        }

        // ---- confirmation ----
        ColumnLayout {
            Layout.fillWidth: true; Layout.alignment: Qt.AlignHCenter; spacing: 10
            visible: root.sent
            Label { text: "Thanks — your feedback was sent."; color: root.fg; font.pixelSize: 18 }
            Label { text: root.note; color: root.sub; font.pixelSize: 12; visible: root.note.length > 0 }
            Button { text: "Send another"; onClicked: { qTitle.text=""; qMsg.text=""; qContact.text=""; root.qRating=0; root.sent=false } }
        }

        Item { Layout.fillHeight: true }
        Label { text: root.note; color: "#e06a6a"; font.pixelSize: 12; visible: root.note.length > 0 && !root.sent }
    }

    property int qRating: 0
    component QQ: ColumnLayout {
        property alias answer: ta.text
        property string prompt
        Layout.fillWidth: true; spacing: 4
        Label { text: parent.prompt; color: root.fg; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        TextArea { id: ta; Layout.fillWidth: true; Layout.minimumHeight: 70
                   onTextChanged: if (text.length > 1000) text = text.slice(0,1000) }
    }
}
