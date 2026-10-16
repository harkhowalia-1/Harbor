// Input routing: keyboard (via the AppKit bridge), game controllers (polled) and the pointer
// drive the keymap (synthetic touches) and the virtual motion sensors.
#import "HBRuntime.h"
#import <GameController/GameController.h>
#import <dlfcn.h>
#import <objc/message.h>

// NSEventModifierFlags values (AppKit is not linked into the Catalyst side).
enum { kHBShift = 1 << 17, kHBControl = 1 << 18, kHBOption = 1 << 19, kHBCommand = 1 << 20 };
// Mac virtual key codes used directly here.
enum { kHBKeyH = 4, kHBKeyK = 40, kHBKeyM = 46, kHBLeft = 123, kHBRight = 124, kHBDown = 125, kHBUp = 126 };

#pragma mark - AppKit bridge

static void (*sInstallKeyMonitor)(HBKeyCallback);
static void (*sConfigureWindows)(double, double, bool);
static bool (*sPointer)(double *, double *);
static bool (*sContentSize)(double *, double *);
static void (*sPostKey)(uint16_t, bool);
static void (*sPostMouse)(double, double, bool);

static void HBLoadBridge(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libHarborAppKit.dylib"];
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW);
        if (!handle) {
            HBLog(@"AppKit bridge unavailable: %s", dlerror());
            return;
        }
        sInstallKeyMonitor = dlsym(handle, "HBBridgeInstallKeyMonitor");
        sConfigureWindows = dlsym(handle, "HBBridgeConfigureWindows");
        sPointer = dlsym(handle, "HBBridgePointerPosition");
        sContentSize = dlsym(handle, "HBBridgeWindowContentSize");
        sPostKey = dlsym(handle, "HBBridgePostKey");
        sPostMouse = dlsym(handle, "HBBridgePostMouse");
    });
}

@implementation HBBridge
+ (BOOL)available {
    HBLoadBridge();
    return sInstallKeyMonitor != NULL;
}
+ (void)installKeyMonitor:(HBKeyCallback)callback {
    if (self.available) sInstallKeyMonitor(callback);
}
+ (void)configureWindowsWithAspect:(CGSize)aspect resizable:(BOOL)resizable {
    HBLoadBridge();
    if (sConfigureWindows) sConfigureWindows(aspect.width, aspect.height, resizable);
}
+ (BOOL)pointerPosition:(CGPoint *)position {
    HBLoadBridge();
    double x = 0, y = 0;
    if (!sPointer || !sPointer(&x, &y)) return NO;
    *position = CGPointMake(x, y);
    return YES;
}
+ (BOOL)windowContentSize:(CGSize *)size {
    HBLoadBridge();
    double width = 0, height = 0;
    if (!sContentSize || !sContentSize(&width, &height)) return NO;
    *size = CGSizeMake(width, height);
    return YES;
}
+ (void)postKey:(uint16_t)keyCode down:(BOOL)down {
    HBLoadBridge();
    if (sPostKey) sPostKey(keyCode, down);
}
+ (void)postMouseAt:(CGPoint)point down:(BOOL)down {
    HBLoadBridge();
    if (sPostMouse) sPostMouse(point.x, point.y, down);
}
@end

#pragma mark - Keymap storage

@implementation HBKeymap

+ (HBKeymap *)shared {
    static HBKeymap *keymap;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keymap = [[HBKeymap alloc] init];
        [keymap load];
    });
    return keymap;
}

- (void)load {
    NSDictionary *json = [HBConfig.shared readJSON:@"keymap.json"];
    NSMutableArray *elements = [NSMutableArray array];
    for (id element in json[@"elements"]) {
        if ([element isKindOfClass:NSDictionary.class]) [elements addObject:[element mutableCopy]];
    }
    self.elements = elements;
}

- (void)save {
    [HBConfig.shared writeJSON:@{@"version": @1, @"elements": self.elements ?: @[]} name:@"keymap.json"];
}

@end

#pragma mark - Key names

NSString *HBKeyLabel(uint16_t keyCode) {
    static NSDictionary<NSNumber *, NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{
            @0: @"A", @1: @"S", @2: @"D", @3: @"F", @4: @"H", @5: @"G", @6: @"Z", @7: @"X", @8: @"C", @9: @"V",
            @11: @"B", @12: @"Q", @13: @"W", @14: @"E", @15: @"R", @16: @"Y", @17: @"T", @18: @"1", @19: @"2",
            @20: @"3", @21: @"4", @22: @"6", @23: @"5", @24: @"=", @25: @"9", @26: @"7", @27: @"-", @28: @"8",
            @29: @"0", @30: @"]", @31: @"O", @32: @"U", @33: @"[", @34: @"I", @35: @"P", @36: @"↩", @37: @"L",
            @38: @"J", @39: @"'", @40: @"K", @41: @";", @42: @"\\", @43: @",", @44: @"/", @45: @"N", @46: @"M",
            @47: @".", @48: @"⇥", @49: @"Space", @50: @"`", @51: @"⌫", @53: @"Esc", @55: @"⌘", @56: @"⇧",
            @57: @"⇪", @58: @"⌥", @59: @"⌃", @60: @"R⇧", @61: @"R⌥", @62: @"R⌃", @122: @"F1", @120: @"F2",
            @99: @"F3", @118: @"F4", @96: @"F5", @97: @"F6", @98: @"F7", @100: @"F8", @101: @"F9", @109: @"F10",
            @103: @"F11", @111: @"F12", @123: @"←", @124: @"→", @125: @"↓", @126: @"↑",
        };
    });
    return names[@(keyCode)] ?: [NSString stringWithFormat:@"#%u", keyCode];
}

#pragma mark - Controller state

/// Names of the pressed buttons on the first extended gamepad, plus its stick positions.
static NSSet<NSString *> *HBControllerButtons(CGPoint *left, CGPoint *right) {
    *left = *right = CGPointZero;
    GCExtendedGamepad *pad = GCController.controllers.firstObject.extendedGamepad;
    if (!pad) return [NSSet set];
    *left = CGPointMake(pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value);
    *right = CGPointMake(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value);
    NSMutableSet *pressed = [NSMutableSet set];
    void (^check)(NSString *, GCControllerButtonInput *) = ^(NSString *name, GCControllerButtonInput *button) {
        if (button.isPressed) [pressed addObject:name];
    };
    check(@"buttonA", pad.buttonA);
    check(@"buttonB", pad.buttonB);
    check(@"buttonX", pad.buttonX);
    check(@"buttonY", pad.buttonY);
    check(@"leftShoulder", pad.leftShoulder);
    check(@"rightShoulder", pad.rightShoulder);
    check(@"leftTrigger", pad.leftTrigger);
    check(@"rightTrigger", pad.rightTrigger);
    check(@"dpadUp", pad.dpad.up);
    check(@"dpadDown", pad.dpad.down);
    check(@"dpadLeft", pad.dpad.left);
    check(@"dpadRight", pad.dpad.right);
    check(@"buttonMenu", pad.buttonMenu);
    check(@"buttonOptions", pad.buttonOptions);
    check(@"leftThumbstickButton", pad.leftThumbstickButton);
    check(@"rightThumbstickButton", pad.rightThumbstickButton);
    return pressed;
}

#pragma mark - Router

@interface HBElementState : NSObject
@property (nonatomic) NSInteger finger;
@property (nonatomic) CGPoint lastPoint;
@end
@implementation HBElementState
- (instancetype)init {
    if ((self = [super init])) _finger = -1;
    return self;
}
@end

static NSMutableSet<NSNumber *> *gKeysDown;
static NSMapTable<NSMutableDictionary *, HBElementState *> *gStates;
static NSSet<NSString *> *gPreviousButtons;
static NSArray *gStateElements;
static BOOL gMappingEnabled;
static CFTimeInterval gLastTick;

static BOOL HBTextInputActive(void) {
    UIWindow *window = HBAppWindow();
    SEL selector = NSSelectorFromString(@"firstResponder");
    if (![window respondsToSelector:selector]) return NO;
    id responder = ((id (*)(id, SEL))objc_msgSend)(window, selector);
    return [responder conformsToProtocol:@protocol(UIKeyInput)];
}

static BOOL HBKeyIsMapped(uint16_t keyCode) {
    NSNumber *key = @(keyCode);
    for (NSDictionary *element in HBKeymap.shared.elements) {
        if ([element[@"key"] isEqual:key]) return YES;
        NSDictionary *keys = element[@"keys"];
        if ([keys isKindOfClass:NSDictionary.class] && [keys.allValues containsObject:key]) return YES;
    }
    return NO;
}

static BOOL HBMotionUsesArrows(void) { return [HBConfig.shared.motion isEqual:@"keyboard"]; }

static bool HBOnKey(uint16_t keyCode, bool down, uint64_t flags, bool isRepeat) {
    BOOL command = (flags & kHBCommand) != 0;
    if (down && command && (flags & kHBShift)) {
        switch (keyCode) {
        case kHBKeyK: [HBOverlay.shared toggleEditor]; return true;
        case kHBKeyM:
            gMappingEnabled = !gMappingEnabled;
            if (!gMappingEnabled) [HBTouchInjector.shared endAll];
            HBLog(@"Keymapping %@", gMappingEnabled ? @"on" : @"off");
            return true;
        case kHBKeyH: HBOverlay.shared.showsHints = !HBOverlay.shared.showsHints; return true;
        }
    }
    if (HBOverlay.shared.editing) {
        if (down && !isRepeat) [HBOverlay.shared editorKey:keyCode label:HBKeyLabel(keyCode)];
        return true;
    }
    // ⌘-shortcuts (Quit, Hide, …) always reach the system.
    if (command || !gMappingEnabled || HBTextInputActive()) {
        if (!down) [gKeysDown removeObject:@(keyCode)];
        return false;
    }
    BOOL arrow = keyCode >= kHBLeft && keyCode <= kHBUp;
    if (HBKeyIsMapped(keyCode) || (arrow && HBMotionUsesArrows())) {
        if (down) [gKeysDown addObject:@(keyCode)];
        else [gKeysDown removeObject:@(keyCode)];
        return true;
    }
    return false;
}

static double HBKeyAxis(NSDictionary *keys, NSString *negative, NSString *positive) {
    double value = 0;
    if ([gKeysDown containsObject:keys[negative] ?: @(-1)]) value -= 1;
    if ([gKeysDown containsObject:keys[positive] ?: @(-1)]) value += 1;
    return value;
}

static void HBUpdateMotion(CGPoint rightStick, double dt) {
    NSString *source = HBConfig.shared.motion;
    double x = 0, y = 0;
    if ([source isEqual:@"keyboard"]) {
        x = ([gKeysDown containsObject:@(kHBRight)] ? 1 : 0) - ([gKeysDown containsObject:@(kHBLeft)] ? 1 : 0);
        y = ([gKeysDown containsObject:@(kHBUp)] ? 1 : 0) - ([gKeysDown containsObject:@(kHBDown)] ? 1 : 0);
    } else if ([source isEqual:@"controller"]) {
        x = rightStick.x;
        y = rightStick.y;
    } else if ([source isEqual:@"mouse"]) {
        CGPoint p;
        if ([HBBridge pointerPosition:&p]) {
            x = (p.x - 0.5) * 2;
            y = (0.5 - p.y) * 2;
        }
    }
    HBMotionSetTarget(x, y);
    HBMotionStep(dt);
}

/// One pass of the keymap: works out which elements are held and moves their fingers.
static void HBUpdateKeymap(NSSet<NSString *> *buttons, CGPoint leftStick, CGPoint rightStick) {
    UIWindow *window = HBAppWindow();
    if (!window) return;
    CGSize size = window.bounds.size;
    HBTouchInjector *injector = HBTouchInjector.shared;
    if (HBKeymap.shared.elements != gStateElements) {
        // The editor replaced the keymap: lift every finger and start from a clean slate.
        [injector endAll];
        [gStates removeAllObjects];
        gStateElements = HBKeymap.shared.elements;
    }

    for (NSMutableDictionary *element in HBKeymap.shared.elements) {
        HBElementState *state = [gStates objectForKey:element];
        if (!state) {
            state = [HBElementState new];
            [gStates setObject:state forKey:element];
        }
        CGPoint center = CGPointMake([element[@"x"] doubleValue] * size.width, [element[@"y"] doubleValue] * size.height);
        CGPoint target = center;
        BOOL active = NO;

        if ([element[@"type"] isEqual:@"joystick"]) {
            NSDictionary *keys = element[@"keys"];
            double dx = 0, dy = 0;
            if ([keys isKindOfClass:NSDictionary.class]) {
                dx = HBKeyAxis(keys, @"left", @"right");
                dy = HBKeyAxis(keys, @"up", @"down");
            }
            NSString *stick = element[@"controller"];
            if ([stick isEqual:@"leftThumbstick"]) {
                dx += leftStick.x;
                dy -= leftStick.y;
            } else if ([stick isEqual:@"rightThumbstick"]) {
                dx += rightStick.x;
                dy -= rightStick.y;
            }
            double length = hypot(dx, dy);
            if (length > 1) {
                dx /= length;
                dy /= length;
            }
            active = length > 0.15;
            double radius = ([element[@"radius"] doubleValue] ?: 0.12) * MIN(size.width, size.height);
            target = CGPointMake(center.x + dx * radius, center.y + dy * radius);
        } else {
            active = (element[@"key"] && [gKeysDown containsObject:element[@"key"]]) ||
                     (element[@"controller"] && [buttons containsObject:element[@"controller"]]);
        }

        if (active && state.finger < 0) {
            // Joysticks press at their centre, then slide out, like a thumb would.
            state.finger = [injector beginAt:center];
            state.lastPoint = center;
        }
        if (active && state.finger >= 0 && !CGPointEqualToPoint(target, state.lastPoint)) {
            [injector moveFinger:state.finger to:target];
            state.lastPoint = target;
        }
        if (!active && state.finger >= 0) {
            [injector endFinger:state.finger];
            state.finger = -1;
        }
    }
}

static void HBTick(void) {
    CFTimeInterval now = CACurrentMediaTime();
    double dt = gLastTick > 0 ? MIN(now - gLastTick, 0.1) : 1.0 / 60;
    gLastTick = now;

    CGPoint left, right;
    NSSet<NSString *> *buttons = HBControllerButtons(&left, &right);
    if (HBOverlay.shared.editing) {
        for (NSString *name in buttons) {
            if (![gPreviousButtons containsObject:name]) [HBOverlay.shared editorControllerInput:name];
        }
        if (hypot(left.x, left.y) > 0.6) [HBOverlay.shared editorControllerInput:@"leftThumbstick"];
        if (hypot(right.x, right.y) > 0.6) [HBOverlay.shared editorControllerInput:@"rightThumbstick"];
    } else if (gMappingEnabled) {
        HBUpdateKeymap(buttons, left, right);
    }
    gPreviousButtons = buttons;
    HBUpdateMotion(right, dt);
}

void HBStartInput(void) {
    gKeysDown = [NSMutableSet set];
    gStates = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsStrongMemory
                                    valueOptions:NSPointerFunctionsStrongMemory];
    gMappingEnabled = HBConfig.shared.keymapping;
    [HBKeymap shared];
    if (HBBridge.available) {
        [HBBridge installKeyMonitor:HBOnKey];
    } else {
        HBLog(@"Keyboard mapping disabled: AppKit bridge missing");
    }
    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) { HBTick(); }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    HBOverlay.shared.showsHints = HBConfig.shared.showKeymapHints;
    HBLog(@"Input ready: %lu keymap controls, motion=%@", (unsigned long)HBKeymap.shared.elements.count,
          HBConfig.shared.motion);
}
