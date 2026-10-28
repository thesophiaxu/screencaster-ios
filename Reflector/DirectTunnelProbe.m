#import "DirectTunnelProbe.h"
#import "idevice.h"
#import "ExtensionRecordingStore.h"
#import <float.h>
#import <arpa/inet.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <notify.h>
#import <mach/mach.h>
#import <os/proc.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <dlfcn.h>
#import <unistd.h>
#import <stdatomic.h>
#import <pthread.h>

NSDictionary *PhantomExtensionMemory(void) {
    task_vm_info_data_t info={0};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
    kern_return_t result=task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&info,&count);
    return @{@"footprintBytes":@(result==KERN_SUCCESS?info.phys_footprint:0),@"peakFootprintBytes":@(result==KERN_SUCCESS?info.ledger_phys_footprint_peak:0),@"availableMemoryBytes":@(os_proc_available_memory())};
}

struct PhantomScreenHandle;
extern struct IdeviceFfiError *phantom_screen_connect(struct AdapterHandle *, struct RsdHandshakeHandle *, struct PhantomScreenHandle **);
extern struct IdeviceFfiError *phantom_screen_take(struct PhantomScreenHandle *, uint8_t **, uintptr_t *, uint32_t *, double *);
extern void phantom_screen_free(struct PhantomScreenHandle *);

extern uint64_t phantom_transport_counter(uintptr_t index);
extern uint64_t phantom_tcp_counter(uintptr_t index);
static NSDictionary *PhantomTransportCounters(void) {
    NSArray *transportNames=@[@"tlsWireRead",@"tlsPlainRead",@"tlsWritePending",@"dvtReadStage",@"dvtHeaders",@"dvtLength",@"dvtIdentifier",@"dvtFragment",@"dvtBodyRead",@"dvtDecoded",@"dvtEnqueued",@"dvtDequeued"];
    NSArray *tcpNames=@[@"tcpPayloadRead",@"tcpAccepted",@"tcpDuplicate",@"tcpAhead",@"tcpLastSeq",@"tcpExpectedSeq",@"tcpLastLength",@"tcpACKs",@"tcpLastPort",@"tcpReorderBuffered",@"tcpReorderReleased",@"tcpReorderPeak"];
    NSMutableDictionary *r=[NSMutableDictionary new];
    for(NSUInteger i=0;i<transportNames.count;i++)r[transportNames[i]]=@(phantom_transport_counter(i));
    for(NSUInteger i=0;i<tcpNames.count;i++)r[tcpNames[i]]=@(phantom_tcp_counter(i));
    return r;
}

// Diagnostic-only socket binding for the static Rust client's two TCP connections.
// The VPN provider's ordinary outbound sockets otherwise bypass its own tunnel.
// Restrict the override to the synthetic peer; all other destinations are unchanged.
static atomic_uint boundConnections;
static atomic_int lastBindError;
static pthread_mutex_t boundMutex=PTHREAD_MUTEX_INITIALIZER;
static int boundFDs[16];
static unsigned int boundFDCount;
static void PhantomShutdownBoundConnections(void) {
    pthread_mutex_lock(&boundMutex);
    for(unsigned int i=0;i<boundFDCount;i++) {
        struct sockaddr_in peer={0};socklen_t size=sizeof(peer);
        // Never close a descriptor owned by Rust; only interrupt this diagnostic's sockets.
        if(!getpeername(boundFDs[i],(struct sockaddr *)&peer,&size) && peer.sin_family==AF_INET && ntohl(peer.sin_addr.s_addr)==0x0a070001) shutdown(boundFDs[i],SHUT_RDWR);
    }
    boundFDCount=0;
    pthread_mutex_unlock(&boundMutex);
}
int connect(int fd, const struct sockaddr *address, socklen_t length) {
    static int (*systemConnect)(int,const struct sockaddr *,socklen_t);
    static dispatch_once_t once;
    dispatch_once(&once,^{systemConnect=dlsym(RTLD_NEXT,"connect");});
    if(!systemConnect) { errno=ENOSYS;return -1; }
    if(address && address->sa_family==AF_INET && length>=sizeof(struct sockaddr_in) &&
       ntohl(((const struct sockaddr_in *)address)->sin_addr.s_addr)==0x0a070001) {
        struct ifaddrs *interfaces=NULL;unsigned int index=0;
        if(getifaddrs(&interfaces)==0) {
            for(struct ifaddrs *p=interfaces;p;p=p->ifa_next) {
                if(p->ifa_addr && p->ifa_addr->sa_family==AF_INET && ntohl(((struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr)==0x0a070000) {index=if_nametoindex(p->ifa_name);break;}
            }
            freeifaddrs(interfaces);
        }
        if(!index) {atomic_store(&lastBindError,ENODEV);errno=ENODEV;return -1;}
        if(setsockopt(fd,IPPROTO_IP,IP_BOUND_IF,&index,sizeof(index))) {atomic_store(&lastBindError,errno);return -1;}
        // The shared VPN's primary address belongs to Tailscale. Pin only the
        // synthetic capture sockets to their reflector source address.
        struct sockaddr_in local={0};socklen_t localLength=sizeof(local);
        if(getsockname(fd,(struct sockaddr *)&local,&localLength)) {atomic_store(&lastBindError,errno);return -1;}
        if(local.sin_addr.s_addr==INADDR_ANY) {
            local.sin_len=sizeof(local);local.sin_family=AF_INET;local.sin_addr.s_addr=htonl(0x0a070000);
            if(bind(fd,(struct sockaddr *)&local,sizeof(local))) {atomic_store(&lastBindError,errno);return -1;}
        } else if(ntohl(local.sin_addr.s_addr)!=0x0a070000) {atomic_store(&lastBindError,EADDRNOTAVAIL);errno=EADDRNOTAVAIL;return -1;}
        atomic_fetch_add(&boundConnections,1);atomic_store(&lastBindError,0);
        pthread_mutex_lock(&boundMutex);
        if(boundFDCount<16)boundFDs[boundFDCount++]=fd;
        pthread_mutex_unlock(&boundMutex);
    }
    return systemConnect(fd,address,length);
}

// Authentication only. No screenshot API, keys on disk, or debug logging.
NSDictionary *PhantomProbeDirectTunnel(NSData *pairingData) {
    struct RpPairingFileHandle *pairing=NULL;
    struct AdapterHandle *adapter=NULL;
    struct RsdHandshakeHandle *rsd=NULL;
    struct IdeviceFfiError *error=NULL;
    NSString *step=@"read-pairing";
    double start=NSProcessInfo.processInfo.systemUptime;
    idevice_set_global_timeout(12);
    error=rp_pairing_file_from_bytes(pairingData.bytes,pairingData.length,&pairing);
    if(!error) {
        step=@"authenticate-localhost-from-extension";
        struct sockaddr_in addr={0};addr.sin_len=sizeof(addr);addr.sin_family=AF_INET;
        addr.sin_port=htons(49152);inet_pton(AF_INET,"127.0.0.1",&addr.sin_addr);
        error=tunnel_create_rppairing((const idevice_sockaddr *)&addr,sizeof(addr),"Phantom local capture",pairing,NULL,NULL,&adapter,&rsd);
    }
    NSDictionary *result=@{@"at":@(NSDate.date.timeIntervalSince1970),@"step":step,@"ok":@(!error),@"message":error && error->message?@(error->message):@"Authenticated",@"ms":@((NSProcessInfo.processInfo.systemUptime-start)*1000)};
    if(error)idevice_error_free(error);
    if(rsd)rsd_handshake_free(rsd);if(adapter)adapter_free(adapter);if(pairing)rp_pairing_file_free(pairing);
    return result;
}

@interface PhantomExtensionCapture ()
@property(atomic) BOOL stopped;
@property(atomic) NSUInteger lockEpoch;
@property(atomic) double lastTransition;
@property NSLock *logLock;
@property NSFileHandle *log;
@property NSMutableData *pendingLog;
@property double lastLogFlush;
@property double lastStatusWrite;
@property NSData *pendingStatus;
@property NSURL *folder;
@property NSURL *protectedSentinel;
@property int lockToken;
@property(atomic) NSUInteger frames;
@property(atomic, readwrite) BOOL finished;
@property ExtensionRecordingStore *recording;
@property(atomic) double requestStarted;
@end

@implementation PhantomExtensionCapture
- (NSDictionary *)liveStatus { return self.recording.liveStatus; }
- (void)event:(NSString *)event values:(NSDictionary *)values {
    [self.logLock lock];
    NSMutableDictionary *row=[@{@"event":event,@"at":@(NSDate.date.timeIntervalSince1970),@"uptime":@(NSProcessInfo.processInfo.systemUptime),@"pid":@(getpid())} mutableCopy];
    [row addEntriesFromDictionary:values ?: @{}];
    NSData *data=[NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
    if(data) {
        [self.pendingLog appendData:data];[self.pendingLog appendBytes:"\n" length:1];
        double now=NSProcessInfo.processInfo.systemUptime;
        if (self.pendingLog.length>=64*1024 || now-self.lastLogFlush>=60 || [event isEqualToString:@"probe-closed"]) {
            [self.log writeData:self.pendingLog];[self.pendingLog setLength:0];self.lastLogFlush=now;
        }
    }
    [self.logLock unlock];
}
- (void)status:(NSString *)message {
    [self event:@"status" values:@{@"message":message}];
    NSDictionary *row=@{@"at":@(NSDate.date.timeIntervalSince1970),@"message":message,@"frames":@(self.frames),@"pid":@(getpid()),@"session":self.folder.lastPathComponent};
    NSURL *url=[self.folder.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"extension-capture-status.json"];
    self.pendingStatus=[NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
    if (NSProcessInfo.processInfo.systemUptime-self.lastStatusWrite>=60) {
        [self.pendingStatus writeToURL:url atomically:YES];self.lastStatusWrite=NSProcessInfo.processInfo.systemUptime;
    }
}
- (BOOL)check:(struct IdeviceFfiError *)error step:(NSString *)step {
    if(!error) { [self event:step values:@{@"ok":@YES}];return YES; }
    NSString *message=error->message ? @(error->message) : @"unknown error";
    idevice_error_free(error);[self status:[NSString stringWithFormat:@"%@: %@",step,message]];return NO;
}
- (BOOL)unlocked {
    uint64_t state=UINT64_MAX;
    if(self.lockToken<0 || notify_get_state(self.lockToken,&state)!=NOTIFY_STATUS_OK || state!=0) return NO;
    if(NSProcessInfo.processInfo.systemUptime-self.lastTransition<3) return NO;
    // New file opens fail while Complete-protected data is unavailable. No UIKit dependency.
    return [NSData dataWithContentsOfURL:self.protectedSentinel options:0 error:nil]!=nil;
}
- (NSDictionary *)memory { return PhantomExtensionMemory(); }

- (BOOL)prepareCaptureMemoryWithAdapter:(struct AdapterHandle *)adapter handshake:(struct RsdHandshakeHandle *)rsd {
    struct RemoteServerHandle *server=NULL;
    struct ProcessControlHandle *control=NULL;
    NSDictionary *before=[self memory];
    BOOL accepted=NO;
    [self status:@"Requesting developer memory allowance for recorder…"];
    self.requestStarted=NSProcessInfo.processInfo.systemUptime;
    if(![self check:remote_server_connect_rsd(adapter,rsd,&server) step:@"connect-memory-process-control"])goto cleanup;
    self.requestStarted=NSProcessInfo.processInfo.systemUptime;
    if(![self check:process_control_new(server,&control) step:@"open-memory-process-control"])goto cleanup;
    self.requestStarted=NSProcessInfo.processInfo.systemUptime;
    // The developer service applies this to this extension instance, never the host or another app.
    accepted=[self check:process_control_disable_memory_limit(control,(uint64_t)getpid()) step:@"disable-memory-limit"];
cleanup:
    self.requestStarted=0;
    // ProcessControl borrows RemoteServer; release in that order, before its adapter.
    if(control)process_control_free(control);
    if(server)remote_server_free(server);
    NSDictionary *result=@{@"accepted":@(accepted),@"before":before,@"after":[self memory]};
    [self event:@"memory-limit-preflight" values:result];
    if(!accepted) {
        [self.recording recordError:@"Developer memory allowance unavailable; waiting to retry before capture"];
    } else {
        [self.recording recordError:@""];
    }
    return accepted;
}

- (void)startWithPairing:(NSData *)pairing seconds:(double)seconds {
    self.logLock=[NSLock new];self.pendingLog=[NSMutableData new];self.lockToken=-1;self.stopped=NO;
    NSURL *root=[[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.me.sophiaxu.phantomcapture"] URLByAppendingPathComponent:@"Documents/Capture/diagnostics"];
    self.folder=[root URLByAppendingPathComponent:[@"extension-capture-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:self.folder withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
    NSURL *logURL=[self.folder URLByAppendingPathComponent:@"events.jsonl"];
    [NSFileManager.defaultManager createFileAtPath:logURL.path contents:nil attributes:nil];self.log=[NSFileHandle fileHandleForWritingAtPath:logURL.path];
    self.protectedSentinel=[self.folder URLByAppendingPathComponent:@"unlocked.sentinel"];
    BOOL created=[NSFileManager.defaultManager createFileAtPath:self.protectedSentinel.path contents:[@"unlocked" dataUsingEncoding:NSUTF8StringEncoding] attributes:@{NSFileProtectionKey:NSFileProtectionComplete}];
    if(!created) { [self status:@"Cannot create protected-data sentinel; capture refused"];self.finished=YES;return; }
    self.lastTransition=NSProcessInfo.processInfo.systemUptime;
    __weak typeof(self) weakSelf=self;
    if(notify_register_dispatch("com.apple.springboard.lockstate",&self->_lockToken,dispatch_queue_create("PhantomExtensionLock",DISPATCH_QUEUE_SERIAL),^(int token){
        typeof(self) self=weakSelf;if(!self)return;
        self.lockEpoch+=1;self.lastTransition=NSProcessInfo.processInfo.systemUptime;
        uint64_t state=UINT64_MAX;notify_get_state(token,&state);
        [self event:@"lock-transition" values:@{@"state":@(state),@"epoch":@(self.lockEpoch)}];
        if(state!=0)PhantomShutdownBoundConnections();
    })!=NOTIFY_STATUS_OK) { [self status:@"Cannot observe lock state; capture refused"];self.finished=YES;return; }
    double duration=seconds>0?MAX(15,MIN(seconds,600)):0;
    NSThread *thread=[[NSThread alloc] initWithBlock:^{ @autoreleasepool { [self run:pairing seconds:duration]; } }];
    thread.name=@"Phantom extension capture";thread.stackSize=1024*1024;thread.qualityOfService=NSQualityOfServiceUtility;[thread start];
}
- (void)stop { self.stopped=YES;PhantomShutdownBoundConnections(); }
- (void)run:(NSData *)pairingData seconds:(double)seconds {
    double end=seconds>0?NSProcessInfo.processInfo.systemUptime+seconds:DBL_MAX;
    if (self.recordVideo) {
        self.recording=[[ExtensionRecordingStore alloc] initWithRoot:self.folder.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent];
        __weak typeof(self) weak=self;self.recording.unlocked=^{ return [weak unlocked]; };
    }
    self.finished=NO;
    NSThread *watchdog=[[NSThread alloc] initWithBlock:^{ @autoreleasepool {
        double lastHeartbeat=0;
        while(!self.finished) { @autoreleasepool {
            double now=NSProcessInfo.processInfo.systemUptime;
            if(now-lastHeartbeat>=2) {
                [self event:@"heartbeat" values:@{@"frames":@(self.frames),@"unlocked":@([self unlocked]),@"memory":[self memory],@"transport":PhantomTransportCounters(),@"requestAge":@(self.requestStarted?now-self.requestStarted:0)}];lastHeartbeat=now;
            }
            if(now>=end) { [self event:@"deadline" values:nil];[self stop];break; }
            if(self.requestStarted && now-self.requestStarted>8) {
                [self event:@"request-watchdog" values:nil];self.requestStarted=0;PhantomShutdownBoundConnections();
            }
            [NSThread sleepForTimeInterval:0.5];
        }}
    }}];watchdog.name=@"Phantom capture watchdog";[watchdog start];
    idevice_set_global_timeout(8);
    [self event:@"started" values:@{@"durationSeconds":@(seconds),@"memory":[self memory]}];
    NSUInteger attempt=0;
    while(!self.stopped && NSProcessInfo.processInfo.systemUptime<end) { @autoreleasepool {
        [self.recording tickWithMemory:[self memory]];
        if (self.recording && !self.recording.desired) { [self stop];break; }
        if(![self unlocked]) { [self.recording pause];[NSThread sleepForTimeInterval:0.25];continue; }
        struct RpPairingFileHandle *pairing=NULL;struct AdapterHandle *adapter=NULL;
        struct RsdHandshakeHandle *rsd=NULL;struct PhantomScreenHandle *client=NULL;
        double reconnectDelay=1;
        attempt++;[self event:@"connection-attempt" values:@{@"attempt":@(attempt)}];
        if(![self check:rp_pairing_file_from_bytes(pairingData.bytes,pairingData.length,&pairing) step:@"read-pairing"])goto disconnect;
        {
            struct sockaddr_in addr={0};addr.sin_len=sizeof(addr);addr.sin_family=AF_INET;addr.sin_port=htons(49152);inet_pton(AF_INET,"10.7.0.1",&addr.sin_addr);
            [self status:@"Extension authenticating through global reflector…"];
            if(![self check:tunnel_create_rppairing((const idevice_sockaddr *)&addr,sizeof(addr),"Phantom extension capture",pairing,NULL,NULL,&adapter,&rsd) step:@"connect-tunnel"])goto disconnect;
        }
        if(![self prepareCaptureMemoryWithAdapter:adapter handshake:rsd]) { reconnectDelay=10;goto disconnect; }
        if(self.stopped || ![self unlocked])goto disconnect;
        if(![self check:phantom_screen_connect(adapter,rsd,&client) step:@"connect-coredevice-screenshot"])goto disconnect;
        while(!self.stopped && NSProcessInfo.processInfo.systemUptime<end && [self unlocked]) { @autoreleasepool {
            [self.recording tickWithMemory:[self memory]];
            if (self.recording && !self.recording.desired) { [self stop];break; }
            NSUInteger epoch=self.lockEpoch;double start=NSProcessInfo.processInfo.systemUptime;
            uint8_t *bytes=NULL;uintptr_t length=0;uint32_t display=0;double resolveMS=0;
            self.requestStarted=start;
            struct IdeviceFfiError *error=phantom_screen_take(client,&bytes,&length,&display,&resolveMS);
            self.requestStarted=0;
            if(error) { if(bytes)idevice_data_free(bytes,length);[self check:error step:@"take-screenshot"];break; }
            double captureMS=(NSProcessInfo.processInfo.systemUptime-start)*1000;
            if(self.stopped || ![self unlocked] || epoch!=self.lockEpoch) { if(bytes)idevice_data_free(bytes,length);[self event:@"discarded-lock-or-stop" values:nil];break; }
            if (!bytes || !length) { if(bytes)idevice_data_free(bytes,length);[self.recording pause];[NSThread sleepForTimeInterval:0.5];continue; }
            [self event:@"screenshot-received" values:@{@"bytes":@(length),@"display":@(display),@"captureMS":@(captureMS),@"memory":[self memory]}];
            CVPixelBufferRef buffer=NULL;
            double resizeStart=NSProcessInfo.processInfo.systemUptime;
            @autoreleasepool {
                NSData *data=bytes?[[NSData alloc] initWithBytesNoCopy:bytes length:length deallocator:^(void *p, NSUInteger n){ idevice_data_free(p,n); }]:nil;
                if (self.recording) {
                    buffer=[self.recording.video copyHalfSizeBufferFromEncodedData:data];
                } else {
                    CGImageSourceRef source=data?CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL):NULL;
                    NSDictionary *properties=source?CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL)):nil;
                    NSDictionary *options=@{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@64,(__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES};
                    CGImageRef thumbnail=source?CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options):NULL;
                    BOOL decoded=thumbnail!=NULL;if(thumbnail)CGImageRelease(thumbnail);if(source)CFRelease(source);
                    if(!decoded) { [self status:@"Screenshot did not decode"];break; }
                    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
                    NSMutableString *hash=[NSMutableString new];for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hash appendFormat:@"%02x",digest[i]];
                    if(self.stopped || ![self unlocked] || epoch!=self.lockEpoch) { [self event:@"discarded-lock-or-stop" values:nil];break; }
                    self.frames++;
                    [self event:@"frame" values:@{@"number":@(self.frames),@"sha256":hash,@"bytes":@(data.length),@"width":properties[(__bridge NSString *)kCGImagePropertyPixelWidth]?:@0,@"height":properties[(__bridge NSString *)kCGImagePropertyPixelHeight]?:@0,@"ms":@((NSProcessInfo.processInfo.systemUptime-start)*1000),@"memory":[self memory]}];
                }
            } // Release screenshot/archive/decode temporaries before calling the encoder.
            if (self.recording) {
                if (!buffer) { [self.recording recordError:@"Half-size decode failed or pixel pool exhausted"];[self stop];break; }
                if (self.stopped || ![self unlocked] || epoch!=self.lockEpoch) { CVPixelBufferRelease(buffer);[self.recording pause];break; }
                double resizeMS=(NSProcessInfo.processInfo.systemUptime-resizeStart)*1000;
                [self event:@"frame-decoded" values:@{@"width":@(CVPixelBufferGetWidth(buffer)),@"height":@(CVPixelBufferGetHeight(buffer)),@"resizeMS":@(resizeMS),@"memory":[self memory]}];
                BOOL saved=[self.recording appendBuffer:buffer at:NSDate.date.timeIntervalSince1970 display:display resolveMS:resolveMS captureMS:captureMS resizeMS:resizeMS];
                CVPixelBufferRelease(buffer);self.frames=self.recording.video.frames;
                [self event:@"frame" values:@{@"number":@(self.frames),@"display":@(display),@"resolveMS":@(resolveMS),@"captureMS":@(captureMS),@"resizeMS":@(resizeMS),@"bytes":@(length),@"ms":@((NSProcessInfo.processInfo.systemUptime-start)*1000),@"memory":[self memory]}];
                if (!saved) { [self.recording recordError:self.recording.video.error?:@"Video append failed"];[self stop];break; }
            }
            if(self.frames==1 || self.frames%10==0)[self status:[NSString stringWithFormat:@"%lu frames %@ inside VPN extension",(unsigned long)self.frames,self.recording?@"saved":@"captured"]];
            double delay=1.0-(NSProcessInfo.processInfo.systemUptime-start);if(delay>0)[NSThread sleepForTimeInterval:delay];
        }}
    disconnect:
        [self.recording pause];
        self.requestStarted=0;PhantomShutdownBoundConnections();
        if(client)phantom_screen_free(client);if(rsd)rsd_handshake_free(rsd);if(adapter)adapter_free(adapter);if(pairing)rp_pairing_file_free(pairing);
        [self event:@"connection-closed" values:@{@"attempt":@(attempt)}];
        // Keep Stop responsive even when the memory prerequisite is unavailable.
        double retryAt=NSProcessInfo.processInfo.systemUptime+reconnectDelay;
        while(!self.stopped && NSProcessInfo.processInfo.systemUptime<MIN(retryAt,end)) {
            [self.recording tickWithMemory:[self memory]];
            [NSThread sleepForTimeInterval:0.25];
        }
    }}
    if (self.recording) {
        [self.recording requestStop];
        while (![self unlocked]) { @autoreleasepool { [self.recording tickWithMemory:[self memory]];[NSThread sleepForTimeInterval:0.5]; } }
        [self.recording finish];[self.recording tickWithMemory:[self memory]];
    }
    self.finished=YES;
    if(self.lockToken>=0) {notify_cancel(self.lockToken);self.lockToken=-1;}
    [self event:@"finished" values:@{@"frames":@(self.frames),@"attempts":@(attempt)}];
    [self status:[NSString stringWithFormat:@"Recording stopped after %lu frames",(unsigned long)self.frames]];
    [self.pendingStatus writeToURL:[self.folder.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"extension-capture-status.json"] atomically:YES];
    [self event:@"probe-closed" values:@{@"memory":[self memory],@"boundConnections":@(atomic_load(&boundConnections)),@"bindError":@(atomic_load(&lastBindError))}];
}
@end
