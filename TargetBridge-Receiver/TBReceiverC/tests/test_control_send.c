#include "../src/control_send.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
static uint64_t milliseconds(void) {
    struct timespec time; clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * 1000 + time.tv_nsec / 1000000;
}
int main(void) {
    int fd[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0);
    for (int i = 0; i < 2; i++) assert(fcntl(fd[i], F_SETFL, O_NONBLOCK) == 0);
    int size = 1024; setsockopt(fd[0], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
    uint8_t filler[1024] = {0};
    while (send(fd[0], filler, sizeof(filler), 0) > 0) {}
    assert(errno == EAGAIN || errno == EWOULDBLOCK);
    struct tb_control_send queue = {0};
    const uint8_t one[] = {0,0,0,3,0x24,'a','b'}, two[] = {0,0,0,2,0x25,'c'};
    uint64_t start = milliseconds();
    assert(tb_control_enqueue(&queue, one, sizeof(one), start) == 0);
    assert(tb_control_enqueue(&queue, two, sizeof(two), start) == 0);
    assert(tb_control_flush(&queue, fd[0], start) == 0);
    assert(milliseconds() - start < 50 && queue.count == 2);
    // After resuming reads, packets retain their framing and FIFO ordering.
    while (recv(fd[1], filler, sizeof(filler), 0) > 0) {}
    assert(tb_control_flush(&queue, fd[0], start + 1) == 0 && queue.count == 0 && queue.bytes == 0);
    uint8_t received[sizeof(one) + sizeof(two)];
    assert(recv(fd[1], received, sizeof(received), 0) == sizeof(received));
    assert(!memcmp(received, one, sizeof(one)) && !memcmp(received + sizeof(one), two, sizeof(two)));
    assert(tb_control_enqueue(&queue, one, sizeof(one), start) == 0);
    assert(tb_control_flush(&queue, fd[0], start + TB_CONTROL_MAX_AGE_MS) == -1);
    tb_control_clear(&queue); assert(queue.bytes == 0 && queue.count == 0);
    for (unsigned int i = 0; i < TB_CONTROL_MAX_PACKETS; i++) assert(tb_control_enqueue(&queue, one, sizeof(one), start) == 0);
    assert(tb_control_enqueue(&queue, one, sizeof(one), start) == -1);
    tb_control_clear(&queue);
    uint8_t *large = calloc(1, TB_CONTROL_MAX_BYTES);
    assert(tb_control_enqueue(&queue, large, TB_CONTROL_MAX_BYTES, start) == 0);
    assert(tb_control_enqueue(&queue, one, sizeof(one), start) == -1);
    tb_control_clear(&queue);
    // Partial sends stay at the head; a later packet can never overtake them.
    assert(tb_control_enqueue(&queue, large, TB_CONTROL_MAX_BYTES - sizeof(two), start) == 0);
    assert(tb_control_enqueue(&queue, two, sizeof(two), start) == 0);
    size_t total = 0;
    while (queue.count) {
        assert(tb_control_flush(&queue, fd[0], start + 1) == 0);
        ssize_t count;
        while ((count = recv(fd[1], filler, sizeof(filler), 0)) > 0) {
            for (ssize_t i = 0; i < count; i++, total++) {
                uint8_t expected = total < TB_CONTROL_MAX_BYTES - sizeof(two) ? 0 : two[total - (TB_CONTROL_MAX_BYTES - sizeof(two))];
                assert(filler[i] == expected);
            }
        }
    }
    assert(total == TB_CONTROL_MAX_BYTES);
    free(large); tb_control_clear(&queue); close(fd[0]); close(fd[1]);
    puts("control send: nonblocking congestion, resume, packet ordering, partial writes, deadline and capacity passed");
    return 0;
}
