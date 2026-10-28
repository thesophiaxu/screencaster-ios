#import <Foundation/Foundation.h>
NSDictionary *PhantomProbeDirectTunnel(NSData *pairingData);
NSDictionary *PhantomExtensionMemory(void);

@interface PhantomExtensionCapture : NSObject
@property(nonatomic) BOOL recordVideo;
@property(atomic, readonly) BOOL finished;
@property(atomic, copy, readonly) NSDictionary *liveStatus;
- (void)startWithPairing:(NSData *)pairing seconds:(double)seconds;
- (void)stop;
@end
