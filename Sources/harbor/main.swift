import Foundation
import HarborCore

let usage = """
harbor: run iPhone and iPad apps as native Mac apps.

USAGE
  harbor convert <app.ipa|App.app> [options]   Convert and install into /Applications
      --device <id>        Device profile to present (see `harbor devices`)
      --name <name>        Name in /Applications, the Dock and Spotlight
      --bundle-id <id>     Use a different bundle id (keeps data apart from an official copy)
      --dest <dir>         Install somewhere other than /Applications
      --sign <identity>    Codesigning identity (default: ad hoc)
      --keep-extensions    Keep PlugIns/ (app extensions are removed by default)
      --no-runtime         Do not inject the Harbor runtime
  harbor inspect <app.ipa|App.app>             Check compatibility without converting
  harbor list                                  List converted apps
  harbor devices                               List device profiles
  harbor settings <app> [options]              Show or change an app's runtime settings
      --device <id>  --orientation auto|portrait|landscape  --scale <n>
      --motion off|keyboard|controller|mouse  --resizable on|off  --aspect locked|free  --keymapping on|off
      --hints on|off  --spoof-device on|off  --spoof-screen on|off  --spoof-idiom on|off
      --keychain-emulation on|off  --reset-keymap
  harbor open <app>                            Launch a converted app
  harbor remove <app> [--delete-data]          Move a converted app (and optionally its data) to the Trash

<app> is a bundle id, a name, or a path.
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

/// Minimal flag parser: `--flag value` pairs, bare `--switch`es and positional arguments.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var switches: Set<String> = []

    init(_ raw: ArraySlice<String>, switches known: Set<String>) throws {
        var it = raw.makeIterator()
        while let arg = it.next() {
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                if known.contains(key) {
                    switches.insert(key)
                } else {
                    guard let value = it.next() else { throw CLIError("\(arg) needs a value") }
                    options[key] = value
                }
            } else {
                positional.append(arg)
            }
        }
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = options[key] else { return nil }
        switch value.lowercased() {
        case "on", "yes", "true", "1": return true
        case "off", "no", "false", "0": return false
        default: throw CLIError("--\(key) takes on or off")
        }
    }
}

func resolveApp(_ query: String?) throws -> InstalledApp {
    guard let query else { throw CLIError("Name the app (bundle id, name or path). See `harbor list`.") }
    guard let app = AppLibrary.find(query) else { throw CLIError("No converted app matches '\(query)'. See `harbor list`.") }
    return app
}

func printSettings(_ s: AppSettings, for app: InstalledApp) {
    let store = AppStore(bundleID: app.bundleID)
    print("""
    \(app.name) (\(app.bundleID))
      device             \(s.device.id)  [\(s.device.name), \(Int(s.device.width))×\(Int(s.device.height)) pt]
      orientation        \(s.orientation.rawValue)
      window scale       \(s.windowScale)
      resizable          \(s.resizable ? "on" : "off")
      aspect ratio       \(s.freeAspect ? "free" : "locked")\(s.freeAspect && !s.resizable ? "  (needs resizable on)" : "")
      motion             \(s.motion.rawValue)
      keymapping         \(s.keymapping ? "on" : "off")  (\(store.keymapElementCount()) mapped controls)
      keymap hints       \(s.showKeymapHints ? "on" : "off")
      spoof device       \(s.spoofDevice ? "on" : "off")
      spoof screen       \(s.spoofScreen ? "on" : "off")
      spoof idiom        \(s.spoofIdiom ? "on" : "off")
      keychain emulation \(s.keychainEmulation ? "on" : "off")
    """)
}

func run() throws {
    let argv = CommandLine.arguments
    guard argv.count > 1 else { print(usage); return }
    let command = argv[1]
    let rest = argv.dropFirst(2)

    switch command {
    case "convert":
        let args = try Arguments(rest, switches: ["keep-extensions", "no-runtime"])
        guard let path = args.positional.first else { throw CLIError("convert needs an .ipa or .app") }
        var options = ConversionOptions(source: URL(fileURLWithPath: path).standardizedFileURL)
        options.deviceProfileID = args.options["device"]
        options.nameOverride = args.options["name"]
        options.bundleIDOverride = args.options["bundle-id"]
        if let dest = args.options["dest"] { options.destinationDirectory = URL(fileURLWithPath: dest, isDirectory: true) }
        if let identity = args.options["sign"] { options.signingIdentity = identity }
        options.keepExtensions = args.switches.contains("keep-extensions")
        options.injectRuntime = !args.switches.contains("no-runtime")
        let result = try Converter(options: options) { print("• \($0)") }.run()
        for warning in result.warnings { print("⚠︎ \(warning)") }
        print("✓ \(result.app.name) is ready. Open it from Launchpad, Spotlight or \(result.app.path)")

    case "inspect":
        guard let path = rest.first else { throw CLIError("inspect needs an .ipa or .app") }
        let r = try Inspector.inspect(URL(fileURLWithPath: path).standardizedFileURL)
        let families = r.deviceFamilies.map { $0 == 1 ? "iPhone" : $0 == 2 ? "iPad" : "\($0)" }.joined(separator: ", ")
        print("""
        \(r.name) \(r.version) (\(r.bundleID))
          devices     \(families)
          platform    \(r.platform), minimum OS \(r.minimumOS)
          binaries    \(r.binaryCount)
          encrypted   \(r.encrypted ? "yes" : "no")
        """)
        if !r.missingLibraries.isEmpty {
            print("  not on macOS (will be weak-linked):")
            r.missingLibraries.forEach { print("    \($0)") }
        }
        r.warnings.forEach { print("⚠︎ \($0)") }
        if r.canConvert { print("✓ Can be converted") } else { r.problems.forEach { print("✗ \($0)") } }

    case "list":
        let apps = AppLibrary.installedApps()
        if apps.isEmpty { print("No converted apps yet. Try: harbor convert MyApp.ipa"); return }
        for app in apps {
            let status = app.isPresent ? "" : "  (missing)"
            print("\(app.name)\t\(app.version)\t\(app.bundleID)\t\(app.path)\(status)")
        }

    case "devices":
        for p in DeviceProfile.all {
            print("\(p.id.padding(toLength: 20, withPad: " ", startingAt: 0))\(p.name) — \(Int(p.width))×\(Int(p.height)) pt @\(Int(p.scale))x, \(p.machine)")
        }

    case "settings":
        let args = try Arguments(rest, switches: ["reset-keymap"])
        let app = try resolveApp(args.positional.first)
        let store = AppStore(bundleID: app.bundleID)
        var s = store.loadSettings() ?? AppSettings(device: .defaultPhone)
        let before = s
        if let id = args.options["device"] {
            guard let profile = DeviceProfile.named(id) else { throw CLIError("Unknown device '\(id)'. See `harbor devices`.") }
            s.device = profile
        }
        if let o = args.options["orientation"] {
            guard let value = AppSettings.Orientation(rawValue: o) else { throw CLIError("--orientation takes auto, portrait or landscape") }
            s.orientation = value
        }
        if let m = args.options["motion"] {
            guard let value = AppSettings.MotionSource(rawValue: m) else { throw CLIError("--motion takes off, keyboard, controller or mouse") }
            s.motion = value
        }
        if let scale = args.options["scale"] {
            guard let value = Double(scale), value >= 0.25, value <= 4 else { throw CLIError("--scale takes a number from 0.25 to 4") }
            s.windowScale = value
        }
        s.resizable = try args.bool("resizable") ?? s.resizable
        if let aspect = args.options["aspect"] {
            guard ["locked", "free"].contains(aspect) else { throw CLIError("--aspect takes locked or free") }
            s.freeAspect = aspect == "free"
            // A free shape only means something for a window that can be resized.
            if s.freeAspect && args.options["resizable"] == nil { s.resizable = true }
        }
        s.keymapping = try args.bool("keymapping") ?? s.keymapping
        s.showKeymapHints = try args.bool("hints") ?? s.showKeymapHints
        s.spoofDevice = try args.bool("spoof-device") ?? s.spoofDevice
        s.spoofScreen = try args.bool("spoof-screen") ?? s.spoofScreen
        s.spoofIdiom = try args.bool("spoof-idiom") ?? s.spoofIdiom
        s.keychainEmulation = try args.bool("keychain-emulation") ?? s.keychainEmulation
        if args.switches.contains("reset-keymap") { try store.resetKeymap() }
        if s != before {
            try store.save(s)
            print("Saved. Quit and reopen \(app.name) to apply.")
        }
        printSettings(s, for: app)

    case "open":
        try AppLibrary.launch(try resolveApp(rest.first))

    case "remove":
        let args = try Arguments(rest, switches: ["delete-data"])
        let app = try resolveApp(args.positional.first)
        let notes = try AppLibrary.uninstall(app, removeData: args.switches.contains("delete-data"))
        notes.forEach { print("⚠︎ \($0)") }
        print("Moved \(app.name) to the Trash\(args.switches.contains("delete-data") ? " with its data" : "").")

    case "help", "--help", "-h":
        print(usage)

    default:
        throw CLIError("Unknown command '\(command)'.\n\n\(usage)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("harbor: \(error)\n".utf8))
    exit(1)
}
