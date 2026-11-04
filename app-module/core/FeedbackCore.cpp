#include "FeedbackCore.h"
#include <QJsonDocument>
#include <QJsonObject>
#include <QByteArray>
#include <QDebug>
#include <sodium.h>

// Desk X25519 public key (seal target). Rotation = rebuild feedback_core with a new key +
// ship an app update. The matching private key lives only on the Feedback Desk host.
static const char* kDeskPubKeyHex =
    "b91c2bae485bfe8d12caf0ba6c3a8449b17f8b236d2f99405cd5073ec958ef7c";

// Defense-in-depth cap (mirrors feedback_common.LIMITS.payload_max_bytes); the UI also
// enforces per-field limits in-input.
static const int kMaxPayloadBytes = 8192;

static QString toJson(const QJsonObject& o)
{
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

FeedbackCore::FeedbackCore(QObject* parent)
    : QObject(parent)
{
    m_sodiumReady = (sodium_init() >= 0);  // 0 = ok, 1 = already initialized, -1 = failed
    qDebug() << "FeedbackCore constructed; sodium ready:" << m_sodiumReady;
}

FeedbackCore::~FeedbackCore() = default;

void FeedbackCore::initLogos(LogosAPI* api)
{
    logosAPI = api;  // base-class member; do not shadow
    qDebug() << "FeedbackCore: Logos API initialized";
}

QString FeedbackCore::deskPublicKey()
{
    QJsonObject r;
    r["pubkey"] = QString::fromLatin1(kDeskPubKeyHex);
    return toJson(r);
}

QString FeedbackCore::seal(const QString& payloadJson)
{
    QJsonObject r;
    if (!m_sodiumReady) { r["error"] = "libsodium not initialized"; return toJson(r); }

    const QByteArray pk = QByteArray::fromHex(QByteArray(kDeskPubKeyHex));
    if (pk.size() != crypto_box_PUBLICKEYBYTES) { r["error"] = "bad desk public key"; return toJson(r); }

    const QByteArray m = payloadJson.toUtf8();
    if (m.isEmpty() || m.size() > kMaxPayloadBytes) { r["error"] = "payload size out of range"; return toJson(r); }

    QByteArray c(m.size() + crypto_box_SEALBYTES, Qt::Uninitialized);
    const int rc = crypto_box_seal(
        reinterpret_cast<unsigned char*>(c.data()),
        reinterpret_cast<const unsigned char*>(m.constData()),
        static_cast<unsigned long long>(m.size()),
        reinterpret_cast<const unsigned char*>(pk.constData()));
    if (rc != 0) { r["error"] = "seal failed"; return toJson(r); }

    r["ok"] = true;
    r["ciphertext_b64"] = QString::fromLatin1(c.toBase64());  // wire payload = base64(ciphertext)
    return toJson(r);
}
