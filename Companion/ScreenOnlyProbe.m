#import "ScreenOnlyProbe.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <CommonCrypto/CommonDigest.h>

static ScreenOnlyProbe *activeProbe;
@interface ScreenOnlyProbe ()
@property NSURL *folder;
@property NSFileHandle *log;
@property NSString *status;
@property id session;
@property id proxy;
@property dispatch_queue_t queue;
@property dispatch_source_t timer;
@property BOOL stopped;
@property BOOL inFlight;
@property int lockToken;
@property double deadline;
@property double unlockedSince;
@property NSUInteger frames;
@property NSUInteger requests;
@property UIBackgroundTaskIdentifier backgroundTask;
@end

@implementation ScreenOnlyProbe
+ (void)start {
    if (activeProbe) return;
    activeProbe = [ScreenOnlyProbe new];
    [activeProbe begin];
}
+ (void)stop { if (activeProbe) dispatch_async(activeProbe.queue, ^{ [activeProbe finish:@"Stopped by user"]; }); }
+ (NSString *)statusText { @synchronized(activeProbe) { return activeProbe.status ?: @"Starting screenshot-only probe…"; } }
- (void)record:(NSString *)event values:(NSDictionary *)values {
    NSMutableDictionary *row = [@{@"at":@(NSDate.date.timeIntervalSince1970), @"event":event} mutableCopy];
    [row addEntriesFromDictionary:values ?: @{}];
    NSData *json = [NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
    [self.log writeData:json]; [self.log writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [self.log synchronizeFile];
}
- (void)report:(NSString *)text {
    @synchronized(self) { self.status = text; }
    [self record:@"status" values:@{@"message":text,@"frames":@(self.frames),@"requests":@(self.requests)}];
    NSDictionary *value = @{@"at":@(NSDate.date.timeIntervalSince1970),@"message":text,@"frames":@(self.frames),@"requests":@(self.requests),@"stopped":@(self.stopped)};
    [[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil]
        writeToURL:[self.folder URLByAppendingPathComponent:@"status.json"] atomically:YES];
}
- (void)finish:(NSString *)reason {
    if (self.stopped) return;
    self.stopped = YES;
    if (self.timer) dispatch_source_cancel(self.timer);
    [self report:reason];
    if ([self.session respondsToSelector:NSSelectorFromString(@"connection")]) {
        id connection = ((id(*)(id,SEL))objc_msgSend)(self.session,NSSelectorFromString(@"connection"));
        if ([connection respondsToSelector:@selector(invalidate)]) [connection invalidate];
    }
    self.proxy = nil; self.session = nil;
    if (self.lockToken >= 0) { notify_cancel(self.lockToken); self.lockToken = -1; }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.backgroundTask != UIBackgroundTaskInvalid) {
            [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];
            self.backgroundTask = UIBackgroundTaskInvalid;
        }
    });
}
- (void)begin {
    self.lockToken = -1;
    self.backgroundTask = UIBackgroundTaskInvalid;
    self.queue = dispatch_queue_create("phantom.screen-only-probe", DISPATCH_QUEUE_SERIAL);
    NSURL *group = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.me.sophiaxu.phantomcapture"];
    self.folder = [[group URLByAppendingPathComponent:@"Documents/Capture/diagnostics"] URLByAppendingPathComponent:[@"screen-only-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:self.folder withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
    NSURL *file = [self.folder URLByAppendingPathComponent:@"events.jsonl"];
    [NSFileManager.defaultManager createFileAtPath:file.path contents:nil attributes:nil];
    self.log = [NSFileHandle fileHandleForWritingAtPath:file.path];
    self.backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Screenshot capability probe" expirationHandler:^{
        dispatch_async(self.queue, ^{ [self finish:@"Background execution allowance expired"]; });
    }];
    dispatch_async(self.queue, ^{
        [self report:@"Connecting directly to screenshot service; UI automation is not requested"];
        self.deadline = NSProcessInfo.processInfo.systemUptime + 120;
        if (notify_register_check("com.apple.springboard.lockstate", &self->_lockToken) != NOTIFY_STATUS_OK) {
            [self finish:@"Lock state unavailable; refusing capture"]; return;
        }
        // These frameworks supply the XPC protocol and image classes. No test
        // runner, enableAutomationMode, or UI automation initialization is called.
        NSArray *paths = @[@"/System/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore",@"/System/Developer/Library/Frameworks/XCUIAutomation.framework/XCUIAutomation",@"/System/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/XCTAutomationSupport"];
        for (NSString *path in paths) {
            void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);
            const char *error = handle ? NULL : dlerror();
            [self record:@"load" values:@{@"path":path,@"ok":@(handle != NULL),@"error":error ? @(error) : @""}];
        }
        Class cls = NSClassFromString(@"XCTRunnerDaemonSession");
        SEL initialize = NSSelectorFromString(@"initiateSessionWithCompletion:");
        if (![cls respondsToSelector:initialize]) { [self finish:@"Screenshot session API unavailable"]; return; }
        self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self.queue);
        dispatch_source_set_timer(self.timer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC/2,NSEC_PER_SEC/20);
        dispatch_source_set_event_handler(self.timer,^{ [self tick]; });
        dispatch_resume(self.timer);
        @try {
            // Xcode 27 implementation confirms completion(session, error).
            ((void(*)(id,SEL,id))objc_msgSend)(cls,initialize,^(id session, NSError *error) {
                dispatch_async(self.queue, ^{
                    if (self.stopped) return;
                    if (error || !session) { [self finish:[NSString stringWithFormat:@"Session failed: %@",error ?: @"no session"]]; return; }
                    self.session = session;
                    self.proxy = ((id(*)(id,SEL))objc_msgSend)(session,NSSelectorFromString(@"daemonProxy"));
                    [self record:@"session-connected" values:@{@"class":NSStringFromClass([session class]),@"proxy":@(self.proxy != nil)}];
                    [self report:@"Connected; testing inner-display screenshots without UI automation"];
                });
            });
        } @catch (NSException *exception) { [self finish:[NSString stringWithFormat:@"Session exception: %@",exception.reason]]; }
    });
}
- (BOOL)unlocked {
    uint64_t state = UINT64_MAX; int changed = 0;
    if (self.lockToken < 0 || notify_get_state(self.lockToken,&state) != NOTIFY_STATUS_OK || notify_check(self.lockToken,&changed) != NOTIFY_STATUS_OK) return NO;
    if (state != 0 || changed) { self.unlockedSince = 0; return NO; }
    __block BOOL available = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{ available = UIApplication.sharedApplication.protectedDataAvailable; });
    if (!available) { self.unlockedSince = 0; return NO; }
    double now = NSProcessInfo.processInfo.systemUptime;
    if (!self.unlockedSince) self.unlockedSince = now;
    return now-self.unlockedSince >= 3;
}
- (void)tick {
    if (self.stopped) return;
    if (NSProcessInfo.processInfo.systemUptime >= self.deadline) { [self finish:@"Probe finished (120-second limit)"]; return; }
    if (!self.proxy || self.inFlight || ![self unlocked]) return;
    @try {
        Class encClass = NSClassFromString(@"XCTImageEncoding");
        SEL encInit = NSSelectorFromString(@"initWithUniformTypeIdentifier:compressionQuality:");
        NSMethodSignature *signature = [encClass instanceMethodSignatureForSelector:encInit];
        id encoding;
        if (signature && strcmp([signature getArgumentTypeAtIndex:3],@encode(float)) == 0)
            encoding = ((id(*)(id,SEL,id,float))objc_msgSend)([encClass alloc],encInit,@"public.jpeg",0.5f);
        else if (signature && strcmp([signature getArgumentTypeAtIndex:3],@encode(double)) == 0)
            encoding = ((id(*)(id,SEL,id,double))objc_msgSend)([encClass alloc],encInit,@"public.jpeg",0.5);
        else { [self finish:@"Unknown image-encoding ABI"]; return; }
        Class reqClass = NSClassFromString(@"XCTScreenshotRequest");
        SEL init4 = NSSelectorFromString(@"initWithScreenID:rect:encoding:options:");
        SEL init3 = NSSelectorFromString(@"initWithScreenID:rect:encoding:");
        id request = nil;
        if ([reqClass instancesRespondToSelector:init4]) request = ((id(*)(id,SEL,long,CGRect,id,id))objc_msgSend)([reqClass alloc],init4,2,CGRectNull,encoding,nil);
        else if ([reqClass instancesRespondToSelector:init3]) request = ((id(*)(id,SEL,long,CGRect,id))objc_msgSend)([reqClass alloc],init3,2,CGRectNull,encoding);
        if (!request) { [self finish:@"Screenshot request API unavailable"]; return; }
        self.inFlight = YES; self.requests++;
        double began = NSProcessInfo.processInfo.systemUptime;
        [self record:@"screenshot-request" values:@{@"number":@(self.requests),@"display":@2}];
        ((void(*)(id,SEL,id,id))objc_msgSend)(self.proxy,NSSelectorFromString(@"_XCT_requestScreenshot:withReply:"),request,^(id image,NSError *error) {
            dispatch_async(self.queue, ^{
                self.inFlight = NO;
                if (self.stopped) return;
                if (error || !image) { [self finish:[NSString stringWithFormat:@"Screenshot rejected: %@",error ?: @"no image"]]; return; }
                if (![self unlocked]) { [self record:@"discarded-lock-transition" values:nil]; return; }
                NSData *data = [image isKindOfClass:NSData.class] ? image : ([image respondsToSelector:@selector(data)] ? ((id(*)(id,SEL))objc_msgSend)(image,@selector(data)) : nil);
                UIImage *decoded = data ? [UIImage imageWithData:data] : nil;
                if (!decoded.CGImage) { [self finish:@"Screenshot reply could not be decoded"]; return; }
                self.frames++;
                unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
                NSMutableString *hash = [NSMutableString new]; for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [hash appendFormat:@"%02x",digest[i]];
                [self record:@"frame" values:@{@"number":@(self.frames),@"bytes":@(data.length),@"width":@(CGImageGetWidth(decoded.CGImage)),@"height":@(CGImageGetHeight(decoded.CGImage)),@"sha256":hash,@"ms":@((NSProcessInfo.processInfo.systemUptime-began)*1000)}];
                [self report:[NSString stringWithFormat:@"%lu screenshots received without requesting UI automation",(unsigned long)self.frames]];
            });
        });
    } @catch (NSException *exception) { [self finish:[NSString stringWithFormat:@"Screenshot exception: %@",exception.reason]]; }
}
@end
