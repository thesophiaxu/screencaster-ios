#import <Foundation/Foundation.h>
#ifndef PHANTOM_EXTENSION
#import <UIKit/UIKit.h>
#else
@class UIImage;
#endif
#import <CoreVideo/CoreVideo.h>

@interface VideoRecorder : NSObject
@property (nonatomic, readonly) NSString *error;
@property (nonatomic, readonly) NSString *currentFile;
@property (nonatomic, readonly) NSUInteger frames;
@property (nonatomic, readonly) unsigned long long fileBytes;
@property (nonatomic, copy) void (^completed)(NSDictionary *segment);
@property (nonatomic, copy) void (^event)(NSString *message);
@property (nonatomic, copy) BOOL (^canWrite)(void);
- (CVPixelBufferRef)copyHalfSizeBufferFromEncodedData:(NSData *)data CF_RETURNS_RETAINED;
- (instancetype)initWithFolder:(NSURL *)folder;
// Returned buffer is half the upright raster width/height, rounded down to even.
#ifndef PHANTOM_EXTENSION
+ (CVPixelBufferRef)copyHalfSizeBuffer:(UIImage *)image CF_RETURNS_RETAINED;
#endif
- (BOOL)append:(CVPixelBufferRef)buffer capturedAt:(double)wallTime display:(long long)displayID;
- (BOOL)finish;
@end
