// Device identity: what the app is told it runs on. Only the app's own code sees the profile;
// UIKit and other system code keep seeing the real Mac, so the OS keeps behaving correctly.
#import "HBRuntime.h"
#import <sys/sysctl.h>
#import <sys/utsname.h>

static char gMachine[64];
static BOOL gSpoofDevice, gSpoofIdiom, gLandscape;

#pragma mark - C functions (dyld interposing)

typedef struct {
    const void *replacement;
    const void *original;
} HBInterpose;

#define HB_INTERPOSE(replacement, original)                                                        \
    __attribute__((used)) static const HBInterpose hb_interpose_##original                          \
        __attribute__((section("__DATA,__interpose"))) = {(const void *)(uintptr_t)&replacement, \
                                                          (const void *)(uintptr_t)&original};

static int HBCopyOut(const char *value, void *oldp, size_t *oldlenp) {
    size_t length = strlen(value) + 1;
    if (!oldp) {
        *oldlenp = length;
        return 0;
    }
    if (*oldlenp < length) {
        errno = ENOMEM;
        return -1;
    }
    memcpy(oldp, value, length);
    *oldlenp = length;
    return 0;
}

static int hb_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (gSpoofDevice && name && oldlenp && !newp && strcmp(name, "hw.machine") == 0 && HB_CALLED_BY_APP()) {
        return HBCopyOut(gMachine, oldp, oldlenp);
    }
    return sysctlbyname(name, oldp, oldlenp, newp, newlen);
}
HB_INTERPOSE(hb_sysctlbyname, sysctlbyname)

static int hb_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (gSpoofDevice && namelen == 2 && name[0] == CTL_HW && name[1] == HW_MACHINE && oldlenp && !newp &&
        HB_CALLED_BY_APP()) {
        return HBCopyOut(gMachine, oldp, oldlenp);
    }
    return sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}
HB_INTERPOSE(hb_sysctl, sysctl)

static int hb_uname(struct utsname *info) {
    int result = uname(info);
    if (result == 0 && gSpoofDevice && HB_CALLED_BY_APP()) strlcpy(info->machine, gMachine, sizeof info->machine);
    return result;
}
HB_INTERPOSE(hb_uname, uname)

#pragma mark - UIDevice

typedef id (*HBGetter)(id, SEL);
static HBGetter origModel, origLocalizedModel, origName, origSystemName;
static UIUserInterfaceIdiom (*origDeviceIdiom)(id, SEL);
static UIUserInterfaceIdiom (*origTraitIdiom)(id, SEL);
static UIDeviceOrientation (*origDeviceOrientation)(id, SEL);
static UIInterfaceOrientation (*origSceneOrientation)(id, SEL);
static UIInterfaceOrientation (*origGeometryOrientation)(id, SEL);
static UIInterfaceOrientation (*origStatusBarOrientation)(id, SEL);

static id hb_model(id self, SEL _cmd) {
    return gSpoofDevice && HB_CALLED_BY_APP() ? HBConfig.shared.deviceModel : origModel(self, _cmd);
}

static id hb_localizedModel(id self, SEL _cmd) {
    return gSpoofDevice && HB_CALLED_BY_APP() ? HBConfig.shared.deviceModel : origLocalizedModel(self, _cmd);
}

static id hb_name(id self, SEL _cmd) {
    // iOS 16+ reports the generic model name to apps without a special entitlement.
    return gSpoofDevice && HB_CALLED_BY_APP() ? HBConfig.shared.deviceModel : origName(self, _cmd);
}

static id hb_systemName(id self, SEL _cmd) {
    if (gSpoofDevice && HB_CALLED_BY_APP()) return HBConfig.shared.devicePhone ? @"iOS" : @"iPadOS";
    return origSystemName(self, _cmd);
}

static UIUserInterfaceIdiom HBProfileIdiom(void) {
    return HBConfig.shared.devicePhone ? UIUserInterfaceIdiomPhone : UIUserInterfaceIdiomPad;
}

static UIUserInterfaceIdiom hb_deviceIdiom(id self, SEL _cmd) {
    return gSpoofIdiom && HB_CALLED_BY_APP() ? HBProfileIdiom() : origDeviceIdiom(self, _cmd);
}

static UIUserInterfaceIdiom hb_traitIdiom(id self, SEL _cmd) {
    UIUserInterfaceIdiom real = origTraitIdiom(self, _cmd);
    // Unspecified traits stay unspecified; only a concrete idiom is rewritten.
    return gSpoofIdiom && real != UIUserInterfaceIdiomUnspecified && HB_CALLED_BY_APP() ? HBProfileIdiom() : real;
}

#pragma mark - Orientation

// A Mac reports "unknown" device orientation and portrait interface orientation. Games that
// lay themselves out from these values get a consistent answer that matches the window shape.

/// A window of any shape is landscape whenever it is wider than tall.
static BOOL HBIsLandscape(void) {
    if (!HBConfig.shared.freeAspect) return gLandscape;
    CGSize size = HBSpoofedScreenSize();
    return size.width > size.height;
}

static UIDeviceOrientation hb_deviceOrientation(id self, SEL _cmd) {
    if (!HB_CALLED_BY_APP()) return origDeviceOrientation(self, _cmd);
    return HBIsLandscape() ? UIDeviceOrientationLandscapeLeft : UIDeviceOrientationPortrait;
}

static UIInterfaceOrientation HBInterfaceOrientation(void) {
    return HBIsLandscape() ? UIInterfaceOrientationLandscapeRight : UIInterfaceOrientationPortrait;
}

static UIInterfaceOrientation hb_sceneOrientation(id self, SEL _cmd) {
    return HB_CALLED_BY_APP() ? HBInterfaceOrientation() : origSceneOrientation(self, _cmd);
}

static UIInterfaceOrientation hb_geometryOrientation(id self, SEL _cmd) {
    return HB_CALLED_BY_APP() ? HBInterfaceOrientation() : origGeometryOrientation(self, _cmd);
}

static UIInterfaceOrientation hb_statusBarOrientation(id self, SEL _cmd) {
    return HB_CALLED_BY_APP() ? HBInterfaceOrientation() : origStatusBarOrientation(self, _cmd);
}

void HBInstallDeviceHooks(void) {
    HBConfig *config = HBConfig.shared;
    gSpoofDevice = config.spoofDevice;
    gSpoofIdiom = config.spoofIdiom;
    gLandscape = config.landscape;
    strlcpy(gMachine, config.deviceMachine.UTF8String, sizeof gMachine);

    Class device = UIDevice.class;
    origModel = (HBGetter)HBSwizzle(device, @selector(model), (IMP)hb_model);
    origLocalizedModel = (HBGetter)HBSwizzle(device, @selector(localizedModel), (IMP)hb_localizedModel);
    origName = (HBGetter)HBSwizzle(device, @selector(name), (IMP)hb_name);
    origSystemName = (HBGetter)HBSwizzle(device, @selector(systemName), (IMP)hb_systemName);
    origDeviceIdiom = (void *)HBSwizzle(device, @selector(userInterfaceIdiom), (IMP)hb_deviceIdiom);
    origTraitIdiom = (void *)HBSwizzle(UITraitCollection.class, @selector(userInterfaceIdiom), (IMP)hb_traitIdiom);
    origDeviceOrientation = (void *)HBSwizzle(device, @selector(orientation), (IMP)hb_deviceOrientation);
    origSceneOrientation = (void *)HBSwizzle(UIWindowScene.class, @selector(interfaceOrientation), (IMP)hb_sceneOrientation);
    origStatusBarOrientation = (void *)HBSwizzle(UIApplication.class, @selector(statusBarOrientation), (IMP)hb_statusBarOrientation);
    if (@available(iOS 16.0, *)) {
        origGeometryOrientation = (void *)HBSwizzle(UIWindowSceneGeometry.class, @selector(interfaceOrientation),
                                                    (IMP)hb_geometryOrientation);
    }
}
