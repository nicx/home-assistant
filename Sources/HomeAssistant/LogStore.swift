import Foundation

/// Captures Home Assistant's stdout/stderr (and the first-run pip install
/// output) into an in-memory ring buffer for the log window, and appends every
/// line to a log file on disk.
@MainActor
final class LogStore: ObservableObject {
    /// Most recent log lines, newest last. Capped at `capacity`.
    @Published private(set) var lines: [String] = []

    private let capacity = 4000
    private let fileHandle: FileHandle?
    let logFileURL: URL

    init() {
        let dir = LogStore.logDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logFileURL = dir.appendingPathComponent("home-assistant.log")

        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        _ = try? fileHandle?.seekToEnd()
    }

    deinit {
        try? fileHandle?.close()
    }

    /// Append a raw chunk (may contain multiple newline-separated lines).
    func append(_ chunk: String) {
        let incoming = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in incoming where !line.isEmpty {
            lines.append(line)
        }
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        if let data = chunk.data(using: .utf8) {
            try? fileHandle?.write(contentsOf: data)
        }
    }

    func appendSystem(_ message: String) {
        let stamped = "[HomeAssistant] \(message)\n"
        append(stamped)
    }

    func clear() {
        lines.removeAll()
    }

    static func logDirectory() -> URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/HomeAssistant", isDirectory: true)
    }
}
