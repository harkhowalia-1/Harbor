import Foundation

public enum Shell {
    public struct Failure: Error, CustomStringConvertible {
        public let command: String
        public let status: Int32
        public let output: String
        public var description: String {
            "\(command) failed (exit \(status)): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    /// Runs a tool to completion and returns its combined stdout and stderr.
    @discardableResult
    public static func run(_ tool: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        if process.terminationStatus != 0 && !allowFailure {
            let name = URL(fileURLWithPath: tool).lastPathComponent
            throw Failure(command: name, status: process.terminationStatus, output: output)
        }
        return output
    }
}
