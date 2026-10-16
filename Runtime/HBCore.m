#import "HBRuntime.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <ptrauth.h>
#import <pwd.h>
#import <stdatomic.h>

#pragma mark - Logging

void HBLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("app.harbor.runtime", "runtime"); });
    os_log(log, "%{public}@", message);
    if (getenv("HARBOR_VERBOSE")) fprintf(stderr, "[Harbor] %s\n", message.UTF8String);
}

#pragma mark - Settings

@implementation HBConfig

+ (HBConfig *)shared {
    static HBConfig *config;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ config = [[HBConfig alloc] init]; });
    return config;
}

static NSNumber *HBNumber(id value) { return [value isKindOfClass:NSNumber.class] ? value : nil; }

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
    // NSHomeDirectory() is the sandbox container; the shared Harbor folder is under the real home.
    struct passwd *pw = getpwuid(getuid());
    NSString *home = pw && pw->pw_dir ? @(pw->pw_dir) : NSHomeDirectory();
    _appFolder = [home stringByAppendingPathComponent:
                  [@"Library/Application Support/Harbor/Apps" stringByAppendingPathComponent:_bundleID]];
    _containerFolder = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Harbor"];

    NSDictionary *settings = [self readJSON:@"settings.json"];
    if (!settings) {
        NSString *path = [NSBundle.mainBundle pathForResource:@"HarborDefaults" ofType:@"json"];
        NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
        settings = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        HBLog(@"settings.json not readable; using bundle defaults");
    }
    if (![settings isKindOfClass:NSDictionary.class]) settings = @{};

    NSDictionary *device = [settings[@"device"] isKindOfClass:NSDictionary.class] ? settings[@"device"] : @{};
    _deviceName = device[@"name"] ?: @"iPhone";
    _deviceModel = device[@"model"] ?: @"iPhone";
    _deviceMachine = device[@"machine"] ?: @"iPhone18,1";
    _devicePhone = ![device[@"idiom"] isEqual:@"pad"];
    _devicePortraitSize = CGSizeMake(HBNumber(device[@"width"]).doubleValue ?: 402,
                                     HBNumber(device[@"height"]).doubleValue ?: 874);

    _windowScale = HBNumber(settings[@"windowScale"]).doubleValue ?: 1.0;
    _resizable = [HBNumber(settings[@"resizable"]) boolValue];
    _freeAspect = _resizable && [HBNumber(settings[@"freeAspect"]) boolValue];
    _spoofDevice = HBNumber(settings[@"spoofDevice"]) ? [settings[@"spoofDevice"] boolValue] : YES;
    _spoofScreen = HBNumber(settings[@"spoofScreen"]) ? [settings[@"spoofScreen"] boolValue] : YES;
    _spoofIdiom = HBNumber(settings[@"spoofIdiom"]) ? [settings[@"spoofIdiom"] boolValue] : YES;
    _keychainEmulation = HBNumber(settings[@"keychainEmulation"]) ? [settings[@"keychainEmulation"] boolValue] : YES;
    _keymapping = HBNumber(settings[@"keymapping"]) ? [settings[@"keymapping"] boolValue] : YES;
    _showKeymapHints = [HBNumber(settings[@"showKeymapHints"]) boolValue];
    _motion = [settings[@"motion"] isKindOfClass:NSString.class] ? settings[@"motion"] : @"keyboard";

    NSString *orientation = settings[@"orientation"];
    if ([orientation isEqual:@"landscape"]) {
        _landscape = YES;
    } else if ([orientation isEqual:@"portrait"]) {
        _landscape = NO;
    } else {
        _landscape = [self appIsLandscapeOnly];
    }
    return self;
}

/// "auto" orientation: landscape when every orientation the app declares is a landscape one.
- (BOOL)appIsLandscapeOnly {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSArray *orientations = info[_devicePhone ? @"UISupportedInterfaceOrientations~iphone"
                                              : @"UISupportedInterfaceOrientations~ipad"]
                            ?: info[@"UISupportedInterfaceOrientations"];
    if (![orientations isKindOfClass:NSArray.class] || orientations.count == 0) return NO;
    for (NSString *o in orientations) {
        if (![o isKindOfClass:NSString.class] || ![o containsString:@"Landscape"]) return NO;
    }
    return YES;
}

- (CGSize)orientedDeviceSize {
    CGSize s = _devicePortraitSize;
    return _landscape ? CGSizeMake(s.height, s.width) : s;
}

- (NSDictionary *)readJSON:(NSString *)name {
    for (NSString *folder in @[_appFolder, _containerFolder]) {
        NSData *data = [NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:name]];
        if (!data) continue;
        id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
        if ([json isKindOfClass:NSDictionary.class]) return json;
    }
    return nil;
}

- (BOOL)writeJSON:(id)object name:(NSString *)name {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    if (!data) return NO;
    for (NSString *folder in @[_appFolder, _containerFolder]) {
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        if ([data writeToFile:[folder stringByAppendingPathComponent:name] atomically:YES]) return YES;
        HBLog(@"Could not write %@ to %@", name, folder);
    }
    return NO;
}

@end

#pragma mark - App code ranges

#define HB_MAX_IMAGES 256
static uintptr_t gImageStart[HB_MAX_IMAGES];
static uintptr_t gImageEnd[HB_MAX_IMAGES];
static atomic_int gImageCount;
static char gBundlePath[PATH_MAX];
static size_t gBundlePathLength;

static void HBImageAdded(const struct mach_header *header, intptr_t slide) {
    Dl_info info;
    if (!dladdr(header, &info) || !info.dli_fname) return;
    char resolved[PATH_MAX];
    const char *path = realpath(info.dli_fname, resolved) ? resolved : info.dli_fname;
    if (strncmp(path, gBundlePath, gBundlePathLength) != 0 || strstr(path, "/libHarbor")) return;
    unsigned long size = 0;
    uint8_t *text = getsegmentdata((const struct mach_header_64 *)header, "__TEXT", &size);
    if (!text || !size) return;
    int index = atomic_load(&gImageCount);
    if (index >= HB_MAX_IMAGES) return;
    gImageStart[index] = (uintptr_t)text;
    gImageEnd[index] = (uintptr_t)text + size;
    atomic_store(&gImageCount, index + 1);
}

BOOL HBAddressIsAppCode(const void *address) {
    uintptr_t a = (uintptr_t)ptrauth_strip(address, ptrauth_key_return_address);
    int count = atomic_load(&gImageCount);
    for (int i = 0; i < count; i++) {
        if (a >= gImageStart[i] && a < gImageEnd[i]) return YES;
    }
    return NO;
}

static void HBRegisterAppImages(void) {
    const char *bundle = NSBundle.mainBundle.bundlePath.fileSystemRepresentation;
    if (!realpath(bundle, gBundlePath)) strlcpy(gBundlePath, bundle, sizeof gBundlePath);
    strlcat(gBundlePath, "/", sizeof gBundlePath);
    gBundlePathLength = strlen(gBundlePath);
    _dyld_register_func_for_add_image(HBImageAdded);
}

#pragma mark - Swizzling and windows

IMP HBSwizzle(Class cls, SEL sel, IMP replacement) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        HBLog(@"Cannot hook -[%@ %@]: no such method", cls, NSStringFromSelector(sel));
        return NULL;
    }
    IMP original = method_getImplementation(method);
    // Add on the class itself when the method is inherited, so the superclass stays untouched.
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) {
        method_setImplementation(method, replacement);
    }
    return original;
}

UIWindow *HBAppWindow(void) {
    UIWindow *fallback = nil;
    Class overlay = NSClassFromString(@"HBOverlayWindow");
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSString *name = NSStringFromClass(window.class);
            if ((overlay && [window isKindOfClass:overlay]) || [name hasPrefix:@"UIText"] || [name hasPrefix:@"UIRemote"]) continue;
            if (window.isKeyWindow) return window;
            if (!fallback && !window.hidden) fallback = window;
        }
    }
    return fallback;
}

#pragma mark - Entry point

__attribute__((constructor)) static void HBRuntimeInit(void) {
    @autoreleasepool {
        HBConfig *config = HBConfig.shared;
        HBRegisterAppImages();
        HBInstallDeviceHooks();
        HBInstallScreenHooks();
        HBInstallMotionHooks();
        HBInstallCameraHooks();
        HBInstallWebMediaHooks();
        HBLog(@"Runtime loaded in %@ as %@ (%@), %@ %.0fx%.0f%@",
              config.bundleID, config.deviceName, config.deviceMachine,
              config.landscape ? @"landscape" : @"portrait",
              config.orientedDeviceSize.width, config.orientedDeviceSize.height,
              config.freeAspect ? @", any window shape" : @"");

        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            HBStartInput();
            NSString *selfTest = NSProcessInfo.processInfo.environment[@"HARBOR_SELFTEST"];
            if (selfTest.length) HBRunSelfTest(selfTest);
        }];
    }
}
