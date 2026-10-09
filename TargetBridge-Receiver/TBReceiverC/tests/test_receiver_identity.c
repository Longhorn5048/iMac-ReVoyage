#include "../src/receiver_identity.h"
#include "../src/session_auth.h"
#include <assert.h>
int main(void) {
    char root[] = "/tmp/revoyage-identity.XXXXXX";
    assert(mkdtemp(root));
    char path[256], id[37], again[37]; snprintf(path, sizeof(path), "%s/receiver.id", root);
    assert(tb_receiver_id_load(path, id)); assert(tb_receiver_id_valid(id));
    assert(tb_receiver_id_load(path, again)); assert(strcmp(id, again) == 0);
    struct stat status; assert(stat(path, &status) == 0); assert((status.st_mode & 0777) == 0600);
    unlink(path); assert(symlink("missing", path) == 0); assert(!tb_receiver_id_load(path, again)); unlink(path);
    FILE *file = fopen(path, "w"); assert(file); fputs("invalid", file); fclose(file);
    assert(!tb_receiver_id_load(path, again)); unlink(path); rmdir(root);
    uint8_t nonce[32], digest[32]; for (int i = 0; i < 32; i++) nonce[i] = i;
    tb_receiver_identity_digest(nonce, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "12345678-1234-4234-8234-123456789abc", digest);
    char hex[65]; for (int i = 0; i < 32; i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    assert(strcmp(hex, "16e985febd4b5a711d97875351819ac85ce6a7dc09e5d8d28be9c9befb290d35") == 0);
    uint8_t sender_nonce[32], proof[64];
    for (int i = 0; i < 32; i++) sender_nonce[i] = i + 32;
    const char *key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const char *fixed_id = "12345678-1234-4234-8234-123456789abc";
    memcpy(proof, sender_nonce, 32);
    tb_session_auth_digest_v2(nonce, sender_nonce, key, fixed_id, 0, proof + 32);
    assert(tb_session_auth_verify_v2(nonce, key, fixed_id, proof, 64));
    proof[0] ^= 1; assert(!tb_session_auth_verify_v2(nonce, key, fixed_id, proof, 64)); proof[0] ^= 1;
    tb_session_auth_digest_v2(nonce, sender_nonce, key, fixed_id, 1, digest);
    for (int i = 0; i < 32; i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    assert(strcmp(hex, "1e2288aca170d203dffc410e92b0a3860215289080feac272922b17ad84a5ed9") == 0);
    puts("Receiver identity persistence, corruption/symlink rejection and Swift HMAC vector passed.");
}
