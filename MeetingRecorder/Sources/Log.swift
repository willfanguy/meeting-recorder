import Foundation

/// Simple logging to stderr (stdout is reserved for status output).
func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(timestamp)] \(message)\n".utf8))
}
