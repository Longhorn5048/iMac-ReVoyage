#ifndef RV_UPDATE_ARCHIVE_H
#define RV_UPDATE_ARCHIVE_H
#import <Foundation/Foundation.h>
#include <sys/stat.h>

#define RV_UPDATE_PORT 54324
#define RV_UPDATE_MAX_BYTES (96ULL * 1024 * 1024)
static uint16_t rv_zip16(const uint8_t *p) { return (uint16_t)p[0] | (uint16_t)p[1] << 8; }
static uint32_t rv_zip32(const uint8_t *p) { return (uint32_t)rv_zip16(p) | (uint32_t)rv_zip16(p + 2) << 16; }

/* Check central AND local names before invoking the system extractor. Reject
 * links, traversal, encryption, ZIP64 and oversized Receiver contents. Sources
 * in the full distribution are never extracted by the updater. */
static BOOL RVValidateUpdateArchive(NSData *data) {
    if (data.length < 22 || data.length > RV_UPDATE_MAX_BYTES) return NO;
    const uint8_t *b = data.bytes;
    size_t end = data.length - 22, floor = data.length > 65557 ? data.length - 65557 : 0;
    while (end > floor && rv_zip32(b + end) != 0x06054b50) --end;
    if (rv_zip32(b + end) != 0x06054b50 || end + 22 + rv_zip16(b + end + 20) != data.length ||
        rv_zip16(b + end + 4) || rv_zip16(b + end + 6)) return NO;
    unsigned count = rv_zip16(b + end + 10);
    if (!count || count > 12000 || count != rv_zip16(b + end + 8)) return NO;
    size_t offset = rv_zip32(b + end + 16), size = rv_zip32(b + end + 12);
    if (offset > end || size > end - offset || offset + size != end) return NO;
    uint64_t receiverBytes = 0; BOOL receiver = NO;
    NSMutableSet *names = [NSMutableSet new];
    for (unsigned i = 0; i < count; ++i) {
        if (offset > end || end - offset < 46 || rv_zip32(b + offset) != 0x02014b50) return NO;
        size_t nameLen = rv_zip16(b + offset + 28), extra = rv_zip16(b + offset + 30), comment = rv_zip16(b + offset + 32);
        size_t entrySize = 46 + nameLen + extra + comment;
        if (!nameLen || nameLen > 1024 || entrySize > end - offset) return NO;
        NSString *name = [[NSString alloc] initWithBytes:b + offset + 46 length:nameLen encoding:NSUTF8StringEncoding];
        if (!name || [name hasPrefix:@"/"] || [name containsString:@"\\"] ||
            [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
            [[name componentsSeparatedByString:@"/"] containsObject:@".."] ||
            [[name componentsSeparatedByString:@"/"] containsObject:@"."] || [names containsObject:name]) return NO;
        [names addObject:name];
        uint16_t flags = rv_zip16(b + offset + 8), method = rv_zip16(b + offset + 10);
        uint32_t compressed = rv_zip32(b + offset + 20), unpacked = rv_zip32(b + offset + 24);
        uint32_t mode = rv_zip32(b + offset + 38) >> 16;
        if ((flags & 1) || (method != 0 && method != 8) || S_ISLNK(mode) ||
            ((mode & S_IFMT) && !S_ISREG(mode) && !S_ISDIR(mode))) return NO;
        size_t local = rv_zip32(b + offset + 42);
        if (local > rv_zip32(b + end + 16) || rv_zip32(b + end + 16) - local < 30 ||
            rv_zip32(b + local) != 0x04034b50) return NO;
        size_t localName = rv_zip16(b + local + 26), localExtra = rv_zip16(b + local + 28);
        size_t header = 30 + localName + localExtra;
        if (header > rv_zip32(b + end + 16) - local || localName != nameLen ||
            memcmp(b + local + 30, b + offset + 46, nameLen) ||
            compressed > rv_zip32(b + end + 16) - local - header ||
            rv_zip16(b + local + 6) != flags || rv_zip16(b + local + 8) != method) return NO;
        if ([name hasPrefix:@"Receiver/"]) {
            receiver = YES; receiverBytes += unpacked;
            if (unpacked > 256ULL * 1024 * 1024 || receiverBytes > 768ULL * 1024 * 1024) return NO;
        }
        offset += entrySize;
    }
    return receiver && offset == end;
}
#endif
