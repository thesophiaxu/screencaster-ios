#import <Foundation/Foundation.h>
#import "../Probe/ProbeMonitor.h"
int main(void) { @autoreleasepool {
    ProbeMonitor *monitor = [ProbeMonitor new];
    monitor.snapshot = @{@"state":@"capturing", @"frames":@42};
    NSError *error;
    if (![monitor start:&error]) { NSLog(@"%@",error); return 1; }
    double end = NSProcessInfo.processInfo.systemUptime + 15;
    while (!monitor.stopRequested && NSProcessInfo.processInfo.systemUptime < end) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    BOOL stopped = monitor.stopRequested;
    [monitor close];
    return stopped ? 0 : 2;
} }
