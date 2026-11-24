import Foundation
import os

/// File-backed logging for field diagnosis. Writes to
/// ~/Library/Logs/MiVoice/MiVoice.log with simple size rotation, keeps an
/// os_log copy, and runs a main-thread watchdog so a freeze leaves a marker
/// naming the operation that was running when the main thread stopped.
enum Log {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    private static let logger = Logger(subsystem: "app.mivoice", category: "app")
    private static let ioQueue = DispatchQueue(label: "app.mivoice.log.io")
    private static let stateLock = NSLock()
    private static let maxBytes: UInt64 = 2_000_000
    private static let keepArchives = 4

    private static var handle: FileHandle?
    private static var currentSize: UInt64 = 0
    private static var lastStep = "launch"
    private static var lastMainTick = Date()
    private static var stallReported = false
    private static var watchdog: DispatchSourceTimer?

    static var directoryURL: URL {
        let library = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/MiVoice", isDirectory: true)
    }

    static var fileURL: URL {
        directoryURL.appendingPathComponent("MiVoice.log")
    }

    static func start() {
        ioQueue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            rotateIfNeededLocked()
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            if let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? NSNumber {
                currentSize = size.uint64Value
            } else {
                currentSize = 0
            }
            handle = try? FileHandle(forWritingTo: fileURL)
            handle?.seekToEndOfFile()
            if currentSize > maxBytes {
                rotateIfNeededLocked()
            }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        write(
            level: .info,
            "===== MiVoice \(version) (\(build)) started \(Self.timestamp()) macOS \(os) arch=\(Self.arch) ====="
        )
        startWatchdog()
    }

    static func info(_ message: String) {
        write(level: .info, message)
    }

    static func debug(_ message: String) {
        write(level: .debug, message)
    }

    static func warn(_ message: String) {
        write(level: .warn, message)
    }

    static func error(_ message: String) {
        write(level: .error, message)
    }

    /// Records the operation currently running. The watchdog reports this name
    /// if the main thread stops responding. Written synchronously so the last
    /// step survives a crash or forced quit.
    static func step(_ name: String) {
        stateLock.lock()
        lastStep = name
        stateLock.unlock()
        write(level: .info, "STEP \(name)", sync: true)
    }

    static var currentStep: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastStep
    }

    static func flush() {
        ioQueue.sync {
            try? handle?.synchronizeFile()
        }
    }

    private static func write(level: Level, _ message: String, sync: Bool = false) {
        let line = "\(timestamp()) [\(level.rawValue)] [\(threadName)] \(message)\n"
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warn:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }

        let append = {
            guard let data = line.data(using: .utf8) else { return }
            handle?.write(data)
            currentSize += UInt64(data.count)
            if currentSize > maxBytes {
                rotateIfNeededLocked()
            }
        }
        if sync {
            ioQueue.sync(execute: append)
        } else {
            ioQueue.async(execute: append)
        }
    }

    private static func rotateIfNeededLocked() {
        guard currentSize > maxBytes else { return }
        let fm = FileManager.default
        handle?.closeFile()
        handle = nil
        for index in stride(from: keepArchives, through: 2, by: -1) {
            let from = directoryURL.appendingPathComponent("MiVoice.log.\(index - 1)")
            let to = directoryURL.appendingPathComponent("MiVoice.log.\(index)")
            try? fm.removeItem(at: to)
            try? fm.moveItem(at: from, to: to)
        }
        let first = directoryURL.appendingPathComponent("MiVoice.log.1")
        try? fm.removeItem(at: first)
        try? fm.moveItem(at: fileURL, to: first)
        fm.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        currentSize = 0
    }

    private static func startWatchdog() {
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            stateLock.lock()
            lastMainTick = Date()
            stateLock.unlock()
        }
        RunLoop.main.add(timer, forMode: .common)

        let source = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "app.mivoice.watchdog")
        )
        source.schedule(deadline: .now() + 2, repeating: 2)
        source.setEventHandler {
            stateLock.lock()
            let step = lastStep
            let elapsed = Date().timeIntervalSince(lastMainTick)
            let wasReported = stallReported
            if elapsed > 4 {
                stallReported = true
            } else if wasReported {
                stallReported = false
            }
            stateLock.unlock()

            if elapsed > 4 {
                write(
                    level: .error,
                    "[WATCHDOG] main thread stalled \(Int(elapsed))s lastStep=\(step)"
                )
            } else if wasReported {
                write(
                    level: .info,
                    "[WATCHDOG] main thread recovered lastStep=\(step)"
                )
            }
        }
        source.resume()
        watchdog = source
    }

    static func exportBundle(systemInfo: String) -> URL? {
        flush()
        let fm = FileManager.default
        let stamp = filenameTimestamp()
        let work = fm.temporaryDirectory
            .appendingPathComponent("MiVoice-Diagnostics-\(stamp)", isDirectory: true)
        try? fm.removeItem(at: work)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        for name in ["MiVoice.log", "MiVoice.log.1", "MiVoice.log.2", "MiVoice.log.3", "MiVoice.log.4"] {
            let source = directoryURL.appendingPathComponent(name)
            if fm.fileExists(atPath: source.path) {
                try? fm.copyItem(at: source, to: work.appendingPathComponent(name))
            }
        }

        let info = """
        MiVoice diagnostic bundle
        Created: \(timestamp())
        Log file: \(fileURL.path)

        \(systemInfo)
        """
        try? info.write(to: work.appendingPathComponent("system.txt"), atomically: true, encoding: .utf8)

        // Include recent crash/hang reports for this app, if present.
        let reports = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.lowercased().hasPrefix("mivoice") {
                try? fm.copyItem(at: file, to: work.appendingPathComponent(file.lastPathComponent))
            }
        }

        let destination = (fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser)
            .appendingPathComponent("MiVoice-Diagnostics-\(stamp).zip")
        try? fm.removeItem(at: destination)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", work.path, destination.path]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0, fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: work)
                return destination
            }
        } catch {
            // fall through to the folder
        }
        return work
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func filenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static var threadName: String {
        Thread.isMainThread ? "main" : "bg"
    }

    private static var arch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
