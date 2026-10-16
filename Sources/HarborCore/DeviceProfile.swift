import Foundation

/// The device an app is told it is running on. The runtime reports these values to app code only;
/// system frameworks still see the real Mac.
public struct DeviceProfile: Codable, Hashable, Identifiable, Sendable {
    public enum Idiom: String, Codable, Sendable { case phone, pad }

    public var id: String
    public var name: String
    /// UIDevice.model ("iPhone" / "iPad").
    public var model: String
    /// hw.machine / utsname.machine, e.g. "iPhone18,1".
    public var machine: String
    public var idiom: Idiom
    /// Portrait screen size in points.
    public var width: Double
    public var height: Double
    public var scale: Double
    public var systemVersion: String

    public static let all: [DeviceProfile] = [
        DeviceProfile(id: "iphone-17-pro", name: "iPhone 17 Pro", model: "iPhone", machine: "iPhone18,1",
                      idiom: .phone, width: 402, height: 874, scale: 3, systemVersion: "27.0"),
        DeviceProfile(id: "iphone-17-pro-max", name: "iPhone 17 Pro Max", model: "iPhone", machine: "iPhone18,2",
                      idiom: .phone, width: 440, height: 956, scale: 3, systemVersion: "27.0"),
        DeviceProfile(id: "iphone-16", name: "iPhone 16", model: "iPhone", machine: "iPhone17,3",
                      idiom: .phone, width: 393, height: 852, scale: 3, systemVersion: "27.0"),
        DeviceProfile(id: "iphone-se-3", name: "iPhone SE (3rd generation)", model: "iPhone", machine: "iPhone14,6",
                      idiom: .phone, width: 375, height: 667, scale: 2, systemVersion: "26.0"),
        DeviceProfile(id: "ipad-pro-13-m4", name: "iPad Pro 13-inch (M4)", model: "iPad", machine: "iPad16,5",
                      idiom: .pad, width: 1032, height: 1376, scale: 2, systemVersion: "27.0"),
        DeviceProfile(id: "ipad-air-11-m2", name: "iPad Air 11-inch (M2)", model: "iPad", machine: "iPad14,8",
                      idiom: .pad, width: 820, height: 1180, scale: 2, systemVersion: "27.0"),
        DeviceProfile(id: "ipad-mini-a17", name: "iPad mini (A17 Pro)", model: "iPad", machine: "iPad16,1",
                      idiom: .pad, width: 744, height: 1133, scale: 2, systemVersion: "27.0"),
    ]

    public static let defaultPhone = all[0]
    public static let defaultPad = all[5]

    public static func named(_ id: String) -> DeviceProfile? { all.first { $0.id == id } }
}
