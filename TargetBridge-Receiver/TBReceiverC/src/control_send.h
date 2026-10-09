#ifndef TB_CONTROL_SEND_H
#define TB_CONTROL_SEND_H
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

#define TB_CONTROL_MAX_BYTES 32768u
#define TB_CONTROL_MAX_PACKETS 128u
#define TB_CONTROL_MAX_AGE_MS 250u
struct tb_control_packet { uint8_t *data; size_t size, offset; uint64_t queued_ms; };
struct tb_control_send {
    struct tb_control_packet packets[TB_CONTROL_MAX_PACKETS];
    size_t head, count, bytes;
};
static inline void tb_control_clear(struct tb_control_send *queue) {
    while (queue->count) {
        free(queue->packets[queue->head].data);
        queue->head = (queue->head + 1) % TB_CONTROL_MAX_PACKETS;
        queue->count--;
    }
    memset(queue, 0, sizeof(*queue));
}
static inline int tb_control_enqueue(struct tb_control_send *queue, const uint8_t *data, size_t size, uint64_t now) {
    if (!size || size > TB_CONTROL_MAX_BYTES - queue->bytes || queue->count == TB_CONTROL_MAX_PACKETS) return -1;
    uint8_t *copy = malloc(size);
    if (!copy) return -1;
    memcpy(copy, data, size);
    size_t tail = (queue->head + queue->count) % TB_CONTROL_MAX_PACKETS;
    queue->packets[tail] = (struct tb_control_packet){copy, size, 0, now};
    queue->count++; queue->bytes += size;
    return 0;
}
/* Nonblocking even for fixture sockets. Never wait in the rendering loop.
 * A partial packet stays at the head until finished; any fatal failure requires
 * closing the connection, so later packets cannot corrupt its framing. */
static inline int tb_control_flush(struct tb_control_send *queue, int fd, uint64_t now) {
    size_t budget = 16384;
    for (unsigned int calls = 0; queue->count && budget && calls < TB_CONTROL_MAX_PACKETS; calls++) {
        struct tb_control_packet *packet = &queue->packets[queue->head];
        if (now - packet->queued_ms >= TB_CONTROL_MAX_AGE_MS) return -1;
        size_t size = packet->size - packet->offset;
        if (size > budget) size = budget;
        ssize_t sent = send(fd, packet->data + packet->offset, size, MSG_DONTWAIT);
        if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return -1;
        packet->offset += (size_t)sent; budget -= (size_t)sent; queue->bytes -= (size_t)sent;
        if (packet->offset == packet->size) {
            free(packet->data); memset(packet, 0, sizeof(*packet));
            queue->head = (queue->head + 1) % TB_CONTROL_MAX_PACKETS; queue->count--;
        }
    }
    return 0;
}
#endif
