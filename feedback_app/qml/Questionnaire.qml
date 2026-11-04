// Questionnaire — STRUCTURAL DRAFT. 4 test questions, defined in-app (change with app updates, not
// remotely). Port to Logos.Controls / mobile-ready-ui during the build; wire core.send(...).
// Free-text answers capped at 1000 chars (feedback_common.LIMITS.answer_max).
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    property var core
    property string connState: "connecting"
    property bool sent: false
    property int rating: 0

    Flickable {
        anchors.fill: parent
        anchors.margins: 16
        contentHeight: col.implicitHeight
        visible: !root.sent

        ColumnLayout {
            id: col
            width: parent.width
            spacing: 16

            Label { text: "Basecamp questionnaire"; font.pixelSize: 22; font.bold: true }

            // Q1 — rating 1..5
            Label { text: "1. How would you rate Basecamp so far? (1 = poor, 5 = great)" }
            RowLayout {
                spacing: 8
                Repeater {
                    model: 5
                    Button {
                        text: (index + 1)
                        checkable: true
                        checked: root.rating === index + 1
                        onClicked: root.rating = index + 1
                    }
                }
            }

            FeedbackQuestion { id: q2; prompt: "2. What, if anything, has Basecamp been useful for so far?" }
            FeedbackQuestion { id: q3; prompt: "3. Which modules or apps are you most excited about?" }
            FeedbackQuestion { id: q4; prompt: "4. One thing you would improve right now?" }

            Button {
                text: root.connState === "blocked" ? "Save (will send when messaging allows)" : "Submit"
                enabled: root.connState !== "connecting" && root.rating > 0
                onClicked: {
                    root.core.send({
                        v: 1, kind: "questionnaire",
                        answers: { q1: root.rating, q2: q2.answer, q3: q3.answer, q4: q4.answer }
                    })
                    root.sent = true
                }
            }
        }
    }

    ColumnLayout {
        anchors.centerIn: parent
        visible: root.sent
        Label { text: "Thanks — your responses were sent."; font.pixelSize: 18 }
    }

    // inline component: a prompt + a 1000-char-capped text area
    component FeedbackQuestion: ColumnLayout {
        property alias answer: ta.text
        property string prompt
        Layout.fillWidth: true
        spacing: 4
        Label { text: parent.prompt; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        TextArea {
            id: ta
            Layout.fillWidth: true
            Layout.minimumHeight: 80
            onTextChanged: if (text.length > 1000) text = text.slice(0, 1000)
        }
    }
}
