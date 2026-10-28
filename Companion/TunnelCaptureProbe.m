#import "TunnelCaptureProbe.h"
#import <UIKit/UIKit.h>
#import <notify.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <CommonCrypto/CommonDigest.h>
#import "idevice.h"

@interface TunnelCaptureProbe ()
@property NSString *status;
@property NSFileHandle *log;
@property NSURL *folder;
@property NSLock *logLock;
@property BOOL stopped;
@property int lockToken;
@property double unlockedSince;
@property UIBackgroundTaskIdentifier backgroundTask;
@property NSMutableArray *observers;
@end
static TunnelCaptureProbe *captureProbe;
@implementation TunnelCaptureProbe
+ (void)start { if (captureProbe) return; captureProbe=[self new]; [captureProbe begin]; }
+ (void)stop { captureProbe.stopped=YES; }
+ (NSString *)statusText { @synchronized(captureProbe) { return captureProbe.status ?: @"Preparing on-phone tunnel…"; } }
- (void)event:(NSString *)name values:(NSDictionary *)values {
    [self.logLock lock];
    NSMutableDictionary *row=[@{@"at":@(NSDate.date.timeIntervalSince1970),@"uptime":@(NSProcessInfo.processInfo.systemUptime),@"event":name} mutableCopy];
    [row addEntriesFromDictionary:values ?: @{}];
    [self.log writeData:[NSJSONSerialization dataWithJSONObject:row options:0 error:nil]];
    [self.log writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; [self.log synchronizeFile];
    [self.logLock unlock];
}
- (void)report:(NSString *)value {
    @synchronized(self) { self.status=value; }
    [self event:@"status" values:@{@"message":value}];
    [[NSJSONSerialization dataWithJSONObject:@{@"at":@(NSDate.date.timeIntervalSince1970),@"message":value} options:0 error:nil] writeToURL:[self.folder URLByAppendingPathComponent:@"status.json"] atomically:YES];
}
- (BOOL)check:(struct IdeviceFfiError *)error step:(NSString *)step {
    if (!error) { [self event:step values:@{@"ok":@YES}]; return YES; }
    NSString *message=error->message ? @(error->message) : @"unknown error";
    idevice_error_free(error);
    [self report:[NSString stringWithFormat:@"%@: %@",step,message]]; return NO;
}
- (BOOL)unlocked {
    uint64_t state=UINT64_MAX; int changed=0;
    if (self.lockToken<0 || notify_get_state(self.lockToken,&state)!=NOTIFY_STATUS_OK || notify_check(self.lockToken,&changed)!=NOTIFY_STATUS_OK) return NO;
    if(state!=0 || changed) { self.unlockedSince=0; return NO; }
    __block BOOL available=NO; dispatch_sync(dispatch_get_main_queue(),^{ available=UIApplication.sharedApplication.protectedDataAvailable; });
    if(!available) { self.unlockedSince=0; return NO; }
    double now=NSProcessInfo.processInfo.systemUptime;
    if(!self.unlockedSince) self.unlockedSince=now;
    return now-self.unlockedSince>=3;
}
- (void)begin {
    self.lockToken=-1; self.logLock=[NSLock new]; self.observers=[NSMutableArray new]; self.backgroundTask=UIBackgroundTaskInvalid;
    NSURL *group=[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.me.sophiaxu.phantomcapture"];
    self.folder=[[group URLByAppendingPathComponent:@"Documents/Capture/diagnostics"] URLByAppendingPathComponent:[@"tunnel-capture-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:self.folder withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
    NSURL *logURL=[self.folder URLByAppendingPathComponent:@"events.jsonl"];
    [NSFileManager.defaultManager createFileAtPath:logURL.path contents:nil attributes:nil];self.log=[NSFileHandle fileHandleForWritingAtPath:logURL.path];
    NSURL *support=[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"PhantomTunnel"];
    [NSFileManager.defaultManager createDirectoryAtURL:support withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionComplete} error:nil];
    NSURL *pairing=[support URLByAppendingPathComponent:@"pairing.plist"];
    NSURL *legacy=[[[NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"ApplicationSupport/PhantomTunnel"] URLByAppendingPathComponent:@"pairing.plist"];
    if([NSFileManager.defaultManager fileExistsAtPath:pairing.path]) [NSFileManager.defaultManager removeItemAtURL:legacy error:nil];
    [pairing setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionComplete,NSFilePosixPermissions:@0600} ofItemAtPath:pairing.path error:nil];
    for (NSString *name in @[UIApplicationDidEnterBackgroundNotification,UIApplicationWillEnterForegroundNotification,UIApplicationProtectedDataWillBecomeUnavailable,UIApplicationProtectedDataDidBecomeAvailable]) {
        id observer=[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){ [self event:@"lifecycle" values:@{@"name":note.name,@"backgroundTimeRemaining":@(UIApplication.sharedApplication.backgroundTimeRemaining)}]; }];
        [self.observers addObject:observer];
    }
    self.backgroundTask=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"Phantom tunnel persistence diagnostic" expirationHandler:^{
        [self event:@"background-allowance-expired" values:nil];
        if(self.backgroundTask!=UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];self.backgroundTask=UIBackgroundTaskInvalid; }
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{ [self run:pairing]; });
}
- (void)run:(NSURL *)pairingURL {
    struct RpPairingFileHandle *pairing=NULL; struct AdapterHandle *adapter=NULL;
    struct RsdHandshakeHandle *rsd=NULL; struct RemoteServerHandle *server=NULL; struct ScreenshotClientHandle *client=NULL;
    idevice_set_global_timeout(12);
    if(notify_register_check("com.apple.springboard.lockstate",&self->_lockToken)!=NOTIFY_STATUS_OK) { [self report:@"Cannot observe lock state; capture refused"];goto cleanup; }
    if(![NSFileManager.defaultManager fileExistsAtPath:pairingURL.path]) { [self report:@"Pairing record not provisioned yet"];goto cleanup; }
    if(![self check:rp_pairing_file_read(pairingURL.path.UTF8String,&pairing) step:@"read-pairing"]) goto cleanup;
    {
    NSString *host=NSProcessInfo.processInfo.environment[@"PHANTOM_TUNNEL_HOST"] ?: @"127.0.0.1";
    BOOL isSelf=[host isEqualToString:@"127.0.0.1"];
    struct ifaddrs *interfaces=NULL;if(getifaddrs(&interfaces)==0) {
        for(struct ifaddrs *p=interfaces;p;p=p->ifa_next) { if(!p->ifa_addr || p->ifa_addr->sa_family!=AF_INET) continue; char address[INET_ADDRSTRLEN]; inet_ntop(AF_INET,&((struct sockaddr_in *)p->ifa_addr)->sin_addr,address,sizeof(address));if([host isEqualToString:@(address)])isSelf=YES; if([host isEqualToString:@"10.7.0.1"] && strcmp(address,"10.7.0.0")==0)isSelf=YES; }
        freeifaddrs(interfaces);
    }
    if(!isSelf) { [self report:@"Refusing target that is not an address of this phone"];goto cleanup; }
    [self report:[NSString stringWithFormat:@"Authenticating to this phone at %@:49152…",host]];
    struct sockaddr_in addr={0};addr.sin_len=sizeof(addr);addr.sin_family=AF_INET;addr.sin_port=htons(49152);inet_pton(AF_INET,host.UTF8String,&addr.sin_addr);
    if(![self check:tunnel_create_rppairing((const idevice_sockaddr *)&addr,sizeof(addr),"Phantom local capture",pairing,NULL,NULL,&adapter,&rsd) step:@"connect-tunnel"]) goto cleanup;
    }
    [self report:@"Tunnel authenticated. Connecting to Instruments screenshot service…"];
    if(![self check:remote_server_connect_rsd(adapter,rsd,&server) step:@"connect-instruments"]) goto cleanup;
    if(![self check:screenshot_client_new(server,&client) step:@"open-screenshot-channel"]) goto cleanup;
    {
        double seconds=[NSProcessInfo.processInfo.environment[@"PHANTOM_TUNNEL_CAPTURE_SECONDS"] doubleValue];
        BOOL single=seconds<=0; double end=NSProcessInfo.processInfo.systemUptime+(single?30:MIN(seconds,600));
        NSUInteger frames=0; double lastHeartbeat=0;
        while(!self.stopped && NSProcessInfo.processInfo.systemUptime<end) { @autoreleasepool {
            double now=NSProcessInfo.processInfo.systemUptime;
            if(now-lastHeartbeat>=2) { [self event:@"heartbeat" values:@{@"frames":@(frames)}];lastHeartbeat=now; }
            if(![self unlocked]) { [NSThread sleepForTimeInterval:0.25];continue; }
            uint8_t *bytes=NULL;uintptr_t length=0;double start=NSProcessInfo.processInfo.systemUptime;
            if(![self check:screenshot_client_take_screenshot(client,&bytes,&length) step:@"take-screenshot"]) { if(bytes)idevice_data_free(bytes,length);break; }
            NSData *data=bytes?[NSData dataWithBytes:bytes length:length]:nil;
            if(bytes)idevice_data_free(bytes,length);
            if(![self unlocked]) { [self event:@"discarded-lock-transition" values:nil];continue; }
            UIImage *image=data?[UIImage imageWithData:data]:nil;
            if(!image.CGImage) { [self report:@"Service returned an undecodable image"];break; }
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
            NSMutableString *hash=[NSMutableString new];for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hash appendFormat:@"%02x",digest[i]];
            frames++;
            [self event:@"frame" values:@{@"number":@(frames),@"sha256":hash,@"bytes":@(data.length),@"width":@(CGImageGetWidth(image.CGImage)),@"height":@(CGImageGetHeight(image.CGImage)),@"ms":@((NSProcessInfo.processInfo.systemUptime-start)*1000)}];
            [self report:[NSString stringWithFormat:@"%lu frames received through the on-phone tunnel. Images stay in memory.",(unsigned long)frames]];
            if(single) break;
            double delay=0.5-(NSProcessInfo.processInfo.systemUptime-start);if(delay>0)[NSThread sleepForTimeInterval:delay];
        }}
        [self event:@"finished" values:@{@"frames":@(frames),@"userStopped":@(self.stopped)}];
    }
cleanup:
    if(client)screenshot_client_free(client);if(server)remote_server_free(server);if(rsd)rsd_handshake_free(rsd);if(adapter)adapter_free(adapter);if(pairing)rp_pairing_file_free(pairing);
    if(self.lockToken>=0) {notify_cancel(self.lockToken);self.lockToken=-1;}
    [self event:@"probe-closed" values:nil];
    dispatch_async(dispatch_get_main_queue(),^{
        for(id observer in self.observers)[NSNotificationCenter.defaultCenter removeObserver:observer];
        [self.observers removeAllObjects];
        if(self.backgroundTask!=UIBackgroundTaskInvalid){[UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];self.backgroundTask=UIBackgroundTaskInvalid;}
    });
}
@end
