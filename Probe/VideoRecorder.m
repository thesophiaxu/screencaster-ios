#import "VideoRecorder.h"
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <ImageIO/ImageIO.h>

@implementation VideoRecorder {
    NSURL *_folder, *_partialURL, *_finalURL;
    VTCompressionSessionRef _encoder;
    CVPixelBufferPoolRef _pool;
    size_t _poolWidth, _poolHeight;
    AVAssetWriter *_writer;
    AVAssetWriterInput *_input;
    NSString *_error, *_currentFile;
    NSUInteger _frames, _segmentFrames, _index;
    unsigned long long _closedBytes;
    int _width, _height;
    long long _display;
    double _start, _last;
}
- (instancetype)initWithFolder:(NSURL *)folder { if ((self=[super init])) _folder=folder; return self; }
- (NSString *)error { return _error; }
- (NSString *)currentFile { return _currentFile ?: @""; }
- (NSUInteger)frames { return _frames; }
- (unsigned long long)fileBytes {
    return _closedBytes + (_partialURL ? [[NSFileManager.defaultManager attributesOfItemAtPath:_partialURL.path error:nil][NSFileSize] unsignedLongLongValue] : 0);
}
#ifndef PHANTOM_EXTENSION
+ (CVPixelBufferRef)copyHalfSizeBuffer:(UIImage *)image {
    size_t width=MAX(2, ((size_t)llround(image.size.width*image.scale/2))/2*2);
    size_t height=MAX(2, ((size_t)llround(image.size.height*image.scale/2))/2*2);
    CVPixelBufferRef buffer=NULL;
    NSDictionary *attributes=@{(id)kCVPixelBufferCGImageCompatibilityKey:@YES,(id)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES,(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    if (CVPixelBufferCreate(NULL,width,height,kCVPixelFormatType_32BGRA,(__bridge CFDictionaryRef)attributes,&buffer)!=kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(buffer,0);
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx=CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer),width,height,8,CVPixelBufferGetBytesPerRow(buffer),color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(color);
    if (!ctx) { CVPixelBufferUnlockBaseAddress(buffer,0); CVPixelBufferRelease(buffer); return NULL; }
    CGContextTranslateCTM(ctx,0,height); CGContextScaleCTM(ctx,1,-1);
    CGContextSetInterpolationQuality(ctx,kCGInterpolationMedium);
    UIGraphicsPushContext(ctx);
    [image drawInRect:CGRectMake(0,0,width,height)];
    UIGraphicsPopContext(); CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(buffer,0);
    return buffer;
}
#endif
// Explicit subsampling on CreateImageAtIndex avoids the thumbnail path
// that exceeded the extension memory budget on inner-display PNGs. The
// observed CoreDevice screenshots contain already-oriented pixel data.
// Reject a full-size fallback; retain at most two half-size pool surfaces.
- (CVPixelBufferRef)copyHalfSizeBufferFromEncodedData:(NSData *)data {
    NSDictionary *noCache=@{(id)kCGImageSourceShouldCache:@NO};
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)data,(__bridge CFDictionaryRef)noCache);
    if (!source) return NULL;
    NSDictionary *props=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
    size_t maxSide=MAX([props[(id)kCGImagePropertyPixelWidth] unsignedLongValue],[props[(id)kCGImagePropertyPixelHeight] unsignedLongValue])/2;
    if (!maxSide || maxSide>4096) { CFRelease(source); return NULL; }
#if PHANTOM_TEST_THUMBNAIL_DECODE
    // Opt-in regression workload for measuring the debugging-memory entitlement.
    NSDictionary *options=@{(id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(id)kCGImageSourceCreateThumbnailWithTransform:@YES,(id)kCGImageSourceThumbnailMaxPixelSize:@(maxSide),(id)kCGImageSourceSubsampleFactor:@2,(id)kCGImageSourceShouldCacheImmediately:@YES};
    CGImageRef image=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);
#else
    NSDictionary *options=@{(id)kCGImageSourceSubsampleFactor:@2,(id)kCGImageSourceShouldCacheImmediately:@YES};
    CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,(__bridge CFDictionaryRef)options);
#endif
    CFRelease(source);
    if (!image) return NULL;
    size_t sourceWidth=[props[(id)kCGImagePropertyPixelWidth] unsignedLongValue],sourceHeight=[props[(id)kCGImagePropertyPixelHeight] unsignedLongValue];
    // Fail visibly if ImageIO ignored subsampling; do not draw a full-size raster.
    if (CGImageGetWidth(image)>(sourceWidth+1)/2 || CGImageGetHeight(image)>(sourceHeight+1)/2) { CGImageRelease(image);return NULL; }
    size_t width=MAX(2,sourceWidth/4*2),height=MAX(2,sourceHeight/4*2);
    if (!_pool || width!=_poolWidth || height!=_poolHeight) {
        if (_pool) CVPixelBufferPoolRelease(_pool); _pool=NULL;
        NSDictionary *attrs=@{(id)kCVPixelBufferWidthKey:@(width),(id)kCVPixelBufferHeightKey:@(height),(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(id)kCVPixelBufferCGImageCompatibilityKey:@YES,(id)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES,(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
        CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)attrs,&_pool); _poolWidth=width;_poolHeight=height;
    }
    CVPixelBufferRef buffer=NULL;
    if (_pool) CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL,_pool,(__bridge CFDictionaryRef)@{(id)kCVPixelBufferPoolAllocationThresholdKey:@2},&buffer);
    if (buffer) {
        CVPixelBufferLockBaseAddress(buffer,0);
        CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx=CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer),width,height,8,CVPixelBufferGetBytesPerRow(buffer),color,kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst);
        CGColorSpaceRelease(color);
        if (ctx) { CGContextSetInterpolationQuality(ctx,kCGInterpolationLow);CGContextDrawImage(ctx,CGRectMake(0,0,width,height),image);CGContextRelease(ctx); }
        CVPixelBufferUnlockBaseAddress(buffer,0);
        if (!ctx) { CVPixelBufferRelease(buffer);buffer=NULL; }
    }
    CGImageRelease(image);
    return buffer;
}
- (BOOL)fail:(NSString *)message { _error=message; if (self.event) self.event(message); return NO; }
- (void)receive:(CMSampleBufferRef)sample status:(OSStatus)status {
    if (self.canWrite && !self.canWrite()) return;
    if (status || !sample || !CMSampleBufferDataIsReady(sample)) { [self fail:[NSString stringWithFormat:@"encoder-failed status=%d",(int)status]]; return; }
    if (self.canWrite && !self.canWrite()) return;
    if (!_writer) {
        NSError *error;
        _writer=[[AVAssetWriter alloc] initWithURL:_partialURL fileType:AVFileTypeMPEG4 error:&error];
        if (!_writer) { [self fail:[@"writer-failed " stringByAppendingString:error.localizedDescription ?: @"unknown"]]; return; }
        _input=[[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:nil sourceFormatHint:CMSampleBufferGetFormatDescription(sample)];
        _input.expectsMediaDataInRealTime=YES;
        if (![_writer canAddInput:_input]) { [self fail:@"writer-failed cannot add HEVC track"]; return; }
        [_writer addInput:_input];
        if (![_writer startWriting]) { [self fail:[@"writer-failed " stringByAppendingString:_writer.error.localizedDescription]]; return; }
        [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionComplete} ofItemAtPath:_partialURL.path error:nil];
        [_writer startSessionAtSourceTime:kCMTimeZero];
    }
    // Two frames/second maximum; a stalled file sink fails visibly instead of
    // accumulating an unbounded queue or silently throwing away admitted frames.
    double deadline=NSProcessInfo.processInfo.systemUptime+2;
    while (!_input.readyForMoreMediaData && _writer.status==AVAssetWriterStatusWriting && NSProcessInfo.processInfo.systemUptime<deadline) [NSThread sleepForTimeInterval:0.005];
    if (self.canWrite && !self.canWrite()) return;
    if (!_input.readyForMoreMediaData || ![_input appendSampleBuffer:sample]) [self fail:[@"writer-failed " stringByAppendingString:_writer.error.localizedDescription ?: @"backpressure timeout"]];
    else { _frames++; _segmentFrames++; }
}
static void encoded(void *ref, void *source, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    @autoreleasepool { [(__bridge VideoRecorder *)ref receive:sample status:status]; }
}
- (BOOL)begin:(CVPixelBufferRef)buffer at:(double)time display:(long long)display {
    _width=(int)CVPixelBufferGetWidth(buffer); _height=(int)CVPixelBufferGetHeight(buffer); _display=display; _start=time; _last=time; _segmentFrames=0;
    _currentFile=[NSString stringWithFormat:@"%05lu-%lld.mp4",(unsigned long)_index++,(long long)time];
    _finalURL=[_folder URLByAppendingPathComponent:_currentFile];
    _partialURL=[_folder URLByAppendingPathComponent:[_currentFile stringByAppendingString:@".partial"]];
    NSDictionary *spec=@{(__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES};
    NSDictionary *attrs=@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(id)kCVPixelBufferWidthKey:@(_width),(id)kCVPixelBufferHeightKey:@(_height),(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    OSStatus status=VTCompressionSessionCreate(NULL,_width,_height,kCMVideoCodecType_HEVC,(__bridge CFDictionaryRef)spec,(__bridge CFDictionaryRef)attrs,NULL,encoded,(__bridge void *)self,&_encoder);
    if (status) return [self fail:[NSString stringWithFormat:@"hardware-hevc-unavailable status=%d",(int)status]];
#if PHANTOM_EXTENSION
    NSNumber *expectedFPS=@1;
#else
    NSNumber *expectedFPS=@2;
#endif
    NSDictionary *properties=@{(__bridge NSString *)kVTCompressionPropertyKey_RealTime:@YES,(__bridge NSString *)kVTCompressionPropertyKey_ExpectedFrameRate:expectedFPS,(__bridge NSString *)kVTCompressionPropertyKey_AllowFrameReordering:@NO,(__bridge NSString *)kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration:@10,(__bridge NSString *)kVTCompressionPropertyKey_AverageBitRate:@1000000,(__bridge NSString *)kVTCompressionPropertyKey_ProfileLevel:(__bridge NSString *)kVTProfileLevel_HEVC_Main_AutoLevel};
    status=VTSessionSetProperties(_encoder,(__bridge CFDictionaryRef)properties);
    if (status) return [self fail:[NSString stringWithFormat:@"encoder-settings-failed status=%d",(int)status]];
    status=VTCompressionSessionPrepareToEncodeFrames(_encoder);
    if (status) return [self fail:[NSString stringWithFormat:@"encoder-prepare-failed status=%d",(int)status]];
    CFTypeRef hardware=NULL;
    VTSessionCopyProperty(_encoder,kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,NULL,&hardware);
    BOOL accelerated=hardware && CFEqual(hardware,kCFBooleanTrue);
    if (hardware) CFRelease(hardware);
    if (!accelerated) return [self fail:@"hardware-hevc-unavailable: encoder did not confirm hardware acceleration"];
    if (self.event) self.event([NSString stringWithFormat:@"video-open file=%@ display=%lld width=%d height=%d codec=hevc hardware=1",_currentFile,_display,_width,_height]);
    return YES;
}
- (BOOL)append:(CVPixelBufferRef)buffer capturedAt:(double)time display:(long long)display {
    if (_error) return NO;
    if (_encoder && (time-_start>=60 || _display!=display || _width!=CVPixelBufferGetWidth(buffer) || _height!=CVPixelBufferGetHeight(buffer))) if (![self finish]) return NO;
    if (!_encoder && ![self begin:buffer at:time display:display]) return NO;
    CMTime pts=CMTimeMakeWithSeconds(time-_start,60000);
    OSStatus status=VTCompressionSessionEncodeFrame(_encoder,buffer,pts,CMTimeMake(1,2),NULL,NULL,NULL);
    if (!status) status=VTCompressionSessionCompleteFrames(_encoder,pts);
    if (self.canWrite && !self.canWrite()) return YES; // Lock interrupted encoding; close the segment after unlock.
    if (status) return [self fail:[NSString stringWithFormat:@"encode-failed status=%d",(int)status]];
    _last=time;
    return !_error;
}
- (BOOL)finish {
    if (self.canWrite && !self.canWrite()) return NO;
    if (_encoder) { VTCompressionSessionCompleteFrames(_encoder,kCMTimeInvalid); VTCompressionSessionInvalidate(_encoder); CFRelease(_encoder); _encoder=NULL; }
    if (_writer && _writer.status==AVAssetWriterStatusWriting) {
        [_writer endSessionAtSourceTime:CMTimeMakeWithSeconds(_last-_start+0.5,60000)];
        [_input markAsFinished];
        dispatch_semaphore_t done=dispatch_semaphore_create(0);
        [_writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
        if (dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))) { [_writer cancelWriting]; [self fail:@"video-finalize-failed timeout"]; }
        if (_writer.status!=AVAssetWriterStatusCompleted && !_error) [self fail:[@"video-finalize-failed " stringByAppendingString:_writer.error.localizedDescription ?: @"unknown"]];
    }
    if (!_error && _writer.status==AVAssetWriterStatusCompleted) {
        NSError *error;
        if (![NSFileManager.defaultManager moveItemAtURL:_partialURL toURL:_finalURL error:&error]) [self fail:[@"video-finalize-failed " stringByAppendingString:error.localizedDescription]];
        else {
            unsigned long long bytes=[[NSFileManager.defaultManager attributesOfItemAtPath:_finalURL.path error:nil][NSFileSize] unsignedLongLongValue];
            _closedBytes+=bytes;
            NSDictionary *metadata=@{@"file":_currentFile,@"start":@(_start),@"end":@(_last+0.5),@"frames":@(_segmentFrames),@"bytes":@(bytes),@"width":@(_width),@"height":@(_height),@"display":@(_display),@"codec":@"hevc",@"hardware":@YES};
            if (self.completed) self.completed(metadata);
        }
    }
    _writer=nil; _input=nil; _partialURL=nil; _finalURL=nil;
    return !_error;
}
- (void)dealloc { if (_pool) CVPixelBufferPoolRelease(_pool); if (_encoder) { VTCompressionSessionInvalidate(_encoder); CFRelease(_encoder); } }
@end
