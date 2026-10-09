#ifndef REVOYAGE_MEDIA_PROTOCOL_H
#define REVOYAGE_MEDIA_PROTOCOL_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <CommonCrypto/CommonHMAC.h>

enum { RV_MEDIA_PORT = 54323, RV_MEDIA_MAX_PACKET = 262153,
       RV_MEDIA_MAX_REQUEST = 8192, RV_MEDIA_MAX_QUEUED = 524288,
       RV_MEDIA_PCM_RATE = 48000, RV_MEDIA_PCM_CHUNK = 960 };
enum { RV_MEDIA_CHALLENGE = 0x51, RV_MEDIA_AUTH = 0x52, RV_MEDIA_PROOF = 0x53,
       RV_MEDIA_REGISTRY = 0x54, RV_MEDIA_REQUEST = 0x55, RV_MEDIA_STATUS = 0x56,
       RV_MEDIA_JPEG = 0x57, RV_MEDIA_PCM = 0x58, RV_MEDIA_STOP = 0x59,
       RV_MEDIA_HEARTBEAT = 0x5a };

/* Both peers contribute a nonce. A fake service cannot solicit a reusable
 * proof or replay an earlier receiver proof to authenticate itself. */
static inline void rv_media_proof(const uint8_t receiver_nonce[32], const uint8_t sender_nonce[32],
                                  const char key[64], int receiver, uint8_t digest[32]) {
    const char *domain = receiver ? "ReVoyageMediaReceiverV1" : "ReVoyageMediaSenderV1";
    uint8_t message[96];
    memcpy(message, receiver_nonce, 32); memcpy(message + 32, sender_nonce, 32);
    size_t count = strlen(domain); memcpy(message + 64, domain, count);
    CCHmac(kCCHmacAlgSHA256, key, 64, message, 64 + count, digest);
}
static inline int rv_media_equal(const uint8_t *a, const uint8_t *b, size_t count) {
    uint8_t difference = 0;
    for (size_t i = 0; i < count; ++i) difference |= a[i] ^ b[i];
    return difference == 0;
}
static inline void rv_media_put_u64(uint8_t out[8], uint64_t value) {
    for (int i = 7; i >= 0; --i) { out[i] = (uint8_t)value; value >>= 8; }
}
#endif
