#import "ExtensionRecordingStore.h"
#import <sys/resource.h>

@interface ExtensionRecordingStore ()
@property(atomic, copy, readwrite) NSDictionary *liveStatus;
@end

@implementation ExtensionRecordingStore {
    NSURL *_root, *_folder;
    VideoRecorder *_video;
    NSString *_session, *_error, *_command;
    NSMutableArray *_events, *_recentHistory;
    NSMutableDictionary<NSURL *, NSMutableData *> *_pendingAppends;
    NSString *_checkpointState, *_checkpointError;
    double _lastCheckpoint;
    NSUInteger _checkpointWrites, _appendFlushes;
    BOOL _desired, _needsClose, _wasUnlocked;
    double _started, _lastFrame, _lastPublish, _lastMetric, _lastCPU, _fps, _captureMS, _resizeMS, _encodeMS, _stopped, _resolveMS;
    uint32_t _display;
    NSUInteger _requested, _lastFrames, _locks, _unlocks;
    size_t _width, _height;
}
- (void)write:(id)value to:(NSURL *)url {
    NSError *error=nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
    if (data && ![data writeToURL:url options:NSDataWritingAtomic error:&error]) _error=error.localizedDescription;
}
// Bounded metadata batching. Completed clip manifests bypass this buffer.
- (void)appendData:(NSData *)data to:(NSURL *)url {
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) [NSFileManager.defaultManager createFileAtPath:url.path contents:nil attributes:nil];
    NSFileHandle *f=[NSFileHandle fileHandleForWritingAtPath:url.path];
    if (!f) { _error=@"Cannot open metadata log"; return; }
    @try { [f seekToEndOfFile];[f writeData:data];_appendFlushes++; }
    @catch(NSException *e) { _error=e.reason; }
    @finally { [f closeFile]; }
}
- (void)flushAppends {
    for (NSURL *url in [_pendingAppends.allKeys copy]) {
        NSMutableData *data=_pendingAppends[url];
        if (data.length) [self appendData:data to:url];
    }
    [_pendingAppends removeAllObjects];
}
- (void)appendJSON:(id)value to:(NSURL *)url {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data) return;
    NSMutableData *line=[data mutableCopy];[line appendBytes:"\n" length:1];
    if ([url.lastPathComponent isEqualToString:@"segments.jsonl"]) { [self appendData:line to:url];return; }
    if (!_pendingAppends[url]) _pendingAppends[url]=[NSMutableData new];
    [_pendingAppends[url] appendData:line];
    NSUInteger bytes=0;for (NSData *pending in _pendingAppends.allValues) bytes+=pending.length;
    if (bytes>=64*1024) [self flushAppends];
}
- (void)event:(NSString *)message {
    NSDictionary *row=@{@"at":@(NSDate.date.timeIntervalSince1970),@"message":message};
    [_events addObject:row];if (_events.count>30) [_events removeObjectAtIndex:0];
    [self appendJSON:row to:[_folder URLByAppendingPathComponent:@"events.jsonl"]];
}
- (instancetype)initWithRoot:(NSURL *)root {
    if (!(self=[super init])) return nil;
    _root=root;_started=NSDate.date.timeIntervalSince1970;_session=NSUUID.UUID.UUIDString;_desired=YES;_events=[NSMutableArray new];_recentHistory=[NSMutableArray new];_pendingAppends=[NSMutableDictionary new];_error=@"";_command=@"";
    NSData *existingCommand=[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"command.json"]];
    NSDictionary *existing=existingCommand?[NSJSONSerialization JSONObjectWithData:existingCommand options:0 error:nil]:nil;
    if ([existing[@"id"] isKindOfClass:NSString.class]) _command=existing[@"id"];
    _folder=[[_root URLByAppendingPathComponent:@"sessions"] URLByAppendingPathComponent:_session];
    NSError *error=nil;
    for (NSURL *dir in @[_folder,[_root URLByAppendingPathComponent:@"history"]]) {
        if (![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error]) { _error=error.localizedDescription;_desired=NO; }
    }
    [_folder setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    _video=[[VideoRecorder alloc] initWithFolder:_folder];
    __weak typeof(self) weak=self;
    _video.canWrite=^BOOL{ typeof(self) self=weak;return self && self.unlocked && self.unlocked(); };
    _video.event=^(NSString *message){ [weak event:message]; };
    _video.completed=^(NSDictionary *segment){
        typeof(self) self=weak;if (!self) return;
        [self appendJSON:segment to:[self->_folder URLByAppendingPathComponent:@"segments.jsonl"]];
        [self saveSession];
    };
    [self event:@"VPN screenshot recorder: max 1 fps, half-size hardware HEVC, one frame in flight, no session limit"];
    [self saveSession];
    return self;
}
- (VideoRecorder *)video { return _video; }
- (BOOL)desired { return _desired; }
- (NSString *)error { return _error.length ? _error : _video.error; }
- (void)recordError:(NSString *)error { if ([_error isEqualToString:error]) return;_error=error;if(error.length)[self event:error]; }
- (void)saveSession {
    [self write:@{@"id":_session,@"startedAt":@(_started),@"updatedAt":@(NSDate.date.timeIntervalSince1970),@"state":_desired?@"recording":@"stopped",@"frames":@(_video.frames),@"bytes":@(_video.fileBytes),@"codec":@"HEVC",@"width":@(_width),@"height":@(_height),@"display":@(_display),@"error":self.error?:@""} to:[_folder URLByAppendingPathComponent:@"session.json"]];
}
- (void)tickWithMemory:(NSDictionary *)memory {
    double now=NSDate.date.timeIntervalSince1970;
    if (now-_lastPublish<1) return;_lastPublish=now;
    NSData *data=[NSData dataWithContentsOfURL:[_root URLByAppendingPathComponent:@"command.json"]];
    NSDictionary *cmd=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if ([cmd[@"id"] isKindOfClass:NSString.class] && ![_command isEqual:cmd[@"id"]] && [cmd[@"at"] doubleValue]>=_started-2) {
        _command=cmd[@"id"];if ([cmd[@"action"] isEqual:@"stop"]) [self requestStop];
    }
    BOOL available=self.unlocked && self.unlocked();
    if (_wasUnlocked && !available) { _locks++;[self pause]; }
    if (!_wasUnlocked && available) _unlocks++;
    _wasUnlocked=available;
    NSString *state=_desired?(available?@"capturing":@"locked"):@"stopped";
    if (self.error.length) state=@"error";
    if (!_lastMetric || now-_lastMetric>=10) {
        struct rusage usage={0};getrusage(RUSAGE_SELF,&usage);
        double cpu=usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1e6+usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1e6;
        double delta=_lastMetric?now-_lastMetric:0;
        _fps=delta?(_video.frames-_lastFrames)/delta:0;
        NSDateFormatter *fmt=[NSDateFormatter new];fmt.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];fmt.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];fmt.dateFormat=@"yyyy-MM-dd";
        NSDictionary *row=@{@"at":@(now),@"session":_session,@"state":state,@"frames":@(_video.frames),@"bytes":@(_video.fileBytes),@"fps":@(_fps),@"cpu":@(delta?100*(cpu-_lastCPU)/delta:0),@"memoryMiB":@([memory[@"footprintBytes"] doubleValue]/1048576.0),@"battery":@(-1),@"thermal":@(NSProcessInfo.processInfo.thermalState),@"captureMS":@(_captureMS),@"resizeMS":@(_resizeMS),@"encodeMS":@(_encodeMS)};
        [self appendJSON:row to:[[_root URLByAppendingPathComponent:@"history"] URLByAppendingPathComponent:[[fmt stringFromDate:NSDate.date] stringByAppendingString:@".jsonl"]]];
        [_recentHistory addObject:row];if(_recentHistory.count>12)[_recentHistory removeObjectAtIndex:0];
        _lastMetric=now;_lastCPU=cpu;_lastFrames=_video.frames;
    }
    NSArray *thermal=@[@"Nominal",@"Fair",@"Serious",@"Critical"];
    self.liveStatus=@{@"schema":@2,@"session":_session,@"state":state,@"heartbeat":@(now),@"startedAt":@(_started),@"elapsed":@((_stopped?:now)-_started),@"limitSeconds":@0,@"frames":@(_video.frames),@"bytes":@(_video.fileBytes),@"lastFrameAt":@(_lastFrame),@"lastFile":_video.currentFile,@"discarded":@0,@"buffered":@0,@"locks":@(_locks),@"unlocks":@(_unlocks),@"displays":@{},@"events":[_events copy],@"error":self.error?:@"",@"thermal":thermal[MIN(3,NSProcessInfo.processInfo.thermalState)],@"codec":@"HEVC",@"maxFPS":@1,@"width":@(_width),@"height":@(_height),@"desired":@(_desired),@"command":_command,@"recentFPS":@(_fps),@"requested":@(_requested),@"resolveMS":@(_resolveMS),@"captureMS":@(_captureMS),@"resizeMS":@(_resizeMS),@"encodeMS":@(_encodeMS),@"backend":@"vpn-coredevice-screenshot",@"displaySelection":@"explicit-active-panel",@"recentHistory":[_recentHistory copy],@"statusCheckpointWrites":@(_checkpointWrites),@"metadataAppendFlushes":@(_appendFlushes)};
    // Keep the durable fallback current at transitions, otherwise once a minute.
    if (!_lastCheckpoint || now-_lastCheckpoint>=60 || ![_checkpointState isEqualToString:state] || ![_checkpointError isEqualToString:self.error?:@""]) {
        [self flushAppends];[self saveSession];
        [self write:self.liveStatus to:[_root URLByAppendingPathComponent:@"status.json"]];
        _checkpointWrites++;_lastCheckpoint=now;_checkpointState=state;_checkpointError=[self.error?:@"" copy];
    }
}
- (void)pause { _needsClose=YES; }
- (BOOL)appendBuffer:(CVPixelBufferRef)buffer at:(double)time display:(uint32_t)display resolveMS:(double)resolveMS captureMS:(double)captureMS resizeMS:(double)resizeMS {
    _requested++;_display=display;_resolveMS=resolveMS;_captureMS=captureMS;_resizeMS=resizeMS;
    if (!_desired || !self.unlocked || !self.unlocked()) return YES;
    if (_needsClose) { if (![_video finish]) return NO;_needsClose=NO; }
    _width=CVPixelBufferGetWidth(buffer);_height=CVPixelBufferGetHeight(buffer);
    double begin=NSProcessInfo.processInfo.systemUptime;
    NSUInteger previous=_video.frames;
    BOOL ok=[_video append:buffer capturedAt:time display:display];
    _encodeMS=(NSProcessInfo.processInfo.systemUptime-begin)*1000;
    if (_video.frames>previous) _lastFrame=time;
    return ok;
}
- (void)requestStop { if (_desired) { _desired=NO;_stopped=NSDate.date.timeIntervalSince1970;[self event:@"Stop requested; finalizing when unlocked"]; } }
- (BOOL)finish {
    [self requestStop];
    if (!self.unlocked || !self.unlocked()) return NO;
    BOOL ok=[_video finish];_lastPublish=0;_lastCheckpoint=0;[self flushAppends];[self saveSession];return ok;
}
@end
