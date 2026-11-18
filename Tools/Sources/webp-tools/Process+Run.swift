import Foundation

struct ToolFailure: Error, CustomStringConvertible {
    let description: String
}

struct ToolResult {
    let succeeded: Bool
    let output: String
}

/// Runs a program found on `PATH` and captures its combined output.
func runTool(_ name: String, _ arguments: [String]) throws -> ToolResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [name] + arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ToolResult(
        succeeded: process.terminationStatus == 0,
        output: String(decoding: data, as: UTF8.self)
    )
}

/// Runs a program and throws if it fails.
func requireTool(_ name: String, _ arguments: [String]) throws {
    let result = try runTool(name, arguments)
    guard result.succeeded else {
        throw ToolFailure(description: "\(name) failed: \(result.output)")
    }
}

/// Creates a temporary directory for the duration of `body`.
func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("webp-tools-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}
