#ifndef TB_SESSION_AUTH_H
#define TB_SESSION_AUTH_H

#include "proto.h"
#include <CommonCrypto/CommonHMAC.h>
#include <stdint.h>
#include <string.h>

/* Separate directional domains prevent reflection and cross-protocol replay.
 * The nonce is freshly generated for every accepted TCP connection. */
static inline void tb_session_auth_digest(const uint8_t nonce[32], const char *key,
                                         int receiver_proof, uint8_t digest[32]) {
    const char *domain = receiver_proof ? "ReVoyageSessionReceiverV1" : "ReVoyageSessionSenderV1";
    uint8_t message[64] = {0};
    size_t domain_length = strlen(domain);
    memcpy(message, nonce, 32);
    memcpy(message + 32, domain, domain_length);
    CCHmac(kCCHmacAlgSHA256, key, strlen(key), message, 32 + domain_length, digest);
}

/* UUID proof is tied to the same fresh nonce as mutual session authentication. */
static inline void tb_receiver_identity_digest(const uint8_t nonce[32], const char *key,
                                              const char *id, uint8_t digest[32]) {
    uint8_t message[100];
    const char *domain = "ReVoyageReceiverIdentityV1";
    memcpy(message, nonce, 32);
    memcpy(message + 32, id, 36);
    memcpy(message + 68, domain, strlen(domain));
    CCHmac(kCCHmacAlgSHA256, key, strlen(key), message, 68 + strlen(domain), digest);
}

static inline void tb_session_auth_digest_v2(const uint8_t nonce[32], const uint8_t sender_nonce[32],
    const char *key, const char *id, int receiver_proof, uint8_t digest[32]) {
    const char *domain = receiver_proof ? "ReVoyageSessionReceiverV2" : "ReVoyageSessionSenderV2";
    uint8_t message[128];
    memcpy(message, nonce, 32); memcpy(message + 32, sender_nonce, 32);
    memcpy(message + 64, id, 36); memcpy(message + 100, domain, strlen(domain));
    CCHmac(kCCHmacAlgSHA256, key, strlen(key), message, 100 + strlen(domain), digest);
}

static inline int tb_session_auth_verify_v2(const uint8_t nonce[32], const char *key,
    const char *id, const uint8_t *proof, size_t length) {
    if (!key || strlen(key) != 64 || !id || strlen(id) != 36 || !proof || length != 64) return 0;
    uint8_t expected[32]; tb_session_auth_digest_v2(nonce, proof, key, id, 0, expected);
    unsigned int difference = 0;
    for (size_t i = 0; i < 32; i++) difference |= expected[i] ^ proof[i + 32];
    return difference == 0;
}

static inline int tb_session_auth_verify(const uint8_t nonce[32], const char *key,
                                        const uint8_t *proof, size_t length) {
    if (!key || strlen(key) != 64 || !proof || length != 32) return 0;
    uint8_t expected[32];
    tb_session_auth_digest(nonce, key, 0, expected);
    unsigned int difference = 0;
    for (size_t i = 0; i < sizeof(expected); i++) difference |= expected[i] ^ proof[i];
    return difference == 0;
}

static inline int tb_session_packet_allowed(int authenticated, uint8_t type) {
    return authenticated || type == TB_PKT_SESSION_AUTH ||
           type == TB_PKT_HEARTBEAT || type == TB_PKT_TEARDOWN;
}

#endif
