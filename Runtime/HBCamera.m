// Camera: iPhone apps open the back camera, which no Mac has. Under Mac Catalyst the built-in
// camera and Continuity Camera report as front-facing and USB cameras as external, so an app that
// only asks for a back camera finds none. When the app's own code asks for a back wide-angle
// camera and there is none, it gets the Mac's cameras instead. Multi-lens types (dual, triple,
// telephoto) still come back empty, so apps take their usual single-camera path.
#import "HBRuntime.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// AVCaptureDevicePosition. AVFoundation is not linked: the hooks exist only in apps that load it.
static const NSInteger HBPositionUnspecified = 0, HBPositionBack = 1;

static NSString *gWideAngle, *gExternal, *gVideo;
static id (*origDefaultDevice)(id, SEL, NSString *, NSString *, NSInteger);
static id (*origDiscovery)(id, SEL, NSArray *, NSString *, NSInteger);

static NSString *HBConstant(const char *symbol) {
    __unsafe_unretained NSString *const *value = (__unsafe_unretained NSString *const *)dlsym(RTLD_DEFAULT, symbol);
    return value ? *value : nil;
}

static BOOL HBIsVideo(NSString *media) { return !media || [media isEqual:gVideo]; }

/// Logged once per API, the first time the fallback is used.
static void HBLogFallback(BOOL *logged, NSString *api, id device) {
    if (*logged) return;
    *logged = YES;
    HBLog(@"Camera: no back camera on this Mac; %@ gets %@", api, device ? [device valueForKey:@"localizedName"] : @"none");
}

static id hb_defaultDevice(id self, SEL _cmd, NSString *type, NSString *media, NSInteger position) {
    BOOL app = HB_CALLED_BY_APP();
    id device = origDefaultDevice(self, _cmd, type, media, position);
    if (device || !app || position != HBPositionBack || ![type isEqual:gWideAngle] || !HBIsVideo(media)) return device;
    device = ((id (*)(id, SEL, NSString *))objc_msgSend)(self, @selector(defaultDeviceWithMediaType:), gVideo);
    static BOOL logged;
    HBLogFallback(&logged, @"AVCaptureDevice.default(.builtInWideAngleCamera, position: .back)", device);
    return device;
}

static id hb_discovery(id self, SEL _cmd, NSArray *types, NSString *media, NSInteger position) {
    BOOL app = HB_CALLED_BY_APP();
    id session = origDiscovery(self, _cmd, types, media, position);
    if (!app || position != HBPositionBack || ![types containsObject:gWideAngle] || !HBIsVideo(media)) return session;
    NSArray *devices = ((NSArray * (*)(id, SEL))objc_msgSend)(session, @selector(devices));
    if (devices.count) return session;
    NSArray *all = gExternal ? @[gWideAngle, gExternal] : @[gWideAngle];
    session = origDiscovery(self, _cmd, all, media, HBPositionUnspecified);
    devices = ((NSArray * (*)(id, SEL))objc_msgSend)(session, @selector(devices));
    static BOOL logged;
    HBLogFallback(&logged, @"AVCaptureDevice.DiscoverySession(position: .back)", devices.firstObject);
    return session;
}

void HBInstallCameraHooks(void) {
    Class device = NSClassFromString(@"AVCaptureDevice");
    Class discovery = NSClassFromString(@"AVCaptureDeviceDiscoverySession");
    gWideAngle = HBConstant("AVCaptureDeviceTypeBuiltInWideAngleCamera");
    gExternal = HBConstant("AVCaptureDeviceTypeExternal");
    gVideo = HBConstant("AVMediaTypeVideo");
    if (!device || !discovery || !gWideAngle || !gVideo) return;

    origDefaultDevice = (void *)HBSwizzle(object_getClass(device), @selector(defaultDeviceWithDeviceType:mediaType:position:),
                                          (IMP)hb_defaultDevice);
    origDiscovery = (void *)HBSwizzle(object_getClass(discovery), @selector(discoverySessionWithDeviceTypes:mediaType:position:),
                                      (IMP)hb_discovery);
}
