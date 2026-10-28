#import "FrontBoardProbe.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <UIKit/UIKit.h>

@implementation FrontBoardProbe {
    NSURL *_logURL;
    dispatch_queue_t _logQueue;
    NSMutableArray *_monitors;
    NSUInteger _callbacks;
    id _displayMonitor;
    NSString *_lastInventory;
}
- (void)log:(NSString *)kind value:(id)value {
    NSDictionary *row=@{@"at":@(NSDate.date.timeIntervalSince1970),@"kind":kind,@"value":value ?: NSNull.null};
    dispatch_sync(_logQueue, ^{
        NSMutableData *data=[[NSJSONSerialization dataWithJSONObject:row options:0 error:nil] mutableCopy];
        [data appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        NSFileHandle *f=[NSFileHandle fileHandleForWritingAtPath:self->_logURL.path];
        @try { [f seekToEndOfFile]; [f writeData:data]; [f closeFile]; } @catch (__unused NSException *e) {}
    });
}
- (NSDictionary *)values:(id)object keys:(NSArray *)keys {
    if (!object) return @{};
    NSMutableDictionary *out=[NSMutableDictionary new];
    out[@"class"]=NSStringFromClass([object class]);
    for (NSString *key in keys) {
        @try {
            if (![object respondsToSelector:NSSelectorFromString(key)]) continue;
            id value=[object valueForKey:key];
            if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) out[key]=value;
            else if (value) out[key]=[value description];
        } @catch (NSException *e) { out[key]=[@"exception: " stringByAppendingString:e.reason ?: e.name]; }
    }
    return out;
}
- (void)dumpClass:(Class)c {
    if (!c) return;
    NSMutableDictionary *out=[NSMutableDictionary new];
    out[@"name"]=NSStringFromClass(c);
    for (NSNumber *meta in @[@NO,@YES]) {
        unsigned int count=0;
        Method *methods=class_copyMethodList(meta.boolValue ? object_getClass(c) : c,&count);
        NSMutableArray *rows=[NSMutableArray new];
        for (unsigned int i=0;i<count;i++) [rows addObject:@{@"selector":NSStringFromSelector(method_getName(methods[i])),@"types":@(method_getTypeEncoding(methods[i]))}];
        free(methods);
        out[meta.boolValue ? @"classMethods" : @"instanceMethods"]=rows;
    }
    [self log:@"runtime-class" value:out];
}
- (void)receivedLayout:(id)layout monitor:(id)monitor context:(id)context {
    @synchronized(self) { _callbacks++; }
    NSMutableDictionary *row=[[self values:layout keys:@[@"displayType",@"displayBacklightLevel",@"backlightState",@"interfaceOrientation",@"bounds",@"timestamp"]] mutableCopy];
    row[@"monitor"]=[NSString stringWithFormat:@"%p",monitor];
    @try {
        id config=[layout respondsToSelector:NSSelectorFromString(@"displayConfiguration")] ? [layout valueForKey:@"displayConfiguration"] : nil;
        row[@"configuration"]=[self values:config keys:@[@"displayID",@"name",@"uniqueIdentifier",@"isMainDisplay",@"isConnected",@"isHiddenDisplay",@"bounds",@"pixelSize",@"scale",@"identity"]];
        if (context) row[@"context"]=[self values:context keys:@[@"duration",@"animationSettings"]];
    } @catch (NSException *e) { row[@"error"]=e.reason ?: e.name; }
    [self log:@"layout-callback" value:row];
}
- (void)layoutMonitor:(id)monitor didUpdateDisplayLayout:(id)layout { [self receivedLayout:layout monitor:monitor context:nil]; }
- (void)layoutMonitor:(id)monitor didUpdateDisplayLayout:(id)layout withContext:(id)context { [self receivedLayout:layout monitor:monitor context:context]; }
- (void)start {
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",RTLD_LAZY);
    unsigned int count=0; Class *classes=objc_copyClassList(&count);
    for (unsigned int i=0;i<count;i++) {
        NSString *name=NSStringFromClass(classes[i]);
        if ([name hasPrefix:@"FBSDisplay"] && ![name containsString:@"CA"]) [self dumpClass:classes[i]];
    }
    free(classes);
    Class displayClass=NSClassFromString(@"FBSDisplayMonitor");
    SEL sharedDisplay=NSSelectorFromString(@"pui_sharedDisplayMonitor");
    @try {
        if ([displayClass respondsToSelector:sharedDisplay]) _displayMonitor=((id(*)(id,SEL))objc_msgSend)(displayClass,sharedDisplay);
        [self log:@"display-monitor" value:@{@"available":@(_displayMonitor!=nil)}];
    } @catch (NSException *e) { [self log:@"display-monitor-exception" value:e.reason ?: e.name]; }
    Class monitorClass=NSClassFromString(@"FBSDisplayLayoutMonitor");
    Class configClass=NSClassFromString(@"FBSDisplayLayoutMonitorConfiguration");
    @try {
        SEL configFactory=NSSelectorFromString(@"configurationForDefaultMainDisplayMonitor");
        SEL factory=NSSelectorFromString(@"monitorWithConfiguration:");
        id monitor=nil;
        if ([configClass respondsToSelector:configFactory] && [monitorClass respondsToSelector:factory]) {
            id config=((id(*)(id,SEL))objc_msgSend)(configClass,configFactory);
            [self log:@"monitor-configuration" value:[self values:config keys:@[@"displayConfiguration",@"displayType",@"name"]]];
            // Factory-created monitors are immutable: addObserver: traps on
            // this OS. Supply the callback on configuration before construction.
            SEL setter=NSSelectorFromString(@"setTransitionHandler:");
            if (![config respondsToSelector:setter]) { [self log:@"monitor-not-started" value:@"No transition-handler setter"]; return; }
            __weak FrontBoardProbe *weak=self;
            // Consume the callback's layout directly; immutable monitors can
            // leave currentLayout nil. No app/window/accessibility query is made.
            void (^changed)(id,id)=^(id sender,id layout) {
                NSString *senderClass=sender ? NSStringFromClass([sender class]) : @"nil";
                dispatch_async(dispatch_get_main_queue(), ^{
                    FrontBoardProbe *self=weak; if (!self) return;
                    [self log:@"transition-notification" value:@{@"senderClass":senderClass}];
                    [self receivedLayout:layout monitor:sender context:nil];
                });
            };
            ((void(*)(id,SEL,id))objc_msgSend)(config,setter,changed);
            monitor=((id(*)(id,SEL,id))objc_msgSend)(monitorClass,factory,config);
        } else {
            [self log:@"monitor-not-started" value:@"Default main-display configuration factory unavailable; inspect runtime metadata before selecting an initializer."];
        }
        if (monitor) {
            [_monitors addObject:monitor];
            [self log:@"transition-handler-registered" value:NSStringFromClass([monitor class])];
            if ([monitor respondsToSelector:NSSelectorFromString(@"currentLayout")]) [self receivedLayout:[monitor valueForKey:@"currentLayout"] monitor:monitor context:nil];
        }
    } @catch (NSException *e) { [self log:@"monitor-exception" value:e.reason ?: e.name]; }
}
- (void)inventory {
    if (!_displayMonitor) return;
    double start=NSProcessInfo.processInfo.systemUptime;
    @try {
        NSMutableDictionary *row=[NSMutableDictionary new];
        NSArray *identityKeys=@[@"displayID",@"uniqueIdentifier",@"isMainDisplay",@"isMainRootDisplay",@"isUIKitMainLike",@"isAlwaysConnected",@"type"];
        id main=[_displayMonitor valueForKey:@"mainIdentity"];
        row[@"mainIdentity"]=[self values:main keys:identityKeys];
        NSMutableArray *configs=[NSMutableArray new];
        for (id identity in [_displayMonitor valueForKey:@"connectedIdentities"]) {
            id config=((id(*)(id,SEL,id))objc_msgSend)(_displayMonitor,NSSelectorFromString(@"configurationForIdentity:"),identity);
            [configs addObject:@{@"identity":[self values:identity keys:identityKeys],@"configuration":[self values:config keys:@[@"name",@"bounds",@"pixelSize",@"isMainDisplay",@"isMainRootDisplay",@"isHiddenDisplay",@"isUIKitMainLike",@"type",@"tags",@"seed",@"nativeOrientation"]]}];
        }
        row[@"connected"]=configs;
        NSString *fingerprint=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding];
        if (![fingerprint isEqualToString:_lastInventory]) {
            _lastInventory=fingerprint;
            row[@"readMS"]=@(1000*(NSProcessInfo.processInfo.systemUptime-start));
            [self log:@"display-inventory-changed" value:row];
        }
    } @catch (NSException *e) { [self log:@"inventory-exception" value:e.reason ?: e.name]; _displayMonitor=nil; }
}
- (void)runAtRoot:(NSURL *)root heartbeat:(void (^)(void))heartbeat {
    NSURL *folder=[root URLByAppendingPathComponent:@"diagnostics"];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    _logURL=[folder URLByAppendingPathComponent:[NSString stringWithFormat:@"frontboard-%@.jsonl",NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createFileAtPath:_logURL.path contents:nil attributes:nil];
    _logQueue=dispatch_queue_create("phantom.frontboard.log",DISPATCH_QUEUE_SERIAL); _monitors=[NSMutableArray new];
    [self log:@"probe-started" value:@{@"captureEnabled":@NO,@"accessibilityQueries":@NO,@"durationSeconds":@600}];
    void (^start)(void)=^{ [self start]; };
    if (NSThread.isMainThread) start(); else dispatch_sync(dispatch_get_main_queue(),start);
    double end=NSProcessInfo.processInfo.systemUptime+600;
    while (NSProcessInfo.processInfo.systemUptime<end && [NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"frontboard-probe.enabled"]].length>0) {
        @autoreleasepool {
            NSUInteger callbacks; @synchronized(self) { callbacks=_callbacks; }
            NSDictionary *status=@{@"at":@(NSDate.date.timeIntervalSince1970),@"file":_logURL.lastPathComponent,@"callbacks":@(callbacks),@"monitors":@(_monitors.count),@"recording":@NO};
            [[NSJSONSerialization dataWithJSONObject:status options:0 error:nil] writeToURL:[root URLByAppendingPathComponent:@"frontboard-status.json"] options:NSDataWritingAtomic error:nil];
            void (^inventory)(void)=^{ [self inventory]; };
            if (NSThread.isMainThread) inventory(); else dispatch_sync(dispatch_get_main_queue(),inventory);
            if (heartbeat) heartbeat();
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
        }
    }
    void (^stop)(void)=^{ for (id monitor in self->_monitors) { SEL sel=NSSelectorFromString(@"invalidate"); if ([monitor respondsToSelector:sel]) ((void(*)(id,SEL))objc_msgSend)(monitor,sel); } };
    if (NSThread.isMainThread) stop(); else dispatch_sync(dispatch_get_main_queue(),stop);
    [NSFileManager.defaultManager removeItemAtURL:[root URLByAppendingPathComponent:@"frontboard-probe.enabled"] error:nil];
    [self log:@"probe-finished" value:@{ @"callbacks":@(_callbacks) }];
}
@end
