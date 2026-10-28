#import <Foundation/Foundation.h>

// Explicit diagnostic mode; never called during normal recorder startup.
@interface ScreenOnlyProbe : NSObject
+ (void)start;
+ (void)stop;
+ (NSString *)statusText;
@end
