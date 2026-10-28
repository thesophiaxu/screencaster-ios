#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../../Reflector/ExtensionRecordingStore.h"
static double fakeNow=1800000000;
static NSDate *testDate(id self, SEL cmd) { return [NSDate dateWithTimeIntervalSince1970:fakeNow]; }
// Exercise persistence policy with a deterministic writer and clock; no capture APIs.
@implementation VideoRecorder { NSUInteger _count; }
- (instancetype)initWithFolder:(NSURL *)folder { return [super init]; }
- (NSString *)error { return @""; }
- (NSString *)currentFile { return @"test.mp4"; }
- (NSUInteger)frames { return _count; }
- (unsigned long long)fileBytes { return _count*100; }
- (CVPixelBufferRef)copyHalfSizeBufferFromEncodedData:(NSData *)data { return NULL; }
- (BOOL)append:(CVPixelBufferRef)buffer capturedAt:(double)time display:(long long)display { _count++;return YES; }
- (BOOL)finish { if(self.completed)self.completed(@{@"file":@"test.mp4",@"frames":@(_count)});return YES; }
@end
static NSDictionary *readCheckpoint(NSURL *url) { return [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:url] options:0 error:nil]; }
int main(void) { @autoreleasepool {
    Method date=class_getClassMethod(NSDate.class,@selector(date));IMP original=method_setImplementation(date,(IMP)testDate);
    NSURL *root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    ExtensionRecordingStore *store=[[ExtensionRecordingStore alloc] initWithRoot:root];
    __block BOOL unlocked=YES;store.unlocked=^{return unlocked;};
    NSDictionary *memory=@{@"footprintBytes":@1000};
    [store tickWithMemory:memory];NSDictionary *old=store.liveStatus;
    NSURL *status=[root URLByAppendingPathComponent:@"status.json"];
    double first=[readCheckpoint(status)[@"heartbeat"] doubleValue];
    for(int i=1;i<60;i++) { fakeNow+=1;[store tickWithMemory:memory]; }
    NSCAssert([store.liveStatus[@"heartbeat"] doubleValue]==fakeNow,@"RAM status must remain live");
    NSCAssert([old[@"heartbeat"] doubleValue]==first,@"Published snapshots must be immutable");
    NSCAssert([readCheckpoint(status)[@"heartbeat"] doubleValue]==first,@"No per-second status rewrites");
    NSCAssert([store.liveStatus[@"recentHistory"] count]>=5,@"Unflushed history is available to IPC");
    fakeNow+=1;[store tickWithMemory:memory];
    NSCAssert([readCheckpoint(status)[@"heartbeat"] doubleValue]==fakeNow,@"Checkpoint at 60 seconds");
    unlocked=NO;fakeNow+=1;[store tickWithMemory:memory];
    NSCAssert([readCheckpoint(status)[@"state"] isEqual:@"locked"],@"Lock transition persists immediately");
    unlocked=YES;fakeNow+=1;[store tickWithMemory:memory];
    [store recordError:@"test error"];fakeNow+=1;[store tickWithMemory:memory];
    NSCAssert([readCheckpoint(status)[@"error"] isEqual:@"test error"],@"Error transition persists immediately");
    double errorCheckpoint=[readCheckpoint(status)[@"heartbeat"] doubleValue];
    for(int i=0;i<5;i++) { [store recordError:@"test error"];fakeNow+=1;[store tickWithMemory:memory]; }
    NSCAssert([readCheckpoint(status)[@"heartbeat"] doubleValue]==errorCheckpoint,@"Repeated error does not rewrite checkpoint");
    [store recordError:@""];[store finish];[store tickWithMemory:memory];
    NSCAssert([readCheckpoint(status)[@"state"] isEqual:@"stopped"],@"Final status persists");
    NSString *session=store.liveStatus[@"session"];
    NSURL *folder=[[root URLByAppendingPathComponent:@"sessions"] URLByAppendingPathComponent:session];
    NSCAssert([NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:@"segments.jsonl"]].length>0,@"Completed clip manifest persisted immediately");
    NSCAssert([NSData dataWithContentsOfURL:[folder URLByAppendingPathComponent:@"events.jsonl"]].length>0,@"Buffered events flushed at Stop");
    method_setImplementation(date,original);
    [NSFileManager.defaultManager removeItemAtURL:root error:nil];
    puts("PASS: immutable live snapshots, minute checkpoints, state/error transitions, duplicate-error coalescing, buffered history, durable completion and Stop");
} return 0; }
