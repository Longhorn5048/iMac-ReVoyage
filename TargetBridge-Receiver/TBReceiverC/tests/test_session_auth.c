#include "session_auth.h"
#include <assert.h>
#include <stdio.h>

static void decode_hex(const char *text, uint8_t output[32]) {
    for (int i = 0; i < 32; i++) {
        unsigned int value;
        assert(sscanf(text + i * 2, "%2x", &value) == 1);
        output[i] = (uint8_t)value;
    }
}

int main(void) {
    uint8_t nonce[32], sender[32], receiver[32], known[32];
    char key[65];
    memset(key, 'a', 64); key[64] = 0;
    for (int i = 0; i < 32; i++) nonce[i] = (uint8_t)i;
    tb_session_auth_digest(nonce, key, 0, sender);
    decode_hex("a2e616e50866f35a1d6db603c4cb655438ce91993e801e914fc07b5e008c28b7", known);
    assert(memcmp(sender, known, 32) == 0);
    assert(tb_session_auth_verify(nonce, key, sender, 32));
    tb_session_auth_digest(nonce, key, 1, receiver);
    decode_hex("6ec57636a59c68c6f917e0f1bc7199c99d23d3d95934b66e405a9112c05a2985", known);
    assert(memcmp(receiver, known, 32) == 0);
    assert(!tb_session_auth_verify(nonce, key, receiver, 32));
    nonce[0] ^= 1;
    assert(!tb_session_auth_verify(nonce, key, sender, 32));
    nonce[0] ^= 1;
    key[0] = 'b';
    assert(!tb_session_auth_verify(nonce, key, sender, 32));
    assert(!tb_session_auth_verify(nonce, key, sender, 31));
    assert(!tb_session_auth_verify(nonce, key, NULL, 32));
    for (int type = 0; type <= 255; type++) {
        int handshake = type == TB_PKT_SESSION_AUTH || type == TB_PKT_HEARTBEAT || type == TB_PKT_TEARDOWN;
        assert(tb_session_packet_allowed(0, (uint8_t)type) == handshake);
        assert(tb_session_packet_allowed(1, (uint8_t)type));
    }
    puts("session auth: shared vectors, wrong key, replay, reflection and all packet gates passed");
    return 0;
}
