#import "ProbeBenchmark.h"
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <sys/resource.h>
#import <mach/mach.h>
#import <objc/message.h>

@interface NSObject (PhantomGestureSPI)
- (id)initWithName:(NSString *)name displayID:(long long)displayID interfaceOrientation:(NSInteger)orientation;
- (id)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
- (void)addPointerEventPath:(id)path;
- (id)eventSynthesizer;
- (void)synthesizeEvent:(id)event completion:(void (^)(BOOL, NSError *))completion;
- (NSInteger)interfaceOrientation;
@end

@implementation ProbeBenchmark {
    NSURL *_folder;
    NSFileHandle *_metrics;
    double _start, _lastSample;
    NSMutableArray *_latencies;
    dispatch_group_t _worker;
    long long _displayID;
    CGSize _displaySize;
    NSInteger _orientation;
    BOOL _captureDisabled;
    double _swipeInterval;
}
- (instancetype)initWithFolder:(NSURL *)folder duration:(double)duration {
    if ((self = [super init])) {
        _folder = folder; self.duration = duration; _latencies = [NSMutableArray new];
        _captureDisabled = [NSProcessInfo.processInfo.environment[@"PHANTOM_CAPTURE_DISABLED"] boolValue];
        _swipeInterval = MAX(0, [NSProcessInfo.processInfo.environment[@"PHANTOM_SWIPE_INTERVAL"] doubleValue]);
        NSURL *url = [folder URLByAppendingPathComponent:@"benchmark.jsonl"];
        [NSFileManager.defaultManager createFileAtPath:url.path contents:nil attributes:nil];
        _metrics = [NSFileHandle fileHandleForWritingAtPath:url.path];
    }
    return self;
}
- (void)start {
    _start = NSProcessInfo.processInfo.systemUptime;
    void (^enable)(void) = ^{ UIDevice.currentDevice.batteryMonitoringEnabled = YES; };
    if (NSThread.isMainThread) enable(); else dispatch_sync(dispatch_get_main_queue(), enable);
    _worker = dispatch_group_create();
    dispatch_group_async(_worker, dispatch_queue_create("phantom.benchmark.swipes", DISPATCH_QUEUE_SERIAL), ^{
        @autoreleasepool {
            @try {
                __block XCUIApplication *home;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    @try {
                        home = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];
                        [home activate];
                        XCUIScreen *screen = XCUIScreen.screens.lastObject;
                        self->_displayID = [[screen valueForKey:@"displayID"] longLongValue];
                        if (self->_captureDisabled) {
                            // Reuse the verified geometry without taking even a setup screenshot.
                            self->_displaySize = CGSizeMake([NSProcessInfo.processInfo.environment[@"PHANTOM_GESTURE_WIDTH"] doubleValue], [NSProcessInfo.processInfo.environment[@"PHANTOM_GESTURE_HEIGHT"] doubleValue]);
                            if (self->_displaySize.width <= 0 || self->_displaySize.height <= 0) {
                                self.failure = @"No-capture benchmark requires verified gesture dimensions"; return;
                            }
                        } else self->_displaySize = screen.screenshot.image.size;
                        self->_orientation = [home interfaceOrientation];
                    } @catch (NSException *e) { self.failure = e.reason; }
                });
                if (self.failure.length) return;
                int token = -1;
                if (notify_register_check("com.apple.springboard.lockstate", &token) != NOTIFY_STATUS_OK) {
                    self.failure = @"Lock monitor unavailable for swipe worker"; return;
                }
                while (!self.stopping && NSProcessInfo.processInfo.systemUptime - self->_start < self.duration) {
                    double swipeStarted = NSProcessInfo.processInfo.systemUptime;
                    uint64_t locked = UINT64_MAX;
                    notify_get_state(token, &locked);
                    if (locked != 0) { self.failure = @"Phone locked; stopped swipes"; break; }
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        @try {
                            if (self.stopping) return;
                            if (home.state != XCUIApplicationStateRunningForeground) {
                                self.failure = @"Home Screen is no longer foreground; stopped swipes"; return;
                            }
                            [self performTargetedSwipe];
                        } @catch (NSException *e) { self.failure = e.reason; }
                    });
                    if (self.failure.length) break;
                    double pause = MAX(0.15, self->_swipeInterval - (NSProcessInfo.processInfo.systemUptime - swipeStarted));
                    [NSThread sleepForTimeInterval:pause];
                }
                notify_cancel(token);
            } @catch (NSException *exception) {
                self.failure = [NSString stringWithFormat:@"Swipe exception: %@", exception.reason];
            }
        }
    });
}
- (void)performTargetedSwipe {
    Class recordClass = NSClassFromString(@"XCSynthesizedEventRecord");
    Class pathClass = NSClassFromString(@"XCPointerEventPath");
    id synthesizer = [XCUIDevice.sharedDevice eventSynthesizer];
    if (![recordClass instancesRespondToSelector:@selector(initWithName:displayID:interfaceOrientation:)] ||
        ![pathClass instancesRespondToSelector:@selector(initForTouchAtPoint:offset:)] ||
        ![synthesizer respondsToSelector:@selector(synthesizeEvent:completion:)]) {
        self.failure = @"Display-targeted event synthesis unavailable"; return;
    }
    BOOL left = self.swipes % 2 == 0;
    CGPoint start = CGPointMake(_displaySize.width*(left ? 0.8 : 0.2),_displaySize.height*0.55);
    CGPoint finish = CGPointMake(_displaySize.width*(left ? 0.2 : 0.8),_displaySize.height*0.55);
    id path = [[pathClass alloc] initForTouchAtPoint:start offset:0];
    for (int step=1; step<=6; step++) {
        double fraction = step/6.0;
        [path moveToPoint:CGPointMake(start.x+(finish.x-start.x)*fraction,start.y) atOffset:0.3*fraction];
    }
    [path liftUpAtOffset:0.31];
    id record = [[recordClass alloc] initWithName:@"Phantom Home Screen swipe" displayID:_displayID interfaceOrientation:_orientation];
    [record addPointerEventPath:path];
    __block BOOL done = NO;
    [synthesizer synthesizeEvent:record completion:^(BOOL success, NSError *error) {
        if (!success || error) self.failure = error.localizedDescription ?: @"Gesture rejected";
        done = YES;
    }];
    double deadline = NSProcessInfo.processInfo.systemUptime + 4;
    while (!done && NSProcessInfo.processInfo.systemUptime < deadline) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    if (!done) self.failure = @"Gesture acknowledgement timed out";
    if (!self.failure.length) self.swipes++;
}
- (void)recordCaptureMilliseconds:(double)milliseconds { [_latencies addObject:@(milliseconds)]; }
- (void)sampleFrames:(NSInteger)frames bytes:(unsigned long long)bytes {
    double now = NSProcessInfo.processInfo.systemUptime;
    if (_lastSample && now - _lastSample < 5 && !self.stopping) return;
    _lastSample = now;
    struct rusage usage = {0}; getrusage(RUSAGE_SELF, &usage);
    double cpu = usage.ru_utime.tv_sec + usage.ru_utime.tv_usec/1e6 + usage.ru_stime.tv_sec + usage.ru_stime.tv_usec/1e6;
    task_vm_info_data_t memory = {0}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t memoryResult = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memory, &count);
    __block float battery = -1, brightness = -1;
    __block NSInteger batteryState = 0;
    void (^ui)(void) = ^{
        battery = UIDevice.currentDevice.batteryLevel;
        batteryState = UIDevice.currentDevice.batteryState;
        brightness = UIScreen.mainScreen.brightness;
    };
    if (NSThread.isMainThread) ui(); else dispatch_sync(dispatch_get_main_queue(), ui);
    NSDictionary *sample = @{
        @"at":@(NSDate.date.timeIntervalSince1970), @"elapsed":@(now-_start),
        @"captureDisabled":@(_captureDisabled), @"swipeInterval":@(_swipeInterval),
        @"frames":@(frames), @"bytes":@(bytes), @"swipes":@(self.swipes),
        @"cpuSeconds":@(cpu), @"footprintBytes":memoryResult==KERN_SUCCESS ? @(memory.phys_footprint) : @(-1),
        @"residentBytes":memoryResult==KERN_SUCCESS ? @(memory.resident_size) : @(-1),
        @"batteryLevel":@(battery), @"batteryState":@(batteryState), @"brightness":@(brightness),
        @"thermalState":@(NSProcessInfo.processInfo.thermalState),
        @"lowPowerMode":@(NSProcessInfo.processInfo.lowPowerModeEnabled),
        @"swipeError":self.failure ?: @"", @"captureMilliseconds":[_latencies copy],
        @"finished":@(self.stopping), @"gestureDisplayID":@(_displayID), @"gestureSize":NSStringFromCGSize(_displaySize), @"gestureOrientation":@(_orientation)
    };
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:sample options:0 error:nil] mutableCopy];
    [data appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [_metrics writeData:data]; [_metrics synchronizeFile]; [_latencies removeAllObjects];
}
- (void)finishFrames:(NSInteger)frames bytes:(unsigned long long)bytes {
    self.stopping = YES;
    // The foreground check and at most one in-flight gesture remain before exit.
    // Do not block the main run loop needed by XCTest gesture completion.
    double deadline = NSProcessInfo.processInfo.systemUptime + 8;
    while (dispatch_group_wait(_worker, DISPATCH_TIME_NOW) != 0 && NSProcessInfo.processInfo.systemUptime < deadline) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    [self sampleFrames:frames bytes:bytes];
    [_metrics closeFile];
}
@end
