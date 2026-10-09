/* Shared, role-scoped uninstaller. Default invocation only prints a plan.
 * --test-root confines filesystem tests and disables all system operations. */
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <signal.h>
#include <libproc.h>
#include <unistd.h>

static NSArray<NSString *> *bundleIDs(BOOL sender) {
    return sender ? @[@"com.targetbridge.sender", @"re.voyage.sender"]
        : @[@"com.targetbridge.receiver", @"re.voyage.receiver", @"re.voyage.rescue",
            @"re.voyage.storage-watcher", @"re.voyage.media-bridge"];
}

static BOOL safeParent(NSString *path, NSString *root) {
    NSString *parent = path.stringByDeletingLastPathComponent.stringByStandardizingPath;
    if (![parent isEqualToString:parent.stringByResolvingSymlinksInPath]) return NO;
    if ([root isEqualToString:@"/"]) return YES;
    return [parent isEqualToString:root] || [parent hasPrefix:[root stringByAppendingString:@"/"]];
}

static NSString *shellQuote(NSString *s) {
    return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static int run(NSString *tool, NSArray<NSString *> *arguments, NSData **output) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return -1;
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (output) *output = data;
    return task.terminationStatus;
}

static int administratorCommand(NSString *command) {
    NSString *escaped = [[command stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                        stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return run(@"/usr/bin/osascript", @[@"-e", [NSString stringWithFormat:
        @"do shell script \"%@\" with administrator privileges", escaped]], NULL);
}

static void add(NSMutableArray *entries, NSString *root, NSString *relative, NSString *kind) {
    [entries addObject:@{@"path": [root stringByAppendingPathComponent:relative], @"kind": kind}];
}

static NSArray *plan(NSString *home, BOOL sender, NSString *currentApp, BOOL test) {
    NSMutableArray *entries = [NSMutableArray array];
    NSArray *names = sender ? @[@"iMac ReVoyage Sender.app", @"TargetBridge.app"]
        : @[@"iMac ReVoyage Receiver.app", @"iMac ReVoyage Rescue.app", @"iMac ReVoyage Storage Watcher.app",
            @"iMac ReVoyage Media Bridge.app", @"TargetBridge Receiver.app"];
    for (NSString *name in names) {
        add(entries, home, [@"Applications/iMac ReVoyage" stringByAppendingPathComponent:name], @"app");
        add(entries, home, [@"Applications" stringByAppendingPathComponent:name], @"app");
    }
    if (sender) add(entries, home, @"Applications/.ReVoyage-Sender-previous.app.backup", @"app");
    if (currentApp) [entries addObject:@{@"path":currentApp, @"kind":@"app"}];
    add(entries, home, sender ? @"Library/Application Support/TargetBridge" : @"Library/Application Support/TargetBridge Receiver", @"tree");
    if (sender) {
        NSString *root = test ? [home stringByAppendingPathComponent:@"System"] : @"/";
        add(entries, root, @"Library/Audio/Plug-Ins/HAL/ReVoyageMicrophone.driver", @"driver");
        add(entries, root, @"Library/Audio/Plug-Ins/HAL/ReVoyageSpeaker.driver", @"driver");
    }
    if (!sender) {
        for (NSString *label in @[@"re.voyage.receiver", @"re.voyage.rescue", @"re.voyage.storage",
                                  @"re.voyage.media", @"re.voyage.updater", @"com.targetbridge.receiver"]) {
            add(entries, home, [NSString stringWithFormat:@"Library/LaunchAgents/%@.plist", label], @"agent");
        }
        for (NSString *file in @[@"network.out.log", @"network.err.log", @"rescue.out.log", @"rescue.err.log",
                                 @"storage.out.log", @"storage.err.log", @"media.out.log", @"media.err.log",
                                 @"updater.out.log", @"updater.err.log", @"updater-install.log"]) {
            add(entries, home, [@"Library/Logs/iMac ReVoyage" stringByAppendingPathComponent:file], @"file");
        }
        for (NSString *file in @[@"TargetBridgeReceiver.launchd.out.log", @"TargetBridgeReceiver.launchd.err.log"]) {
            add(entries, home, [@"Library/Logs" stringByAppendingPathComponent:file], @"file");
        }
        add(entries, home, @"Library/Application Support/ReVoyage/storage-share-path", @"file");
        add(entries, home, @"Library/Application Support/ReVoyage", @"empty");
        add(entries, home, @"Library/Logs/iMac ReVoyage", @"empty");
    }
    NSArray *preferenceIDs = sender ? [bundleIDs(sender) arrayByAddingObjectsFromArray:
        @[@"com.targetbridge.sender.camera", @"com.targetbridge.sender.microphone", @"com.targetbridge.sender.speaker"]] : bundleIDs(sender);
    for (NSString *identifier in preferenceIDs) {
        add(entries, home, [NSString stringWithFormat:@"Library/Preferences/%@.plist", identifier], @"file");
        add(entries, home, [@"Library/Caches" stringByAppendingPathComponent:identifier], @"tree");
        add(entries, home, [NSString stringWithFormat:@"Library/Saved Application State/%@.savedState", identifier], @"tree");
        NSString *byHost = [home stringByAppendingPathComponent:@"Library/Preferences/ByHost"];
        if (safeParent([byHost stringByAppendingPathComponent:@"entry"], home)) {
            for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:byHost error:nil]) {
                if ([name hasPrefix:[identifier stringByAppendingString:@"."]] && [name hasSuffix:@".plist"])
                    add(entries, home, [@"Library/Preferences/ByHost" stringByAppendingPathComponent:name], @"file");
            }
        }
    }
    add(entries, home, @"Applications/iMac ReVoyage", @"empty");
    return entries;
}

static BOOL appOwned(NSString *path, BOOL sender) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                         [path stringByAppendingPathComponent:@"Contents/Info.plist"]];
    BOOL appName = [path.pathExtension isEqualToString:@"app"] ||
        (sender && [path.lastPathComponent isEqualToString:@".ReVoyage-Sender-previous.app.backup"]);
    return appName && [bundleIDs(sender) containsObject:info[@"CFBundleIdentifier"]];
}

static BOOL stopOwnedProcesses(NSArray *entries, BOOL sender, NSMutableArray *errors) {
    NSMutableSet *executables = [NSMutableSet set];
    for (NSDictionary *entry in entries) {
        NSString *path = entry[@"path"];
        if (![entry[@"kind"] isEqual:@"app"] || !appOwned(path, sender)) continue;
        NSString *executable = [NSBundle bundleWithPath:path].executablePath.stringByResolvingSymlinksInPath;
        if (executable) [executables addObject:executable];
    }
    int required = proc_listallpids(NULL, 0);
    if (required <= 0 || required > 1000000) { [errors addObject:@"Cannot inspect running app processes."]; return NO; }
    size_t capacity = (size_t)required + 1024;
    pid_t *pids = calloc(capacity, sizeof(pid_t));
    if (!pids) { [errors addObject:@"Cannot allocate the process list."]; return NO; }
    int count = proc_listallpids(pids, (int)(capacity * sizeof(pid_t)));
    if (count < 0) { free(pids); [errors addObject:@"Cannot read running app processes."]; return NO; }
    BOOL success = YES;
    for (int i = 0; i < count && i < (int)capacity; i++) {
        pid_t pid = pids[i];
        if (pid <= 0 || pid == getpid()) continue;
        struct proc_bsdinfo info;
        char buffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbi_uid != getuid() ||
            proc_pidpath(pid, buffer, sizeof(buffer)) <= 0) continue;
        NSString *path = @(buffer).stringByResolvingSymlinksInPath;
        if (![executables containsObject:path]) continue;
        NSRunningApplication *running = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (!running || ![running terminate]) kill(pid, SIGTERM);
        for (int attempt = 0; kill(pid, 0) == 0 && attempt < 40; attempt++) usleep(100000);
        memset(buffer, 0, sizeof(buffer));
        if (proc_pidpath(pid, buffer, sizeof(buffer)) > 0 && [path isEqual:@(buffer).stringByResolvingSymlinksInPath]) {
            kill(pid, SIGKILL);
            for (int attempt = 0; kill(pid, 0) == 0 && attempt < 20; attempt++) usleep(100000);
            memset(buffer, 0, sizeof(buffer));
            if (proc_pidpath(pid, buffer, sizeof(buffer)) > 0 && [path isEqual:@(buffer).stringByResolvingSymlinksInPath]) {
                [errors addObject:[@"Could not stop app process: " stringByAppendingString:path]]; success = NO;
            }
        }
    }
    free(pids);
    return success;
}

static NSString *sharePath(id json, NSString *recordName) {
    if ([json isKindOfClass:NSArray.class]) {
        for (id record in json) {
            NSString *path = sharePath(record, nil);
            if (path) return path;
        }
        return nil;
    }
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = json;
    if ([recordName isEqualToString:@"ReVoyageStorage"] || [dict[@"name"] isEqual:@"ReVoyageStorage"]) {
        id path = dict[@"path"] ?: dict[@"directory_path"];
        if ([path isKindOfClass:NSString.class]) return path;
    }
    for (NSString *key in dict) {
        NSString *path = sharePath(dict[key], key);
        if (path) return path;
    }
    return nil;
}

static BOOL disableOwnedShare(NSString *home, NSMutableArray *errors) {
    NSString *marker = [home stringByAppendingPathComponent:@"Library/Application Support/ReVoyage/storage-share-path"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:marker]) return YES;
    if (!safeParent(marker, home) || [fm destinationOfSymbolicLinkAtPath:marker error:nil]) {
        [errors addObject:@"SMB ownership marker is a symlink; kept unchanged."]; return NO;
    }
    NSString *saved = [[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSData *listing = nil;
    if (run(@"/usr/sbin/sharing", @[@"-l", @"-f", @"json"], &listing) != 0) {
        [errors addObject:@"Cannot inspect the owned SMB share; uninstall stopped before deleting its record."]; return NO;
    }
    id json = [NSJSONSerialization JSONObjectWithData:listing options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class] && ![json isKindOfClass:NSArray.class]) {
        [errors addObject:@"SMB share listing is not supported; no share was removed."]; return NO;
    }
    NSString *current = sharePath(json, nil);
    if (!current) return YES; // Share was already removed.
    if (!saved.isAbsolutePath || ![saved.stringByStandardizingPath isEqual:current.stringByStandardizingPath]) {
        [errors addObject:@"SMB share path differs from the ownership record; no share was removed."]; return NO;
    }
    if (administratorCommand(@"/usr/sbin/sharing -r ReVoyageStorage") != 0) {
        [errors addObject:@"SMB removal was cancelled or failed; uninstall stopped, data was preserved."]; return NO;
    }
    return YES;
}

static BOOL removeEntry(NSDictionary *entry, NSString *home, BOOL sender, BOOL test, NSMutableArray *errors) {
    NSString *path = entry[@"path"], *kind = entry[@"kind"];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isApp = [kind isEqual:@"app"], isDriver = [kind isEqual:@"driver"];
    BOOL exists = [fm fileExistsAtPath:path] || [fm destinationOfSymbolicLinkAtPath:path error:nil] != nil;
    if (!exists) return YES;
    if (!safeParent(path, home) && !(!test && safeParent(path, @"/") &&
        (isApp || (isDriver && ([path isEqual:@"/Library/Audio/Plug-Ins/HAL/ReVoyageMicrophone.driver"] || [path isEqual:@"/Library/Audio/Plug-Ins/HAL/ReVoyageSpeaker.driver"]))))) {
        [errors addObject:[@"Unsafe ancestor; retained: " stringByAppendingString:path]]; return NO;
    }
    if (isApp && !appOwned(path, sender)) return YES; // Never remove a different app with the same filename.
    if (isDriver) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
        NSString *identifier = [path.lastPathComponent isEqual:@"ReVoyageSpeaker.driver"] ? @"com.targetbridge.sender.speaker" : @"com.targetbridge.sender.microphone";
        if (![info[@"CFBundleIdentifier"] isEqual:identifier] ||
            [fm destinationOfSymbolicLinkAtPath:path error:nil]) {
            [errors addObject:@"Virtual audio device ownership differs; it was preserved."]; return NO;
        }
    }
    if ([kind isEqual:@"empty"] && [[fm contentsOfDirectoryAtPath:path error:nil] count] != 0) return YES;
    NSError *error = nil;
    if ([fm removeItemAtPath:path error:&error]) return YES;
    if ((isApp || isDriver) && !test && administratorCommand([@"/bin/rm -rf -- " stringByAppendingString:shellQuote(path)]) == 0) return YES;
    [errors addObject:[NSString stringWithFormat:@"Could not remove %@: %@", path, error.localizedDescription]];
    return NO;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *role = nil, *app = nil, *testRoot = nil;
        BOOL apply = NO, gui = NO;
        for (int i = 1; i < argc; i++) {
            NSString *arg = @(argv[i]);
            if ([arg isEqual:@"--role"] && i + 1 < argc) role = @(argv[++i]);
            else if ([arg isEqual:@"--app"] && i + 1 < argc) app = @(argv[++i]);
            else if ([arg isEqual:@"--test-root"] && i + 1 < argc) testRoot = @(argv[++i]);
            else if ([arg isEqual:@"--apply"]) apply = YES;
            else if ([arg isEqual:@"--gui"]) gui = YES;
            else { fprintf(stderr, "usage: ReVoyageUninstaller --role sender|receiver [--app PATH] [--gui|--apply] [--test-root PATH]\n"); return 64; }
        }
        if (!role || ![@[@"sender", @"receiver"] containsObject:role]) return 64;
        BOOL sender = [role isEqual:@"sender"], test = testRoot != nil;
        NSString *home = (testRoot ?: NSHomeDirectory()).stringByStandardizingPath;
        if (!home.isAbsolutePath || [home isEqual:@"/"] || [home isEqual:@"/Users"] ||
            ![home isEqual:home.stringByResolvingSymlinksInPath] || (test && [home isEqual:NSHomeDirectory()])) return 64;
        if (app && (!app.isAbsolutePath || !appOwned(app, sender))) return 64;
        NSArray *entries = plan(home, sender, app.stringByStandardizingPath, test);
        if (gui && test) return 64;
        if (gui && !apply) {
            [NSApplication sharedApplication];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Uninstall iMac ReVoyage / 卸载 iMac ReVoyage";
            alert.informativeText = @"Remove this role’s apps, services, pairing credentials, settings, caches and logs. Stored files and physical devices are kept.\n移除本端应用、服务、凭据、设置、缓存和日志。保留存储文件及物理设备。";
            [alert addButtonWithTitle:@"Cancel / 取消"];
            [alert addButtonWithTitle:@"Uninstall / 卸载"];
            if ([alert runModal] != NSAlertSecondButtonReturn) return 0;
            apply = YES;
        }
        if (!apply) {
            NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"role":role, @"entries":entries,
                @"keychainService":sender ? @"com.revoyage.sender.receiver-pairing" : @"", @"bundleIDs":bundleIDs(sender)}
                options:NSJSONWritingPrettyPrinted error:nil];
            fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); return 0;
        }
        NSMutableArray *errors = [NSMutableArray array];
        if (!test && sender) {
            NSData *listing = nil;
            if (run(@"/usr/bin/systemextensionsctl", @[@"list"], &listing) != 0) {
                [errors addObject:@"Cannot inspect camera registration; no application was removed."]; goto finished;
            }
            NSString *text = [[NSString alloc] initWithData:listing encoding:NSUTF8StringEncoding];
            if (!text || [text containsString:@"com.targetbridge.sender.camera"]) {
                [errors addObject:@"Remove the camera extension through Sender first. If macOS requests a restart, restart and retry uninstall. / 请先通过 Sender 卸载摄像头扩展；如系统要求重启，请重启后重试。"]; goto finished;
            }
        }
        if (!test && !sender && !disableOwnedShare(home, errors)) goto finished;
        if (!test) {
            // Stop launchd supervision before terminating apps, so they cannot respawn.
            for (NSDictionary *entry in entries) if ([entry[@"kind"] isEqual:@"agent"]) {
                NSString *label = [entry[@"path"] lastPathComponent].stringByDeletingPathExtension;
                NSString *target = [NSString stringWithFormat:@"gui/%u/%@", getuid(), label];
                if (run(@"/bin/launchctl", @[@"print", target], NULL) == 0 &&
                    run(@"/bin/launchctl", @[@"bootout", target], NULL) != 0) {
                    [errors addObject:[@"Could not stop background service: " stringByAppendingString:label]];
                    goto finished;
                }
            }
            if (!stopOwnedProcesses(entries, sender, errors)) goto finished;
            NSMutableSet *installedIDs = [NSMutableSet set];
            for (NSDictionary *entry in entries) {
                if ([entry[@"kind"] isEqual:@"app"] && appOwned(entry[@"path"], sender)) {
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                        [entry[@"path"] stringByAppendingPathComponent:@"Contents/Info.plist"]];
                    [installedIDs addObject:info[@"CFBundleIdentifier"]];
                }
            }
            if (sender) {
                OSStatus status = SecItemDelete((__bridge CFDictionaryRef)@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                    (__bridge id)kSecAttrService:@"com.revoyage.sender.receiver-pairing"});
                if (status != errSecSuccess && status != errSecItemNotFound)
                    [errors addObject:[NSString stringWithFormat:@"Keychain cleanup failed (%d).", (int)status]];
            }
            for (NSString *identifier in bundleIDs(sender)) {
                for (id host in @[(__bridge id)kCFPreferencesAnyHost, (__bridge id)kCFPreferencesCurrentHost]) {
                    CFArrayRef keys = CFPreferencesCopyKeyList((__bridge CFStringRef)identifier, kCFPreferencesCurrentUser, (__bridge CFStringRef)host);
                    for (NSString *key in CFBridgingRelease(keys)) CFPreferencesSetValue((__bridge CFStringRef)key, NULL,
                        (__bridge CFStringRef)identifier, kCFPreferencesCurrentUser, (__bridge CFStringRef)host);
                    if (!CFPreferencesSynchronize((__bridge CFStringRef)identifier, kCFPreferencesCurrentUser, (__bridge CFStringRef)host))
                        [errors addObject:[@"Preference cleanup failed: " stringByAppendingString:identifier]];
                }
                if ([installedIDs containsObject:identifier] && run(@"/usr/bin/tccutil", @[@"reset", @"All", identifier], NULL) != 0)
                    [errors addObject:[@"Privacy permission cleanup failed: " stringByAppendingString:identifier]];
            }
            // Keep the helper and apps available to retry if credential/permission cleanup failed.
            if (errors.count) goto finished;
        }
        // Remove the privileged audio driver first. If that fails, retain the
        // app/helper for retry; never claim that virtual devices were removed.
        for (NSDictionary *entry in entries) if ([entry[@"kind"] isEqual:@"driver"])
            if (!removeEntry(entry, home, sender, test, errors)) goto finished;
        for (NSDictionary *entry in entries) if (![entry[@"kind"] isEqual:@"driver"])
            removeEntry(entry, home, sender, test, errors);
finished:
        if (errors.count) for (NSString *error in errors) fprintf(stderr, "%s\n", error.UTF8String);
        else puts("Uninstall complete. User storage files and physical devices were preserved.");
        if (gui) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = errors.count ? @"Uninstall incomplete / 卸载未完成" : @"Uninstalled / 已卸载";
            alert.informativeText = errors.count ? [errors componentsJoinedByString:@"\n"] : @"Software cleanup completed. Restart macOS to unload any removed audio driver. User storage files and physical devices were preserved.\n软件已清理，如移除了音频驱动，请重启 macOS 使其卸载。用户存储文件及物理设备已保留。";
            [alert runModal];
        }
        return errors.count ? 1 : 0;
    }
}
