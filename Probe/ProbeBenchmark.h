#import <Foundation/Foundation.h>
@interface ProbeBenchmark : NSObject
@property (atomic) BOOL stopping;
@property (atomic) NSUInteger swipes;
@property (atomic, copy) NSString *failure;
@property double duration;
- (instancetype)initWithFolder:(NSURL *)folder duration:(double)duration;
- (void)start;
- (void)sampleFrames:(NSInteger)frames bytes:(unsigned long long)bytes;
- (void)recordCaptureMilliseconds:(double)milliseconds;
- (void)finishFrames:(NSInteger)frames bytes:(unsigned long long)bytes;
@end
