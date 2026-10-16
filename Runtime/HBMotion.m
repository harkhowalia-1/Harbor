// Motion sensors. Macs have no accelerometer or gyroscope, so CMMotionManager is answered by a
// virtual device whose tilt is driven by the keyboard, a controller stick or the pointer.
#import "HBRuntime.h"
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>

static const double kMaxTilt = 0.7; // radians, about 40°
static double gTargetX, gTargetY, gTiltX, gTiltY;
static double gLastPitch, gLastRoll, gLastSampleTime;
static CMRotationRate gRate;
static BOOL gLandscape;

void HBMotionSetTarget(double x, double y) {
    gTargetX = fmax(-1, fmin(1, x));
    gTargetY = fmax(-1, fmin(1, y));
}

/// Eases the virtual device toward its target tilt; called at 60 Hz by the input loop.
void HBMotionStep(double dt) {
    double k = 1 - exp(-dt * 10);
    gTiltX += (gTargetX - gTiltX) * k;
    gTiltY += (gTargetY - gTiltY) * k;
}

/// Gravity in device axes (units of g). Screen-space tilt is rotated into device axes for
/// landscape apps, where the device's top edge points to the left of the screen.
static CMAcceleration HBGravity(void) {
    double gx = sin(gTiltX * kMaxTilt), gy = sin(gTiltY * kMaxTilt);
    double ax = gLandscape ? gy : gx;
    double ay = gLandscape ? -gx : gy;
    double az = -sqrt(fmax(0, 1 - ax * ax - ay * ay));
    return (CMAcceleration){ax, ay, az};
}

static void HBCurrentAttitude(double *pitch, double *roll) {
    CMAcceleration g = HBGravity();
    *pitch = asin(fmax(-1, fmin(1, -g.y)));
    *roll = atan2(g.x, -g.z);
}

static CMRotationRate HBSampleRate(void) {
    double now = NSProcessInfo.processInfo.systemUptime;
    double pitch, roll;
    HBCurrentAttitude(&pitch, &roll);
    double dt = now - gLastSampleTime;
    if (gLastSampleTime > 0 && dt > 0.001) {
        gRate = (CMRotationRate){(pitch - gLastPitch) / dt, (roll - gLastRoll) / dt, 0};
        gLastPitch = pitch;
        gLastRoll = roll;
        gLastSampleTime = now;
    } else if (gLastSampleTime == 0) {
        gLastPitch = pitch;
        gLastRoll = roll;
        gLastSampleTime = now;
    }
    return gRate;
}

#pragma mark - Sample objects

@interface HBAccelerometerData : CMAccelerometerData
@property (nonatomic) CMAcceleration hbValue;
@property (nonatomic) NSTimeInterval hbTime;
@end
@implementation HBAccelerometerData
- (CMAcceleration)acceleration { return _hbValue; }
- (NSTimeInterval)timestamp { return _hbTime; }
@end

@interface HBGyroData : CMGyroData
@property (nonatomic) CMRotationRate hbValue;
@property (nonatomic) NSTimeInterval hbTime;
@end
@implementation HBGyroData
- (CMRotationRate)rotationRate { return _hbValue; }
- (NSTimeInterval)timestamp { return _hbTime; }
@end

@interface HBAttitude : CMAttitude
@property (nonatomic) double hbPitch, hbRoll;
@end
@implementation HBAttitude
- (double)pitch { return _hbPitch; }
- (double)roll { return _hbRoll; }
- (double)yaw { return 0; }
- (CMQuaternion)quaternion {
    // Core Motion composes yaw (Z), then pitch (X), then roll (Y); yaw is 0 here.
    double cp = cos(_hbPitch / 2), sp = sin(_hbPitch / 2), cr = cos(_hbRoll / 2), sr = sin(_hbRoll / 2);
    return (CMQuaternion){sp * cr, cp * sr, sp * sr, cp * cr};
}
- (CMRotationMatrix)rotationMatrix {
    CMQuaternion q = self.quaternion;
    double x = q.x, y = q.y, z = q.z, w = q.w;
    return (CMRotationMatrix){
        1 - 2 * (y * y + z * z), 2 * (x * y + w * z),     2 * (x * z - w * y),
        2 * (x * y - w * z),     1 - 2 * (x * x + z * z), 2 * (y * z + w * x),
        2 * (x * z + w * y),     2 * (y * z - w * x),     1 - 2 * (x * x + y * y)};
}
- (void)multiplyByInverseOfAttitude:(CMAttitude *)attitude {
    _hbPitch -= attitude.pitch;
    _hbRoll -= attitude.roll;
}
- (id)copyWithZone:(NSZone *)zone {
    HBAttitude *copy = [[HBAttitude alloc] init];
    copy.hbPitch = _hbPitch;
    copy.hbRoll = _hbRoll;
    return copy;
}
@end

@interface HBDeviceMotion : CMDeviceMotion
@property (nonatomic, strong) HBAttitude *hbAttitude;
@property (nonatomic) CMAcceleration hbGravity;
@property (nonatomic) CMRotationRate hbRate;
@property (nonatomic) NSTimeInterval hbTime;
@end
@implementation HBDeviceMotion
- (CMAttitude *)attitude { return _hbAttitude; }
- (CMAcceleration)gravity { return _hbGravity; }
- (CMAcceleration)userAcceleration { return (CMAcceleration){0, 0, 0}; }
- (CMRotationRate)rotationRate { return _hbRate; }
- (CMCalibratedMagneticField)magneticField {
    return (CMCalibratedMagneticField){{0, 0, 0}, CMMagneticFieldCalibrationAccuracyUncalibrated};
}
- (double)heading { return -1; }
- (NSTimeInterval)timestamp { return _hbTime; }
@end

static CMAccelerometerData *HBMakeAccelerometerData(void) {
    HBAccelerometerData *data = [[HBAccelerometerData alloc] init];
    data.hbValue = HBGravity();
    data.hbTime = NSProcessInfo.processInfo.systemUptime;
    return data;
}

static CMGyroData *HBMakeGyroData(void) {
    HBGyroData *data = [[HBGyroData alloc] init];
    data.hbValue = HBSampleRate();
    data.hbTime = NSProcessInfo.processInfo.systemUptime;
    return data;
}

static CMDeviceMotion *HBMakeDeviceMotion(void) {
    HBDeviceMotion *motion = [[HBDeviceMotion alloc] init];
    HBAttitude *attitude = [[HBAttitude alloc] init];
    double pitch, roll;
    HBCurrentAttitude(&pitch, &roll);
    attitude.hbPitch = pitch;
    attitude.hbRoll = roll;
    motion.hbAttitude = attitude;
    motion.hbGravity = HBGravity();
    motion.hbRate = HBSampleRate();
    motion.hbTime = NSProcessInfo.processInfo.systemUptime;
    return motion;
}

#pragma mark - Streams

@interface HBStream : NSObject
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic) BOOL active;
@end
@implementation HBStream
- (void)stop {
    if (_timer) dispatch_source_cancel(_timer);
    _timer = nil;
    _active = NO;
}
- (void)dealloc { [self stop]; }
@end

typedef NS_ENUM(NSInteger, HBStreamKind) { HBStreamAccelerometer, HBStreamGyro, HBStreamDeviceMotion };
static char kStreamKeys[3];

static HBStream *HBStreamFor(id manager, HBStreamKind kind) {
    HBStream *stream = objc_getAssociatedObject(manager, &kStreamKeys[kind]);
    if (!stream) {
        stream = [HBStream new];
        objc_setAssociatedObject(manager, &kStreamKeys[kind], stream, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return stream;
}

static void HBStart(CMMotionManager *manager, HBStreamKind kind, NSOperationQueue *queue, id handler) {
    HBStream *stream = HBStreamFor(manager, kind);
    [stream stop];
    stream.active = YES;
    if (!handler) return; // pull mode: the app reads the latest sample itself
    NSOperationQueue *target = queue ?: NSOperationQueue.mainQueue;
    NSTimeInterval interval = kind == HBStreamAccelerometer ? manager.accelerometerUpdateInterval
                            : kind == HBStreamGyro          ? manager.gyroUpdateInterval
                                                            : manager.deviceMotionUpdateInterval;
    interval = fmax(interval, 1.0 / 100);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                              (uint64_t)(interval * NSEC_PER_SEC), (uint64_t)(interval * NSEC_PER_SEC / 10));
    dispatch_source_set_event_handler(timer, ^{
        id sample = kind == HBStreamAccelerometer ? HBMakeAccelerometerData()
                  : kind == HBStreamGyro          ? HBMakeGyroData()
                                                  : HBMakeDeviceMotion();
        [target addOperationWithBlock:^{ ((void (^)(id, NSError *))handler)(sample, nil); }];
    });
    stream.timer = timer;
    dispatch_resume(timer);
}

static void HBStop(id manager, HBStreamKind kind) { [HBStreamFor(manager, kind) stop]; }

#pragma mark - CMMotionManager hooks

static BOOL hb_yes(id self, SEL _cmd) { return YES; }
static BOOL hb_accelActive(id self, SEL _cmd) { return HBStreamFor(self, HBStreamAccelerometer).active; }
static BOOL hb_gyroActive(id self, SEL _cmd) { return HBStreamFor(self, HBStreamGyro).active; }
static BOOL hb_motionActive(id self, SEL _cmd) { return HBStreamFor(self, HBStreamDeviceMotion).active; }

static id hb_accelData(id self, SEL _cmd) {
    return HBStreamFor(self, HBStreamAccelerometer).active ? HBMakeAccelerometerData() : nil;
}
static id hb_gyroData(id self, SEL _cmd) { return HBStreamFor(self, HBStreamGyro).active ? HBMakeGyroData() : nil; }
static id hb_deviceMotion(id self, SEL _cmd) {
    return HBStreamFor(self, HBStreamDeviceMotion).active ? HBMakeDeviceMotion() : nil;
}

static void hb_startAccel(id self, SEL _cmd) { HBStart(self, HBStreamAccelerometer, nil, nil); }
static void hb_startAccelQ(id self, SEL _cmd, NSOperationQueue *q, id h) { HBStart(self, HBStreamAccelerometer, q, h); }
static void hb_stopAccel(id self, SEL _cmd) { HBStop(self, HBStreamAccelerometer); }
static void hb_startGyro(id self, SEL _cmd) { HBStart(self, HBStreamGyro, nil, nil); }
static void hb_startGyroQ(id self, SEL _cmd, NSOperationQueue *q, id h) { HBStart(self, HBStreamGyro, q, h); }
static void hb_stopGyro(id self, SEL _cmd) { HBStop(self, HBStreamGyro); }
static void hb_startMotion(id self, SEL _cmd) { HBStart(self, HBStreamDeviceMotion, nil, nil); }
static void hb_startMotionQ(id self, SEL _cmd, NSOperationQueue *q, id h) { HBStart(self, HBStreamDeviceMotion, q, h); }
static void hb_startMotionFrame(id self, SEL _cmd, CMAttitudeReferenceFrame f) { HBStart(self, HBStreamDeviceMotion, nil, nil); }
static void hb_startMotionFrameQ(id self, SEL _cmd, CMAttitudeReferenceFrame f, NSOperationQueue *q, id h) {
    HBStart(self, HBStreamDeviceMotion, q, h);
}
static void hb_stopMotion(id self, SEL _cmd) { HBStop(self, HBStreamDeviceMotion); }
static CMAttitudeReferenceFrame hb_frames(id self, SEL _cmd) {
    return CMAttitudeReferenceFrameXArbitraryZVertical | CMAttitudeReferenceFrameXArbitraryCorrectedZVertical;
}

void HBInstallMotionHooks(void) {
    HBConfig *config = HBConfig.shared;
    gLandscape = config.landscape;
    if ([config.motion isEqual:@"off"]) return;
    Class m = CMMotionManager.class;
    HBSwizzle(object_getClass(m), @selector(availableAttitudeReferenceFrames), (IMP)hb_frames);
    HBSwizzle(m, @selector(isAccelerometerAvailable), (IMP)hb_yes);
    HBSwizzle(m, @selector(isGyroAvailable), (IMP)hb_yes);
    HBSwizzle(m, @selector(isDeviceMotionAvailable), (IMP)hb_yes);
    HBSwizzle(m, @selector(isAccelerometerActive), (IMP)hb_accelActive);
    HBSwizzle(m, @selector(isGyroActive), (IMP)hb_gyroActive);
    HBSwizzle(m, @selector(isDeviceMotionActive), (IMP)hb_motionActive);
    HBSwizzle(m, @selector(accelerometerData), (IMP)hb_accelData);
    HBSwizzle(m, @selector(gyroData), (IMP)hb_gyroData);
    HBSwizzle(m, @selector(deviceMotion), (IMP)hb_deviceMotion);
    HBSwizzle(m, @selector(startAccelerometerUpdates), (IMP)hb_startAccel);
    HBSwizzle(m, @selector(startAccelerometerUpdatesToQueue:withHandler:), (IMP)hb_startAccelQ);
    HBSwizzle(m, @selector(stopAccelerometerUpdates), (IMP)hb_stopAccel);
    HBSwizzle(m, @selector(startGyroUpdates), (IMP)hb_startGyro);
    HBSwizzle(m, @selector(startGyroUpdatesToQueue:withHandler:), (IMP)hb_startGyroQ);
    HBSwizzle(m, @selector(stopGyroUpdates), (IMP)hb_stopGyro);
    HBSwizzle(m, @selector(startDeviceMotionUpdates), (IMP)hb_startMotion);
    HBSwizzle(m, @selector(startDeviceMotionUpdatesToQueue:withHandler:), (IMP)hb_startMotionQ);
    HBSwizzle(m, @selector(startDeviceMotionUpdatesUsingReferenceFrame:), (IMP)hb_startMotionFrame);
    HBSwizzle(m, @selector(startDeviceMotionUpdatesUsingReferenceFrame:toQueue:withHandler:), (IMP)hb_startMotionFrameQ);
    HBSwizzle(m, @selector(stopDeviceMotionUpdates), (IMP)hb_stopMotion);
}
