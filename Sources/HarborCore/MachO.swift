import Foundation
import MachO

/// A packed Mach-O version number (xxxx.yy.zz in nibbles), as stored in LC_BUILD_VERSION.
public struct MachOVersion: Comparable, CustomStringConvertible, Sendable {
    public var raw: UInt32

    public init(raw: UInt32) { self.raw = raw }
    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        raw = UInt32(major) << 16 | UInt32(minor & 0xff) << 8 | UInt32(patch & 0xff)
    }

    public var major: Int { Int(raw >> 16) }
    public var minor: Int { Int((raw >> 8) & 0xff) }
    public var patch: Int { Int(raw & 0xff) }

    public var description: String { patch > 0 ? "\(major).\(minor).\(patch)" : "\(major).\(minor)" }
    public static func < (a: MachOVersion, b: MachOVersion) -> Bool { a.raw < b.raw }
}

public enum MachOPlatform: UInt32, Sendable {
    case unknown = 0, macOS = 1, iOS = 2, tvOS = 3, watchOS = 4, bridgeOS = 5
    case macCatalyst = 6, iOSSimulator = 7, tvOSSimulator = 8, watchOSSimulator = 9
    case driverKit = 10, visionOS = 11, visionOSSimulator = 12
}

public enum MachOError: Error, CustomStringConvertible {
    case notMachO(String)
    case unsupportedArchitecture(String)
    case encrypted(String)
    case simulatorBinary(String)
    case insufficientHeaderSpace(String, needed: Int, available: Int)
    case malformed(String)

    public var description: String {
        switch self {
        case .notMachO(let f): return "\(f) is not a Mach-O file"
        case .unsupportedArchitecture(let f): return "\(f) has no arm64 slice (32-bit iOS binaries cannot run on a Mac)"
        case .encrypted(let f):
            return "\(f) is FairPlay-encrypted. Harbor only converts decrypted apps: your own builds, ad-hoc/enterprise builds, or open-source apps."
        case .simulatorBinary(let f): return "\(f) was built for the iOS Simulator, not a device. Build for 'Any iOS Device (arm64)' instead."
        case .insufficientHeaderSpace(let f, let needed, let available):
            return "\(f) has only \(available) bytes free in its Mach-O header (\(needed) needed). Relink with -headerpad_max_install_names."
        case .malformed(let f): return "\(f) is a malformed Mach-O file"
        }
    }
}

/// Load-command constants (mirrors <mach-o/loader.h>; spelled out so the patcher reads on its own).
enum LC {
    static let segment64: UInt32 = 0x19
    static let loadDylib: UInt32 = 0xC
    static let idDylib: UInt32 = 0xD
    static let loadWeakDylib: UInt32 = 0x8000_0018
    static let reexportDylib: UInt32 = 0x8000_001F
    static let lazyLoadDylib: UInt32 = 0x20
    static let loadUpwardDylib: UInt32 = 0x8000_0023
    static let versionMinIPhoneOS: UInt32 = 0x25
    static let buildVersion: UInt32 = 0x32
    static let encryptionInfo64: UInt32 = 0x2C

    static let dylibLoaders: Set<UInt32> = [loadDylib, loadWeakDylib, reexportDylib, lazyLoadDylib, loadUpwardDylib]
}

/// A thin, 64-bit, little-endian arm64 Mach-O image loaded into memory for patching.
/// Fat inputs are thinned to their arm64 slice: a Mac only ever runs that slice.
public struct MachOBinary {
    public struct LoadCommand: Sendable {
        public let offset: Int
        public let cmd: UInt32
        public let size: Int
    }

    public struct DylibReference: Sendable {
        public let command: LoadCommand
        public let path: String
        public var isWeak: Bool { command.cmd == LC.loadWeakDylib }
    }

    public struct BuildVersion: Sendable {
        public let platform: MachOPlatform
        public let minOS: MachOVersion
        public let sdk: MachOVersion
    }

    static let headerSize = 32
    static let magic64: UInt32 = 0xFEED_FACF
    static let magic32: UInt32 = 0xFEED_FACE
    static let fatMagic: UInt32 = 0xCAFE_BABE
    static let fatMagic64: UInt32 = 0xCAFE_BABF
    static let cpuTypeARM64: UInt32 = 0x0100_000C

    public private(set) var bytes: [UInt8]
    public let name: String
    /// True when the source file was a universal binary and has been thinned.
    public let wasThinned: Bool

    // MARK: Detection and loading

    /// Cheap check on the first bytes; used to find every binary inside an app bundle.
    public static func isMachO(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count == 8 else { return false }
        let le = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if le == magic64 || le == magic32 { return true }
        let be = UInt32(bigEndian: le)
        if be == fatMagic || be == fatMagic64 {
            // Java class files share 0xCAFEBABE; a real fat header has a small arch count.
            let count = UInt32(bigEndian: head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
            return count > 0 && count < 16
        }
        return false
    }

    public init(contentsOf url: URL) throws {
        let data = try [UInt8](Data(contentsOf: url))
        try self.init(bytes: data, name: url.lastPathComponent)
    }

    public init(bytes data: [UInt8], name: String) throws {
        self.name = name
        guard data.count >= 8 else { throw MachOError.notMachO(name) }
        let le = MachOBinary.readU32(data, 0)
        let be = UInt32(bigEndian: le)
        if be == MachOBinary.fatMagic || be == MachOBinary.fatMagic64 {
            bytes = try MachOBinary.arm64Slice(of: data, is64: be == MachOBinary.fatMagic64, name: name)
            wasThinned = true
        } else if le == MachOBinary.magic64 {
            bytes = data
            wasThinned = false
        } else if le == MachOBinary.magic32 {
            throw MachOError.unsupportedArchitecture(name)
        } else {
            throw MachOError.notMachO(name)
        }
        guard u32(4) == MachOBinary.cpuTypeARM64 else { throw MachOError.unsupportedArchitecture(name) }
        guard MachOBinary.headerSize + Int(u32(20)) <= bytes.count else { throw MachOError.malformed(name) }
    }

    private static func arm64Slice(of data: [UInt8], is64: Bool, name: String) throws -> [UInt8] {
        let count = Int(UInt32(bigEndian: readU32(data, 4)))
        let entrySize = is64 ? 32 : 20
        var best: (offset: Int, size: Int, subtype: UInt32)?
        for i in 0..<count {
            let e = 8 + i * entrySize
            guard e + entrySize <= data.count else { throw MachOError.malformed(name) }
            let cpu = UInt32(bigEndian: readU32(data, e))
            let sub = UInt32(bigEndian: readU32(data, e + 4)) & 0x00FF_FFFF
            let offset: Int, size: Int
            if is64 {
                offset = Int(UInt64(bigEndian: readU64(data, e + 8)))
                size = Int(UInt64(bigEndian: readU64(data, e + 16)))
            } else {
                offset = Int(UInt32(bigEndian: readU32(data, e + 8)))
                size = Int(UInt32(bigEndian: readU32(data, e + 12)))
            }
            guard cpu == cpuTypeARM64 else { continue }
            // Prefer plain arm64 over arm64e: third-party arm64e code is not ABI-stable.
            if best == nil || (best!.subtype == 2 && sub != 2) { best = (offset, size, sub) }
        }
        guard let slice = best else { throw MachOError.unsupportedArchitecture(name) }
        guard slice.offset + slice.size <= data.count else { throw MachOError.malformed(name) }
        return Array(data[slice.offset..<(slice.offset + slice.size)])
    }

    // MARK: Header inspection

    public var fileType: UInt32 { u32(12) }
    public var isExecutable: Bool { fileType == 0x2 }
    var commandCount: Int { Int(u32(16)) }
    var commandsSize: Int { Int(u32(20)) }

    public var loadCommands: [LoadCommand] {
        var result: [LoadCommand] = []
        var offset = MachOBinary.headerSize
        for _ in 0..<commandCount {
            guard offset + 8 <= bytes.count else { break }
            let size = Int(u32(offset + 4))
            guard size >= 8 else { break }
            result.append(LoadCommand(offset: offset, cmd: u32(offset), size: size))
            offset += size
        }
        return result
    }

    public var buildVersion: BuildVersion? {
        for lc in loadCommands {
            if lc.cmd == LC.buildVersion {
                return BuildVersion(platform: MachOPlatform(rawValue: u32(lc.offset + 8)) ?? .unknown,
                                    minOS: MachOVersion(raw: u32(lc.offset + 12)),
                                    sdk: MachOVersion(raw: u32(lc.offset + 16)))
            }
            if lc.cmd == LC.versionMinIPhoneOS {
                return BuildVersion(platform: .iOS,
                                    minOS: MachOVersion(raw: u32(lc.offset + 8)),
                                    sdk: MachOVersion(raw: u32(lc.offset + 12)))
            }
        }
        return nil
    }

    /// The FairPlay crypt id: nil when the binary has no encryption command, 0 when decrypted.
    public var cryptID: UInt32? {
        loadCommands.first { $0.cmd == LC.encryptionInfo64 }.map { u32($0.offset + 16) }
    }

    public var linkedDylibs: [DylibReference] {
        loadCommands.filter { LC.dylibLoaders.contains($0.cmd) }.map { lc in
            DylibReference(command: lc, path: cString(at: lc.offset + Int(u32(lc.offset + 8)), limit: lc.offset + lc.size))
        }
    }

    /// File offset of the first byte of segment or section content; load commands may grow up to here.
    var firstContentOffset: Int {
        var first = bytes.count
        for lc in loadCommands where lc.cmd == LC.segment64 {
            let fileOffset = Int(u64(lc.offset + 40))
            let fileSize = u64(lc.offset + 48)
            if fileOffset > 0 && fileSize > 0 { first = min(first, fileOffset) }
            let sectionCount = Int(u32(lc.offset + 64))
            for i in 0..<sectionCount {
                let s = lc.offset + 72 + i * 80
                guard s + 80 <= lc.offset + lc.size else { break }
                let size = u64(s + 40)
                let offset = Int(u32(s + 48))
                let type = u32(s + 64) & 0xff
                let zeroFill = type == 0x1 || type == 0xC || type == 0x12
                if offset > 0 && size > 0 && !zeroFill { first = min(first, offset) }
            }
        }
        return first
    }

    /// Bytes available after the load commands for new commands.
    public var headerSlack: Int { firstContentOffset - MachOBinary.headerSize - commandsSize }

    // MARK: Patching

    /// Re-labels an iOS binary as Mac Catalyst so dyld maps UIKit & friends from /System/iOSSupport.
    /// Returns false if the binary already targets Catalyst or macOS.
    @discardableResult
    public mutating func convertToCatalyst(minimumOS floor: MachOVersion = MachOVersion(14, 0)) throws -> Bool {
        let name = self.name
        var changed = false
        var sawPlatform = false
        try rewriteCommands { lc, blob in
            switch lc.cmd {
            case LC.buildVersion:
                sawPlatform = true
                let platform = MachOPlatform(rawValue: blob.u32(8)) ?? .unknown
                switch platform {
                case .iOSSimulator: throw MachOError.simulatorBinary(name)
                case .iOS:
                    let minOS = max(MachOVersion(raw: blob.u32(12)), floor)
                    blob.setU32(8, MachOPlatform.macCatalyst.rawValue)
                    blob.setU32(12, minOS.raw)
                    blob.setU32(16, max(MachOVersion(raw: blob.u32(16)), minOS).raw)
                    changed = true
                default: break
                }
            case LC.versionMinIPhoneOS:
                // Pre-iOS 12 binaries carry the older 16-byte command; it grows to a 24-byte LC_BUILD_VERSION.
                sawPlatform = true
                let minOS = max(MachOVersion(raw: blob.u32(8)), floor)
                let sdk = max(MachOVersion(raw: blob.u32(12)), minOS)
                blob = MachOBinary.buildVersionCommand(minOS: minOS, sdk: sdk)
                changed = true
            default: break
            }
        } append: {
            guard !sawPlatform else { return [] }
            changed = true
            return [MachOBinary.buildVersionCommand(minOS: floor, sdk: floor)]
        }
        return changed
    }

    /// Turns a hard dependency into a weak one so a framework missing on macOS no longer stops launch.
    public mutating func weakLink(dylibPath: String) {
        for ref in linkedDylibs where ref.path == dylibPath && ref.command.cmd == LC.loadDylib {
            setU32(ref.command.offset, LC.loadWeakDylib)
        }
    }

    /// Appends an LC_LOAD_DYLIB. It goes last so the ordinals of existing imports stay valid.
    public mutating func addDylib(path: String) throws {
        guard !linkedDylibs.contains(where: { $0.path == path }) else { return }
        try rewriteCommands { _, _ in } append: {
            var name = Array(path.utf8) + [0]
            while (24 + name.count) % 8 != 0 { name.append(0) }
            var blob = Blob(size: 24 + name.count)
            blob.setU32(0, LC.loadDylib)
            blob.setU32(4, UInt32(24 + name.count))
            blob.setU32(8, 24)          // name offset
            blob.setU32(12, 2)          // timestamp
            blob.setU32(16, 0x0001_0000) // current version 1.0
            blob.setU32(20, 0x0001_0000) // compatibility version 1.0
            blob.bytes.replaceSubrange(24..<blob.bytes.count, with: name)
            return [blob]
        }
    }

    public func write(to url: URL) throws {
        try Data(bytes).write(to: url, options: .atomic)
    }

    // MARK: Load-command rewriting

    struct Blob {
        var bytes: [UInt8]
        init(size: Int) { bytes = [UInt8](repeating: 0, count: size) }
        init(_ bytes: ArraySlice<UInt8>) { self.bytes = Array(bytes) }
        func u32(_ o: Int) -> UInt32 { MachOBinary.readU32(bytes, o) }
        mutating func setU32(_ o: Int, _ v: UInt32) { MachOBinary.writeU32(&bytes, o, v) }
    }

    static func buildVersionCommand(minOS: MachOVersion, sdk: MachOVersion) -> Blob {
        var blob = Blob(size: 24)
        blob.setU32(0, LC.buildVersion)
        blob.setU32(4, 24)
        blob.setU32(8, MachOPlatform.macCatalyst.rawValue)
        blob.setU32(12, minOS.raw)
        blob.setU32(16, sdk.raw)
        blob.setU32(20, 0) // no tool entries
        return blob
    }

    /// Rebuilds the load-command area, letting `transform` edit (or resize) each command and
    /// `append` add new ones at the end, then writes it back if it fits before the first section.
    private mutating func rewriteCommands(_ transform: (LoadCommand, inout Blob) throws -> Void,
                                          append: () throws -> [Blob]) throws {
        var blobs: [Blob] = []
        for lc in loadCommands {
            var blob = Blob(bytes[lc.offset..<(lc.offset + lc.size)])
            try transform(lc, &blob)
            blobs.append(blob)
        }
        blobs += try append()
        let newArea = blobs.flatMap(\.bytes)
        let limit = firstContentOffset - MachOBinary.headerSize
        guard newArea.count <= limit else {
            throw MachOError.insufficientHeaderSpace(name, needed: newArea.count - commandsSize,
                                                     available: limit - commandsSize)
        }
        let oldSize = commandsSize
        bytes.replaceSubrange(MachOBinary.headerSize..<(MachOBinary.headerSize + newArea.count), with: newArea)
        if oldSize > newArea.count {
            let start = MachOBinary.headerSize + newArea.count
            bytes.replaceSubrange(start..<(MachOBinary.headerSize + oldSize),
                                  with: [UInt8](repeating: 0, count: oldSize - newArea.count))
        }
        setU32(16, UInt32(blobs.count))
        setU32(20, UInt32(newArea.count))
    }

    // MARK: Byte helpers

    func u32(_ o: Int) -> UInt32 { MachOBinary.readU32(bytes, o) }
    func u64(_ o: Int) -> UInt64 { MachOBinary.readU64(bytes, o) }
    mutating func setU32(_ o: Int, _ v: UInt32) { MachOBinary.writeU32(&bytes, o, v) }

    func cString(at start: Int, limit: Int) -> String {
        var end = start
        while end < min(limit, bytes.count) && bytes[end] != 0 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    static func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    static func readU64(_ b: [UInt8], _ o: Int) -> UInt64 {
        UInt64(readU32(b, o)) | UInt64(readU32(b, o + 4)) << 32
    }

    static func writeU32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        b[o] = UInt8(v & 0xff)
        b[o + 1] = UInt8((v >> 8) & 0xff)
        b[o + 2] = UInt8((v >> 16) & 0xff)
        b[o + 3] = UInt8((v >> 24) & 0xff)
    }
}

/// Answers "will dyld find this library when the process runs as Mac Catalyst?"
public enum SystemLibraryResolver {
    static let iOSSupportRoot = "/System/iOSSupport"

    public static func isAvailableToCatalyst(_ installName: String) -> Bool {
        // Only absolute system paths can be checked; @rpath etc. are resolved inside the bundle.
        guard installName.hasPrefix("/") else { return true }
        let candidates = [iOSSupportRoot + installName, installName]
        for path in candidates {
            if _dyld_shared_cache_contains_path(path) { return true }
            if FileManager.default.fileExists(atPath: path) { return true }
            // Framework binaries live only in the shared cache, but their bundle directory stays on disk.
            if let range = path.range(of: ".framework/") {
                let frameworkDir = String(path[..<range.lowerBound]) + ".framework"
                if FileManager.default.fileExists(atPath: frameworkDir) { return true }
            }
        }
        return false
    }
}
