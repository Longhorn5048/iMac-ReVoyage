#ifndef REVOYAGE_DISPLAY_POWER_H
#define REVOYAGE_DISPLAY_POWER_H
#include <stddef.h>
#include <stdint.h>

#define RV_POWER_REQUEST_NOTIFICATION "re.voyage.display.power-request"
#define RV_POWER_RESULT_NOTIFICATION "re.voyage.display.power-result"
#define RV_RESCUE_READY_NOTIFICATION "re.voyage.display.rescue-ready"
#define RV_RECEIVER_RESTART_NOTIFICATION "re.voyage.display.receiver-restart"
#define RV_POWER_REQUEST_TIMEOUT_MS 5000ULL
/* Authenticated TCP: 0x39 = [displayOn (0/1), 8-byte BE requestID].
 * 0x3a = [displayOn, accepted (0/1), 8-byte BE requestID]. The ID must
 * be nonzero and prevents a late ACK from confirming a newer request.
 * 0x3d/0x3e use the same layouts for Sender awake/asleep state. Receiver
 * combines it with manual off; Sender wake must not clear manual off. */
static inline uint64_t rv_display_power_read_id(const uint8_t *bytes) {
    uint64_t id = 0;
    for (int i = 0; i < 8; i++) id = (id << 8) | bytes[i];
    return id;
}
static inline void rv_display_power_write_id(uint8_t *bytes, uint64_t id) {
    for (int i = 7; i >= 0; i--) { bytes[i] = (uint8_t)id; id >>= 8; }
}
static inline int rv_display_power_decode(const uint8_t *bytes, size_t len, int *display_on, uint64_t *request_id) {
    if (!bytes || len != 9 || bytes[0] > 1 || !display_on || !request_id) return 0;
    uint64_t id = rv_display_power_read_id(bytes + 1);
    if (!id) return 0;
    *display_on = bytes[0];
    *request_id = id;
    return 1;
}
#endif
