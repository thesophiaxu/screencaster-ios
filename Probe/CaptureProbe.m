#import <XCTest/XCTest.h>
#import "ProbeMonitor.h"
#import "ProbeBenchmark.h"
#import "RecorderService.h"
#import <UIKit/UIKit.h>
#import <notify.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>

static BOOL probeTestEntered = NO;

// Disable XCTest's independent diagnostic captures before tests start.
@interface ProbeDefaults : NSObject
+ (void)backgroundWhenReady:(NSInteger)remaining;
@end
@implementation ProbeDefaults
+ (void)load {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        @"DisableDiagnosticScreenRecordings": @YES,
        @"DisableDiagnosticScreenshots": @YES
    }];
    NSLog(@"PROBE bootstrap bundle loaded");
    [self backgroundWhenReady:60];
}
+ (void)backgroundWhenReady:(NSInteger)remaining {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        if (probeTestEntered || remaining <= 0) return;
        UIApplication *app = UIApplication.sharedApplication;
        BOOL safe = app.applicationState == UIApplicationStateActive;
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundInactive) safe = NO;
        }
        int token = -1;
        uint64_t locked = UINT64_MAX;
        if (notify_register_check("com.apple.springboard.lockstate", &token) == NOTIFY_STATUS_OK) {
            notify_get_state(token, &locked);
            notify_cancel(token);
        }
        if (!safe || locked != 0 || !app.protectedDataAvailable) {
            [self backgroundWhenReady:remaining - 1];
            return;
        }
        // Direct XCTest launch can stall while trying to background its runner.
        // Never suspend over the UI Automation authorization prompt, and never
        // start a second XCTest bootstrap inside the existing process.
        NSURL *returnURL=[NSURL URLWithString:@"phantom-monitor://returned"];
        if ([app canOpenURL:returnURL]) {
            [app openURL:returnURL options:@{} completionHandler:nil];
            return;
        }
        SEL suspend = NSSelectorFromString(@"suspend");
        if ([app respondsToSelector:suspend]) {
            NSLog(@"PROBE bootstrap backgrounding runner");
            ((void (*)(id, SEL))objc_msgSend)(app, suspend);
        }
    });
}
@end

@interface CaptureProbe : XCTestCase
@property NSURL *folder;
@property NSFileHandle *logFile;
@property UIWindow *probeWindow;
@property UILabel *statusLabel;
@property BOOL stopped;
@property NSInteger saved;
@property ProbeMonitor *monitor;
@property NSMutableArray *events;
@property NSMutableDictionary *displayCounts;
@property NSString *lastError;
@property NSString *lastFilename;
@property double startedAt;
@property double startedUptime;
@property double lastFrameAt;
@property unsigned long long savedBytes;
@property NSUInteger discarded;
@property NSUInteger locks;
@property NSUInteger unlocks;
@property NSUInteger buffered;
@property NSString *phase;
@property ProbeBenchmark *benchmark;
@property double limitSeconds;
@end

@implementation CaptureProbe
- (void)log:(NSString *)message {
    NSString *line = [NSString stringWithFormat:@"%.3f %@\n", NSDate.date.timeIntervalSince1970, message];
    [self.logFile writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [self.logFile synchronizeFile];
    NSLog(@"PROBE %@", message);
    if (![message hasPrefix:@"frame="] && ![message hasPrefix:@"screens="]) {
        [self.events addObject:@{@"at":@(NSDate.date.timeIntervalSince1970),@"message":message}];
        if (self.events.count > 60) [self.events removeObjectAtIndex:0];
    }
    if ([message containsString:@"failed"] || [message containsString:@"exception"] || [message containsString:@"unavailable"]) self.lastError = message;
}
- (void)publish {
    NSArray *thermalNames = @[@"Nominal", @"Fair", @"Serious", @"Critical"];
    NSInteger thermal = NSProcessInfo.processInfo.thermalState;
    self.monitor.snapshot = @{
        @"schema":@1, @"session":self.folder.lastPathComponent ?: @"",
        @"state":self.phase ?: @"starting", @"heartbeat":@(NSDate.date.timeIntervalSince1970),
        @"startedAt":@(self.startedAt), @"elapsed":@(NSProcessInfo.processInfo.systemUptime-self.startedUptime),
        @"limitSeconds":@(self.limitSeconds), @"frames":@(self.saved), @"bytes":@(self.savedBytes),
        @"lastFrameAt":@(self.lastFrameAt), @"lastFile":self.lastFilename ?: @"",
        @"discarded":@(self.discarded), @"buffered":@(self.buffered),
        @"locks":@(self.locks), @"unlocks":@(self.unlocks),
        @"displays":[self.displayCounts copy] ?: @{}, @"events":[self.events copy] ?: @[],
        @"error":self.lastError ?: @"", @"thermal":thermalNames[MIN(MAX(thermal,0),3)]
    };
}
- (void)stopProbe { self.stopped = YES; }
- (void)showStatus {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        self.probeWindow = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = UIColor.systemBackgroundColor;
        self.statusLabel = [UILabel new];
        self.statusLabel.numberOfLines = 0;
        self.statusLabel.textAlignment = NSTextAlignmentCenter;
        self.statusLabel.text = @"Phantom Capture Probe\nStarting XCTest capture…\n\n1 frame/second, unlocked only.\nStops automatically after 10 minutes.";
        UIButton *stop = [UIButton buttonWithType:UIButtonTypeSystem];
        [stop setTitle:@"Stop probe" forState:UIControlStateNormal];
        [stop addTarget:self action:@selector(stopProbe) forControlEvents:UIControlEventTouchUpInside];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.statusLabel, stop]];
        stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 24;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.centerYAnchor constraintEqualToAnchor:vc.view.centerYAnchor],
            [stack.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:24],
            [stack.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-24]
        ]];
        self.probeWindow.rootViewController = vc;
        [self.probeWindow makeKeyAndVisible];
        break;
    }
}
- (void)setUp {
    dispatch_async(dispatch_get_main_queue(), ^{ probeTestEntered = YES; });
    [super setUp];
}
- (void)testCapture {
    self.continueAfterFailure = YES;
    if (![NSProcessInfo.processInfo.environment[@"PHANTOM_BENCHMARK_SECONDS"] doubleValue] || [NSProcessInfo.processInfo.environment[@"PHANTOM_CAPTURE_MODE"] isEqualToString:@"video"]) {
        [[[RecorderService alloc] init] run]; return;
    }
    double benchmarkSeconds = [NSProcessInfo.processInfo.environment[@"PHANTOM_BENCHMARK_SECONDS"] doubleValue];
    BOOL captureDisabled = benchmarkSeconds > 0 && [NSProcessInfo.processInfo.environment[@"PHANTOM_CAPTURE_DISABLED"] boolValue];
    self.limitSeconds = benchmarkSeconds > 0 ? MIN(benchmarkSeconds, 300) : 600;
    self.startedAt = NSDate.date.timeIntervalSince1970;
    self.startedUptime = NSProcessInfo.processInfo.systemUptime;
    self.events = [NSMutableArray new];
    self.displayCounts = [NSMutableDictionary new];
    self.monitor = [ProbeMonitor new];
    self.phase = @"starting";
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    self.folder = [[documents URLByAppendingPathComponent:@"Probe"] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSError *error;
    if (![NSFileManager.defaultManager createDirectoryAtURL:self.folder withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error]) {
        XCTFail(@"Storage failed: %@", error); return;
    }
    [self.folder setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    NSURL *logURL = [self.folder URLByAppendingPathComponent:@"events.log"];
    [NSFileManager.defaultManager createFileAtPath:logURL.path contents:nil attributes:nil];
    self.logFile = [NSFileHandle fileHandleForWritingAtPath:logURL.path];
    [self log:[NSString stringWithFormat:@"started version=7 maxSeconds=%.0f intervalSeconds=1 allScreens=true commitDelay=3 benchmark=%d captureDisabled=%d",self.limitSeconds,benchmarkSeconds>0,captureDisabled]];
    [self publish];
    if (![self.monitor start:&error]) {
        [self log:[NSString stringWithFormat:@"monitor-start-failed %@", error]];
        [self.logFile closeFile]; return;
    }
    int token = -1;
    int registered = notify_register_check("com.apple.springboard.lockstate", &token);
    if (registered != NOTIFY_STATUS_OK) {
        [self log:@"lock-monitor-unavailable; refusing capture"]; self.phase=@"error"; [self publish]; [self.logFile closeFile]; [self.monitor close]; return;
    }
    void (^ui)(void) = ^{ [self showStatus]; };
    if (NSThread.isMainThread) ui(); else dispatch_sync(dispatch_get_main_queue(), ui);
    if (benchmarkSeconds > 0) {
        self.benchmark = [[ProbeBenchmark alloc] initWithFolder:self.folder duration:self.limitSeconds];
        [self.benchmark start];
        [self.benchmark sampleFrames:0 bytes:0];
        [self log:@"benchmark-started alternating-home-swipes"];
    }
    double end = NSProcessInfo.processInfo.systemUptime + self.limitSeconds;
    uint64_t previous = UINT64_MAX;
    NSMutableArray<NSDictionary *> *pending = [NSMutableArray new];
    double unlockedSince = NSProcessInfo.processInfo.systemUptime;
    while (!self.stopped && !self.monitor.stopRequested && NSProcessInfo.processInfo.systemUptime < end) {
        @autoreleasepool {
            uint64_t state = UINT64_MAX;
            notify_get_state(token, &state);
            __block BOOL protected = NO;
            void (^check)(void) = ^{ protected = UIApplication.sharedApplication.protectedDataAvailable; };
            if (NSThread.isMainThread) check(); else dispatch_sync(dispatch_get_main_queue(), check);
            int changed = 1;
            notify_check(token, &changed);
            if (changed || state != 0 || !protected) {
                if (pending.count) [self log:[NSString stringWithFormat:@"discarded-pending=%lu lock-transition",(unsigned long)pending.count]];
                self.discarded += pending.count;
                [pending removeAllObjects];
                unlockedSince = NSProcessInfo.processInfo.systemUptime;
            }
            if (state != previous) { if (previous != UINT64_MAX) { if (state == 0) self.unlocks++; else self.locks++; } [self log:[NSString stringWithFormat:@"lock-state=%llu protected=%d", state, protected]]; previous = state; }
            // Hold frames for three seconds so a late lock notification can
            // discard transition frames. Do not flush the tail at stop.
            while (state == 0 && protected && pending.count &&
                   NSProcessInfo.processInfo.systemUptime - [pending.firstObject[@"uptime"] doubleValue] >= 3) {
                NSDictionary *frame = pending.firstObject;
                uint64_t current = UINT64_MAX; notify_get_state(token, &current);
                if (NSThread.isMainThread) check(); else dispatch_sync(dispatch_get_main_queue(), check);
                if (current != 0 || !protected) { self.discarded += pending.count; [pending removeAllObjects]; break; }
                NSData *jpeg = frame[@"jpeg"];
                NSString *name = [NSString stringWithFormat:@"%06ld-screen%@.jpg",(long)self.saved,frame[@"index"]];
                NSError *writeError;
                if ([jpeg writeToURL:[self.folder URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:&writeError]) {
                    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
                    CC_SHA256(jpeg.bytes, (CC_LONG)jpeg.length, digest);
                    NSMutableString *hash = [NSMutableString new];
                    for (int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [hash appendFormat:@"%02x",digest[i]];
                    self.saved++;
                    self.savedBytes += jpeg.length;
                    self.lastFrameAt = [frame[@"wallTime"] doubleValue];
                    self.lastFilename = name;
                    NSString *display = frame[@"screen"];
                    self.displayCounts[display] = @([self.displayCounts[display] integerValue]+1);
                    [self log:[NSString stringWithFormat:@"frame=%@ capturedAt=%@ screen=%@ size=%@ bytes=%lu sha256=%@",name,frame[@"wallTime"],frame[@"screen"],frame[@"size"],(unsigned long)jpeg.length,hash]];
                } else { [self log:[NSString stringWithFormat:@"write-failed %@",writeError]]; self.stopped=YES; break; }
                [pending removeObjectAtIndex:0];
            }
            if (!captureDisabled && state == 0 && protected && NSProcessInfo.processInfo.systemUptime-unlockedSince >= 3) {
                @try {
                    NSArray<XCUIScreen *> *screens = XCUIScreen.screens;
                    if (self.saved == 0) [self log:[NSString stringWithFormat:@"screens=%@",screens]];
                    for (NSUInteger screenIndex=0; screenIndex<screens.count; screenIndex++) {
                    double captureStart = NSProcessInfo.processInfo.systemUptime;
                    XCUIScreenshot *shot = screens[screenIndex].screenshot;
                    NSData *jpeg = UIImageJPEGRepresentation(shot.image, 0.7);
                    [self.benchmark recordCaptureMilliseconds:(NSProcessInfo.processInfo.systemUptime-captureStart)*1000];
                    uint64_t after = UINT64_MAX; notify_get_state(token, &after);
                    if (NSThread.isMainThread) check(); else dispatch_sync(dispatch_get_main_queue(), check);
                    if (after == 0 && protected && jpeg.length) {
                        [pending addObject:@{@"jpeg":jpeg,@"index":@(screenIndex),@"screen":screens[screenIndex].description,@"size":NSStringFromCGSize(shot.image.size),@"uptime":@(NSProcessInfo.processInfo.systemUptime),@"wallTime":@(NSDate.date.timeIntervalSince1970)}];
                        if (pending.count > 12) { self.discarded++; [pending removeObjectAtIndex:0]; }
                    } else { self.discarded += pending.count + 1; [pending removeAllObjects]; [self log:@"discarded-frame locked-or-empty"]; }
                    }
                } @catch (NSException *exception) { [self log:[NSString stringWithFormat:@"capture-exception %@ %@",exception.name,exception.reason]]; }
            }
            [self.benchmark sampleFrames:self.saved bytes:self.savedBytes];
            self.buffered = pending.count;
            self.phase = self.stopped ? @"error" : state != 0 ? @"locked" : !protected ? @"protected" : captureDisabled ? @"benchmark-no-capture" : NSProcessInfo.processInfo.systemUptime-unlockedSince < 3 ? @"settling" : @"capturing";
            [self publish];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusLabel.text = [NSString stringWithFormat:@"Phantom Capture Probe\n%ld frames saved\n%@\n\nUse another app, then lock and unlock.\nFiles stay on this phone.\nStops after 10 minutes.", (long)self.saved, state == 0 ? @"Unlocked" : @"Locked — no frames saved"];
            });
        }
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    }
    [self.benchmark finishFrames:self.saved bytes:self.savedBytes];
    if (self.benchmark) [self log:[NSString stringWithFormat:@"benchmark-finished swipes=%lu error=%@",(unsigned long)self.benchmark.swipes,self.benchmark.failure ?: @"none"]];
    self.discarded += pending.count;
    [pending removeAllObjects];
    self.buffered = 0;
    self.phase = self.stopped ? @"error" : @"stopped";
    [self log:[NSString stringWithFormat:@"finished saved=%ld reason=%@",(long)self.saved,self.monitor.stopRequested ? @"companion-stop" : self.stopped ? @"error-or-stop" : @"session-time-limit"]];
    [self publish];
    notify_cancel(token);
    [self.logFile closeFile];
    dispatch_async(dispatch_get_main_queue(), ^{ self.statusLabel.text = @"Probe stopped. Files preserved."; });
    // Give the foreground companion time to observe the terminal status.
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:30]];
    [self.monitor close];
}
@end
