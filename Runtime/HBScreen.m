// Screen and window: the window takes the device's shape, and the app is told the screen
// is exactly that window, as it would be on a phone.
#import "HBRuntime.h"
#import <objc/runtime.h>

static CGRect (*origBounds)(id, SEL);
static CGRect (*origNativeBounds)(id, SEL);
static CGSize gWindowSize;
static BOOL gSpoofScreen;
static CGSize gAppliedSize;

/// AppKit points per UIKit point. Catalyst draws iPad-idiom UIKit content at 77%, and the
/// screen and window-frame APIs speak AppKit points while the app's views speak UIKit points.
static CGFloat HBAppKitScale(void) {
    CGSize content;
    CGSize uikit = HBAppWindow().bounds.size;
    if (uikit.width > 1 && [HBBridge windowContentSize:&content]) {
        CGFloat ratio = content.width / uikit.width;
        if (ratio > 0.5 && ratio < 1.5) return ratio;
    }
    return 0.77;
}

/// Device size × window scale, shrunk (keeping the aspect ratio) to fit the Mac's display.
static CGSize HBTargetWindowSize(void) {
    HBConfig *config = HBConfig.shared;
    CGSize base = config.orientedDeviceSize;
    base.width *= config.windowScale;
    base.height *= config.windowScale;
    CGRect screen = origBounds(UIScreen.mainScreen, @selector(bounds));
    if (screen.size.width < 1 || screen.size.height < 1) return base;
    CGFloat f = HBAppKitScale();
    CGFloat maxWidth = screen.size.width * 0.92 / f;
    CGFloat maxHeight = (screen.size.height - 80) * 0.92 / f; // menu bar, title bar, Dock
    CGFloat k = MIN(1.0, MIN(maxWidth / base.width, maxHeight / base.height));
    return CGSizeMake(floor(base.width * k), floor(base.height * k));
}

CGSize HBSpoofedScreenSize(void) {
    if (gWindowSize.width < 1) gWindowSize = HBTargetWindowSize();
    // Report the real window once it has taken its final shape (Catalyst may round by a point);
    // before that, the size it is about to become.
    UIWindow *window = HBAppWindow();
    CGSize actual = window.windowScene ? window.windowScene.coordinateSpace.bounds.size : window.bounds.size;
    BOOL settled = fabs(actual.width - gWindowSize.width) <= 2 && fabs(actual.height - gWindowSize.height) <= 2;
    if (actual.width > 1 && (settled || HBConfig.shared.resizable)) gWindowSize = actual;
    return gWindowSize;
}

static CGRect hb_bounds(id self, SEL _cmd) {
    if (gSpoofScreen && HB_CALLED_BY_APP() && self == UIScreen.mainScreen) {
        return (CGRect){CGPointZero, HBSpoofedScreenSize()};
    }
    return origBounds(self, _cmd);
}

static CGRect hb_nativeBounds(UIScreen *self, SEL _cmd) {
    if (gSpoofScreen && HB_CALLED_BY_APP() && self == UIScreen.mainScreen) {
        // nativeBounds is always portrait and in pixels.
        CGSize size = HBSpoofedScreenSize();
        CGFloat scale = self.scale;
        return CGRectMake(0, 0, MIN(size.width, size.height) * scale, MAX(size.width, size.height) * scale);
    }
    return origNativeBounds(self, _cmd);
}

#pragma mark - Windows follow the scene

static const void *HBFollowsSceneKey = &HBFollowsSceneKey;

static BOOL HBSameSize(CGSize a, CGSize b) { return fabs(a.width - b.width) <= 2 && fabs(a.height - b.height) <= 2; }

/// Apps without scenes size their window from UIScreen.bounds. That is the device size Harbor
/// reports, not the Mac's screen, so UIKit never resizes the window with its scene and the app
/// stays at its first size inside a resized window. A window that covered the whole scene (or
/// the screen the app was told about) is kept covering it.
static void HBFitWindows(UIWindowScene *scene) {
    CGSize size = scene.coordinateSpace.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    Class overlay = NSClassFromString(@"HBOverlayWindow");
    for (UIWindow *window in scene.windows) {
        NSString *name = NSStringFromClass(window.class);
        if ((overlay && [window isKindOfClass:overlay]) || [name hasPrefix:@"UIText"] || [name hasPrefix:@"UIRemote"]) continue;
        CGRect frame = window.frame;
        if (!objc_getAssociatedObject(window, HBFollowsSceneKey)) {
            BOOL full = CGPointEqualToPoint(frame.origin, CGPointZero) &&
                        (HBSameSize(frame.size, size) || HBSameSize(frame.size, gWindowSize) ||
                         HBSameSize(frame.size, gAppliedSize));
            if (!full) continue;
            objc_setAssociatedObject(window, HBFollowsSceneKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (CGRectEqualToRect(frame, (CGRect){CGPointZero, size})) continue;
        window.frame = (CGRect){CGPointZero, size};
        HBLog(@"Window content resized from %.0fx%.0f to %.0fx%.0f", frame.size.width, frame.size.height, size.width, size.height);
    }
}

/// Watches a scene's geometry (live resizing, zoom, full screen) and refits its windows.
@interface HBSceneObserver : NSObject
@end

@implementation HBSceneObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    UIWindowScene *scene = object;
    if (NSThread.isMainThread) {
        HBFitWindows(scene);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ HBFitWindows(scene); });
    }
}
@end

static void HBObserveScene(UIWindowScene *scene) {
    if (@available(iOS 16.0, *)) {
        if (objc_getAssociatedObject(scene, HBFollowsSceneKey)) return;
        HBSceneObserver *observer = [HBSceneObserver new];
        objc_setAssociatedObject(scene, HBFollowsSceneKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [scene addObserver:observer forKeyPath:@"effectiveGeometry" options:0 context:NULL];
    }
}

/// Requests the target frame when the window has the wrong shape: a fixed window must match
/// exactly; a resizable one keeps the user's size as long as the aspect ratio is right.
/// A window of any shape keeps the user's size; it only gets the device's shape when it is new.
/// `last` is the final check after launch: a scene still at UIKit's default size by then was not
/// restored from an earlier session.
static void HBEnsureWindowShape(UIWindowScene *scene, CGSize target, BOOL last) {
    if (@available(iOS 16.0, *)) {
        CGSize current = scene.coordinateSpace.bounds.size;
        if (current.width < 1 || current.height < 1) return;
        HBConfig *config = HBConfig.shared;
        BOOL aspectOK = fabs(current.width / current.height - target.width / target.height) < 0.02;
        BOOL sizeOK = fabs(current.width - target.width) <= 3 && fabs(current.height - target.height) <= 3;
        BOOL unsized = CGSizeEqualToSize(current, CGSizeMake(1024, 768));
        // A scene still at UIKit's default size has not been restored or sized yet.
        if (unsized && !last) return;
        if (!unsized && (config.freeAspect || (config.resizable ? aspectOK : sizeOK))) return;
        CGRect screen = origBounds(scene.screen, @selector(bounds));
        CGFloat f = HBAppKitScale();
        CGSize frameSize = CGSizeMake(round(target.width * f), round(target.height * f));
        CGRect frame = CGRectMake(floor((screen.size.width - frameSize.width) / 2),
                                  floor((screen.size.height - frameSize.height) / 2), frameSize.width, frameSize.height);
        UIWindowSceneGeometryPreferencesMac *prefs = [[UIWindowSceneGeometryPreferencesMac alloc] initWithSystemFrame:frame];
        [scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *error) {
            HBLog(@"Window resize refused: %@", error.localizedDescription);
        }];
        HBLog(@"Window reshaped from %.0fx%.0f to %.0fx%.0f", current.width, current.height, target.width, target.height);
    }
}

static void HBSizeScene(UIScene *scene) {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    // Catalyst's invisible menu bar scene has no windows and must keep UIKit's default size.
    if ([scene.session.persistentIdentifier hasPrefix:@"NSMenuBarScene"]) return;
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    HBConfig *config = HBConfig.shared;
    CGSize size = HBTargetWindowSize();
    BOOL changed = !CGSizeEqualToSize(size, gAppliedSize);
    gAppliedSize = size;
    gWindowSize = size;

    UISceneSizeRestrictions *restrictions = windowScene.sizeRestrictions;
    if (config.freeAspect) {
        CGFloat side = floor(MIN(size.width, size.height) * 0.5);
        restrictions.minimumSize = CGSizeMake(side, side);
        restrictions.maximumSize = CGSizeMake(size.width * 4, size.height * 4);
    } else if (config.resizable) {
        restrictions.minimumSize = CGSizeMake(floor(size.width * 0.4), floor(size.height * 0.4));
        restrictions.maximumSize = CGSizeMake(size.width * 4, size.height * 4);
    } else {
        restrictions.minimumSize = size;
        restrictions.maximumSize = size;
    }

    // macOS restores the previous window frame after this point, so check the shape again
    // once restoration is done.
    HBEnsureWindowShape(windowScene, size, NO);
    for (NSNumber *delay in @[@0.3, @1.0]) {
        BOOL last = delay.doubleValue >= 1.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ HBEnsureWindowShape(windowScene, size, last); });
    }
    [HBBridge configureWindowsWithAspect:config.freeAspect ? CGSizeZero : size resizable:config.resizable];
    HBObserveScene(windowScene);
    HBFitWindows(windowScene);
    if (changed) HBLog(@"Window sized to %.0fx%.0f (%@)", size.width, size.height,
                       config.freeAspect ? @"resizable, any shape" : config.resizable ? @"resizable" : @"fixed");
}

void HBInstallScreenHooks(void) {
    gSpoofScreen = HBConfig.shared.spoofScreen;
    origBounds = (void *)HBSwizzle(UIScreen.class, @selector(bounds), (IMP)hb_bounds);
    origNativeBounds = (void *)HBSwizzle(UIScreen.class, @selector(nativeBounds), (IMP)hb_nativeBounds);

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UISceneWillConnectNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        HBSizeScene(note.object);
    }];
    [center addObserverForName:UISceneDidActivateNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        HBSizeScene(note.object);
    }];
    [center addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        UIWindowScene *scene = ((UIWindow *)note.object).windowScene;
        if (scene) HBFitWindows(scene);
    }];
}
