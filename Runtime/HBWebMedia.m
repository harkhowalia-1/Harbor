// Web media: under Mac Catalyst, WKWebView has no navigator.mediaDevices, MediaStream or
// MediaRecorder (a native macOS web view in the same bundle has them), so web-based apps can't use
// the camera or microphone. When the app creates a web view of its own, this loads
// libHarborWebMedia.dylib (Runtime/WebMedia, which links AVFoundation and WebKit, so apps without
// web views never load it) and lets it add getUserMedia and the rest to that web view.
#import "HBRuntime.h"
#import <WebKit/WebKit.h>
#import <dlfcn.h>
#import <execinfo.h>

static void (*sAttach)(WKUserContentController *);

/// libHarborWebMedia.dylib lives next to this library.
static BOOL HBLoadWebMedia(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (!dladdr((const void *)HBLoadWebMedia, &info) || !info.dli_fname) return;
        NSString *path = [[@(info.dli_fname) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"libHarborWebMedia.dylib"];
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW);
        if (!handle) return HBLog(@"Web media unavailable: %s", dlerror());
        sAttach = dlsym(handle, "HBWebMediaAttach");
    });
    return sAttach != NULL;
}

/// True when the web view is being created by the app: its own code is the first caller outside
/// WebKit, UIKit and the Objective-C runtime (so `WKWebView()` and nib loading count, while web
/// views that system frameworks create on their own don't).
static BOOL HBCreatedByApp(void) {
    void *frames[16];
    int count = backtrace(frames, 16);
    for (int i = 0; i < count; i++) {
        if (HBAddressIsAppCode(frames[i])) return YES;
        Dl_info info;
        if (!dladdr(frames[i], &info) || !info.dli_fname) return NO;
        const char *path = info.dli_fname;
        if (strstr(path, "/libHarborRuntime")) continue; // these hooks
        if (!strstr(path, "/WebKit.framework/") && !strstr(path, "/UIKitCore.framework/") && !strstr(path, "/libobjc.") &&
            !strstr(path, "/libswiftWebKit") && !strstr(path, "/libswiftUIKit")) return NO;
    }
    return NO;
}

static BOOL HBWantsWebMedia(void) {
    return !getenv("HARBOR_NO_WEBMEDIA") && HBCreatedByApp() && HBLoadWebMedia();
}

static id (*origInitFrame)(id, SEL, CGRect, WKWebViewConfiguration *);
static id (*origInitCoder)(id, SEL, NSCoder *);

static id hb_initFrame(WKWebView *self, SEL _cmd, CGRect frame, WKWebViewConfiguration *configuration) {
    // Configurations are copied, but the content controller is shared, so adding first is enough.
    if (HBWantsWebMedia()) sAttach(configuration.userContentController);
    return origInitFrame(self, _cmd, frame, configuration);
}

static id hb_initCoder(WKWebView *self, SEL _cmd, NSCoder *coder) {
    BOOL wanted = HBWantsWebMedia();
    WKWebView *view = origInitCoder(self, _cmd, coder);
    if (wanted) sAttach(view.configuration.userContentController);
    return view;
}

void HBInstallWebMediaHooks(void) {
    Class webView = NSClassFromString(@"WKWebView");
    if (!webView || !NSClassFromString(@"WKContentWorld")) return;
    origInitFrame = (void *)HBSwizzle(webView, @selector(initWithFrame:configuration:), (IMP)hb_initFrame);
    origInitCoder = (void *)HBSwizzle(webView, @selector(initWithCoder:), (IMP)hb_initCoder);
}
