#import "RecorderService.h"
#import "VideoRecorder.h"
#import "FrontBoardProbe.h"
#import <XCTest/XCTest.h>
#import <notify.h>
#import <sys/resource.h>
#import <mach/mach.h>
#import <objc/runtime.h>

@interface NSObject (PhantomActiveDisplay)
- (NSArray *)activeForegroundApplications;
@end

// Capture must not wait for the foreground app to finish animating. Install
// only after XCTest bootstrap, and only in this recorder process.
static void noIdleWait(id object, SEL selector, BOOL animations) {}
static void noIdleWaitPreEvent(id object, SEL selector, BOOL animations, BOOL preEvent) {}

@implementation RecorderService {
    NSURL *_root, *_folder;
    NSString *_session, *_phase, *_lastError, *_lastCommand;
    NSMutableArray *_pending, *_events;
    NSMutableDictionary *_displayCounts;
    VideoRecorder *_video;
    BOOL _desired, _needsClose;
    int _lockToken;
    NSUInteger _locks, _unlocks, _discarded, _lastMetricFrames;
    uint64_t _previousLock;
    double _started, _stableSince, _lastFrameAt, _lastPublish, _lastMetric, _lastCPU, _lastCaptureRequest;
    long long _display;
    int _width, _height;
    XCUIScreen *_cachedScreen;
    NSString *_foregroundKey;
    NSMutableDictionary *_applications;
    double _screenResolvedAt, _resolveMS, _captureMS, _resizeMS, _encodeMS, _recentFPS;
    double _stoppedAt;
    NSUInteger _requested;

}
- (void)write:(id)value to:(NSURL *)url {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    [data writeToURL:url options:NSDataWritingAtomic error:nil];
}
- (void)appendJSON:(NSDictionary *)value to:(NSURL *)url {
    NSMutableData *data=[[NSJSONSerialization dataWithJSONObject:value options:0 error:nil] mutableCopy];
    [data appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) [NSFileManager.defaultManager createFileAtPath:url.path contents:nil attributes:nil];
    NSFileHandle *f=[NSFileHandle fileHandleForWritingAtPath:url.path];
    @try { [f seekToEndOfFile]; [f writeData:data]; [f closeFile]; } @catch (NSException *e) { _lastError=[@"history-write-failed " stringByAppendingString:e.reason]; }
}
- (void)event:(NSString *)message {
    NSDictionary *event=@{@"at":@(NSDate.date.timeIntervalSince1970),@"message":message};
    [_events addObject:event]; if (_events.count>30) [_events removeObjectAtIndex:0];
    if (_folder) [self appendJSON:event to:[_folder URLByAppendingPathComponent:@"events.jsonl"]];
    if ([message containsString:@"failed"] || [message containsString:@"unavailable"]) _lastError=message;
    NSLog(@"PHANTOM %@",message);
}
- (BOOL)unlocked {
    uint64_t value=UINT64_MAX;
    if (notify_get_state(_lockToken,&value)!=NOTIFY_STATUS_OK || value!=0) return NO;
    __block BOOL protected=NO;
    void (^read)(void)=^{ protected=UIApplication.sharedApplication.protectedDataAvailable; };
    if (NSThread.isMainThread) read(); else dispatch_sync(dispatch_get_main_queue(),read);
    return protected;
}
- (void)saveSession:(NSString *)state {
    if (!_folder) return;
    [self write:@{@"id":_session,@"startedAt":@(_started),@"updatedAt":@(NSDate.date.timeIntervalSince1970),@"state":state,@"frames":@(_video.frames),@"bytes":@(_video.fileBytes),@"codec":@"HEVC",@"width":@(_width),@"height":@(_height),@"display":@(_display),@"error":_lastError ?: @""} to:[_folder URLByAppendingPathComponent:@"session.json"]];
}
- (void)begin {
    _session=NSUUID.UUID.UUIDString; _started=NSDate.date.timeIntervalSince1970;
    _folder=[[_root URLByAppendingPathComponent:@"sessions"] URLByAppendingPathComponent:_session];
    NSError *error;
    if (![NSFileManager.defaultManager createDirectoryAtURL:_folder withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error]) { _lastError=error.localizedDescription; _desired=NO; return; }
    [_folder setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    _video=[[VideoRecorder alloc] initWithFolder:_folder];
    __weak RecorderService *weak=self;
    _video.event=^(NSString *message) { [weak event:message]; };
    _video.completed=^(NSDictionary *segment) {
        RecorderService *self=weak; if (!self) return;
        [self appendJSON:segment to:[self->_folder URLByAppendingPathComponent:@"segments.jsonl"]];
        [self event:[NSString stringWithFormat:@"video-closed file=%@ frames=%@ bytes=%@",segment[@"file"],segment[@"frames"],segment[@"bytes"]]];
        [self saveSession:@"recording"];
    };
    _displayCounts=[NSMutableDictionary new];
    _lastError=@""; _lastMetricFrames=0; _lastMetric=0; _locks=0; _unlocks=0; _discarded=0; _display=0; _lastFrameAt=0; _cachedScreen=nil; _foregroundKey=nil; _stoppedAt=0; _requested=0;
    _stableSince=NSProcessInfo.processInfo.systemUptime;
    [self event:@"started HEVC hardware-required half-resolution active-display-only maxFPS=2 sessionLimit=none"];
    [self saveSession:@"recording"];
}
- (XCUIScreen *)activeScreen {
    // Resolve a foreground window's snapshot before reading its private screen
    // identity. Never guess main/last screen or sample every panel.
    __block XCUIScreen *resolved=nil;
    __block NSString *failure=nil;
    void (^resolve)(void)=^{
        @try {
            id system=XCUIDevice.sharedDevice.system;
            if (![system respondsToSelector:@selector(activeForegroundApplications)]) { failure=@"active-display-unavailable: missing foreground API"; return; }
            NSArray *processes=[system activeForegroundApplications];
            NSMutableArray *apps=[NSMutableArray new];
            NSMutableArray *identities=[NSMutableArray new];
            for (id process in processes) {
                NSString *bundle=nil;
                for (NSString *key in @[@"bundleID",@"bundleIdentifier"]) {
                    if ([process respondsToSelector:NSSelectorFromString(key)]) { id value=[process valueForKey:key]; if ([value isKindOfClass:NSString.class]) { bundle=value; break; } }
                }
                if (!bundle.length || [bundle containsString:@"phantomprobe"]) continue;
                [identities addObject:bundle];
                XCUIApplication *app=self->_applications[bundle];
                if (!app) { app=[[XCUIApplication alloc] initWithBundleIdentifier:bundle]; self->_applications[bundle]=app; }
                if ([bundle isEqualToString:@"com.apple.springboard"]) [apps addObject:app]; else [apps insertObject:app atIndex:0];
            }
            NSString *key=[[identities sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
            double now=NSProcessInfo.processInfo.systemUptime;
            // Foreground identity is checked every frame. Reuse the resolved
            // display for at most one second; never retain it across lock/app changes.
            if ([key isEqualToString:self->_foregroundKey] && self->_cachedScreen && now-self->_screenResolvedAt<1) { resolved=self->_cachedScreen; return; }
            self->_foregroundKey=key;
            self->_cachedScreen=nil;
            for (XCUIApplication *app in apps) {
                XCUIElement *best=nil; double area=0;
                for (XCUIElement *window in app.windows.allElementsBoundByIndex) {
                    CGRect frame=window.frame;
                    double candidate=frame.size.width*frame.size.height;
                    if (candidate>area && isfinite(candidate)) { area=candidate; best=window; }
                }
                if (best && area>0) {
                    id screen=[best valueForKey:@"screen"];
                    if ([screen isKindOfClass:XCUIScreen.class]) { resolved=screen; break; }
                }
            }
            if (resolved) { self->_cachedScreen=resolved; self->_screenResolvedAt=NSProcessInfo.processInfo.systemUptime; }
            if (!resolved) failure=@"active-display-unavailable: no resolved foreground window";
        } @catch (NSException *e) { failure=[@"active-display-unavailable: " stringByAppendingString:e.reason]; }
    };
    if (NSThread.isMainThread) resolve(); else dispatch_sync(dispatch_get_main_queue(),resolve);
    if (failure && ![_lastError isEqualToString:failure]) [self event:failure];
    if (resolved && [_lastError hasPrefix:@"active-display-unavailable"]) _lastError=@"";
    return resolved;
}
- (void)publish:(BOOL)force {
    double now=NSDate.date.timeIntervalSince1970;
    if (!force && now-_lastPublish<1) return; _lastPublish=now;
    NSArray *thermal=@[@"Nominal",@"Fair",@"Serious",@"Critical"];
    NSDictionary *status=@{@"schema":@2,@"session":_session ?: @"",@"state":_phase ?: @"starting",@"heartbeat":@(now),@"startedAt":@(_started),@"elapsed":@(_started ? (_stoppedAt ?: now)-_started : 0),@"limitSeconds":@0,@"frames":@(_video.frames),@"bytes":@(_video.fileBytes),@"lastFrameAt":@(_lastFrameAt),@"lastFile":_video.currentFile ?: @"",@"discarded":@(_discarded),@"buffered":@(_pending.count),@"locks":@(_locks),@"unlocks":@(_unlocks),@"displays":[_displayCounts copy] ?: @{},@"events":[_events copy],@"error":_lastError ?: @"",@"thermal":thermal[MIN(3,NSProcessInfo.processInfo.thermalState)],@"codec":@"HEVC",@"maxFPS":@2,@"width":@(_width),@"height":@(_height),@"desired":@(_desired),@"command":_lastCommand ?: @"",@"recentFPS":@(_recentFPS),@"requested":@(_requested),@"resolveMS":@(_resolveMS),@"captureMS":@(_captureMS),@"resizeMS":@(_resizeMS),@"encodeMS":@(_encodeMS)};
    [self write:status to:[_root URLByAppendingPathComponent:@"status.json"]];
}
- (void)metrics {
    double now=NSProcessInfo.processInfo.systemUptime;
    if (_lastMetric && now-_lastMetric<10) return;
    struct rusage usage={0}; getrusage(RUSAGE_SELF,&usage);
    double cpu=usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1e6+usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1e6;
    task_vm_info_data_t memory={0}; mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
    BOOL memoryOK=task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&memory,&count)==KERN_SUCCESS;
    __block float battery=-1;
    void (^read)(void)=^{ battery=UIDevice.currentDevice.batteryLevel; };
    if (NSThread.isMainThread) read(); else dispatch_sync(dispatch_get_main_queue(),read);
    double interval=_lastMetric ? now-_lastMetric : 0;
    _recentFPS=interval ? (_video.frames-_lastMetricFrames)/interval : 0;
    NSDate *date=NSDate.date;
    NSDateFormatter *formatter=[NSDateFormatter new]; formatter.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]; formatter.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0]; formatter.dateFormat=@"yyyy-MM-dd";
    NSDictionary *row=@{@"at":@(date.timeIntervalSince1970),@"session":_session ?: @"",@"state":_phase ?: @"starting",@"frames":@(_video.frames),@"bytes":@(_video.fileBytes),@"fps":@(interval ? (_video.frames-_lastMetricFrames)/interval : 0),@"cpu":@(interval ? 100*(cpu-_lastCPU)/interval : 0),@"memoryMiB":@(memoryOK ? memory.phys_footprint/1048576.0 : -1),@"battery":@(battery),@"thermal":@(NSProcessInfo.processInfo.thermalState),@"display":@(_display),@"width":@(_width),@"height":@(_height),@"resolveMS":@(_resolveMS),@"captureMS":@(_captureMS),@"resizeMS":@(_resizeMS),@"encodeMS":@(_encodeMS)};
    [self appendJSON:row to:[[_root URLByAppendingPathComponent:@"history"] URLByAppendingPathComponent:[[formatter stringFromDate:date] stringByAppendingString:@".jsonl"]]];
    _lastMetric=now; _lastCPU=cpu; _lastMetricFrames=_video.frames;
    [self saveSession:_desired ? @"recording" : @"stopped"];
}
- (void)run {
    NSURL *container=[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.me.sophiaxu.phantomcapture"];
    if (!container) { NSLog(@"PHANTOM shared storage unavailable"); return; }
    NSURL *documents=[container URLByAppendingPathComponent:@"Documents"];
    [NSFileManager.defaultManager createDirectoryAtURL:documents withIntermediateDirectories:YES attributes:nil error:nil];
    _root=[documents URLByAppendingPathComponent:@"Capture"];
    NSURL *legacy=[container URLByAppendingPathComponent:@"Capture"];
    if (![NSFileManager.defaultManager fileExistsAtPath:_root.path] && [NSFileManager.defaultManager fileExistsAtPath:legacy.path]) [NSFileManager.defaultManager moveItemAtURL:legacy toURL:_root error:nil];
    for (NSString *directory in @[@"sessions",@"history"]) [NSFileManager.defaultManager createDirectoryAtURL:[_root URLByAppendingPathComponent:directory] withIntermediateDirectories:YES attributes:nil error:nil];
    [_root setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    _pending=[NSMutableArray new]; _events=[NSMutableArray new]; _previousLock=UINT64_MAX;
    if ([NSData dataWithContentsOfURL:[_root URLByAppendingPathComponent:@"frontboard-probe.enabled"]].length>0) {
        _started=NSDate.date.timeIntervalSince1970; _phase=@"frontboard-probe"; _desired=NO;
        [self event:@"FrontBoard diagnostics only; screen capture disabled"];
        [[[FrontBoardProbe alloc] init] runAtRoot:_root heartbeat:^{ [self publish:YES]; }];
        _phase=@"stopped"; _stoppedAt=NSDate.date.timeIntervalSince1970; [self publish:YES]; return;
    }
    if (notify_register_check("com.apple.springboard.lockstate",&_lockToken)!=NOTIFY_STATUS_OK) { _lastError=@"lock-monitor-unavailable"; _phase=@"error"; [self publish:YES]; return; }
    void (^enable)(void)=^{ UIDevice.currentDevice.batteryMonitoringEnabled=YES; };
    if (NSThread.isMainThread) enable(); else dispatch_sync(dispatch_get_main_queue(),enable);
    _applications=[NSMutableDictionary new];
    Class process=NSClassFromString(@"XCUIApplicationProcess");
    Method idle=class_getInstanceMethod(process,NSSelectorFromString(@"waitForQuiescenceIncludingAnimationsIdle:"));
    Method pre=class_getInstanceMethod(process,NSSelectorFromString(@"waitForQuiescenceIncludingAnimationsIdle:isPreEvent:"));
    if (idle) method_setImplementation(idle,(IMP)noIdleWait);
    if (pre) method_setImplementation(pre,(IMP)noIdleWaitPreEvent);
    _desired=YES; [self begin];
    [self event:[NSString stringWithFormat:@"capture-idle-waits-disabled=%d",idle!=NULL || pre!=NULL]];
    double testSeconds=[NSProcessInfo.processInfo.environment[@"PHANTOM_VIDEO_TEST_SECONDS"] doubleValue];
    double testEnd=testSeconds>0 ? NSProcessInfo.processInfo.systemUptime+testSeconds : DBL_MAX;
    while (NSProcessInfo.processInfo.systemUptime<testEnd) {
        double tick=NSProcessInfo.processInfo.systemUptime;
        @autoreleasepool {
            NSData *commandData=[NSData dataWithContentsOfURL:[_root URLByAppendingPathComponent:@"command.json"]];
            NSDictionary *command=commandData ? [NSJSONSerialization JSONObjectWithData:commandData options:0 error:nil] : nil;
            if ([command[@"id"] isKindOfClass:NSString.class] && ![_lastCommand isEqualToString:command[@"id"]]) {
                _lastCommand=command[@"id"];
                // Ignore old commands left by a previous worker instance.
                if ([command[@"at"] doubleValue]>=_started-2) {
                    if ([command[@"action"] isEqualToString:@"stop"]) { _desired=NO; _lastError=@""; _stoppedAt=NSDate.date.timeIntervalSince1970; [self event:@"stop requested from companion"]; }
                    else if ([command[@"action"] isEqualToString:@"start"] && !_desired) {
                        if (_needsClose && [self unlocked]) { [_video finish]; _needsClose=NO; }
                        if (!_needsClose) { _desired=YES; [self begin]; }
                    }
                }
            }
            BOOL unlocked=[self unlocked];
            int lockChanged=0;
            if (notify_check(_lockToken,&lockChanged)!=NOTIFY_STATUS_OK) unlocked=NO;
            // A lock/unlock cycle can complete while a synchronous XCTest call
            // is blocked. Invalidate even when the current state is unchanged.
            if (lockChanged && _previousLock==!unlocked) {
                _discarded+=_pending.count; [_pending removeAllObjects];
                _stableSince=tick; _cachedScreen=nil; _needsClose=YES;
                [self event:@"lock notification changed; resetting capture guard"];
            }
            if (_previousLock!=!unlocked) {
                if (_previousLock!=UINT64_MAX) { if (unlocked) _unlocks++; else _locks++; }
                [self event:unlocked ? @"unlocked; settling for 3 seconds" : @"locked; pending frames discarded"];
                _previousLock=!unlocked; _stableSince=tick; _cachedScreen=nil;
                _discarded+=_pending.count; [_pending removeAllObjects]; _needsClose=YES;
            }
            if (!unlocked || !_desired) {
                _discarded+=_pending.count; [_pending removeAllObjects];
                _needsClose=YES;
                if (unlocked && _needsClose) { [_video finish]; _needsClose=NO; }
                _phase=_desired ? @"locked" : _lastError.length ? @"error" : @"stopped";
            } else if (tick-_stableSince<3) _phase=@"settling";
            else {
                if (_needsClose) { [_video finish]; _needsClose=NO; }
                _phase=@"capturing";
                while (_pending.count && tick-[_pending[0][@"uptime"] doubleValue]>=3) {
                    NSDictionary *frame=_pending.firstObject;
                    if (![self unlocked]) { _discarded+=_pending.count; [_pending removeAllObjects]; break; }
                    double encodeStart=NSProcessInfo.processInfo.systemUptime;
                    if (![_video append:(__bridge CVPixelBufferRef)frame[@"buffer"] capturedAt:[frame[@"at"] doubleValue] display:[frame[@"display"] longLongValue]]) { _lastError=_video.error; _desired=NO; break; }
                    NSString *displayKey=[NSString stringWithFormat:@"Display %@",frame[@"display"]];
                    _displayCounts[displayKey]=@([_displayCounts[displayKey] unsignedIntegerValue]+1);
                    _encodeMS=1000*(NSProcessInfo.processInfo.systemUptime-encodeStart);
                    _lastFrameAt=[frame[@"at"] doubleValue]; [_pending removeObjectAtIndex:0];
                }
                if (_desired && [self unlocked]) {
                    @try {
                        double resolveStart=NSProcessInfo.processInfo.systemUptime;
                        XCUIScreen *screen=[self activeScreen];
                        _resolveMS=1000*(NSProcessInfo.processInfo.systemUptime-resolveStart);
                        if (screen) {
                            long long display=[[screen valueForKey:@"displayID"] longLongValue];
                            double captureNow=NSProcessInfo.processInfo.systemUptime;
                            if (captureNow-_lastCaptureRequest<0.5) {
                                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5-(captureNow-_lastCaptureRequest)]];
                            }
                            if (![self unlocked]) continue;
                            _lastCaptureRequest=NSProcessInfo.processInfo.systemUptime;
                            double capturedAt=NSDate.date.timeIntervalSince1970;
                            _requested++;
                            UIImage *image=screen.screenshot.image;
                            _captureMS=1000*(NSProcessInfo.processInfo.systemUptime-_lastCaptureRequest);
                            double resizeStart=NSProcessInfo.processInfo.systemUptime;
                            CVPixelBufferRef buffer=[VideoRecorder copyHalfSizeBuffer:image];
                            _resizeMS=1000*(NSProcessInfo.processInfo.systemUptime-resizeStart);
                            if (_resolveMS>1000 || _captureMS>1000) [self event:[NSString stringWithFormat:@"slow-frame resolve=%.0fms screenshot=%.0fms resize=%.0fms encode=%.0fms",_resolveMS,_captureMS,_resizeMS,_encodeMS]];
                            if (buffer) {
                                if ([self unlocked]) {
                                    _width=(int)CVPixelBufferGetWidth(buffer); _height=(int)CVPixelBufferGetHeight(buffer);
                                    if (display!=_display) { _discarded+=_pending.count; [_pending removeAllObjects]; _needsClose=YES; [self event:[NSString stringWithFormat:@"active-display=%lld source=%.0fx%.0f output=%dx%d",display,image.size.width*image.scale,image.size.height*image.scale,_width,_height]]; }
                                    _display=display;
                                    [_pending addObject:@{@"buffer":(__bridge id)buffer,@"at":@(capturedAt),@"uptime":@(NSProcessInfo.processInfo.systemUptime),@"display":@(display)}];
                                    if (_pending.count>8) { [_pending removeObjectAtIndex:0]; _discarded++; }
                                }
                                CVPixelBufferRelease(buffer);
                            } else { _lastError=@"resize-failed"; _desired=NO; }
                        } else _phase=@"waiting-for-display";
                    } @catch (NSException *e) { [self event:[@"capture-failed " stringByAppendingString:e.reason]]; _desired=NO; }
                }
            }
            [self metrics]; [self publish:NO];
        }
        // Never issue screenshot requests more often than twice per second.
        double delay=MAX(0.02,(_desired && [self unlocked] ? 0.5 : 1)-(NSProcessInfo.processInfo.systemUptime-tick));
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:delay]];
    }
    _desired=NO; [_pending removeAllObjects]; if ([self unlocked]) [_video finish];
    _phase=@"stopped"; [self saveSession:@"stopped"]; [self publish:YES]; notify_cancel(_lockToken);
}
@end
