#pragma once

#include <QObject>
#include <QString>
#include <QVariantList>
#include <core/interface.h>

// feedback_core — the one native piece of the Feedback app: seals a feedback payload to the
// Feedback Desk's public key with libsodium crypto_box_seal (anonymous sender, recipient-only
// decryption), which is byte-compatible with the Desk's PyNaCl/tweetnacl. Everything else
// (the forms, delivery send) is pure QML in feedback_ui.
class FeedbackCore : public QObject, public PluginInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID "org.logos.FeedbackCoreInterface" FILE "plugin_metadata.json")
    Q_INTERFACES(PluginInterface)

public:
    explicit FeedbackCore(QObject* parent = nullptr);
    ~FeedbackCore() override;

    QString name()    const override { return QStringLiteral("feedback_core"); }
    QString version() const override { return QStringLiteral("0.1.0"); }

    Q_INVOKABLE void initLogos(LogosAPI* api);

    // Seal a (validated) feedback payload JSON to the baked-in Desk public key.
    // Returns JSON: {"ok":true,"ciphertext_b64":"..."} or {"error":"..."}.
    // ciphertext_b64 is what the UI hands to delivery_module.send as the Waku payload.
    Q_INVOKABLE QString seal(const QString& payloadJson);

    // The Desk public key the UI seals to (for display / sanity only).
    Q_INVOKABLE QString deskPublicKey();

signals:
    void eventResponse(const QString& eventName, const QVariantList& data);

private:
    bool m_sodiumReady = false;
};
