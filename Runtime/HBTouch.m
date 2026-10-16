// Synthetic multi-touch. Builds UITouch objects plus the IOHIDEvent UIKit expects behind them
// and delivers them through -[UIApplication sendEvent:], exactly where real touches arrive.
// This relies on private UIKit/IOKit API, so every call is checked before it is made.
#import "HBRuntime.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef IOHIDEventRef (*HBCreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t,
                                                uint32_t, double, double, double, double, double, Boolean, Boolean,
                                                uint32_t);
typedef IOHIDEventRef (*HBCreateFingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double,
                                             double, double, double, double, double, double, double, double, Boolean,
                                             Boolean, uint32_t);
typedef void (*HBAppendEvent)(IOHIDEventRef, IOHIDEventRef, uint32_t);
typedef void (*HBSetIntegerValue)(IOHIDEventRef, uint32_t, long);

enum {
    kHBTransducerHand = 3,
    kHBDigitizerRange = 1 << 0,
    kHBDigitizerTouch = 1 << 1,
    kHBDigitizerPosition = 1 << 2,
    kHBFieldDisplayIntegrated = (11 << 16) | 25, // kIOHIDEventFieldDigitizerIsDisplayIntegrated
    kHBMaxFingers = 10,
};

static HBCreateDigitizerEvent sCreateHand;
static HBCreateFingerEvent sCreateFinger;
static HBAppendEvent sAppend;
static HBSetIntegerValue sSetInteger;

#pragma mark - Checked private calls

static BOOL HBResponds(id target, NSString *name) {
    BOOL ok = [target respondsToSelector:NSSelectorFromString(name)];
    if (!ok) {
        static NSMutableSet *reported;
        if (!reported) reported = [NSMutableSet set];
        if (![reported containsObject:name]) {
            [reported addObject:name];
            HBLog(@"Touch synthesis: %@ does not respond to %@", [target class], name);
        }
    }
    return ok;
}

static void HBCall(id target, NSString *name) {
    if (HBResponds(target, name)) ((void (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(name));
}

static void HBCallObject(id target, NSString *name, id value) {
    if (HBResponds(target, name)) ((void (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(name), value);
}

static void HBCallInteger(id target, NSString *name, NSInteger value) {
    if (HBResponds(target, name)) ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, NSSelectorFromString(name), value);
}

static void HBCallBool(id target, NSString *name, BOOL value) {
    if (HBResponds(target, name)) ((void (*)(id, SEL, BOOL))objc_msgSend)(target, NSSelectorFromString(name), value);
}

static void HBCallDouble(id target, NSString *name, double value) {
    if (HBResponds(target, name)) ((void (*)(id, SEL, double))objc_msgSend)(target, NSSelectorFromString(name), value);
}

static void HBCallPointer(id target, NSString *name, void *value) {
    if (HBResponds(target, name)) ((void (*)(id, SEL, void *))objc_msgSend)(target, NSSelectorFromString(name), value);
}

static void HBSetLocation(UITouch *touch, CGPoint point, BOOL reset) {
    NSString *name = @"_setLocationInWindow:resetPrevious:";
    if (HBResponds(touch, name)) {
        ((void (*)(id, SEL, CGPoint, BOOL))objc_msgSend)(touch, NSSelectorFromString(name), point, reset);
    }
}

#pragma mark - HID events

static IOHIDEventRef HBCreateHIDEvent(NSArray<UITouch *> *touches) {
    if (!sCreateHand || !sCreateFinger || !sAppend) return NULL;
    uint64_t now = mach_absolute_time();
    IOHIDEventRef hand = sCreateHand(kCFAllocatorDefault, now, kHBTransducerHand, 0, 0,
                                     kHBDigitizerTouch, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    if (sSetInteger) sSetInteger(hand, kHBFieldDisplayIntegrated, 1);
    NSUInteger index = 0;
    for (UITouch *touch in touches) {
        index++;
        UITouchPhase phase = touch.phase;
        uint32_t mask = phase == UITouchPhaseMoved ? kHBDigitizerPosition : (kHBDigitizerRange | kHBDigitizerTouch);
        Boolean touching = phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled;
        CGPoint p = [touch locationInView:touch.window];
        IOHIDEventRef finger = sCreateFinger(kCFAllocatorDefault, now, (uint32_t)index, 2, mask, p.x, p.y, 0,
                                             0, 0, 5, 5, 1, 1, 1, touching, touching, 0);
        if (sSetInteger) sSetInteger(finger, kHBFieldDisplayIntegrated, 1);
        sAppend(hand, finger, 0);
        CFRelease(finger);
    }
    return hand;
}

#pragma mark - Injector

@interface HBFinger : NSObject
@property (nonatomic) NSInteger identifier;
@property (nonatomic, strong) UITouch *touch;
@end
@implementation HBFinger
@end

@implementation HBTouchInjector {
    NSMutableArray<HBFinger *> *_fingers;
    NSInteger _nextIdentifier;
}

+ (HBTouchInjector *)shared {
    static HBTouchInjector *injector;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        sCreateHand = (HBCreateDigitizerEvent)dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
        sCreateFinger = (HBCreateFingerEvent)dlsym(iokit, "IOHIDEventCreateDigitizerFingerEventWithQuality");
        sAppend = (HBAppendEvent)dlsym(iokit, "IOHIDEventAppendEvent");
        sSetInteger = (HBSetIntegerValue)dlsym(iokit, "IOHIDEventSetIntegerValue");
        if (!sCreateHand || !sCreateFinger || !sAppend) HBLog(@"Touch synthesis: IOHIDEvent functions unavailable");
        injector = [[HBTouchInjector alloc] init];
    });
    return injector;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _fingers = [NSMutableArray array];
    return self;
}

- (HBFinger *)fingerWithIdentifier:(NSInteger)identifier {
    for (HBFinger *finger in _fingers) {
        if (finger.identifier == identifier) return finger;
    }
    return nil;
}

- (NSInteger)beginAt:(CGPoint)point {
    UIWindow *window = HBAppWindow();
    if (!window || _fingers.count >= kHBMaxFingers) return -1;
    UIView *view = [window hitTest:point withEvent:nil] ?: window;

    UITouch *touch = [[UITouch alloc] init];
    HBCallObject(touch, @"setWindow:", window); // must come first: it resets other fields
    HBSetLocation(touch, point, YES);
    HBCallObject(touch, @"setView:", view);
    HBCallInteger(touch, @"setPhase:", UITouchPhaseBegan);
    HBCallBool(touch, @"_setIsFirstTouchForView:", YES);
    HBCallBool(touch, @"setIsTap:", NO);
    HBCallInteger(touch, @"setTapCount:", 1);
    HBCallDouble(touch, @"setTimestamp:", NSProcessInfo.processInfo.systemUptime);
    if ([touch respondsToSelector:NSSelectorFromString(@"setGestureView:")]) HBCallObject(touch, @"setGestureView:", view);
    IOHIDEventRef hid = HBCreateHIDEvent(@[touch]);
    if (hid) {
        HBCallPointer(touch, @"_setHidEvent:", hid);
        CFRelease(hid);
    }

    HBFinger *finger = [HBFinger new];
    finger.identifier = ++_nextIdentifier;
    finger.touch = touch;
    [_fingers addObject:finger];
    [self deliver];
    return finger.identifier;
}

- (void)moveFinger:(NSInteger)identifier to:(CGPoint)point {
    HBFinger *finger = [self fingerWithIdentifier:identifier];
    if (!finger) return;
    HBSetLocation(finger.touch, point, NO);
    HBCallInteger(finger.touch, @"setPhase:", UITouchPhaseMoved);
    HBCallDouble(finger.touch, @"setTimestamp:", NSProcessInfo.processInfo.systemUptime);
    [self deliver];
}

- (void)endFinger:(NSInteger)identifier {
    HBFinger *finger = [self fingerWithIdentifier:identifier];
    if (!finger) return;
    HBCallInteger(finger.touch, @"setPhase:", UITouchPhaseEnded);
    HBCallDouble(finger.touch, @"setTimestamp:", NSProcessInfo.processInfo.systemUptime);
    [self deliver];
}

- (void)endAll {
    for (HBFinger *finger in [_fingers copy]) [self endFinger:finger.identifier];
}

/// Sends one event carrying every live finger, then settles their phases for the next event.
- (void)deliver {
    UIApplication *app = UIApplication.sharedApplication;
    if (!HBResponds(app, @"_touchesEvent")) return;
    UIEvent *event = ((UIEvent * (*)(id, SEL)) objc_msgSend)(app, NSSelectorFromString(@"_touchesEvent"));
    if (!event) return;
    NSArray<UITouch *> *touches = [_fingers valueForKey:@"touch"];
    HBCall(event, @"_clearTouches");
    IOHIDEventRef hid = HBCreateHIDEvent(touches);
    if (hid) {
        HBCallPointer(event, @"_setHIDEvent:", hid);
        CFRelease(hid);
    }
    NSString *add = @"_addTouch:forDelayedDelivery:";
    if (HBResponds(event, add)) {
        for (UITouch *touch in touches) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(event, NSSelectorFromString(add), touch, NO);
        }
    }
    [app sendEvent:event];

    for (HBFinger *finger in [_fingers copy]) {
        UITouchPhase phase = finger.touch.phase;
        if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
            [_fingers removeObject:finger];
        } else {
            HBCallInteger(finger.touch, @"setPhase:", UITouchPhaseStationary);
        }
    }
}

@end
