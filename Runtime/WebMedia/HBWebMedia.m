// libHarborWebMedia.dylib: camera, microphone and recording for web pages in converted apps.
// Mac Catalyst's WebKit leaves out navigator.mediaDevices, MediaStream and MediaRecorder. The core
// runtime loads this library the first time the app creates a web view and calls HBWebMediaAttach,
// which adds HBWebMedia.js (compiled in from the generated HBWebMediaScript.h) and the "harborMedia"
// script message handler that backs it:
//  - capture: one AVCaptureSession for the camera and one for the microphone, shared by every page
//    stream; pages long-poll for the newest frame (JPEG) or the audio since their last poll (16-bit
//    mono PCM). A stream that stops polling for a few seconds is dropped, and a session with no
//    streams left stops, so a closed page releases the camera and microphone.
//  - recording: AVAssetWriter encodes H.264 and AAC into an MP4 (or fragmented MP4 when the page asks
//    for timeslices), straight from the capture sessions or from frames and samples the page pushes
//    (canvas.captureStream, Web Audio). The page reads the result back in pieces.
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <os/log.h>
#import "HBWebMediaScript.h"

static void WMLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void WMLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("app.harbor.runtime", "webmedia"); });
    os_log(log, "%{public}@", message);
    if (getenv("HARBOR_VERBOSE")) fprintf(stderr, "[Harbor] %s\n", message.UTF8String);
}

typedef void (^WMReply)(id _Nullable result, NSString *_Nullable error);

static void WMOnMain(WMReply reply, id result, NSString *error) {
    dispatch_async(dispatch_get_main_queue(), ^{ reply(result, error); });
}

static CMTime WMHostNow(void) { return CMClockGetTime(CMClockGetHostTimeClock()); }

@class WMRecorder;

#pragma mark - Capture

/// The camera or the microphone, shared by every page stream of that kind.
@interface WMCapture : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@property (readonly) BOOL video;
@property (readonly) dispatch_queue_t queue;
+ (WMCapture *)camera;
+ (WMCapture *)microphone;
- (void)addRecorder:(WMRecorder *)recorder;
- (void)removeRecorder:(WMRecorder *)recorder;
@end

@interface WMRecorder : NSObject
- (void)captured:(CMSampleBufferRef)sample video:(BOOL)video;
@end

static NSInteger gNextStreamID;

@implementation WMCapture {
    AVCaptureSession *_session;
    AVCaptureDevice *_device;
    NSMutableDictionary<NSNumber *, NSDate *> *_streams; // stream id -> last poll
    NSMutableArray<NSDictionary *> *_waiting;            // {reply, after}
    NSMutableArray<NSDictionary *> *_audio;              // recent audio chunks {sequence, pcm}
    NSDictionary *_lastFrame;
    NSInteger _sequence;
    double _sampleRate;
    NSHashTable<WMRecorder *> *_recorders;
    dispatch_source_t _reaper;
}

+ (WMCapture *)camera {
    static WMCapture *capture;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ capture = [[WMCapture alloc] initWithVideo:YES]; });
    return capture;
}

+ (WMCapture *)microphone {
    static WMCapture *capture;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ capture = [[WMCapture alloc] initWithVideo:NO]; });
    return capture;
}

- (instancetype)initWithVideo:(BOOL)video {
    if (!(self = [super init])) return nil;
    _video = video;
    _queue = dispatch_queue_create(video ? "app.harbor.webmedia.camera" : "app.harbor.webmedia.microphone", DISPATCH_QUEUE_SERIAL);
    _streams = [NSMutableDictionary dictionary];
    _waiting = [NSMutableArray array];
    _audio = [NSMutableArray array];
    _recorders = [NSHashTable weakObjectsHashTable];
    return self;
}

- (AVMediaType)mediaType { return _video ? AVMediaTypeVideo : AVMediaTypeAudio; }

+ (NSArray<AVCaptureDevice *> *)devicesFor:(AVMediaType)type {
    NSMutableArray *types = [NSMutableArray array];
    if (type == AVMediaTypeVideo) {
        [types addObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
        if (@available(iOS 17.0, *)) [types addObjectsFromArray:@[AVCaptureDeviceTypeExternal, AVCaptureDeviceTypeContinuityCamera]];
    } else {
        if (@available(iOS 17.0, *)) [types addObjectsFromArray:@[AVCaptureDeviceTypeMicrophone, AVCaptureDeviceTypeExternal]];
        else [types addObject:AVCaptureDeviceTypeBuiltInMicrophone];
    }
    AVCaptureDeviceDiscoverySession *discovery =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types mediaType:type position:AVCaptureDevicePositionUnspecified];
    NSMutableArray *devices = [discovery.devices mutableCopy] ?: [NSMutableArray array];
    AVCaptureDevice *preferred = [AVCaptureDevice defaultDeviceWithMediaType:type]; // listed first, as browsers do
    if (preferred) {
        [devices removeObject:preferred];
        [devices insertObject:preferred atIndex:0];
    }
    return devices;
}

/// Asks for access (the system prompt shows the app's usage string), then starts capture.
- (void)startWithOptions:(NSDictionary *)options reply:(WMReply)reply {
    AVMediaType type = self.mediaType;
    NSString *what = _video ? @"Camera" : @"Microphone";
    void (^start)(void) = ^{
        dispatch_async(self->_queue, ^{
            NSString *error = [self startSessionWithOptions:options];
            if (error) return WMOnMain(reply, nil, error);
            NSNumber *stream = @(++gNextStreamID);
            self->_streams[stream] = NSDate.date;
            NSMutableDictionary *info = [@{@"id": stream, @"deviceId": self->_device.uniqueID, @"groupId": @"",
                                           @"label": self->_device.localizedName ?: what} mutableCopy];
            if (self->_video) {
                CMVideoDimensions size = CMVideoFormatDescriptionGetDimensions(self->_device.activeFormat.formatDescription);
                info[@"width"] = @(size.width ?: 1280);
                info[@"height"] = @(size.height ?: 720);
            } else {
                const AudioStreamBasicDescription *format =
                    CMAudioFormatDescriptionGetStreamBasicDescription(self->_device.activeFormat.formatDescription);
                info[@"sampleRate"] = @(self->_sampleRate ?: (format && format->mSampleRate ? format->mSampleRate : 48000));
            }
            WMLog(@"Web media: %@ stream %@ from %@", what.lowercaseString, stream, self->_device.localizedName);
            WMOnMain(reply, info, nil);
        });
    };
    switch ([AVCaptureDevice authorizationStatusForMediaType:type]) {
    case AVAuthorizationStatusAuthorized:
        start();
        break;
    case AVAuthorizationStatusNotDetermined: {
        [AVCaptureDevice requestAccessForMediaType:type completionHandler:^(BOOL granted) {
            WMLog(@"Web media: %@ access %@", what.lowercaseString, granted ? @"granted" : @"denied");
            if (granted) start();
            else WMOnMain(reply, nil, [NSString stringWithFormat:@"NotAllowedError: %@ access was denied", what]);
        }];
        break;
    }
    default:
        reply(nil, [NSString stringWithFormat:@"NotAllowedError: %@ access is turned off for this app in System Settings", what]);
    }
}

/// On the capture queue. Returns an error for the page ("Name: message"), or nil once capture runs.
- (NSString *)startSessionWithOptions:(NSDictionary *)options {
    NSArray<AVCaptureDevice *> *devices = [WMCapture devicesFor:self.mediaType];
    AVCaptureDevice *device = devices.firstObject;
    NSString *wanted = [options[@"deviceId"] isKindOfClass:NSString.class] ? options[@"deviceId"] : @"";
    for (AVCaptureDevice *candidate in devices) {
        if ([candidate.uniqueID isEqual:wanted]) device = candidate;
    }
    if (!device) return _video ? @"NotFoundError: This Mac has no camera" : @"NotFoundError: This Mac has no microphone";
    if (_session && [_device.uniqueID isEqual:device.uniqueID]) return nil;
    if (_session && (!wanted.length || _streams.count)) return nil; // keep the running device for the other streams
    [self stopSession];

    AVCaptureSession *session = [AVCaptureSession new];
    [session beginConfiguration];
    if (_video) {
        double width = [options[@"width"] doubleValue];
        AVCaptureSessionPreset preset = width > 0 && width <= 640 ? AVCaptureSessionPreset640x480 : AVCaptureSessionPreset1280x720;
        if ([session canSetSessionPreset:preset]) session.sessionPreset = preset;
    }
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input || ![session canAddInput:input]) {
        WMLog(@"Web media: cannot open %@: %@", device.localizedName, error);
        return [NSString stringWithFormat:@"NotReadableError: %@", error.localizedDescription ?: @"The device is in use"];
    }
    [session addInput:input];
    if (_video) {
        AVCaptureVideoDataOutput *output = [AVCaptureVideoDataOutput new];
        output.alwaysDiscardsLateVideoFrames = YES;
        output.videoSettings = @{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
        [output setSampleBufferDelegate:self queue:_queue];
        if (![session canAddOutput:output]) return @"NotReadableError: The camera cannot deliver frames";
        [session addOutput:output];
    } else {
        AVCaptureAudioDataOutput *output = [AVCaptureAudioDataOutput new];
        [output setSampleBufferDelegate:self queue:_queue];
        if (![session canAddOutput:output]) return @"NotReadableError: The microphone cannot deliver audio";
        [session addOutput:output];
    }
    [session commitConfiguration];
    [session startRunning];
    _session = session;
    _device = device;
    _lastFrame = nil;
    [_audio removeAllObjects];

    _reaper = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_reaper, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    __weak WMCapture *weakSelf = self;
    dispatch_source_set_event_handler(_reaper, ^{ [weakSelf reap]; });
    dispatch_resume(_reaper);
    return nil;
}

- (void)reap {
    for (NSDictionary *waiter in _waiting) _streams[waiter[@"stream"]] = NSDate.date; // still listening
    for (NSNumber *stream in _streams.allKeys) {
        if (-[_streams[stream] timeIntervalSinceNow] > 3) [_streams removeObjectForKey:stream];
    }
    if (!_streams.count) [self stopSession];
}

- (void)stopSession {
    if (!_session) return;
    [_session stopRunning];
    WMLog(@"Web media: %@ stopped", _device.localizedName);
    _session = nil;
    _device = nil;
    _lastFrame = nil;
    [_audio removeAllObjects];
    if (_reaper) dispatch_source_cancel(_reaper);
    _reaper = nil;
    NSArray *waiting = [_waiting copy];
    [_waiting removeAllObjects];
    for (NSDictionary *waiter in waiting) WMOnMain(waiter[@"reply"], NSNull.null, nil);
}

- (void)stopStream:(NSNumber *)stream {
    dispatch_async(_queue, ^{
        [self->_streams removeObjectForKey:stream];
        if (!self->_streams.count) [self stopSession];
    });
}

/// Replies with what arrived after `after` (the newest frame, or all newer audio), or waits for it.
- (void)pollStream:(NSNumber *)stream after:(NSInteger)after reply:(WMReply)reply {
    dispatch_async(_queue, ^{
        if (!self->_streams[stream] || !self->_session) return WMOnMain(reply, nil, @"stream ended");
        self->_streams[stream] = NSDate.date;
        NSInteger since = after;
        if (!self->_video && since == 0) since = self->_sequence; // a new listener starts with the next chunk
        id result = [self resultAfter:since];
        if (result) WMOnMain(reply, result, nil);
        else [self->_waiting addObject:@{@"reply": [reply copy], @"after": @(since), @"stream": stream}];
    });
}

- (id)resultAfter:(NSInteger)after {
    if (_video) return _lastFrame && [_lastFrame[@"sequence"] integerValue] > after ? _lastFrame : nil;
    NSMutableData *pcm = [NSMutableData data];
    NSInteger last = after;
    for (NSDictionary *chunk in _audio) {
        if ([chunk[@"sequence"] integerValue] <= after) continue;
        [pcm appendData:chunk[@"pcm"]];
        last = [chunk[@"sequence"] integerValue];
    }
    if (last == after) return nil;
    return @{@"sequence": @(last), @"sampleRate": @(_sampleRate), @"pcm": [pcm base64EncodedStringWithOptions:0]};
}

- (void)answerWaiting {
    NSArray *waiting = [_waiting copy];
    [_waiting removeAllObjects];
    for (NSDictionary *waiter in waiting) {
        id result = [self resultAfter:[waiter[@"after"] integerValue]];
        if (result) WMOnMain(waiter[@"reply"], result, nil);
        else [_waiting addObject:waiter];
    }
}

- (void)addRecorder:(WMRecorder *)recorder { dispatch_async(_queue, ^{ [self->_recorders addObject:recorder]; }); }
- (void)removeRecorder:(WMRecorder *)recorder { dispatch_async(_queue, ^{ [self->_recorders removeObject:recorder]; }); }

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample
       fromConnection:(AVCaptureConnection *)connection {
    for (WMRecorder *recorder in _recorders.allObjects) [recorder captured:sample video:_video];
    if (_video) [self frameArrived:sample];
    else [self audioArrived:sample];
}

- (void)frameArrived:(CMSampleBufferRef)sample {
    if (!_waiting.count) return; // encode only for pages that are ready for a frame
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
    if (!pixels) return;
    CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    size_t width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixels), width, height, 8,
                                                CVPixelBufferGetBytesPerRow(pixels), space,
                                                kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef image = bitmap ? CGBitmapContextCreateImage(bitmap) : NULL;
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    if (bitmap) CGContextRelease(bitmap);
    CGColorSpaceRelease(space);
    if (!image) return;
    NSData *jpeg = UIImageJPEGRepresentation([UIImage imageWithCGImage:image], 0.8);
    CGImageRelease(image);
    if (!jpeg) return;
    _lastFrame = @{@"sequence": @(++_sequence), @"width": @(width), @"height": @(height),
                   @"jpeg": [jpeg base64EncodedStringWithOptions:0]};
    [self answerWaiting];
}

/// Mixes any linear PCM layout down to mono 16-bit.
static NSData *WMMonoPCM(CMSampleBufferRef sample, double *rate) {
    const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));
    if (!format || format->mFormatID != kAudioFormatLinearPCM || !format->mChannelsPerFrame) return nil;
    size_t size = 0;
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, &size, NULL, 0, NULL, NULL, 0, NULL);
    if (!size) return nil;
    AudioBufferList *list = malloc(size);
    CMBlockBufferRef block = NULL;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, NULL, list, size, NULL, NULL,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &block);
    if (status != noErr) {
        free(list);
        return nil;
    }
    CMItemCount frames = CMSampleBufferGetNumSamples(sample);
    UInt32 channels = format->mChannelsPerFrame, bits = format->mBitsPerChannel;
    BOOL isFloat = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL planar = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    if (planar && list->mNumberBuffers < channels) channels = list->mNumberBuffers;
    NSMutableData *pcm = [NSMutableData dataWithLength:frames * sizeof(int16_t)];
    int16_t *out = pcm.mutableBytes;
    for (CMItemCount i = 0; i < frames; i++) {
        double sum = 0;
        for (UInt32 c = 0; c < channels; c++) {
            const void *base = planar ? list->mBuffers[c].mData : list->mBuffers[0].mData;
            size_t index = planar ? i : i * format->mChannelsPerFrame + c;
            if (isFloat && bits == 32) sum += ((const float *)base)[index];
            else if (isFloat && bits == 64) sum += ((const double *)base)[index];
            else if (bits == 16) sum += ((const int16_t *)base)[index] / 32768.0;
            else if (bits == 32) sum += ((const int32_t *)base)[index] / 2147483648.0;
        }
        double value = fmax(-1, fmin(1, sum / channels));
        out[i] = (int16_t)lrint(value * 32767);
    }
    if (block) CFRelease(block);
    free(list);
    *rate = format->mSampleRate;
    return pcm;
}

- (void)audioArrived:(CMSampleBufferRef)sample {
    if (!_streams.count) return;
    double rate = 0;
    NSData *pcm = WMMonoPCM(sample, &rate);
    static BOOL logged;
    if (!logged) {
        logged = YES;
        const AudioStreamBasicDescription *f = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));
        if (f) WMLog(@"Web media: microphone delivers %.0f Hz, %u channels, %u bits, flags %#x%@", f->mSampleRate,
                     (unsigned)f->mChannelsPerFrame, (unsigned)f->mBitsPerChannel, (unsigned)f->mFormatFlags, pcm.length ? @"" : @" (unreadable)");
    }
    if (!pcm.length) return;
    _sampleRate = rate;
    [_audio addObject:@{@"sequence": @(++_sequence), @"pcm": pcm}];
    if (_audio.count > 100) [_audio removeObjectsInRange:NSMakeRange(0, _audio.count - 100)]; // ~2 s
    [self answerWaiting];
}

@end

#pragma mark - Recording

/// AVAssetWriter throws on samples it can't take (wrong format or state); skip them instead of crashing the app.
static void WMAppend(void (^append)(void)) {
    @try {
        append();
    } @catch (NSException *exception) {
        static BOOL logged;
        if (!logged) WMLog(@"Web media: a sample was rejected: %@", exception.reason);
        logged = YES;
    }
}

/// One MediaRecorder: an AVAssetWriter fed by the capture sessions and by samples the page pushes.
@implementation WMRecorder {
    dispatch_queue_t _queue;
    BOOL _video, _audio, _cameraVideo, _micAudio, _fragmented;
    CGSize _pageSize;
    double _videoBits, _audioBits;
    NSTimeInterval _segment;
    AVAssetWriter *_writer;
    AVAssetWriterInput *_videoInput, *_audioInput;
    AVAssetWriterInputPixelBufferAdaptor *_adaptor;
    NSURL *_file;
    NSMutableData *_output;   // fragmented: segments not yet read; otherwise the finished file
    BOOL _configured, _finished, _paused, _resuming;
    CMTime _offset, _last;
    NSString *_failure;
@public
    NSNumber *_id;
    NSDate *_activity;
}

- (instancetype)initWithOptions:(NSDictionary *)options {
    if (!(self = [super init])) return nil;
    _queue = dispatch_queue_create("app.harbor.webmedia.recorder", DISPATCH_QUEUE_SERIAL);
    NSDictionary *video = [options[@"video"] isKindOfClass:NSDictionary.class] ? options[@"video"] : nil;
    NSDictionary *audio = [options[@"audio"] isKindOfClass:NSDictionary.class] ? options[@"audio"] : nil;
    _video = video != nil;
    _audio = audio != nil;
    _cameraVideo = [video[@"camera"] boolValue];
    _micAudio = [audio[@"mic"] boolValue];
    _pageSize = CGSizeMake([video[@"width"] doubleValue], [video[@"height"] doubleValue]);
    _fragmented = [options[@"fragmented"] boolValue];
    _segment = MAX([options[@"timeslice"] doubleValue] / 1000.0, 1.0);
    _videoBits = [options[@"videoBitsPerSecond"] doubleValue];
    _audioBits = [options[@"audioBitsPerSecond"] doubleValue];
    _offset = kCMTimeZero;
    _last = kCMTimeInvalid;
    _output = [NSMutableData data];
    _activity = NSDate.date;
    return self;
}

- (NSString *)mimeType { return _video ? @"video/mp4" : @"audio/mp4"; }

- (void)start {
    if (_cameraVideo) [WMCapture.camera addRecorder:self];
    if (_micAudio) [WMCapture.microphone addRecorder:self];
    // Without a camera the format is known now; with one, it comes with the first frame.
    if (!_cameraVideo) dispatch_async(_queue, ^{ [self configureWithSize:self->_pageSize start:WMHostNow()]; });
}

/// On the recorder queue: creates the writer once the video size is known.
- (void)configureWithSize:(CGSize)size start:(CMTime)start {
    if (_configured || _finished) return;
    _configured = YES;
    @try {
        [self createWriterWithSize:size start:start];
    } @catch (NSException *exception) {
        _writer = nil;
        [self fail:exception.reason];
    }
}

- (void)createWriterWithSize:(CGSize)size start:(CMTime)start {
    NSError *error = nil;
    if (_fragmented) {
        UTType *type = [UTType typeWithIdentifier:AVFileTypeMPEG4]; // fragments are MP4 even for audio alone
        _writer = [[AVAssetWriter alloc] initWithContentType:type];
        _writer.outputFileTypeProfile = AVFileTypeProfileMPEG4AppleHLS;
        _writer.preferredOutputSegmentInterval = CMTimeMakeWithSeconds(_segment, 600);
        _writer.initialSegmentStartTime = start;
        _writer.delegate = (id<AVAssetWriterDelegate>)self;
    } else {
        NSString *name = [NSString stringWithFormat:@"harbor-recording-%@.%@", NSUUID.UUID.UUIDString, _video ? @"mp4" : @"m4a"];
        _file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
        _writer = [AVAssetWriter assetWriterWithURL:_file fileType:_video ? AVFileTypeMPEG4 : AVFileTypeAppleM4A error:&error];
    }
    if (!_writer) return [self fail:error.localizedDescription ?: @"The recorder could not be created"];
    _writer.shouldOptimizeForNetworkUse = YES;

    if (_video) {
        int width = (int)size.width & ~1, height = (int)size.height & ~1;
        if (width < 2 || height < 2) return [self fail:@"The video has no size"];
        NSMutableDictionary *settings = [@{AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @(width), AVVideoHeightKey: @(height)} mutableCopy];
        NSMutableDictionary *compression = [@{AVVideoMaxKeyFrameIntervalDurationKey: @(MIN(_segment, 2.0))} mutableCopy];
        if (_videoBits > 0) compression[AVVideoAverageBitRateKey] = @(_videoBits);
        settings[AVVideoCompressionPropertiesKey] = compression;
        _videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
        _videoInput.expectsMediaDataInRealTime = YES;
        if (!_cameraVideo) {
            _adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoInput
                sourcePixelBufferAttributes:@{(NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                                              (NSString *)kCVPixelBufferWidthKey: @(width), (NSString *)kCVPixelBufferHeightKey: @(height)}];
        }
        if (![_writer canAddInput:_videoInput]) return [self fail:@"The video cannot be recorded"];
        [_writer addInput:_videoInput];
    }
    if (_audio) {
        NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @48000, AVNumberOfChannelsKey: @1,
                                   AVEncoderBitRateKey: @(_audioBits > 0 ? _audioBits : 128000)};
        _audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:settings];
        _audioInput.expectsMediaDataInRealTime = YES;
        if (![_writer canAddInput:_audioInput]) return [self fail:@"The audio cannot be recorded"];
        [_writer addInput:_audioInput];
    }
    if (![_writer startWriting]) return [self fail:_writer.error.localizedDescription ?: @"The recorder could not start"];
    [_writer startSessionAtSourceTime:start];
    WMLog(@"Web media: recording %@%@%@", _video ? [NSString stringWithFormat:@"%dx%d video", (int)size.width, (int)size.height] : @"",
          _video && _audio ? @" and " : @"", _audio ? @"audio" : @"");
}

- (void)fail:(NSString *)message {
    WMLog(@"Web media: recording failed: %@", message);
    _failure = message;
    _finished = YES;
}

/// Shifts a time to close the gaps left by pauses. Returns NO while paused.
- (BOOL)retime:(CMTime *)time {
    if (_paused) return NO;
    if (_resuming && CMTIME_IS_VALID(_last)) {
        _offset = CMTimeAdd(_offset, CMTimeSubtract(*time, _last));
        _offset = CMTimeSubtract(_offset, CMTimeMake(1, 30));
    }
    _resuming = NO;
    _last = *time;
    *time = CMTimeSubtract(*time, _offset);
    return YES;
}

- (void)captured:(CMSampleBufferRef)sample video:(BOOL)video {
    CFRetain(sample);
    dispatch_async(_queue, ^{
        [self append:sample video:video];
        CFRelease(sample);
    });
}

- (void)append:(CMSampleBufferRef)sample video:(BOOL)video {
    _activity = NSDate.date;
    if (_finished || (video && !_cameraVideo) || (!video && !_micAudio)) return;
    CMTime time = CMSampleBufferGetPresentationTimeStamp(sample);
    if (!_configured) {
        if (!video) return; // audio waits for the first frame, which sets the size and start
        CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
        [self configureWithSize:CGSizeMake(CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels)) start:time];
        if (_finished) return;
    }
    if (_writer.status != AVAssetWriterStatusWriting || ![self retime:&time]) return;
    AVAssetWriterInput *input = video ? _videoInput : _audioInput;
    if (!input.readyForMoreMediaData) return;
    CMSampleBufferRef shifted = sample;
    if (CMTIME_COMPARE_INLINE(_offset, !=, kCMTimeZero)) {
        CMItemCount count = 0;
        CMSampleBufferGetSampleTimingInfoArray(sample, 0, NULL, &count);
        CMSampleTimingInfo *timing = malloc(sizeof(CMSampleTimingInfo) * MAX(count, 1));
        CMSampleBufferGetSampleTimingInfoArray(sample, count, timing, &count);
        for (CMItemCount i = 0; i < count; i++) {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, _offset);
            if (CMTIME_IS_VALID(timing[i].decodeTimeStamp)) timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, _offset);
        }
        if (CMSampleBufferCreateCopyWithNewTiming(NULL, sample, count, timing, &shifted) != noErr) shifted = NULL;
        free(timing);
        if (!shifted) return;
    }
    WMAppend(^{ [input appendSampleBuffer:shifted]; });
    if (shifted != sample) CFRelease(shifted);
}

/// A frame from the page (a JPEG of the canvas), stamped with the time it arrived.
- (void)pushVideo:(NSData *)jpeg {
    dispatch_async(_queue, ^{
        self->_activity = NSDate.date;
        if (self->_finished || !self->_adaptor || self->_writer.status != AVAssetWriterStatusWriting) return;
        CMTime time = WMHostNow();
        if (![self retime:&time] || !self->_videoInput.readyForMoreMediaData) return;
        CGImageRef image = [UIImage imageWithData:jpeg].CGImage;
        if (!image || !self->_adaptor.pixelBufferPool) return;
        CVPixelBufferRef pixels = NULL;
        if (CVPixelBufferPoolCreatePixelBuffer(NULL, self->_adaptor.pixelBufferPool, &pixels) != kCVReturnSuccess) return;
        CVPixelBufferLockBaseAddress(pixels, 0);
        size_t width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef bitmap = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixels), width, height, 8,
                                                    CVPixelBufferGetBytesPerRow(pixels), space,
                                                    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        if (bitmap) {
            CGContextDrawImage(bitmap, CGRectMake(0, 0, width, height), image);
            CGContextRelease(bitmap);
        }
        CGColorSpaceRelease(space);
        CVPixelBufferUnlockBaseAddress(pixels, 0);
        WMAppend(^{ [self->_adaptor appendPixelBuffer:pixels withPresentationTime:time]; });
        CVPixelBufferRelease(pixels);
    });
}

/// Audio from the page (mono Float32), ending at the time it arrived.
- (void)pushAudio:(NSData *)samples rate:(double)rate {
    dispatch_async(_queue, ^{
        self->_activity = NSDate.date;
        if (self->_finished || !self->_audioInput || self->_writer.status != AVAssetWriterStatusWriting || rate <= 0) return;
        CMItemCount frames = samples.length / sizeof(float);
        if (!frames) return;
        CMTime time = CMTimeSubtract(WMHostNow(), CMTimeMakeWithSeconds(frames / rate, (int32_t)rate));
        if (![self retime:&time] || !self->_audioInput.readyForMoreMediaData) return;
        AudioStreamBasicDescription format = {.mSampleRate = rate, .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, .mBytesPerPacket = 4, .mFramesPerPacket = 1,
            .mBytesPerFrame = 4, .mChannelsPerFrame = 1, .mBitsPerChannel = 32};
        CMAudioFormatDescriptionRef description = NULL;
        CMBlockBufferRef block = NULL;
        CMSampleBufferRef sample = NULL;
        if (CMAudioFormatDescriptionCreate(NULL, &format, 0, NULL, 0, NULL, NULL, &description) == noErr &&
            CMBlockBufferCreateWithMemoryBlock(NULL, NULL, samples.length, NULL, NULL, 0, samples.length,
                                               kCMBlockBufferAssureMemoryNowFlag, &block) == noErr &&
            CMBlockBufferReplaceDataBytes(samples.bytes, block, 0, samples.length) == noErr &&
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, block, description, frames, time, NULL, &sample) == noErr) {
            WMAppend(^{ [self->_audioInput appendSampleBuffer:sample]; });
        }
        if (sample) CFRelease(sample);
        if (block) CFRelease(block);
        if (description) CFRelease(description);
    });
}

- (void)pause { dispatch_async(_queue, ^{ self->_paused = YES; self->_activity = NSDate.date; }); }
- (void)resume { dispatch_async(_queue, ^{ self->_paused = NO; self->_resuming = YES; self->_activity = NSDate.date; }); }
- (void)ping { dispatch_async(_queue, ^{ self->_activity = NSDate.date; }); }

- (void)assetWriter:(AVAssetWriter *)writer didOutputSegmentData:(NSData *)data segmentType:(AVAssetSegmentType)type
      segmentReport:(AVAssetSegmentReport *)report {
    dispatch_async(_queue, ^{ [self->_output appendData:data]; });
}

/// Fragmented recordings: the segments written since the last call.
- (void)takeData:(WMReply)reply {
    dispatch_async(_queue, ^{
        self->_activity = NSDate.date;
        NSData *data = [self->_output copy];
        [self->_output setLength:0];
        WMOnMain(reply, @{@"data": [data base64EncodedStringWithOptions:0]}, nil);
    });
}

- (void)detach {
    if (_cameraVideo) [WMCapture.camera removeRecorder:self];
    if (_micAudio) [WMCapture.microphone removeRecorder:self];
}

/// Finishes the file; replies with the size of what is left to read.
- (void)stop:(WMReply)reply {
    [self detach];
    dispatch_async(_queue, ^{
        self->_activity = NSDate.date;
        if (self->_failure && !self->_writer) return WMOnMain(reply, nil, [@"UnknownError: " stringByAppendingString:self->_failure]);
        BOOL wasFinished = self->_finished;
        self->_finished = YES;
        if (wasFinished || !self->_writer || self->_writer.status != AVAssetWriterStatusWriting) {
            if (self->_writer.status == AVAssetWriterStatusWriting) [self->_writer cancelWriting];
            return WMOnMain(reply, @{@"size": @(self->_output.length)}, nil);
        }
        [self->_videoInput markAsFinished];
        [self->_audioInput markAsFinished];
        [self->_writer finishWritingWithCompletionHandler:^{
            dispatch_async(self->_queue, ^{
                if (self->_writer.status == AVAssetWriterStatusFailed) WMLog(@"Web media: recording failed: %@", self->_writer.error);
                if (self->_file) {
                    NSData *data = [NSData dataWithContentsOfURL:self->_file];
                    if (data) [self->_output appendData:data];
                    [NSFileManager.defaultManager removeItemAtURL:self->_file error:nil];
                }
                WMLog(@"Web media: recording finished, %lu bytes", (unsigned long)self->_output.length);
                WMOnMain(reply, @{@"size": @(self->_output.length)}, nil);
            });
        }];
    });
}

- (void)read:(NSUInteger)offset length:(NSUInteger)length reply:(WMReply)reply {
    dispatch_async(_queue, ^{
        self->_activity = NSDate.date;
        NSUInteger start = MIN(offset, self->_output.length), end = MIN(start + length, self->_output.length);
        WMOnMain(reply, [[self->_output subdataWithRange:NSMakeRange(start, end - start)] base64EncodedStringWithOptions:0], nil);
    });
}

- (void)discard {
    [self detach];
    dispatch_async(_queue, ^{
        if (!self->_finished && self->_writer.status == AVAssetWriterStatusWriting) [self->_writer cancelWriting];
        self->_finished = YES;
        if (self->_file) [NSFileManager.defaultManager removeItemAtURL:self->_file error:nil];
        self->_output = [NSMutableData data];
    });
}

@end

#pragma mark - Message handler

@interface WMHandler : NSObject <WKScriptMessageHandlerWithReply>
@end

static NSMutableDictionary<NSNumber *, WMRecorder *> *gRecorders;
static NSMutableDictionary<NSNumber *, WMCapture *> *gStreams; // page stream id -> its device
static NSInteger gNextRecorderID;
static NSMutableArray<WMReply> *gDeviceWatchers;

static NSString *WMPermission(AVMediaType type) {
    switch ([AVCaptureDevice authorizationStatusForMediaType:type]) {
    case AVAuthorizationStatusAuthorized: return @"granted";
    case AVAuthorizationStatusNotDetermined: return @"prompt";
    default: return @"denied";
    }
}

static void WMDevicesChanged(void) {
    NSArray *watchers = [gDeviceWatchers copy];
    [gDeviceWatchers removeAllObjects];
    for (WMReply reply in watchers) reply(@YES, nil);
}

/// Recorders whose page went away (no pushes, pings or samples for 30 s) are discarded.
static void WMStartRecorderReaper(void) {
    static dispatch_source_t timer;
    if (timer) return;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        for (NSNumber *key in gRecorders.allKeys) {
            WMRecorder *recorder = gRecorders[key];
            if (-[recorder->_activity timeIntervalSinceNow] < 30) continue;
            [recorder discard];
            [gRecorders removeObjectForKey:key];
            WMLog(@"Web media: discarded abandoned recording %@", key);
        }
        // Device watchers get a periodic "no change" so no reply waits forever.
        NSArray *watchers = [gDeviceWatchers copy];
        [gDeviceWatchers removeAllObjects];
        for (WMReply reply in watchers) reply(@NO, nil);
    });
    dispatch_resume(timer);
}

@implementation WMHandler

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message
                 replyHandler:(WMReply)reply {
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : @{};
    NSString *op = body[@"op"];
    NSNumber *ident = [body[@"id"] isKindOfClass:NSNumber.class] ? body[@"id"] : @0;
    WMRecorder *recorder = gRecorders[ident];

    if ([op isEqual:@"start"]) {
        WMCapture *capture = [body[@"kind"] isEqual:@"audio"] ? WMCapture.microphone : WMCapture.camera;
        [capture startWithOptions:body reply:^(id result, NSString *error) {
            if (result) gStreams[result[@"id"]] = capture;
            reply(result, error);
        }];
    } else if ([op isEqual:@"poll"]) {
        WMCapture *capture = gStreams[ident];
        if (!capture) return reply(nil, @"stream ended");
        [capture pollStream:ident after:[body[@"after"] integerValue] reply:^(id result, NSString *error) {
            if (error) [gStreams removeObjectForKey:ident];
            reply(result, error);
        }];
    } else if ([op isEqual:@"stop"]) {
        [gStreams[ident] stopStream:ident];
        [gStreams removeObjectForKey:ident];
        reply(NSNull.null, nil);
    } else if ([op isEqual:@"devices"]) {
        NSMutableArray *list = [NSMutableArray array];
        for (AVMediaType type in @[AVMediaTypeVideo, AVMediaTypeAudio]) {
            BOOL labels = [WMPermission(type) isEqual:@"granted"];
            for (AVCaptureDevice *device in [WMCapture devicesFor:type]) {
                [list addObject:@{@"deviceId": device.uniqueID, @"groupId": @"", @"label": labels ? device.localizedName : @"",
                                  @"kind": type == AVMediaTypeVideo ? @"videoinput" : @"audioinput"}];
            }
        }
        [list addObject:@{@"deviceId": @"default", @"groupId": @"", @"kind": @"audiooutput",
                          @"label": [WMPermission(AVMediaTypeAudio) isEqual:@"granted"] ? @"Default" : @""}];
        reply(list, nil);
    } else if ([op isEqual:@"permission"]) {
        reply(WMPermission([body[@"name"] isEqual:@"microphone"] ? AVMediaTypeAudio : AVMediaTypeVideo), nil);
    } else if ([op isEqual:@"watchDevices"]) {
        [gDeviceWatchers addObject:[reply copy]];
    } else if ([op isEqual:@"recordStart"]) {
        WMRecorder *created = [[WMRecorder alloc] initWithOptions:body];
        created->_id = @(++gNextRecorderID);
        gRecorders[created->_id] = created;
        [created start];
        reply(@{@"id": created->_id, @"mimeType": created.mimeType}, nil);
    } else if (!recorder && [op hasPrefix:@"record"]) {
        reply(nil, @"InvalidStateError: The recording is gone");
    } else if ([op isEqual:@"recordPush"]) {
        if ([body[@"video"] isKindOfClass:NSString.class]) {
            NSData *jpeg = [[NSData alloc] initWithBase64EncodedString:body[@"video"] options:0];
            if (jpeg) [recorder pushVideo:jpeg];
        }
        if ([body[@"audio"] isKindOfClass:NSString.class]) {
            NSData *samples = [[NSData alloc] initWithBase64EncodedString:body[@"audio"] options:0];
            if (samples) [recorder pushAudio:samples rate:[body[@"sampleRate"] doubleValue]];
        }
        reply(NSNull.null, nil);
    } else if ([op isEqual:@"recordPause"]) {
        [recorder pause];
        reply(NSNull.null, nil);
    } else if ([op isEqual:@"recordResume"]) {
        [recorder resume];
        reply(NSNull.null, nil);
    } else if ([op isEqual:@"recordPing"]) {
        [recorder ping];
        reply(NSNull.null, nil);
    } else if ([op isEqual:@"recordData"]) {
        [recorder takeData:reply];
    } else if ([op isEqual:@"recordStop"]) {
        [recorder stop:reply];
    } else if ([op isEqual:@"recordRead"]) {
        [recorder read:[body[@"offset"] unsignedIntegerValue] length:[body[@"length"] unsignedIntegerValue] reply:reply];
    } else if ([op isEqual:@"recordRelease"]) {
        [recorder discard];
        [gRecorders removeObjectForKey:ident];
        reply(NSNull.null, nil);
    } else if ([op isEqual:@"log"]) {
        WMLog(@"Web media page: %@", body[@"message"]);
        reply(NSNull.null, nil);
    } else {
        reply(nil, @"NotSupportedError: unknown request");
    }
}

@end

#pragma mark - Entry point

/// Called by the core runtime for each content controller of the app's own web views.
__attribute__((visibility("default"))) void HBWebMediaAttach(WKUserContentController *controller) {
    static char key;
    if (!controller || objc_getAssociatedObject(controller, &key)) return;
    objc_setAssociatedObject(controller, &key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gRecorders = [NSMutableDictionary dictionary];
        gStreams = [NSMutableDictionary dictionary];
        gDeviceWatchers = [NSMutableArray array];
        for (NSNotificationName name in @[AVCaptureDeviceWasConnectedNotification, AVCaptureDeviceWasDisconnectedNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *note) { WMDevicesChanged(); }];
        }
        WMStartRecorderReaper();
    });
    @try {
        WKUserScript *script = [[WKUserScript alloc] initWithSource:HBWebMediaScript
                                                      injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                   forMainFrameOnly:NO];
        [controller addUserScript:script];
        [controller addScriptMessageHandlerWithReply:[WMHandler new] contentWorld:WKContentWorld.pageWorld name:@"harborMedia"];
    } @catch (NSException *exception) {
        WMLog(@"Web media: not added to a web view: %@", exception.reason);
    }
}
