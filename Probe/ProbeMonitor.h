#import <Foundation/Foundation.h>
@interface ProbeMonitor : NSObject
@property (atomic, copy) NSDictionary *snapshot;
@property (atomic) BOOL stopRequested;
- (BOOL)start:(NSError **)error;
- (void)close;
@end
