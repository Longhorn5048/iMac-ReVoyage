/* A separate user LaunchAgent remains alive while the display apps restart.
 * Wired local HTTP only, no account/password/pairing or arbitrary commands. */
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "UpdateArchive.h"
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_types.h>
#include <net/if_dl.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <mach-o/dyld.h>
#include <sys/socket.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <limits.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include "../TargetBridge-Sender/TBDisplayShared/TBWiredNetwork.h"

static NSString *RVHome, *RVInstaller;
static BOOL RVFixture;
static volatile sig_atomic_t RVRunning = 1;
static NSLock *RVLock;
static NSMutableDictionary *RVState;
static BOOL RVBusy;
static void RVStop(int signal) { (void)signal; RVRunning = 0; }

static NSString *RVRoot(void) {
    return [RVHome stringByAppendingPathComponent:@"Library/Application Support/TargetBridge Receiver/Updates"];
}
static NSString *RVSHA(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *hash = [NSMutableString new];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) [hash appendFormat:@"%02x", bytes[i]];
    return hash;
}
static void RVSetState(NSString *phase, NSString *error, double progress) {
    [RVLock lock];
    RVState[@"phase"] = phase; RVState[@"error"] = error ?: @"";
    RVState[@"progress"] = @(progress);
    NSData *json = [NSJSONSerialization dataWithJSONObject:RVState options:0 error:nil];
    [json writeToFile:[RVRoot() stringByAppendingPathComponent:@"last-update.json"] atomically:YES];
    [RVLock unlock];
}
static NSDictionary *RVSnapshot(void) {
    [RVLock lock]; NSMutableDictionary *state = [RVState mutableCopy]; [RVLock unlock];
    state[@"protocol"] = @1;
    NSString *app = [RVHome stringByAppendingPathComponent:@"Applications/iMac ReVoyage/iMac ReVoyage Receiver.app"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]];
    state[@"receiverBuild"] = info[@"CFBundleVersion"] ?: @"";
    NSString *identity = [NSString stringWithContentsOfFile:[RVHome stringByAppendingPathComponent:@"Library/Application Support/TargetBridge Receiver/receiver.id"] encoding:NSUTF8StringEncoding error:nil];
    state[@"receiverID"] = [identity stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    return state;
}
static BOOL RVWrite(int fd, NSData *data) {
    const uint8_t *bytes = data.bytes; size_t remaining = data.length;
    while (remaining) {
        ssize_t n = write(fd, bytes, remaining);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        bytes += n; remaining -= (size_t)n;
    }
    return YES;
}
static void RVReply(int fd, int code, NSDictionary *body) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 %d Response\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", code, (unsigned long)json.length];
    if (RVWrite(fd, [header dataUsingEncoding:NSASCIIStringEncoding])) (void)RVWrite(fd, json);
}
/* A POST sender may still have bytes in flight when rejected. Closing with
 * unread bytes sends RST and can discard our error reply. Allow a short drain
 * after FIN; Sender stops uploading as soon as it receives the reply. */
static void RVReject(int fd, int code, NSString *error) {
    RVReply(fd, code, @{@"error":error}); shutdown(fd, SHUT_WR);
    struct timeval timeout = {1, 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    uint8_t chunk[65536]; uint64_t drained = 0;
    while (drained < RV_UPDATE_MAX_BYTES) {
        ssize_t n = read(fd, chunk, sizeof(chunk)); if (n <= 0) break; drained += n;
    }
    close(fd);
}
static int RVTask(NSString *path, NSArray<NSString *> *arguments, NSString *log) {
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:path]; task.arguments = arguments;
    if (log) {
        [[NSFileManager defaultManager] createFileAtPath:log contents:nil attributes:nil];
        NSFileHandle *output = [NSFileHandle fileHandleForWritingAtPath:log];
        task.standardOutput = output; task.standardError = output;
    } else { task.standardOutput = NSFileHandle.fileHandleWithNullDevice; task.standardError = NSFileHandle.fileHandleWithNullDevice; }
    if (RVFixture) {
        NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy]; env[@"REVOYAGE_DRY_RUN"] = @"1";
        task.environment = env;
    }
    if (![task launchAndReturnError:nil]) return -1;
    [task waitUntilExit]; return task.terminationStatus;
}

/* No Xcode/otool/lipo dependency on the Catalina machine. */
static BOOL RVMachOCompatible(NSData *data) {
    if (data.length >= sizeof(struct fat_header)) {
        struct fat_header fat; memcpy(&fat, data.bytes, sizeof(fat));
        if (fat.magic == FAT_CIGAM || fat.magic == FAT_CIGAM_64) {
            /* lipo -create emits a FAT wrapper even for a single Intel slice. */
            if (CFSwapInt32BigToHost(fat.nfat_arch) != 1) return NO;
            uint64_t offset, size; uint32_t cpu; size_t entry;
            if (fat.magic == FAT_CIGAM_64) {
                entry = sizeof(struct fat_arch_64);
                if (data.length < sizeof(fat) + entry) return NO;
                struct fat_arch_64 arch; memcpy(&arch, (const uint8_t *)data.bytes + sizeof(fat), entry);
                offset = CFSwapInt64BigToHost(arch.offset); size = CFSwapInt64BigToHost(arch.size); cpu = CFSwapInt32BigToHost(arch.cputype);
            } else {
                entry = sizeof(struct fat_arch);
                if (data.length < sizeof(fat) + entry) return NO;
                struct fat_arch arch; memcpy(&arch, (const uint8_t *)data.bytes + sizeof(fat), entry);
                offset = CFSwapInt32BigToHost(arch.offset); size = CFSwapInt32BigToHost(arch.size); cpu = CFSwapInt32BigToHost(arch.cputype);
            }
            if (cpu != CPU_TYPE_X86_64 || offset < sizeof(fat) + entry || offset > data.length ||
                size < sizeof(struct mach_header_64) || size > data.length - offset) return NO;
            uint32_t inner; memcpy(&inner, (const uint8_t *)data.bytes + offset, sizeof(inner));
            if (inner != MH_MAGIC_64) return NO;
            return RVMachOCompatible([data subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)size)]);
        }
    }
    if (data.length < sizeof(struct mach_header_64)) return NO;
    struct mach_header_64 header; memcpy(&header, data.bytes, sizeof(header));
    if (header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_X86_64 ||
        header.sizeofcmds > data.length - sizeof(header) || header.ncmds > 10000) return NO;
    size_t offset = sizeof(header), end = offset + header.sizeofcmds; BOOL minimum = NO;
    for (uint32_t i = 0; i < header.ncmds; ++i) {
        if (end - offset < sizeof(struct load_command)) return NO;
        struct load_command cmd; memcpy(&cmd, (const uint8_t *)data.bytes + offset, sizeof(cmd));
        if (cmd.cmdsize < sizeof(cmd) || cmd.cmdsize > end - offset) return NO;
        uint32_t version = 0;
        if (cmd.cmd == LC_BUILD_VERSION) {
            if (cmd.cmdsize < sizeof(struct build_version_command)) return NO;
            struct build_version_command build; memcpy(&build, (const uint8_t *)data.bytes + offset, sizeof(build));
            if (build.platform != PLATFORM_MACOS) return NO;
            version = build.minos; minimum = YES;
        } else if (cmd.cmd == LC_VERSION_MIN_MACOSX) {
            if (cmd.cmdsize < sizeof(struct version_min_command)) return NO;
            struct version_min_command build; memcpy(&build, (const uint8_t *)data.bytes + offset, sizeof(build));
            version = build.version; minimum = YES;
        }
        if (version > ((10u << 16) | (15u << 8) | 7u)) return NO;
        offset += cmd.cmdsize;
    }
    return minimum;
}
static BOOL RVValidateApps(NSString *receiver) {
    NSDictionary *expected = @{@"Receiver":@[@"re.voyage.receiver", @"TargetBridgeReceiver"],
        @"Rescue":@[@"re.voyage.rescue", @"RescueReceiver"],
        @"Storage Watcher":@[@"re.voyage.storage-watcher", @"StorageWatcher"],
        @"Media Bridge":@[@"re.voyage.media-bridge", @"ReVoyageMediaBridge"]};
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *name in expected) {
        NSString *app = [receiver stringByAppendingPathComponent:[NSString stringWithFormat:@"iMac ReVoyage %@.app", name]];
        if ([name isEqual:@"Media Bridge"] && ![files fileExistsAtPath:app]) continue;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]];
        if (![info[@"CFBundleIdentifier"] isEqual:expected[name][0]] || ![info[@"CFBundleExecutable"] isEqual:expected[name][1]] ||
            ![info[@"LSMinimumSystemVersion"] isKindOfClass:NSString.class] ||
            [info[@"LSMinimumSystemVersion"] compare:@"10.15.7" options:NSNumericSearch] == NSOrderedDescending ||
            RVTask(@"/usr/bin/codesign", @[@"--verify", @"--deep", @"--strict", app], nil) != 0) {
            fprintf(stderr, "Update rejected: bundle metadata/signature: %s\n", app.fileSystemRepresentation); return NO;
        }
        NSString *main = [app stringByAppendingPathComponent:[@"Contents/MacOS" stringByAppendingPathComponent:expected[name][1]]];
        if (![files isExecutableFileAtPath:main] || !RVMachOCompatible([NSData dataWithContentsOfFile:main])) {
            fprintf(stderr, "Update rejected: executable compatibility: %s\n", main.fileSystemRepresentation); return NO;
        }
        NSDirectoryEnumerator *entries = [files enumeratorAtPath:app];
        for (NSString *relative in entries) {
            NSString *path = [app stringByAppendingPathComponent:relative];
            NSDictionary *attrs = [files attributesOfItemAtPath:path error:nil];
            if ([attrs[NSFileType] isEqual:NSFileTypeSymbolicLink]) {
                fprintf(stderr, "Update rejected: symbolic link: %s\n", path.fileSystemRepresentation); return NO;
            }
            if (![attrs[NSFileType] isEqual:NSFileTypeRegular]) continue;
            NSData *image = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
            if (image.length < 4) continue;
            uint32_t magic; memcpy(&magic, image.bytes, 4);
            if ((magic == MH_MAGIC_64 || magic == MH_CIGAM_64 || magic == MH_MAGIC || magic == MH_CIGAM ||
                magic == FAT_CIGAM || magic == FAT_MAGIC || magic == FAT_CIGAM_64 || magic == FAT_MAGIC_64) && !RVMachOCompatible(image)) {
                fprintf(stderr, "Update rejected: embedded image compatibility: %s\n", path.fileSystemRepresentation); return NO;
            }
        }
    }
    NSString *updater = [receiver stringByAppendingPathComponent:@"iMac ReVoyage Receiver.app/Contents/MacOS/ReVoyageReceiverUpdater"];
    return [files isExecutableFileAtPath:updater]; /* Never downgrade away the update service. */
}
static BOOL RVWiredSocket(int fd) {
    struct sockaddr_in local; socklen_t size = sizeof(local);
    if (getsockname(fd, (struct sockaddr *)&local, &size) != 0) return NO;
    if (RVFixture) return local.sin_addr.s_addr == htonl(INADDR_LOOPBACK);
    NSArray *networkInterfaces = CFBridgingRelease(SCNetworkInterfaceCopyAll());
    NSMutableDictionary *types = [NSMutableDictionary new];
    for (id value in networkInterfaces) {
        SCNetworkInterfaceRef interface = (__bridge SCNetworkInterfaceRef)value;
        NSString *name = (__bridge NSString *)SCNetworkInterfaceGetBSDName(interface);
        NSString *type = (__bridge NSString *)SCNetworkInterfaceGetInterfaceType(interface);
        if (name && type) types[name] = type;
    }
    SCPreferencesRef preferences = SCPreferencesCreate(NULL, CFSTR("ReVoyage updater routes"), NULL);
    NSDictionary *virtual = preferences ? (__bridge NSDictionary *)SCPreferencesGetValue(preferences, CFSTR("VirtualNetworkInterfaces")) : nil;
    NSDictionary *bridges = [virtual[@"Bridge"] isKindOfClass:NSDictionary.class] ? virtual[@"Bridge"] : @{};
    struct ifaddrs *interfaces = NULL; BOOL wired = NO;
    if (getifaddrs(&interfaces) != 0) { if (preferences) CFRelease(preferences); return NO; }
    for (struct ifaddrs *ip = interfaces; ip; ip = ip->ifa_next) {
        if (!ip->ifa_addr || ip->ifa_addr->sa_family != AF_INET || (ip->ifa_flags & IFF_LOOPBACK) ||
            ((struct sockaddr_in *)ip->ifa_addr)->sin_addr.s_addr != local.sin_addr.s_addr) continue;
        NSString *name = @(ip->ifa_name);
        id configured = [types[name] isEqual:@"Bridge"] ? bridges[name][@"Interfaces"] : @[name];
        NSArray *members = [configured isKindOfClass:NSArray.class] ? configured : @[];
        BOOL candidate = members.count > 0;
        for (NSString *member in members) {
            int speed = tb_network_link_mbps(member.UTF8String);
            if (![types[member] isEqual:(__bridge NSString *)kSCNetworkInterfaceTypeEthernet] || (speed > 0 && speed < 1000)) candidate = NO;
        }
        if (candidate) wired = YES;
    }
    freeifaddrs(interfaces); if (preferences) CFRelease(preferences); return wired;
}

static void RVApply(NSString *work, NSString *archive) {
    @autoreleasepool {
        NSString *error = @"invalid_archive", *receiver = [work stringByAppendingPathComponent:@"Receiver"];
        RVSetState(@"validating", nil, 1);
        NSData *data = [NSData dataWithContentsOfFile:archive options:NSDataReadingMappedIfSafe error:nil];
        BOOL success = NO;
        if (RVValidateUpdateArchive(data) && RVTask(@"/usr/bin/unzip", @[@"-qq", archive, @"Receiver/*", @"-d", work], nil) == 0) {
            error = @"incompatible_package";
            if (RVValidateApps(receiver)) {
                /* Use OUR installed installer, never execute an uploaded script. */
                NSString *installer = [receiver stringByAppendingPathComponent:@"install_receiver.command"];
                [[NSFileManager defaultManager] removeItemAtPath:installer error:nil];
                if ([[NSFileManager defaultManager] copyItemAtPath:RVInstaller toPath:installer error:nil]) {
                    RVSetState(@"installing", nil, 1); error = @"installation_failed";
                    NSString *logs = [RVHome stringByAppendingPathComponent:@"Library/Logs/iMac ReVoyage"];
                    [[NSFileManager defaultManager] createDirectoryAtPath:logs withIntermediateDirectories:YES attributes:nil error:nil];
                    NSArray *args = RVFixture ? @[installer, @"--test-root", RVHome] : @[installer, @"--remote-update"];
                    success = RVTask(@"/bin/zsh", args, [logs stringByAppendingPathComponent:@"updater-install.log"]) == 0;
                }
            }
        }
        RVSetState(success ? @"completed" : @"failed", success ? nil : error, 1);
        [[NSFileManager defaultManager] removeItemAtPath:work error:nil];
        [RVLock lock]; RVBusy = success && !RVFixture; [RVLock unlock];
        if (success && !RVFixture) {
            /* Receipt persists across the KeepAlive restart, allowing Sender to
             * poll success after the freshly installed updater takes over. */
            sleep(5); exit(0);
        }
    }
}

static void RVClient(int fd) {
    @autoreleasepool {
        struct timeval timeout = {30, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        if (!RVWiredSocket(fd)) { close(fd); return; }
        NSMutableData *buffer = [NSMutableData new]; uint8_t chunk[65536]; NSRange end;
        for (;;) {
            end = [buffer rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, buffer.length)];
            if (end.location != NSNotFound) break;
            if (buffer.length > 8192) { RVReply(fd, 400, @{@"error":@"invalid_request"}); close(fd); return; }
            ssize_t n = read(fd, chunk, sizeof(chunk)); if (n <= 0) { close(fd); return; }
            [buffer appendBytes:chunk length:n];
        }
        NSString *header = [[NSString alloc] initWithBytes:buffer.bytes length:end.location encoding:NSASCIIStringEncoding];
        NSArray *lines = [header componentsSeparatedByString:@"\r\n"];
        if (!header || end.location > 8192) { RVReply(fd, 400, @{@"error":@"invalid_request"}); close(fd); return; }
        if ([lines[0] isEqual:@"GET /status HTTP/1.1"]) { RVReply(fd, 200, RVSnapshot()); close(fd); return; }
        NSMutableDictionary *fields = [NSMutableDictionary new]; BOOL valid = [lines[0] isEqual:@"POST /update HTTP/1.1"];
        for (NSUInteger i = 1; i < lines.count; ++i) {
            NSRange colon = [lines[i] rangeOfString:@":"];
            if (colon.location == NSNotFound) { valid = NO; break; }
            NSString *key = [[lines[i] substringToIndex:colon.location] lowercaseString];
            if (fields[key]) { valid = NO; break; }
            fields[key] = [[lines[i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
        NSString *length = fields[@"content-length"], *hash = fields[@"x-revoyage-sha256"], *request = fields[@"x-revoyage-request-id"];
        NSCharacterSet *nonDigits = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
        uint64_t bytes = length.longLongValue;
        if (!valid || !length.length || length.length > 10 || [length rangeOfCharacterFromSet:nonDigits].location != NSNotFound ||
            !bytes || bytes > RV_UPDATE_MAX_BYTES || fields[@"transfer-encoding"] || fields[@"expect"] ||
            hash.length != 64 || [hash rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound ||
            ![[NSUUID alloc] initWithUUIDString:request]) {
            RVReject(fd, 400, @"invalid_request"); return;
        }
        [RVLock lock];
        if (RVBusy) { [RVLock unlock]; RVReject(fd, 409, @"busy"); return; }
        RVBusy = YES; RVState = [@{@"requestID":request, @"phase":@"receiving", @"error":@"", @"progress":@0} mutableCopy];
        [RVLock unlock];
        RVSetState(@"receiving", nil, 0);
        NSString *work = [RVRoot() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *archive = [work stringByAppendingPathComponent:@"update.zip"];
        NSFileManager *files = NSFileManager.defaultManager;
        BOOL good = [files createDirectoryAtPath:work withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
        good = good && [files createFileAtPath:archive contents:nil attributes:@{NSFilePosixPermissions:@0600}];
        NSFileHandle *output = good ? [NSFileHandle fileHandleForWritingAtPath:archive] : nil;
        uint64_t received = buffer.length - NSMaxRange(end);
        good = good && received <= bytes;
        @try {
            if (good) [output writeData:[buffer subdataWithRange:NSMakeRange(NSMaxRange(end), (NSUInteger)received)]];
            while (good && received < bytes) {
                ssize_t n = read(fd, chunk, (size_t)MIN(sizeof(chunk), bytes - received));
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) { good = NO; break; }
                [output writeData:[NSData dataWithBytes:chunk length:n]]; received += n;
                [RVLock lock]; RVState[@"progress"] = @((double)received / (double)bytes); [RVLock unlock];
            }
            [output closeFile];
        } @catch (NSException *exception) { (void)exception; good = NO; [output closeFile]; }
        NSData *archiveData = good ? [NSData dataWithContentsOfFile:archive options:NSDataReadingMappedIfSafe error:nil] : nil;
        good = good && archiveData.length == bytes && [RVSHA(archiveData) isEqual:hash];
        if (!good) {
            RVSetState(@"failed", @"transfer_failed", 0); [files removeItemAtPath:work error:nil];
            [RVLock lock]; RVBusy = NO; [RVLock unlock]; RVReply(fd, 400, @{@"error":@"transfer_failed"}); close(fd); return;
        }
        RVSetState(@"validating", nil, 1); RVReply(fd, 202, @{@"requestID":request}); close(fd);
        RVApply(work, archive);
    }
}

int main(int argc, char **argv) { @autoreleasepool {
    RVHome = NSHomeDirectory(); uint16_t port = RV_UPDATE_PORT;
    char executable[PATH_MAX]; uint32_t count = sizeof(executable);
    if (_NSGetExecutablePath(executable, &count) != 0) return 1;
    RVInstaller = [[[@(executable) stringByResolvingSymlinksInPath] stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"../Resources/install_receiver.command"];
#ifdef RV_UPDATER_TESTING
    if (argc != 5 || strcmp(argv[1], "--test-root") || strcmp(argv[3], "--port")) return 64;
    char homePath[PATH_MAX], temporaryPath[PATH_MAX];
    if (!realpath(argv[2], homePath) || !realpath(NSTemporaryDirectory().fileSystemRepresentation, temporaryPath)) return 64;
    RVHome = @(homePath);
    NSString *parent = RVHome.stringByDeletingLastPathComponent;
    if (![RVHome.lastPathComponent isEqual:@"home"] || ![parent.lastPathComponent hasPrefix:@"revoyage-install-test-"] ||
        ![parent hasPrefix:[@(temporaryPath) stringByAppendingString:@"/"]]) return 64;
    RVFixture = YES; port = (uint16_t)atoi(argv[4]);
#else
    if (argc != 1) return 64;
#endif
    if (![[NSFileManager defaultManager] isReadableFileAtPath:RVInstaller]) return 1;
    [[NSFileManager defaultManager] createDirectoryAtPath:RVRoot() withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    RVLock = [NSLock new];
    NSData *receipt = [NSData dataWithContentsOfFile:[RVRoot() stringByAppendingPathComponent:@"last-update.json"]];
    id json = receipt ? [NSJSONSerialization JSONObjectWithData:receipt options:0 error:nil] : nil;
    RVState = [json isKindOfClass:NSDictionary.class] ? [json mutableCopy] : [@{@"phase":@"idle", @"error":@"", @"progress":@0} mutableCopy];
    if (![@[@"idle", @"completed", @"failed"] containsObject:RVState[@"phase"]]) RVSetState(@"failed", @"interrupted", 0);
    signal(SIGPIPE, SIG_IGN); signal(SIGTERM, RVStop); signal(SIGINT, RVStop);
    int listener = socket(AF_INET, SOCK_STREAM, 0), reuse = 1;
    if (listener < 0) return 1;
    fcntl(listener, F_SETFD, FD_CLOEXEC);
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address = {.sin_len=sizeof(address), .sin_family=AF_INET, .sin_port=htons(port),
        .sin_addr.s_addr=htonl(RVFixture ? INADDR_LOOPBACK : INADDR_ANY)};
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 4)) return 1;
    // Only after acquiring the listening port: another invocation must never
    // remove an update still owned by the running LaunchAgent.
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:RVRoot() error:nil]) {
        if ([[NSUUID alloc] initWithUUIDString:entry]) {
            [NSFileManager.defaultManager removeItemAtPath:[RVRoot() stringByAppendingPathComponent:entry] error:nil];
        }
    }
    socklen_t length = sizeof(address); getsockname(listener, (struct sockaddr *)&address, &length);
    printf("Updater listening %u\n", ntohs(address.sin_port)); fflush(stdout);
    dispatch_semaphore_t clients = dispatch_semaphore_create(8);
    while (RVRunning) {
        fd_set readSet; FD_ZERO(&readSet); FD_SET(listener, &readSet); struct timeval timeout = {1, 0};
        if (select(listener + 1, &readSet, NULL, NULL, &timeout) <= 0) continue;
        int client = accept(listener, NULL, NULL); if (client < 0) continue;
        if (dispatch_semaphore_wait(clients, DISPATCH_TIME_NOW) != 0) { close(client); continue; }
        int noSigpipe = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, sizeof(noSigpipe));
        fcntl(client, F_SETFD, FD_CLOEXEC);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ RVClient(client); dispatch_semaphore_signal(clients); });
    }
    close(listener);
} return 0; }
