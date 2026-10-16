// Harbor Diagnostics: an iPhone-only test app. It prints what an iOS app sees about its
// device, screen, storage, keychain, motion and controllers, and logs every touch and key,
// so a converted copy shows whether Harbor's runtime is doing its job.
import CoreMotion
import GameController
import Security
import UIKit

func emit(_ tag: String, _ message: String) {
    print("HARBOR-\(tag) \(message)")
    fflush(stdout)
    NSLog("HARBOR-%@ %@", tag, message)
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
    return String(cString: buffer)
}

func unameMachine() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

/// Add, read back and delete a generic password; returns "ok" or the failing OSStatus.
func keychainRoundTrip() -> String {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "app.harbor.diagnostics",
                                kSecAttrAccount as String: "probe"]
    SecItemDelete(query as CFDictionary)
    var add = query
    add[kSecValueData as String] = Data("secret-42".utf8)
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else { return "add=\(addStatus)" }
    var read = query
    read[kSecReturnData as String] = true
    read[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let readStatus = SecItemCopyMatching(read as CFDictionary, &result)
    guard readStatus == errSecSuccess, let data = result as? Data else { return "read=\(readStatus)" }
    let deleteStatus = SecItemDelete(query as CFDictionary)
    guard deleteStatus == errSecSuccess else { return "delete=\(deleteStatus)" }
    return String(decoding: data, as: UTF8.self) == "secret-42" ? "ok" : "mismatch"
}

func sizeString(_ s: CGSize) -> String { "\(Int(s.width))x\(Int(s.height))" }

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        emit("LAUNCH", "pid=\(getpid())")
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = DiagnosticsViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

final class TouchCanvas: UIView {
    private var dots: [ObjectIdentifier: CGPoint] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    private func log(_ phase: String, _ touches: Set<UITouch>) {
        for touch in touches {
            let p = touch.location(in: self)
            emit("TOUCH", "\(phase) x=\(Int(p.x)) y=\(Int(p.y)) type=\(touch.type.rawValue) active=\(dots.count)")
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.forEach { dots[ObjectIdentifier($0)] = $0.location(in: self) }
        log("began", touches)
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.forEach { dots[ObjectIdentifier($0)] = $0.location(in: self) }
        log("moved", touches)
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.forEach { dots[ObjectIdentifier($0)] = nil }
        log("ended", touches)
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.forEach { dots[ObjectIdentifier($0)] = nil }
        log("cancelled", touches)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        UIColor.systemOrange.withAlphaComponent(0.8).setFill()
        for p in dots.values {
            UIBezierPath(ovalIn: CGRect(x: p.x - 28, y: p.y - 28, width: 56, height: 56)).fill()
        }
    }
}

final class DiagnosticsViewController: UIViewController {
    private let label = UILabel()
    private let canvas = TouchCanvas()
    private let ball = UIView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
    private let motion = CMMotionManager()
    private var motionSamples = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        ball.backgroundColor = .systemBlue
        ball.layer.cornerRadius = 12
        view.addSubview(label)
        view.addSubview(canvas)
        view.addSubview(ball)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
            let controller = note.object as? GCController
            emit("CONTROLLER", "connected \(controller?.vendorName ?? "?")")
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.runDiagnostics() }
        startMotion()
    }

    private func runDiagnostics() {
        let screen = UIScreen.main
        let device = UIDevice.current
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let probe = docs.appendingPathComponent("probe.txt")
        let canWrite = (try? "hello".write(to: probe, atomically: true, encoding: .utf8)) != nil
        UserDefaults.standard.set(42, forKey: "probe")
        let report: [(String, String)] = [
            ("screen.bounds", sizeString(screen.bounds.size)),
            ("screen.nativeBounds", sizeString(screen.nativeBounds.size)),
            ("screen.scale", "\(screen.scale)"),
            ("window.bounds", sizeString(view.window?.bounds.size ?? .zero)),
            ("device.model", device.model),
            ("device.systemName", device.systemName),
            ("device.systemVersion", device.systemVersion),
            ("device.idiom", "\(device.userInterfaceIdiom.rawValue)"),
            ("trait.idiom", "\(traitCollection.userInterfaceIdiom.rawValue)"),
            ("hw.machine", sysctlString("hw.machine")),
            ("uname.machine", unameMachine()),
            ("orientation", "\(view.window?.windowScene?.effectiveGeometry.interfaceOrientation.rawValue ?? -1)"),
            ("isiOSAppOnMac", "\(ProcessInfo.processInfo.isiOSAppOnMac)"),
            ("isMacCatalystApp", "\(ProcessInfo.processInfo.isMacCatalystApp)"),
            ("home", NSHomeDirectory()),
            ("documents.writable", "\(canWrite)"),
            ("defaults", "\(UserDefaults.standard.integer(forKey: "probe"))"),
            ("keychain", keychainRoundTrip()),
            ("motion.accelerometer", "\(motion.isAccelerometerAvailable)"),
            ("motion.deviceMotion", "\(motion.isDeviceMotionAvailable)"),
            ("controllers", "\(GCController.controllers().count)"),
        ]
        for (key, value) in report { emit("DIAG", "\(key)=\(value)") }
        emit("DIAG", "done")
        label.text = report.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }

    private func startMotion() {
        guard motion.isAccelerometerAvailable else { return }
        motion.accelerometerUpdateInterval = 1.0 / 30
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            let bounds = self.view.bounds
            self.ball.center = CGPoint(x: bounds.midX + CGFloat(a.x) * bounds.width / 2,
                                       y: bounds.midY - CGFloat(a.y) * bounds.height / 2)
            self.motionSamples += 1
            if self.motionSamples % 30 == 1 {
                emit("MOTION", String(format: "x=%.2f y=%.2f z=%.2f", a.x, a.y, a.z))
            }
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { emit("KEY", "down \(press.key?.keyCode.rawValue ?? -1)") }
        super.pressesBegan(presses, with: event)
    }
}
