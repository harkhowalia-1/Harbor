// libHarborAppKit.dylib: a small macOS (AppKit) library the Catalyst runtime loads with dlopen,
// the same way a Catalyst app loads an AppKit plug-in bundle. It does what UIKit cannot:
// see every key event first, lock a window's aspect ratio, and read the pointer position.
#import <AppKit/AppKit.h>

#define HB_EXPORT __attribute__((visibility("default")))

typedef bool (*HBKeyCallback)(uint16_t keyCode, bool down, uint64_t modifierFlags, bool isRepeat);

static id gKeyMonitor;

static bool HBModifierIsDown(uint16_t keyCode, NSEventModifierFlags flags) {
    switch (keyCode) {
    case 56: case 60: return flags & NSEventModifierFlagShift;
    case 59: case 62: return flags & NSEventModifierFlagControl;
    case 58: case 61: return flags & NSEventModifierFlagOption;
    case 54: case 55: return flags & NSEventModifierFlagCommand;
    case 57: return flags & NSEventModifierFlagCapsLock;
    default: return false;
    }
}

HB_EXPORT void HBBridgeInstallKeyMonitor(HBKeyCallback callback) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gKeyMonitor) [NSEvent removeMonitor:gKeyMonitor];
        NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged;
        gKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
            bool down, repeat = false;
            if (event.type == NSEventTypeFlagsChanged) {
                down = HBModifierIsDown(event.keyCode, event.modifierFlags);
            } else {
                down = event.type == NSEventTypeKeyDown;
                repeat = event.isARepeat;
            }
            // Returning nil swallows the event so the app never sees a mapped key.
            return callback(event.keyCode, down, event.modifierFlags, repeat) ? nil : event;
        }];
    });
}

static void HBApplyWindowShape(double width, double height, bool resizable) {
    for (NSWindow *window in NSApp.windows) {
        if (!window.contentView || window.styleMask & NSWindowStyleMaskBorderless) continue;
        if (width > 0 && height > 0) {
            window.contentAspectRatio = NSMakeSize(width, height);
        } else {
            window.contentResizeIncrements = NSMakeSize(1, 1); // clears any aspect ratio
        }
        if (resizable) {
            window.styleMask |= NSWindowStyleMaskResizable;
        } else {
            window.styleMask &= ~NSWindowStyleMaskResizable;
            window.collectionBehavior = (window.collectionBehavior & ~NSWindowCollectionBehaviorFullScreenPrimary) |
                                        NSWindowCollectionBehaviorFullScreenNone;
            [[window standardWindowButton:NSWindowZoomButton] setEnabled:NO];
        }
    }
}

HB_EXPORT void HBBridgeConfigureWindows(double width, double height, bool resizable) {
    // The NSWindow appears a moment after its UIKit scene connects, so apply now and again shortly.
    dispatch_async(dispatch_get_main_queue(), ^{ HBApplyWindowShape(width, height, resizable); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        HBApplyWindowShape(width, height, resizable);
    });
}

HB_EXPORT bool HBBridgePointerPosition(double *x, double *y) {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    NSView *content = window.contentView;
    if (!content) return false;
    NSPoint point = [content convertPoint:window.mouseLocationOutsideOfEventStream fromView:nil];
    NSRect bounds = content.bounds;
    if (!NSPointInRect(point, bounds)) return false;
    *x = (point.x - bounds.origin.x) / bounds.size.width;
    double fromBottom = (point.y - bounds.origin.y) / bounds.size.height;
    *y = content.isFlipped ? fromBottom : 1 - fromBottom;
    return true;
}

/// Posts a synthetic key event through the normal AppKit queue (used by the runtime self-test).
HB_EXPORT void HBBridgePostKey(uint16_t keyCode, bool down) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *window = NSApp.keyWindow ?: NSApp.windows.firstObject;
        NSEvent *event = [NSEvent keyEventWithType:down ? NSEventTypeKeyDown : NSEventTypeKeyUp
                                          location:NSZeroPoint
                                     modifierFlags:0
                                         timestamp:NSProcessInfo.processInfo.systemUptime
                                      windowNumber:window.windowNumber
                                           context:nil
                                        characters:@""
                       charactersIgnoringModifiers:@""
                                         isARepeat:NO
                                           keyCode:keyCode];
        [NSApp postEvent:event atStart:NO];
    });
}

/// Posts a synthetic left-click at a point given as 0…1 of the key window's content (self-test).
HB_EXPORT void HBBridgePostMouse(double x, double y, bool down) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow ?: NSApp.windows.firstObject;
        NSView *content = window.contentView;
        if (!content) return;
        NSRect bounds = content.bounds;
        double fromTop = content.isFlipped ? y : 1 - y;
        NSPoint inView = NSMakePoint(bounds.origin.x + x * bounds.size.width, bounds.origin.y + fromTop * bounds.size.height);
        NSEvent *event = [NSEvent mouseEventWithType:down ? NSEventTypeLeftMouseDown : NSEventTypeLeftMouseUp
                                            location:[content convertPoint:inView toView:nil]
                                       modifierFlags:0
                                           timestamp:NSProcessInfo.processInfo.systemUptime
                                        windowNumber:window.windowNumber
                                             context:nil
                                         eventNumber:0
                                          clickCount:1
                                            pressure:down ? 1 : 0];
        [NSApp postEvent:event atStart:NO];
    });
}

/// Size of the key (or main) window's content in AppKit points.
HB_EXPORT bool HBBridgeWindowContentSize(double *width, double *height) {
    NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
    NSView *content = window.contentView;
    if (!content) return false;
    *width = content.frame.size.width;
    *height = content.frame.size.height;
    return true;
}
