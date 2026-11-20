// Quick feedback form — STRUCTURAL DRAFT, SUPERSEDED.
// The shipped app is the tabbed app-module/ui/Main.qml (and xAlisher/feedback-app). This early draft
// is kept for reference only. No contact field: contact collection was removed end to end
// (feedback-bc#21) — do not reintroduce it here. The privacy note, opt-in sharing checkbox, anti-scam
// note, reference code and auto-context all live in the shipped Main.qml.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    // injected: the native core (seal + delivery send + rlnState) and connection state
    property var core
    property string connState: "connecting"   // connecting | ready | blocked
    readonly property var topics: ["app","package-manager","node","wallet","delivery","messaging","onboarding","other"]
    property bool sent: false

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12
        visible: !root.sent

        Label { text: "Send feedback"; font.pixelSize: 22; font.bold: true }

        TextField {
            id: title
            Layout.fillWidth: true
            placeholderText: "Title"
            maximumLength: 120
        }

        ComboBox {
            id: topic
            Layout.fillWidth: true
            model: root.topics
        }

        TextArea {
            id: message
            Layout.fillWidth: true
            Layout.minimumHeight: 120
            placeholderText: "What happened? What would you change?"
            // enforce the 2000-char cap in-input
            onTextChanged: if (text.length > 2000) text = text.slice(0, 2000)
        }
        Label {
            Layout.alignment: Qt.AlignRight
            text: message.text.length + " / 2000"
            opacity: 0.6; font.pixelSize: 12
        }

        Label {
            text: "Your feedback goes to our private Discord channel. Please don't include any personal data."
            opacity: 0.6; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true
        }

        Button {
            text: root.connState === "blocked" ? "Save (will send when messaging allows)" : "Send"
            enabled: root.connState !== "connecting" && (title.text.length > 0 || message.text.length > 0)
            onClicked: {
                root.core.send({
                    v: 1, kind: "quick",
                    title: title.text, topic: root.topics[topic.currentIndex],
                    message: message.text
                })
                root.sent = true   // core also queues if blocked (degraded mode)
            }
        }
        Item { Layout.fillHeight: true }
    }

    // confirmation screen
    ColumnLayout {
        anchors.centerIn: parent
        spacing: 10
        visible: root.sent
        Label { text: "Thanks — your feedback was sent."; font.pixelSize: 18 }
        Button { text: "Send another"; onClicked: { title.text=""; message.text=""; root.sent=false } }
    }
}
