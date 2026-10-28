#import <Foundation/Foundation.h>
@interface FrontBoardProbe : NSObject
- (void)runAtRoot:(NSURL *)root heartbeat:(void (^)(void))heartbeat;
@end
