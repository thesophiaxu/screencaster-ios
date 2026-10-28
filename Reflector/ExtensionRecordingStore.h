#import <Foundation/Foundation.h>
#import "../Probe/VideoRecorder.h"

// Used only on the serial capture thread. No image backlog or asynchronous encode queue.
@interface ExtensionRecordingStore : NSObject
@property(nonatomic, readonly) VideoRecorder *video;
// Immutable snapshots may be read from the provider IPC queue. Mutations stay on the capture thread.
@property(atomic, copy, readonly) NSDictionary *liveStatus;
@property(nonatomic, readonly) BOOL desired;
@property(nonatomic, readonly) NSString *error;
@property(nonatomic, copy) BOOL (^unlocked)(void);
- (instancetype)initWithRoot:(NSURL *)root;
- (void)tickWithMemory:(NSDictionary *)memory;
- (BOOL)appendBuffer:(CVPixelBufferRef)buffer at:(double)time display:(uint32_t)display resolveMS:(double)resolveMS captureMS:(double)captureMS resizeMS:(double)resizeMS;
- (void)pause;
- (void)requestStop;
- (BOOL)finish;
- (void)recordError:(NSString *)error;
@end
