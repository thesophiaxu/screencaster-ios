#import <Foundation/Foundation.h>
@interface TunnelCaptureProbe : NSObject
+ (void)start;
+ (void)stop;
+ (NSString *)statusText;
@end
