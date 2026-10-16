// Harbor runtime: injected into every converted app (Mac Catalyst process).
// It corrects what an iPhone/iPad app assumes about its device: identity, screen,
// keychain, motion sensors, touch input and game controllers.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void HBLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

#pragma mark - Settings

/// Settings written by Harbor (settings.json), falling back to the copy baked into the bundle.
@interface HBConfig : NSObject
@property (class, readonly) HBConfig *shared;
@property (readonly) NSString *bundleID;
/// ~/Library/Application Support/Harbor/Apps/<bundle id> (reachable through a sandbox exception).
@property (readonly) NSString *appFolder;
/// <container>/Library/Harbor, the fallback when the shared folder is not writable.
@property (readonly) NSString *containerFolder;

@property (readonly) NSString *deviceName;     // "iPhone 17 Pro"
@property (readonly) NSString *deviceModel;    // "iPhone"
@property (readonly) NSString *deviceMachine;  // "iPhone18,1"
@property (readonly) BOOL devicePhone;
@property (readonly) CGSize devicePortraitSize; // points
@property (readonly) BOOL landscape;
@property (readonly) double windowScale;
/// Resizable with any shape, not just the device's aspect ratio.
@property (readonly) BOOL freeAspect;
@property (readonly) BOOL resizable, spoofDevice, spoofScreen, spoofIdiom, keychainEmulation, keymapping, showKeymapHints;
@property (readonly) NSString *motion; // off | keyboard | controller | mouse

- (CGSize)orientedDeviceSize;
- (nullable NSDictionary *)readJSON:(NSString *)name;
- (BOOL)writeJSON:(id)object name:(NSString *)name;
@end

#pragma mark - Helpers

/// True when `address` lies in the app's own code (main executable or a framework in its bundle),
/// so spoofed values go to the app while UIKit and other system code keep seeing the real Mac.
BOOL HBAddressIsAppCode(const void *address);
#define HB_CALLED_BY_APP() HBAddressIsAppCode(__builtin_return_address(0))

/// Replaces an instance method's implementation and returns the previous one.
IMP _Nullable HBSwizzle(Class cls, SEL sel, IMP replacement);

/// The app's main window (never one of Harbor's overlay windows).
UIWindow *_Nullable HBAppWindow(void);

#pragma mark - Subsystems

void HBInstallDeviceHooks(void);
void HBInstallScreenHooks(void);
void HBInstallMotionHooks(void);
void HBInstallCameraHooks(void);
void HBInstallWebMediaHooks(void);
void HBStartInput(void);
void HBRunSelfTest(NSString *mode);

/// Size the app should believe its screen is (the window's size, in UIKit points).
CGSize HBSpoofedScreenSize(void);

#pragma mark - Touch synthesis

@interface HBTouchInjector : NSObject
@property (class, readonly) HBTouchInjector *shared;
/// Starts a finger at a point in the app window's coordinates; returns its id, or -1.
- (NSInteger)beginAt:(CGPoint)point;
- (void)moveFinger:(NSInteger)finger to:(CGPoint)point;
- (void)endFinger:(NSInteger)finger;
- (void)endAll;
@end

#pragma mark - Motion

/// Screen-space tilt in [-1, 1] on each axis: x > 0 tips the right edge down, y > 0 tips the top edge down.
void HBMotionSetTarget(double x, double y);
/// Advances the virtual device toward its target; called by the input loop.
void HBMotionStep(double dt);

#pragma mark - AppKit bridge (libHarborAppKit.dylib, loaded at runtime)

typedef bool (*HBKeyCallback)(uint16_t keyCode, bool down, uint64_t modifierFlags, bool isRepeat);

@interface HBBridge : NSObject
@property (class, readonly) BOOL available;
+ (void)installKeyMonitor:(HBKeyCallback)callback;
+ (void)configureWindowsWithAspect:(CGSize)aspect resizable:(BOOL)resizable;
/// Pointer position in the key window, normalised to 0…1 from the top left. NO if outside.
+ (BOOL)pointerPosition:(CGPoint *)position;
/// Content size of the app's NSWindow in AppKit points. NO if there is no window yet.
+ (BOOL)windowContentSize:(CGSize *)size;
+ (void)postKey:(uint16_t)keyCode down:(BOOL)down;
/// Self-test only: a left click at a point given as 0…1 of the window.
+ (void)postMouseAt:(CGPoint)point down:(BOOL)down;
@end

#pragma mark - Keymap overlay

@interface HBOverlay : NSObject
@property (class, readonly) HBOverlay *shared;
@property (readonly, getter=isEditing) BOOL editing;
@property (nonatomic) BOOL showsHints;
- (void)toggleEditor;
- (void)reload;
/// Keys and controller buttons go to the editor while it is open.
- (void)editorKey:(uint16_t)keyCode label:(NSString *)label;
- (void)editorControllerInput:(NSString *)name;
@end

/// Keymap storage shared by the input router and the editor.
@interface HBKeymap : NSObject
@property (class, readonly) HBKeymap *shared;
@property (nonatomic, copy) NSArray<NSMutableDictionary *> *elements;
- (void)load;
- (void)save;
@end

/// Human-readable name for a Mac virtual key code.
NSString *HBKeyLabel(uint16_t keyCode);

NS_ASSUME_NONNULL_END
