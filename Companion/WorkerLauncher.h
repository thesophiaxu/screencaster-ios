#import <Foundation/Foundation.h>
@interface WorkerLauncher : NSObject
+ (void)startWithCompletion:(void (^ _Nonnull)(NSString * _Nullable error))completion;
@end
