#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonHMAC.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../TargetBridge-Shared/LocalConnection.h"

extern char *tb_storage_copy_removable_volumes_json(void);

static const uint16_t kStoragePort = 54322;
static const uint32_t kMaxSnapshotBytes = 64 * 1024;
static volatile sig_atomic_t gRunning = 1;

static void stop_watcher(int signal_number) {
    (void)signal_number;
    gRunning = 0;
}

static int send_all(int fd, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t sent = send(fd, cursor, length, 0);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return 0;
        cursor += (size_t)sent;
        length -= (size_t)sent;
    }
    return 1;
}

static int receive_all(int fd, void *bytes, size_t length) {
    uint8_t *cursor = bytes;
    while (length > 0) {
        ssize_t received = recv(fd, cursor, length, 0);
        if (received < 0 && errno == EINTR) continue;
        if (received <= 0) return 0;
        cursor += (size_t)received;
        length -= (size_t)received;
    }
    return 1;
}

static int send_packet(int fd, uint8_t type, const void *payload, uint32_t payload_length) {
    uint32_t packet_length = htonl(payload_length + 1);
    if (!send_all(fd, &packet_length, sizeof(packet_length)) || !send_all(fd, &type, 1)) return 0;
    return payload_length == 0 || send_all(fd, payload, payload_length);
}

static int load_pairing_key(char key[65], const char *override_path) {
    if (!override_path && !rv_pairing_required()) {
        memcpy(key, rv_local_wire_key(), 65);
        return 1;
    }
    @autoreleasepool {
        NSString *path = override_path
            ? [NSString stringWithUTF8String:override_path]
            : [[NSHomeDirectory() stringByAppendingPathComponent:
                @"Library/Application Support/TargetBridge Receiver"] stringByAppendingPathComponent:@"pairing.key"];
        if (!path) return 0;
        struct stat file_status;
        if (stat(path.fileSystemRepresentation, &file_status) != 0 ||
            !S_ISREG(file_status.st_mode) || (file_status.st_mode & 077) != 0) {
            fprintf(stderr, "[storage-watcher] pairing key is missing or not private\n");
            return 0;
        }
        NSError *error = nil;
        NSString *value = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
        if (!value || error) {
            fprintf(stderr, "[storage-watcher] could not read pairing key\n");
            return 0;
        }
        value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
        if (utf8.length != 64) {
            fprintf(stderr, "[storage-watcher] pairing key has invalid length\n");
            return 0;
        }
        const uint8_t *bytes = utf8.bytes;
        for (NSUInteger index = 0; index < 64; index++) {
            if (!((bytes[index] >= '0' && bytes[index] <= '9') ||
                  (bytes[index] >= 'a' && bytes[index] <= 'f'))) {
                fprintf(stderr, "[storage-watcher] pairing key must be lowercase hexadecimal\n");
                return 0;
            }
        }
        memcpy(key, bytes, 64);
        key[64] = '\0';
        return 1;
    }
}

static int authenticate_client(int client_fd, const char key[65]) {
    uint8_t nonce[32];
    arc4random_buf(nonce, sizeof(nonce));
    if (!send_packet(client_fd, 0x41, nonce, sizeof(nonce))) return 0;

    uint32_t network_length = 0;
    if (!receive_all(client_fd, &network_length, sizeof(network_length))) return 0;
    uint32_t packet_length = ntohl(network_length);
    if (packet_length != 33) return 0;
    uint8_t packet[33];
    if (!receive_all(client_fd, packet, sizeof(packet)) || packet[0] != 0x42) return 0;

    static const uint8_t domain[] = "ReVoyageStorageMonitorV1";
    uint8_t message[sizeof(nonce) + sizeof(domain) - 1];
    memcpy(message, nonce, sizeof(nonce));
    memcpy(message + sizeof(nonce), domain, sizeof(domain) - 1);
    uint8_t expected[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key, 64, message, sizeof(message), expected);

    uint8_t difference = 0;
    for (size_t index = 0; index < sizeof(expected); index++) {
        difference |= (uint8_t)(expected[index] ^ packet[index + 1]);
    }
    return difference == 0;
}

static int send_snapshot(int fd, char **previous_json) {
    char *json = tb_storage_copy_removable_volumes_json();
    if (!json) {
        fprintf(stderr, "[storage-watcher] volume enumeration failed\n");
        return 1; // Keep the independent watcher alive; retry on the next interval.
    }
    size_t length = strlen(json);
    if (length == 0 || length > kMaxSnapshotBytes) {
        free(json);
        fprintf(stderr, "[storage-watcher] invalid volume snapshot size\n");
        return 1;
    }
    if (*previous_json && strcmp(*previous_json, json) == 0) {
        free(json);
        return 1;
    }
    if (!send_packet(fd, 0x43, json, (uint32_t)length)) {
        free(json);
        return 0;
    }
    free(*previous_json);
    *previous_json = json;
    return 1;
}

static void serve_client(int client_fd, const char key[65]) {
    struct timeval timeout = {.tv_sec = 5, .tv_usec = 0};
    setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    timeout.tv_sec = 3;
    setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int no_sigpipe = 1;
    setsockopt(client_fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));

    if (!authenticate_client(client_fd, key)) {
        fprintf(stderr, "[storage-watcher] rejected unauthenticated client\n");
        return;
    }
    fprintf(stderr, "[storage-watcher] paired Sender connected\n");
    char *previous_json = NULL;
    while (gRunning) {
        if (!send_snapshot(client_fd, &previous_json)) break;
        for (int second = 0; second < 5 && gRunning; second++) sleep(1);
    }
    free(previous_json);
    fprintf(stderr, "[storage-watcher] Sender connection closed\n");
}

static int make_listener(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = htons(kStoragePort);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 4) != 0) {
        fprintf(stderr, "[storage-watcher] cannot listen on TCP %u: %s\n", kStoragePort, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

int main(int argc, char **argv) {
    const char *pairing_key_path = NULL;
    if (argc == 3 && strcmp(argv[1], "--pairing-key-path") == 0) {
        pairing_key_path = argv[2];
    } else if (argc != 1) {
        fprintf(stderr, "usage: StorageWatcher [--pairing-key-path path]\n");
        return 64;
    }
    signal(SIGTERM, stop_watcher);
    signal(SIGINT, stop_watcher);
    signal(SIGPIPE, SIG_IGN);

    char key[65];
    if (!load_pairing_key(key, pairing_key_path)) return 78;
    fprintf(stderr, "[storage-watcher] starting on TCP %u\n", kStoragePort);
    while (gRunning) {
        int listener = make_listener();
        if (listener < 0) {
            sleep(10);
            continue;
        }
        while (gRunning) {
            struct sockaddr_in peer = {0};
            socklen_t peer_length = sizeof(peer);
            int client = accept(listener, (struct sockaddr *)&peer, &peer_length);
            if (client < 0) {
                if (errno == EINTR) continue;
                if (gRunning) fprintf(stderr, "[storage-watcher] accept failed: %s\n", strerror(errno));
                break;
            }
            serve_client(client, key);
            close(client);
        }
        close(listener);
    }
    memset(key, 0, sizeof(key));
    return 0;
}
