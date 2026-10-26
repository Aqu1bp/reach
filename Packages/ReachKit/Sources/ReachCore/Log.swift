import Foundation
import os

/// Lightweight logging that goes to the unified log and, optionally, to stderr (used by `reach-probe`).
public enum ReachLog {
    public static var echoToStderr = false
    private static let fileQueue = DispatchQueue(label: "reach.log.file", qos: .utility)
    /// Only touched on `fileQueue`.
    nonisolated(unsafe) private static var file: FileHandle?
    private static let mirroring = OSAllocatedUnfairLock(initialState: false)

    /// Also append every line to `url` (diagnostics on devices, where the unified log isn't easily
    /// reachable). The file is started over when it passes `maxBytes`.
    public static func mirror(to url: URL, maxBytes: UInt64 = 4_000_000) {
        mirroring.withLock { $0 = true }
        fileQueue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? UInt64, size > maxBytes {
                try? fm.removeItem(at: url)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            file = try? FileHandle(forWritingTo: url)
            _ = try? file?.seekToEnd()
        }
    }
    private static let subsystem = Bundle.main.bundleIdentifier ?? "reach"
    private static let loggers = OSAllocatedUnfairLock(initialState: [String: Logger]())

    public static func info(_ category: String, _ message: @autoclosure () -> String) {
        emit(category, message(), level: .info)
    }

    public static func debug(_ category: String, _ message: @autoclosure () -> String) {
        emit(category, message(), level: .debug)
    }

    public static func error(_ category: String, _ message: @autoclosure () -> String) {
        emit(category, message(), level: .error)
    }

    private static func emit(_ category: String, _ text: String, level: OSLogType) {
        let logger = loggers.withLock { cache -> Logger in
            if let l = cache[category] { return l }
            let l = Logger(subsystem: subsystem, category: category)
            cache[category] = l
            return l
        }
        logger.log(level: level, "\(text, privacy: .public)")
        if mirroring.withLock({ $0 }) {
            let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) [\(category)] \(text)\n"
            fileQueue.async { try? file?.write(contentsOf: Data(line.utf8)) }
        }
        if echoToStderr {
            let ts = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
            FileHandle.standardError.write("[\(ts)] [\(category)] \(text)\n".data(using: .utf8)!)
        }
    }
}
