// Self-test, for development only: HARBOR_SELFTEST=touch,keys,motion,editor,resize,webmedia exercises the
// runtime from inside a converted app so its effects can be checked in the app's own logs.
#import "HBRuntime.h"
#import <WebKit/WebKit.h>

static void HBAfter(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

static void HBAppendViewTree(NSMutableString *tree, UIView *view, int depth) {
    [tree appendFormat:@"\n  %*s%@ %.0fx%.0f", depth * 2, "", NSStringFromClass(view.class),
                       view.bounds.size.width, view.bounds.size.height];
    if (depth < 3) {
        for (UIView *sub in view.subviews) HBAppendViewTree(tree, sub, depth + 1);
    }
}

/// The scene, the NSWindow and the first levels of the app's views, with their sizes.
static void HBLogViewSizes(NSString *label) {
    UIWindow *window = HBAppWindow();
    NSMutableString *tree = [NSMutableString string];
    if (window) HBAppendViewTree(tree, window, 0);
    CGSize scene = window.windowScene.coordinateSpace.bounds.size, content = CGSizeZero;
    [HBBridge windowContentSize:&content];
    HBLog(@"Self-test %@: scene %.0fx%.0f, NSWindow content %.0fx%.0f, screen spoof %.0fx%.0f%@", label,
          scene.width, scene.height, content.width, content.height,
          HBSpoofedScreenSize().width, HBSpoofedScreenSize().height, tree);
}

/// Resizes the window as a user would, to a size in UIKit points.
static void HBResizeTo(CGSize size) API_AVAILABLE(ios(16.0)) {
    UIWindowScene *scene = HBAppWindow().windowScene;
    CGSize content, current = scene.coordinateSpace.bounds.size;
    CGFloat f = [HBBridge windowContentSize:&content] && current.width > 1 ? content.width / current.width : 0.77;
    CGRect frame = scene.effectiveGeometry.systemFrame;
    frame.size = CGSizeMake(round(size.width * f), round(size.height * f));
    UIWindowSceneGeometryPreferencesMac *prefs = [[UIWindowSceneGeometryPreferencesMac alloc] initWithSystemFrame:frame];
    [scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *error) {
        HBLog(@"Self-test resize refused: %@", error.localizedDescription);
    }];
    HBLog(@"Self-test resize: asked for %.0fx%.0f", size.width, size.height);
}

static WKWebView *HBFindWebView(UIView *view) {
    if ([view isKindOfClass:NSClassFromString(@"WKWebView")]) return (WKWebView *)view;
    for (UIView *sub in view.subviews) {
        WKWebView *found = HBFindWebView(sub);
        if (found) return found;
    }
    return nil;
}

/// Drives camera, microphone, Web Audio and MediaRecorder from the app's own web view and logs the results.
static NSString *const HBWebMediaTest = @R"JS(
const sleep = ms => new Promise(r => setTimeout(r, ms));
const out = [];
const step = async (name, fn) => { try { out.push(`${name}: ${await fn()}`); } catch (e) { out.push(`${name}: FAILED ${e.name}: ${e.message}`); } };
const s = await navigator.mediaDevices.getUserMedia({ video: { width: { ideal: 1280 } }, audio: true });
out.push('tracks ' + s.getTracks().map(t => `${t.kind}:${t.label}:${t.readyState}`).join(', '));
const v = document.createElement('video'); v.muted = true; v.playsInline = true; v.srcObject = s; await v.play();
let peak = 0, heard = 0;
const micSource = s.getAudioTracks()[0]._source;
if (micSource) micSource.listeners.add(d => { heard += d.length; for (const x of d) peak = Math.max(peak, Math.abs(x)); });
const ctx = new AudioContext(), analyser = ctx.createAnalyser();
ctx.createMediaStreamSource(s).connect(analyser);
await sleep(1500);
const c = document.createElement('canvas'); c.width = v.videoWidth; c.height = v.videoHeight;
const g = c.getContext('2d'); g.drawImage(v, 0, 0);
const d = g.getImageData(0, 0, c.width, c.height).data; let sum = 0;
for (let i = 0; i < d.length; i += 4) sum += d[i] + d[i + 1] + d[i + 2];
out.push(`video ${c.width}x${c.height} mean ${(sum / (d.length / 4 * 3)).toFixed(1)}`);
const wave = new Float32Array(analyser.fftSize); analyser.getFloatTimeDomainData(wave);
out.push(`mic ${heard} samples, peak ${peak.toFixed(4)}`);
out.push(`mic rms ${Math.sqrt(wave.reduce((a, x) => a + x * x, 0) / wave.length).toFixed(4)} (context ${ctx.state})`);
const record = async (stream, ms, options, slice, pauseFor) => {
  const r = new MediaRecorder(stream, options), chunks = [];
  r.ondataavailable = e => { if (e.data.size) chunks.push(e.data); };
  const stopped = new Promise(res => { r.onstop = res; });
  r.start(slice);
  if (pauseFor) { await sleep(ms / 2); r.pause(); await sleep(pauseFor); r.resume(); await sleep(ms / 2); } else await sleep(ms);
  r.stop(); await stopped;
  return { blob: new Blob(chunks, { type: r.mimeType }), chunks: chunks.length };
};
const plays = blob => new Promise(res => {
  const m = document.createElement(blob.type.startsWith('video') ? 'video' : 'audio');
  m.preload = 'metadata';
  m.onloadedmetadata = () => res(`${m.duration.toFixed(1)}s${m.videoWidth ? ` ${m.videoWidth}x${m.videoHeight}` : ''}`);
  m.onerror = () => res('unplayable ' + (m.error && m.error.code));
  m.src = URL.createObjectURL(blob);
  setTimeout(() => res('no metadata'), 5000);
});
await step('camera+mic', async () => { const a = await record(s, 2500); return `${a.blob.type} ${a.blob.size} bytes, ${await plays(a.blob)}`; });
await step('mic slices', async () => { const b = await record(new MediaStream(s.getAudioTracks()), 3000, { mimeType: 'audio/mp4' }, 1000);
  return `${b.chunks} chunks, ${b.blob.size} bytes, ${await plays(b.blob)}`; });
await step('camera slices', async () => { const b = await record(s, 2500, undefined, 1000);
  return `${b.chunks} chunks, ${b.blob.size} bytes, ${await plays(b.blob)}`; });
await step('paused 1.5 s of 3.5 s', async () => { const p = await record(s, 2000, undefined, undefined, 1500); return plays(p.blob); });
const canvas = document.createElement('canvas'); canvas.width = 320; canvas.height = 240;
const cg = canvas.getContext('2d'); let n = 0;
const paint = setInterval(() => { cg.fillStyle = `hsl(${n++ * 10}, 80%, 50%)`; cg.fillRect(0, 0, 320, 240); }, 33);
const dest = ctx.createMediaStreamDestination(), tone = ctx.createOscillator(); tone.connect(dest); tone.start();
const mixed = new MediaStream([...canvas.captureStream(30).getVideoTracks(), ...dest.stream.getAudioTracks()]);
await step('canvas+WebAudio', async () => { const m = await record(mixed, 2000); return `${m.blob.size} bytes, ${await plays(m.blob)}`; });
clearInterval(paint); tone.stop();
await step('ImageCapture', async () => `${(await new ImageCapture(s.getVideoTracks()[0]).takePhoto()).size} bytes`);
out.push('devices ' + (await navigator.mediaDevices.enumerateDevices()).map(x => `${x.kind}:${x.label}`).join(', '));
if (navigator.permissions) out.push('permission microphone ' + (await navigator.permissions.query({ name: 'microphone' })).state);
s.getTracks().forEach(t => t.stop()); ctx.close();
return out.join('\n  ');
)JS";

static void HBTestWebMedia(void) {
    WKWebView *webView = HBFindWebView(HBAppWindow());
    if (!webView) return HBLog(@"Self-test webmedia: no web view in the app window");
    HBLog(@"Self-test webmedia: in %@", webView.URL);
    [webView callAsyncJavaScript:HBWebMediaTest arguments:@{} inFrame:nil inContentWorld:[NSClassFromString(@"WKContentWorld") pageWorld]
               completionHandler:^(id result, NSError *error) {
        HBLog(@"Self-test webmedia:\n  %@", error ? error.userInfo[@"WKJavaScriptExceptionMessage"] ?: error : result);
    }];
}

void HBRunSelfTest(NSString *mode) {
    HBLog(@"Self-test scheduled: %@", mode);
    if ([mode containsString:@"webmedia"]) {
        HBAfter(4.0, ^{ HBTestWebMedia(); });
        return;
    }
    if ([mode containsString:@"resize"]) {
        // Grow, then change the shape, logging what the app's views did after each.
        HBAfter(2.0, ^{
            HBLogViewSizes(@"before resize");
            CGSize size = HBAppWindow().bounds.size;
            if (@available(iOS 16.0, *)) HBResizeTo(CGSizeMake(round(size.width * 1.25), round(size.height * 1.25)));
        });
        HBAfter(3.5, ^{ HBLogViewSizes(@"after growing"); });
        HBAfter(4.0, ^{
            CGSize size = HBAppWindow().bounds.size;
            if (@available(iOS 16.0, *)) HBResizeTo(CGSizeMake(round(size.width * 0.6), round(size.height * 0.75)));
        });
        HBAfter(5.5, ^{ HBLogViewSizes(@"after reshaping"); });
        return;
    }
    HBAfter(2.0, ^{
        UIWindow *window = HBAppWindow();
        CGSize size = window.bounds.size;
        HBLog(@"Self-test window %.0fx%.0f, screen spoof %.0fx%.0f", size.width, size.height,
              HBSpoofedScreenSize().width, HBSpoofedScreenSize().height);

        if ([mode containsString:@"touch"]) {
            CGPoint start = CGPointMake(size.width / 2, size.height * 0.35);
            NSInteger finger = [HBTouchInjector.shared beginAt:start];
            HBLog(@"Self-test touch: finger %ld at %.0f,%.0f", (long)finger, start.x, start.y);
            HBAfter(0.15, ^{ [HBTouchInjector.shared moveFinger:finger to:CGPointMake(start.x + 40, start.y + 60)]; });
            HBAfter(0.30, ^{ [HBTouchInjector.shared endFinger:finger]; });
        }
    });
    HBAfter(3.0, ^{
        if ([mode containsString:@"keys"]) {
            // Map F (key code 3) to a button, then press F and G through the AppKit event queue.
            // F must arrive as a touch and never as a key; unmapped G must reach the app as a key.
            HBKeymap.shared.elements = @[[@{@"type": @"button", @"x": @0.5, @"y": @0.7, @"key": @3,
                                            @"label": @"F"} mutableCopy]];
            HBLog(@"Self-test keys: pressing F (mapped) and G (unmapped)");
            [HBBridge postKey:3 down:YES];
            HBAfter(0.3, ^{ [HBBridge postKey:3 down:NO]; });
            HBAfter(0.5, ^{ [HBBridge postKey:5 down:YES]; });
            HBAfter(0.6, ^{ [HBBridge postKey:5 down:NO]; });
        }
    });
    HBAfter(4.5, ^{
        if ([mode containsString:@"motion"]) {
            HBLog(@"Self-test motion: holding → for 1.5 s");
            [HBBridge postKey:124 down:YES];
            HBAfter(1.5, ^{ [HBBridge postKey:124 down:NO]; });
        }
    });
    if ([mode containsString:@"editclick"]) {
        // Drive the editor with real AppKit events: open it, click to add a button, bind F,
        // save with Esc, then press F and expect a touch where the button was placed.
        HBAfter(2.0, ^{ [HBOverlay.shared toggleEditor]; });
        HBAfter(2.5, ^{ [HBBridge postMouseAt:CGPointMake(0.3, 0.6) down:YES]; });
        HBAfter(2.6, ^{ [HBBridge postMouseAt:CGPointMake(0.3, 0.6) down:NO]; });
        HBAfter(3.0, ^{ [HBBridge postKey:3 down:YES]; });
        HBAfter(3.1, ^{ [HBBridge postKey:3 down:NO]; });
        HBAfter(3.5, ^{ [HBBridge postKey:53 down:YES]; });
        HBAfter(3.6, ^{ [HBBridge postKey:53 down:NO]; });
        HBAfter(4.0, ^{
            HBLog(@"Self-test editclick: keymap now %@", HBKeymap.shared.elements);
            [HBBridge postKey:3 down:YES];
        });
        HBAfter(4.3, ^{ [HBBridge postKey:3 down:NO]; });
        return;
    }
    HBAfter(7.0, ^{
        if ([mode containsString:@"editor"]) {
            HBLog(@"Self-test editor: opening");
            [HBOverlay.shared toggleEditor];
        }
    });
}
