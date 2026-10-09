#import <AppKit/AppKit.h>
#import <Security/Security.h>
#include <unistd.h>

static NSString *quote(NSString *text) { return [NSString stringWithFormat:@"'%@'",[text stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]]; }
static BOOL signedByTeam(NSString *path, NSString *team) {
    SecStaticCodeRef code=NULL; SecRequirementRef requirement=NULL;
    NSString *text=[NSString stringWithFormat:@"anchor apple generic and certificate leaf[subject.OU] = \"%@\"",team];
    BOOL valid=SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:path],kSecCSDefaultFlags,&code)==errSecSuccess&&
        SecRequirementCreateWithString((__bridge CFStringRef)text,kSecCSDefaultFlags,&requirement)==errSecSuccess&&
        SecStaticCodeCheckValidity(code,kSecCSCheckAllArchitectures,requirement)==errSecSuccess;
    if(code)CFRelease(code);if(requirement)CFRelease(requirement);return valid;
}
int main(int argc,char **argv) {
    @autoreleasepool {
        if(argc!=3||strcmp(argv[1],"--app")!=0)return 64;
        NSString *app=@(argv[2]); NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]];
        NSString *team=info[@"ReVoyageSigningTeam"];
        if(!app.isAbsolutePath||![app.stringByStandardizingPath isEqual:app.stringByResolvingSymlinksInPath]||
            ![info[@"CFBundleIdentifier"] isEqual:@"com.targetbridge.sender"]||![team isKindOfClass:NSString.class]||team.length!=10||
            [team rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"] invertedSet]].location!=NSNotFound)return 78;
        NSString *source=[app stringByAppendingPathComponent:@"Contents/Resources/ReVoyageMicrophone.driver"];
        NSString *destination=@"/Library/Audio/Plug-Ins/HAL/ReVoyageMicrophone.driver";
        NSDictionary *driver=[NSDictionary dictionaryWithContentsOfFile:[source stringByAppendingPathComponent:@"Contents/Info.plist"]];
        if(![driver[@"CFBundleIdentifier"] isEqual:@"com.targetbridge.sender.microphone"]||
            ![source isEqual:source.stringByResolvingSymlinksInPath]||!signedByTeam(app,team)||!signedByTeam(source,team))return 78;
        NSFileManager *fm=NSFileManager.defaultManager;
        NSString *parent=destination.stringByDeletingLastPathComponent;
        if(![parent isEqual:parent.stringByResolvingSymlinksInPath])return 78;
        if([fm fileExistsAtPath:destination]||[fm destinationOfSymbolicLinkAtPath:destination error:nil]) {
            NSDictionary *existing=[NSDictionary dictionaryWithContentsOfFile:[destination stringByAppendingPathComponent:@"Contents/Info.plist"]];
            if(![destination isEqual:destination.stringByResolvingSymlinksInPath]||![existing[@"CFBundleIdentifier"] isEqual:driver[@"CFBundleIdentifier"]]||
                !signedByTeam(destination,team))return 78;
        }
        [NSApplication sharedApplication];NSAlert *alert=[NSAlert new];
        alert.messageText=@"Install iMac Microphone / 安装 iMac 虚拟麦克风";
        alert.informativeText=@"Install the signed ReVoyage audio input device. Restart macOS afterward; other audio devices and defaults are kept.\n安装已签名的 ReVoyage 音频输入设备，随后需重启 macOS。保留其它音频设备及默认选择。";
        [alert addButtonWithTitle:@"Cancel / 取消"];[alert addButtonWithTitle:@"Install / 安装"];
        if([alert runModal]!=NSAlertSecondButtonReturn)return 2;
        // A root-owned staging directory prevents an unprivileged rename race
        // during replacement. ditto preserves the verified bundle signature.
        NSString *stage=[destination stringByAppendingString:[@".staging-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *requirement=[NSString stringWithFormat:@"=identifier \"com.targetbridge.sender.microphone\" and anchor apple generic and certificate leaf[subject.OU] = \"%@\"",team];
        NSString *command=[NSString stringWithFormat:@"umask 022; trap %@ EXIT HUP INT TERM; /bin/mkdir -p %@ && /usr/bin/ditto %@ %@ && /usr/sbin/chown -R root:wheel %@ && /bin/chmod -R go-w %@ && /usr/bin/codesign --verify --all-architectures --strict -R %@ %@ && /bin/rm -rf -- %@ && /bin/mv %@ %@",
            quote([@"/bin/rm -rf -- " stringByAppendingString:quote(stage)]),quote(parent),quote(source),quote(stage),quote(stage),quote(stage),quote(requirement),quote(stage),quote(destination),quote(stage),quote(destination)];
        NSString *escaped=[[command stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:@"/usr/bin/osascript"];
        task.arguments=@[@"-e",[NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges",escaped]];
        NSError *error=nil;BOOL success=[task launchAndReturnError:&error];if(success){[task waitUntilExit];success=task.terminationStatus==0;}
        alert=[NSAlert new];alert.messageText=success?@"Installed / 已安装":@"Installation incomplete / 安装未完成";
        alert.informativeText=success?@"Restart macOS, then select ReVoyage — iMac Microphone in your calling app.\n请重启 macOS，然后在通话应用中选择 ReVoyage — iMac Microphone。":@"Installation was cancelled or failed; check the administrator prompt.\n安装已取消或失败，请检查管理员提示。";
        [alert runModal];return success?0:1;
    }
}
