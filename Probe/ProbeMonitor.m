#import "ProbeMonitor.h"
#import "../Shared/MonitorToken.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>

@implementation ProbeMonitor {
    dispatch_source_t _listener;
}
- (BOOL)start:(NSError **)error {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]; return NO; }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(19727);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) || listen(fd, 4)) {
        int code = errno; close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
        return NO;
    }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    dispatch_queue_t queue = dispatch_queue_create("phantom.monitor", DISPATCH_QUEUE_SERIAL);
    _listener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, queue);
    __weak ProbeMonitor *weakSelf = self;
    dispatch_source_set_event_handler(_listener, ^{
        int client = accept(fd, NULL, NULL);
        if (client < 0) return;
        fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK);
        int noSignal = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
        struct timeval timeout = {1, 0};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        NSMutableData *request = [NSMutableData new];
        while (request.length < 4096) {
            char buffer[1024];
            ssize_t n = recv(client, buffer, MIN(sizeof(buffer), 4096-request.length), 0);
            if (n <= 0) break;
            [request appendBytes:buffer length:(NSUInteger)n];
            NSString *partial = [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding];
            if ([partial containsString:@"\r\n\r\n"]) break;
        }
        NSString *text = [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding] ?: @"";
        NSArray *lines = [text componentsSeparatedByString:@"\r\n"];
        BOOL authorized = NO;
        for (NSString *line in lines) {
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            if ([[line substringToIndex:colon.location] caseInsensitiveCompare:@"Authorization"] == NSOrderedSame) {
                NSString *value = [[line substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                authorized = [value isEqualToString:[@"Bearer " stringByAppendingString:PHANTOM_MONITOR_TOKEN]];
            }
        }
        ProbeMonitor *monitor = weakSelf;
        NSString *status = @"200 OK";
        NSDictionary *payload;
        NSString *first = lines.firstObject;
        if (!authorized) { status = @"403 Forbidden"; payload = @{@"error":@"Unauthorized"}; }
        else if ([first isEqualToString:@"GET /status HTTP/1.1"]) {
            payload = monitor.snapshot ?: @{@"state":@"starting"};
        } else if ([first isEqualToString:@"POST /stop HTTP/1.1"]) {
            monitor.stopRequested = YES;
            payload = @{@"requested":@YES};
        } else { status = @"404 Not Found"; payload = @{@"error":@"Not found"}; }
        NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        NSString *header = [NSString stringWithFormat:@"HTTP/1.1 %@\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",status,(unsigned long)body.length];
        NSMutableData *response = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [response appendData:body];
        const char *bytes = response.bytes;
        NSUInteger sent = 0;
        while (sent < response.length) {
            ssize_t n = send(client, bytes+sent, response.length-sent, 0);
            if (n <= 0) break;
            sent += n;
        }
        close(client);
    });
    dispatch_source_set_cancel_handler(_listener, ^{ close(fd); });
    dispatch_resume(_listener);
    return YES;

}
- (void)close { if (_listener) { dispatch_source_cancel(_listener); _listener = nil; } }
- (void)dealloc { [self close]; }
@end
