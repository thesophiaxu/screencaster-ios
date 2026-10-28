#import "WorkerLauncher.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <dlfcn.h>

@implementation WorkerLauncher
+ (void)startWithCompletion:(void (^)(NSString *))completion {
    // Use the system's background activation request, the same launch mode that
    // worked through DVT. All selectors/symbols are runtime checked; a denied
    // request is reported, never treated as a successful worker start.
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",RTLD_LAZY);
    Class cls=NSClassFromString(@"FBSSystemService");
    id service=cls ? [[cls alloc] init] : nil;
    SEL portSEL=NSSelectorFromString(@"createClientPort");
    SEL openSEL=NSSelectorFromString(@"openApplication:options:clientPort:withResult:");
    NSString *__unsafe_unretained *key= (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT,"FBSOpenApplicationOptionKeyActivateSuspended");
    void (^fallback)(NSString *)=^(NSString *reason) {
        dispatch_async(dispatch_get_main_queue(),^{
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"phantom-worker://start"] options:@{} completionHandler:^(BOOL ok) {
                completion(ok ? nil : [reason stringByAppendingString:@". The worker URL could not be opened."]);
            }];
        });
    };
    if (!service || !key || ![service respondsToSelector:portSEL] || ![service respondsToSelector:openSEL]) { fallback(@"Background launcher unavailable"); return; }
    @try {
        unsigned int port=((unsigned int (*)(id,SEL))objc_msgSend)(service,portSEL);
        NSDictionary *options=@{*key:@YES};
        ((void (*)(id,SEL,id,id,unsigned int,id))objc_msgSend)(service,openSEL,@"me.sophiaxu.phantomprobe.xctrunner",options,port,^(NSError *error) {
            if (error) fallback(error.localizedDescription); else dispatch_async(dispatch_get_main_queue(),^{ completion(nil); });
        });
    } @catch (NSException *e) { fallback(e.reason); }
}
@end
