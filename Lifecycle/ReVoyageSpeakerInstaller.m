#import <AppKit/AppKit.h>
#import <Security/Security.h>

static NSString *quote(NSString *text) {
    return [NSString stringWithFormat:@"'%@'",[text stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}
static BOOL signedAs(NSString *path, NSString *identifier) {
    SecStaticCodeRef code=NULL;SecRequirementRef requirement=NULL;
    NSString *text=[NSString stringWithFormat:@"identifier \"%@\"",identifier];
    OSStatus status=SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:path],kSecCSDefaultFlags,&code);
    if(status==errSecSuccess)status=SecRequirementCreateWithString((__bridge CFStringRef)text,kSecCSDefaultFlags,&requirement);
    if(status==errSecSuccess)status=SecStaticCodeCheckValidity(code,kSecCSCheckAllArchitectures|kSecCSCheckNestedCode,requirement);
    BOOL valid=status==errSecSuccess;
    if(!valid)fprintf(stderr,"Signature verification failed (%d): %s\n",(int)status,path.UTF8String);
    if(code)CFRelease(code);if(requirement)CFRelease(requirement);return valid;
}
int main(int argc,char **argv) {
    @autoreleasepool {
        if((argc!=3&&argc!=4)||strcmp(argv[1],"--app")||(argc==4&&strcmp(argv[3],"--check")))return 64;
        NSString *app=@(argv[2]);NSString *identifier=@"com.targetbridge.sender.speaker";
        NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"]];
        if(!app.isAbsolutePath||![app.stringByStandardizingPath isEqual:app.stringByResolvingSymlinksInPath]||
            ![info[@"CFBundleIdentifier"] isEqual:@"com.targetbridge.sender"]||!signedAs(app,@"com.targetbridge.sender")) { fprintf(stderr,"Sender path, identity or signature verification failed.\n"); return 78; }
        NSString *source=[app stringByAppendingPathComponent:@"Contents/Resources/ReVoyageSpeaker.driver"];
        NSDictionary *plugin=[NSDictionary dictionaryWithContentsOfFile:[source stringByAppendingPathComponent:@"Contents/Info.plist"]];
        if(![plugin[@"CFBundleIdentifier"] isEqual:identifier]||![source.stringByStandardizingPath isEqual:source.stringByResolvingSymlinksInPath]||!signedAs(source,identifier)) { fprintf(stderr,"iMac speaker bundle verification failed: %s -> %s\n",source.UTF8String,source.stringByResolvingSymlinksInPath.UTF8String); return 78; }
        NSString *destination=@"/Library/Audio/Plug-Ins/HAL/ReVoyageSpeaker.driver";
        NSString *parent=destination.stringByDeletingLastPathComponent;
        if(![parent isEqual:parent.stringByResolvingSymlinksInPath]) { fprintf(stderr,"Audio plug-in parent resolves to a different path.\n"); return 78; }
        NSFileManager *fm=NSFileManager.defaultManager;
        if([fm fileExistsAtPath:destination]||[fm destinationOfSymbolicLinkAtPath:destination error:nil]) {
            NSDictionary *existing=[NSDictionary dictionaryWithContentsOfFile:[destination stringByAppendingPathComponent:@"Contents/Info.plist"]];
            if(![destination isEqual:destination.stringByResolvingSymlinksInPath]||![existing[@"CFBundleIdentifier"] isEqual:identifier]||!signedAs(destination,identifier)) { fprintf(stderr,"Existing speaker driver is not owned by ReVoyage.\n"); return 78; }
        }
        if(argc==4)return 0; // Package regression: verification only, no installation.
        // Root creates a private staging directory, verifies the copied bundle,
        // and replaces only our named output driver. Defaults are never changed.
        NSString *requirement=@"=identifier \"com.targetbridge.sender.speaker\"";
        NSString *command=[NSString stringWithFormat:@"set -eu; umask 022; /bin/mkdir -p %@; stage=$(/usr/bin/mktemp -d %@); trap '/bin/rm -rf -- \"$stage\"' EXIT HUP INT TERM; /usr/bin/ditto --norsrc --noextattr %@ \"$stage/ReVoyageSpeaker.driver\"; /usr/sbin/chown -R root:wheel \"$stage\"; /bin/chmod -R go-w \"$stage\"; /usr/bin/codesign --verify --all-architectures --strict -R %@ \"$stage/ReVoyageSpeaker.driver\"; if [ -L %@ ]; then exit 78; fi; if [ -e %@ ]; then /usr/bin/codesign --verify --all-architectures --strict -R %@ %@; fi; /bin/rm -rf -- %@; /bin/mv \"$stage/ReVoyageSpeaker.driver\" %@",
            quote(parent),quote([parent stringByAppendingPathComponent:@".ReVoyageSpeaker-install.XXXXXX"]),quote(source),quote(requirement),
            quote(destination),quote(destination),quote(requirement),quote(destination),quote(destination),quote(destination)];
        NSString *escaped=[[command stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:@"/usr/bin/osascript"];
        task.arguments=@[@"-e",[NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges",escaped]];
        NSError *error=nil;BOOL success=[task launchAndReturnError:&error];if(success){[task waitUntilExit];success=task.terminationStatus==0;}
        fprintf(success?stdout:stderr,"%s\n",success?"iMac speaker installed. Restart macOS, then select ReVoyage — iMac Speakers in Sound output. / 已安装 iMac 扬声器。请重启 Mac mini，然后在声音输出中选择 ReVoyage — iMac Speakers。":"iMac speaker installation cancelled or failed. / iMac 扬声器安装已取消或失败。");
        return success?0:1;
    }
}
