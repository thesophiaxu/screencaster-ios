#import "TunnelProbe.h"
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <poll.h>
#import <unistd.h>

@implementation TunnelProbe
static NSString *routeStatus;
static BOOL routeStarted;
+ (NSString *)statusText { @synchronized(self) { return routeStatus ?: @"Preparing local route check…"; } }
+ (void)setStatus:(NSString *)text { @synchronized(self) { routeStatus = text; } }
+ (void)start {
    @synchronized(self) { if (routeStarted) return; routeStarted = YES; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSMutableArray *hosts = [NSMutableArray arrayWithObject:@{@"interface":@"loopback",@"address":@"127.0.0.1"}];
        struct ifaddrs *interfaces = NULL;
        if (getifaddrs(&interfaces) == 0) {
            for (struct ifaddrs *p = interfaces; p; p = p->ifa_next) {
                if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
                char address[INET_ADDRSTRLEN];
                inet_ntop(AF_INET,&((struct sockaddr_in *)p->ifa_addr)->sin_addr,address,sizeof(address));
                if (strcmp(address,"127.0.0.1") == 0) continue;
                [hosts addObject:@{@"interface":@(p->ifa_name),@"address":@(address)}];
            }
            freeifaddrs(interfaces);
        }
        NSURL *group = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.me.sophiaxu.phantomcapture"];
        NSURL *folder = [group URLByAppendingPathComponent:@"Documents/Capture/diagnostics"];
        [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *file = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"routes-%@.json",NSUUID.UUID.UUIDString]];
        NSMutableArray *results = [NSMutableArray new];
        for (NSDictionary *host in hosts) {
            for (NSNumber *port in @[@49152,@62078]) {
                [self setStatus:[NSString stringWithFormat:@"Checking %@ port %@…",host[@"interface"],port]];
                double start = NSProcessInfo.processInfo.systemUptime;
                int fd = socket(AF_INET,SOCK_STREAM,0), error = fd < 0 ? errno : 0;
                if (fd >= 0) {
                    fcntl(fd,F_SETFL,O_NONBLOCK);
                    struct sockaddr_in addr = {0}; addr.sin_len = sizeof(addr); addr.sin_family = AF_INET;
                    addr.sin_port = htons(port.intValue); inet_pton(AF_INET,[host[@"address"] UTF8String],&addr.sin_addr);
                    if (connect(fd,(struct sockaddr *)&addr,sizeof(addr)) != 0) {
                        error = errno;
                        if (error == EINPROGRESS) {
                            struct pollfd pfd = {.fd=fd,.events=POLLOUT};
                            int ready = poll(&pfd,1,2000);
                            if (ready > 0) { socklen_t len=sizeof(error); if (getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&len)) error=errno; }
                            else error = ready == 0 ? ETIMEDOUT : errno;
                        }
                    }
                    close(fd);
                }
                [results addObject:@{@"interface":host[@"interface"],@"address":host[@"address"],@"port":port,@"connected":@(error == 0),@"errno":@(error),@"error":error ? @(strerror(error)) : @"",@"ms":@((NSProcessInfo.processInfo.systemUptime-start)*1000)}];
                [[NSJSONSerialization dataWithJSONObject:@{@"at":@(NSDate.date.timeIntervalSince1970),@"results":results,@"completed":@NO} options:NSJSONWritingPrettyPrinted error:nil] writeToURL:file atomically:YES];
            }
        }
        NSUInteger connected = 0; for (NSDictionary *r in results) if ([r[@"connected"] boolValue]) connected++;
        [[NSJSONSerialization dataWithJSONObject:@{@"at":@(NSDate.date.timeIntervalSince1970),@"results":results,@"completed":@YES} options:NSJSONWritingPrettyPrinted error:nil] writeToURL:file atomically:YES];
        [self setStatus:[NSString stringWithFormat:@"Finished: %lu of %lu local endpoints accepted a connection. No VPN settings changed.",(unsigned long)connected,(unsigned long)results.count]];
    });
}
@end
