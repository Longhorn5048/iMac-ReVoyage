#ifndef TB_RECEIVER_IDENTITY_H
#define TB_RECEIVER_IDENTITY_H
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

static inline int tb_receiver_id_valid(const char *id) {
    if (!id || strlen(id) != 36) return 0;
    for (int i = 0; i < 36; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (id[i] != '-') return 0; }
        else if (!((id[i] >= '0' && id[i] <= '9') || (id[i] >= 'a' && id[i] <= 'f'))) return 0;
    }
    return 1;
}

/* An existing invalid identity fails closed rather than silently changing the
 * monitor identity. O_EXCL prevents concurrent startups from replacing it. */
static inline int tb_receiver_id_load(const char *path, char id[37]) {
    id[0] = 0;
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0 && errno == ENOENT) {
        unsigned char bytes[16]; arc4random_buf(bytes, sizeof(bytes));
        bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
        char generated[38];
        snprintf(generated, sizeof(generated),
          "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x\n",
          bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
          bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]);
        int output = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (output >= 0) {
            int ok = write(output, generated, 37) == 37 && fsync(output) == 0;
            if (close(output) != 0) ok = 0;
            if (!ok) return 0;
        } else if (errno != EEXIST) return 0;
        fd = open(path, O_RDONLY | O_NOFOLLOW);
    }
    if (fd < 0) return 0;
    struct stat status;
    char buffer[39] = {0};
    int valid = fstat(fd, &status) == 0 && S_ISREG(status.st_mode) && status.st_uid == getuid();
    ssize_t count = valid ? read(fd, buffer, sizeof(buffer) - 1) : -1;
    close(fd);
    if (count != 36 && !(count == 37 && buffer[36] == '\n')) return 0;
    buffer[36] = 0;
    if (!tb_receiver_id_valid(buffer)) return 0;
    memcpy(id, buffer, 37);
    return 1;
}
#endif
