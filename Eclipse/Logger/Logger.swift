import Foundation
#if canImport(UIKit)
import UIKit
#endif

class Logger: @unchecked Sendable {
    static let shared = Logger()

    enum ExportError: Error {
        case encodingFailed
    }
    
    struct LogEntry {
        let message: String
        let type: String
        let timestamp: Date
    }
    
    private let queue = DispatchQueue(label: "me.cranci.sora.logger", attributes: .concurrent)
    private let fileQueue = DispatchQueue(label: "me.cranci.sora.logger.file")
    private var logs: [LogEntry] = []
    private let logFileURL: URL
    private let sessionMarkerURL: URL
    // Accessed only from fileQueue. Keeping the handle open avoids an
    // open/seek/fsync/close cycle for every MPV, tracker, and stream log.
    private var logFileHandle: FileHandle?
    private var logFileBytes = 0
    private lazy var diskDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM HH:mm:ss"
        return formatter
    }()
    // Accessed only from the barrier-backed logger queue.
    private lazy var debugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM HH:mm:ss"
        return formatter
    }()
    private let maxLogEntries = 1000
    private let maxLogFileBytes = 1_000_000
    private let noisyTypes: Set<String> = ["AniList", "Tracker", "Progress", "Stream", "General", "Info", "TMDB", "MPV", "Matching", "Performance"]
    private let noisyWindowDuration: TimeInterval = 20
    private let noisyTypeBurstLimit = 30
    private let repeatDedupWindow: TimeInterval = 2
    private var noisyWindowStart = Date()
    private var noisyTypeCounts: [String: Int] = [:]
    private var suppressedTypeCounts: [String: Int] = [:]
    private var lastEntryForRepeat: LogEntry?
    private var repeatCount = 0

    private static let sensitiveURLRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:https?|stremio)://[^\s<>\"'\)\]]+"#
    )
    private static let sensitiveValuePatterns: [(regex: NSRegularExpression, replacement: String)] = [
        (
            try! NSRegularExpression(
                pattern: #"(?i)\b(authorization|proxy-authorization)\b[\"']?\s*[:=]\s*[\"']?(?:bearer\s+|basic\s+)?[^\"'\s,;}\]\r\n]+"#
            ),
            "$1=<redacted>"
        ),
        (
            try! NSRegularExpression(
                pattern: #"(?i)\b(authorization|proxy-authorization)\b\s+(?:bearer|basic)\s+[^\s,;}\]\r\n]+"#
            ),
            "$1=<redacted>"
        ),
        (
            try! NSRegularExpression(
                pattern: #"(?i)\b(cookie|set-cookie)\b[\"']?\s*[:=]\s*[\"']?[^\"'\r\n]+"#
            ),
            "$1=<redacted>"
        ),
        (
            try! NSRegularExpression(
                pattern: #"(?i)\b(access[_-]?token|refresh[_-]?token|id[_-]?token|token|api[_-]?key|x-api-key|client[_-]?secret|password|passwd)\b[\"']?\s*[:=]\s*[\"']?[^\"'\s,;}&\]\r\n]+"#
            ),
            "$1=<redacted>"
        ),
        (
            try! NSRegularExpression(
                pattern: #"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#
            ),
            "Bearer <redacted>"
        )
    ]
    
    private init() {
        // Use Documents folder for persistent logs (easier to access)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFileURL = documentsURL.appendingPathComponent("player-logs.txt")
        sessionMarkerURL = documentsURL.appendingPathComponent("app-session.marker")
        ensureLogFileExists()
        logs = loadLogsFromDisk()
        detectPreviousUncleanShutdown()
        markSessionRunning()
        installLifecycleHooks()
    }

    static func displayCategory(for type: String) -> String {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "General" }

        switch trimmed.lowercased() {
        case "matching", "animatch", "animap", "tmdbmatch", "mediamatch":
            return "Matching"
        default:
            return trimmed
        }
    }

    /// Removes secrets before a message can reach memory, disk, debug output,
    /// notifications, exports, or crash-adjacent diagnostics. HTTP and Stremio
    /// URLs are reduced to their origin because provider tokens can be stored
    /// in opaque path segments as well as conventional query items.
    static func redactedSensitiveMessage(_ message: String, maximumLength: Int? = nil) -> String {
        let lowercaseMessage = message.lowercased()
        let mightContainSensitiveValue = lowercaseMessage.contains("://")
            || lowercaseMessage.contains("authorization")
            || lowercaseMessage.contains("cookie")
            || lowercaseMessage.contains("token")
            || lowercaseMessage.contains("api")
            || lowercaseMessage.contains("secret")
            || lowercaseMessage.contains("password")
            || lowercaseMessage.contains("passwd")
            || lowercaseMessage.contains("bearer")

        guard mightContainSensitiveValue else {
            if let maximumLength, maximumLength > 0, message.count > maximumLength {
                return String(message.prefix(maximumLength)) + "...<truncated>"
            }
            return message
        }

        var result = message
        let range = NSRange(result.startIndex..., in: result)
        for match in sensitiveURLRegex.matches(in: result, range: range).reversed() {
            guard let stringRange = Range(match.range, in: result) else { continue }
            let rawURL = String(result[stringRange])
            guard let components = URLComponents(string: rawURL),
                  let scheme = components.scheme?.lowercased(),
                  let host = components.host,
                  !host.isEmpty else {
                result.replaceSubrange(stringRange, with: "<redacted-url>")
                continue
            }

            var origin = URLComponents()
            origin.scheme = scheme == "stremio" ? "stremio" : scheme
            origin.host = host
            origin.port = components.port
            result.replaceSubrange(
                stringRange,
                with: origin.string ?? "\(scheme)://\(host)"
            )
        }

        for pattern in sensitiveValuePatterns {
            let fullRange = NSRange(result.startIndex..., in: result)
            result = pattern.regex.stringByReplacingMatches(
                in: result,
                range: fullRange,
                withTemplate: pattern.replacement
            )
        }

        if let maximumLength, maximumLength > 0, result.count > maximumLength {
            result = String(result.prefix(maximumLength)) + "...<truncated>"
        }
        return result
    }
    
    func log(_ message: String, type: String = "General") {
        let timestamp = Date()

        // Crash diagnostics must survive hard crashes immediately.
        if Self.isCrashDiagnosticType(type) || Self.isCrashDiagnosticMessage(message) {
            let normalizedMessage = Self.redactedSensitiveMessage(message)
                .replacingOccurrences(of: "\n", with: " ")
            let entry = LogEntry(message: normalizedMessage, type: type, timestamp: timestamp)
            appendToDisk(entry, synchronize: true)

            queue.async(flags: .barrier) {
                self.logs.append(entry)
                if self.logs.count > self.maxLogEntries {
                    self.logs.removeFirst(self.logs.count - self.maxLogEntries)
                }
                self.debugLog(entry)

                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("LoggerNotification"),
                        object: nil,
                        userInfo: [
                            "message": entry.message,
                            "type": Self.displayCategory(for: entry.type),
                            "timestamp": entry.timestamp
                        ]
                    )
                }
            }
            return
        }
        
        queue.async(flags: .barrier) {
            // URL parsing and the redaction regexes are intentionally kept off
            // UI, player, and networking caller threads for ordinary logs.
            let normalizedMessage = Self.redactedSensitiveMessage(message)
                .replacingOccurrences(of: "\n", with: " ")
            let entry = LogEntry(message: normalizedMessage, type: type, timestamp: timestamp)
            let now = entry.timestamp
            var entriesToRecord = self.rolloverNoisyWindowIfNeeded(now: now)

            if !self.shouldRecordInNoisyWindow(entry) {
                self.suppressedTypeCounts[entry.type, default: 0] += 1
                return
            }

            if let last = self.lastEntryForRepeat,
               last.type == entry.type,
               last.message == entry.message,
               now.timeIntervalSince(last.timestamp) <= self.repeatDedupWindow {
                self.repeatCount += 1
                self.lastEntryForRepeat = LogEntry(message: last.message, type: last.type, timestamp: now)
                return
            }

            if self.repeatCount > 0, let last = self.lastEntryForRepeat {
                entriesToRecord.append(
                    LogEntry(
                        message: "Previous message repeated \(self.repeatCount)x",
                        type: "\(last.type)-summary",
                        timestamp: now
                    )
                )
                self.repeatCount = 0
            }

            self.lastEntryForRepeat = entry
            entriesToRecord.append(entry)

            for item in entriesToRecord {
                self.record(item)
            }
        }
    }
    
    func getLogs() -> String {
        var result = ""
        queue.sync {
            result = self.formatLogs(self.logs)
        }
        return result
    }
    
    func getLogsAsync(category: String? = nil) async -> String {
        return await withCheckedContinuation { continuation in
            queue.async {
                let selectedCategory = category.flatMap { value -> String? in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty || trimmed == "All" ? nil : Self.displayCategory(for: trimmed)
                }
                let entries = selectedCategory.map { category in
                    self.logs.filter { Self.displayCategory(for: $0.type) == category }
                } ?? self.logs
                let result = self.formatLogs(entries)
                continuation.resume(returning: result)
            }
        }
    }
    
    func clearLogs() {
        queue.async(flags: .barrier) {
            self.logs.removeAll()
            self.lastEntryForRepeat = nil
            self.repeatCount = 0
            self.noisyTypeCounts.removeAll()
            self.suppressedTypeCounts.removeAll()
            self.noisyWindowStart = Date()
            self.fileQueue.sync {
                self.closeLogFileHandle(synchronize: false)
                try? FileManager.default.removeItem(at: self.logFileURL)
                self.ensureLogFileExists()
                self.logFileBytes = 0
            }
        }
    }
    
    func clearLogsAsync() async {
        await withCheckedContinuation { continuation in
            queue.async(flags: .barrier) {
                self.logs.removeAll()
                self.lastEntryForRepeat = nil
                self.repeatCount = 0
                self.noisyTypeCounts.removeAll()
                self.suppressedTypeCounts.removeAll()
                self.noisyWindowStart = Date()
                self.fileQueue.sync {
                    self.closeLogFileHandle(synchronize: false)
                    try? FileManager.default.removeItem(at: self.logFileURL)
                    self.ensureLogFileExists()
                    self.logFileBytes = 0
                }
                continuation.resume()
            }
        }
    }
    
    func exportLogsToTempFile(category: String? = nil) async throws -> URL {
        let selectedCategory = category.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == "All" ? nil : Self.displayCategory(for: trimmed)
        }
        let logs = await getLogsAsync(category: selectedCategory)
        var content = logs.isEmpty ? "No logs available." : logs
#if !os(macOS)
        if let crashReport = CrashReportManager.shared.latestCrashReportText(),
           !crashReport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content += "\n\n==== Last Native Crash Report ====\n\n\(crashReport)"
        }
#endif
        guard let data = content.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = selectedCategory.map { "-\($0.lowercased().replacingOccurrences(of: " ", with: "-"))" } ?? ""
        let filename = "eclipse-logs\(suffix)-\(formatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func formatLogs(_ entries: [LogEntry]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM HH:mm:ss"
        return entries.map { entry in
            "[\(dateFormatter.string(from: entry.timestamp))] [\(Self.displayCategory(for: entry.type))] \(entry.message)"
        }
        .joined(separator: "\n----\n")
    }
    
    private func debugLog(_ entry: LogEntry) {
#if DEBUG
        let formattedMessage = "[\(debugDateFormatter.string(from: entry.timestamp))] [\(Self.displayCategory(for: entry.type))] \(entry.message)"
        print(formattedMessage)
#endif
    }

    private func ensureLogFileExists() {
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
    }

    private func detectPreviousUncleanShutdown() {
        let marker: String? = fileQueue.sync {
            try? String(contentsOf: sessionMarkerURL, encoding: .utf8)
        }
        guard let marker, marker.hasPrefix("running") else { return }

        let entry = LogEntry(
            message: "Detected previous unclean app shutdown (likely crash or force close).",
            type: "Shutdown",
            timestamp: Date()
        )

        appendToDisk(entry, synchronize: false)
        queue.async(flags: .barrier) {
            self.logs.append(entry)
            if self.logs.count > self.maxLogEntries {
                self.logs.removeFirst(self.logs.count - self.maxLogEntries)
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("LoggerNotification"),
                    object: nil,
                    userInfo: [
                        "message": entry.message,
                        "type": Self.displayCategory(for: entry.type),
                        "timestamp": entry.timestamp
                    ]
                )
            }
        }
    }

    private func markSessionRunning() {
        fileQueue.sync {
            let marker = "running:\(Int(Date().timeIntervalSince1970))"
            try? marker.write(to: sessionMarkerURL, atomically: true, encoding: .utf8)
        }
    }

    private func markSessionClean(reason: String) {
        fileQueue.sync {
            try? logFileHandle?.synchronize()
            let marker = "clean:\(reason):\(Int(Date().timeIntervalSince1970))"
            try? marker.write(to: sessionMarkerURL, atomically: true, encoding: .utf8)
        }
    }

    private func installLifecycleHooks() {
#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAppWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
#endif
    }

#if canImport(UIKit)
    @objc private func onAppWillTerminate() {
        markSessionClean(reason: "terminate")
    }

    @objc private func onAppDidEnterBackground() {
        markSessionClean(reason: "background")
    }

    @objc private func onAppDidBecomeActive() {
        markSessionRunning()
    }
#endif

    private func record(_ entry: LogEntry) {
        logs.append(entry)
        if logs.count > maxLogEntries {
            logs.removeFirst(logs.count - maxLogEntries)
        }

        appendToDisk(entry, synchronize: false)
        debugLog(entry)

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("LoggerNotification"),
                object: nil,
                userInfo: [
                    "message": entry.message,
                    "type": Self.displayCategory(for: entry.type),
                    "timestamp": entry.timestamp
                ]
            )
        }
    }

    private func rolloverNoisyWindowIfNeeded(now: Date) -> [LogEntry] {
        guard now.timeIntervalSince(noisyWindowStart) >= noisyWindowDuration else { return [] }

        let summaries = suppressedTypeCounts
            .sorted { $0.key < $1.key }
            .map { type, count in
                LogEntry(
                    message: "Suppressed \(count) noisy \(type) logs in last \(Int(noisyWindowDuration))s",
                    type: "Logger",
                    timestamp: now
                )
            }

        noisyWindowStart = now
        noisyTypeCounts.removeAll(keepingCapacity: true)
        suppressedTypeCounts.removeAll(keepingCapacity: true)
        return summaries
    }

    private func shouldRecordInNoisyWindow(_ entry: LogEntry) -> Bool {
        if shouldBypassNoisySuppression(entry) {
            return true
        }

        let type = entry.type
        guard noisyTypes.contains(type) else { return true }
        let next = noisyTypeCounts[type, default: 0] + 1
        noisyTypeCounts[type] = next
        return next <= noisyTypeBurstLimit
    }

    private func shouldBypassNoisySuppression(_ entry: LogEntry) -> Bool {
        if Self.isCrashDiagnosticType(entry.type) || Self.isCrashDiagnosticMessage(entry.message) {
            return true
        }

        let category = Self.displayCategory(for: entry.type).lowercased()
        let message = entry.message.lowercased()

        if category == "error" {
            return true
        }

        if message.contains("playerheaderproxy") || message.contains("mpvheaderproxy") || message.contains("vlcheaderproxy") {
            return true
        }

        guard category == "mpv" else { return false }

        return message.contains("startup watchdog")
            || message.contains("declaring stalled")
            || message.contains("startup monitor armed")
            || message.contains("[playervc.pip]")
            || message.contains("[pipcontroller]")
            || message.contains("pip hybrid")
            || message.contains("samplebufferpipbridge")
            || message.contains("sample-buffer pip")
            || message.contains("loading initial url")
            || message.contains("load url=")
            || message.contains("rendererload url=")
            || message.contains("load start gen=")
            || message.contains("applying mpv raw http headers")
            || message.contains("clearing http headers")
            || message.contains("command loadfile")
            || message.contains("delegate didfailwitherror")
            || message.contains("playback issue")
            || message.contains("playbackstart")
            || message.contains("loadfile command failed")
            || message.contains("event end-file")
            || message.contains("event file-loaded")
            || message.contains("http error")
            || message.contains("failed")
            || (message.contains("mpv[") && (message.contains(" error:") || message.contains(" warn:")))
    }

    private static func isCrashDiagnosticType(_ type: String) -> Bool {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "vlcplayback", "vlcproxy":
            return true
        default:
            return false
        }
    }

    private static func isCrashDiagnosticMessage(_ message: String) -> Bool {
        let lowercasedMessage = message.lowercased()
        return lowercasedMessage.contains("[vlcrenderer]")
            || lowercasedMessage.contains("[playervc.vlc")
            || lowercasedMessage.contains("vlcheaderproxy")
    }

    private func appendToDisk(_ entry: LogEntry, synchronize: Bool) {
        let write = {
            let line = "[\(self.diskDateFormatter.string(from: entry.timestamp))] [\(entry.type)] \(entry.message)\n"
            guard let data = line.data(using: .utf8) else { return }

            self.prepareLogFileHandleIfNeeded()
            self.rotateLogFileIfNeeded(incomingBytes: data.count)
            self.prepareLogFileHandleIfNeeded()

            guard let handle = self.logFileHandle else { return }
            do {
                try handle.write(contentsOf: data)
                self.logFileBytes += data.count
                if synchronize {
                    try handle.synchronize()
                }
            } catch {
                self.closeLogFileHandle(synchronize: false)
            }
        }

        if synchronize {
            fileQueue.sync(execute: write)
        } else {
            fileQueue.async(execute: write)
        }
    }

    private func prepareLogFileHandleIfNeeded() {
        guard logFileHandle == nil else { return }
        ensureLogFileExists()

        let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)
        logFileBytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0

        guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
        do {
            try handle.seekToEnd()
            logFileHandle = handle
        } catch {
            try? handle.close()
        }
    }

    private func closeLogFileHandle(synchronize: Bool) {
        guard let handle = logFileHandle else { return }
        if synchronize {
            try? handle.synchronize()
        }
        try? handle.close()
        logFileHandle = nil
    }

    private func rotateLogFileIfNeeded(incomingBytes: Int) {
        if logFileBytes + incomingBytes <= maxLogFileBytes { return }

        closeLogFileHandle(synchronize: false)
        try? FileManager.default.removeItem(at: logFileURL)
        ensureLogFileExists()
        logFileBytes = 0
    }

    private func loadLogsFromDisk() -> [LogEntry] {
        var content = ""
        fileQueue.sync {
            content = (try? String(contentsOf: logFileURL, encoding: .utf8)) ?? ""
        }

        if content.isEmpty { return [] }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM HH:mm:ss"
        let pattern = #"\[([^\]]+)\] \[([^\]]+)\] (.+)"#
        let regex = try? NSRegularExpression(pattern: pattern)

        // Walk backward and stop once the newest maxLogEntries valid records
        // are decoded. This preserves the exact retained history while
        // avoiding thousands of DateFormatter/regex parses at launch.
        var parsedNewestFirst: [LogEntry] = []
        parsedNewestFirst.reserveCapacity(maxLogEntries)
        for line in content.split(separator: "\n").reversed() {
            let lineStr = String(line)
            guard let regex,
                  let match = regex.firstMatch(in: lineStr, range: NSRange(lineStr.startIndex..., in: lineStr)),
                  let timestampRange = Range(match.range(at: 1), in: lineStr),
                  let typeRange = Range(match.range(at: 2), in: lineStr),
                  let messageRange = Range(match.range(at: 3), in: lineStr),
                  let timestamp = dateFormatter.date(from: String(lineStr[timestampRange]))
            else {
                continue
            }

            parsedNewestFirst.append(
                LogEntry(
                    message: String(lineStr[messageRange]),
                    type: String(lineStr[typeRange]),
                    timestamp: timestamp
                )
            )
            if parsedNewestFirst.count == maxLogEntries {
                break
            }
        }

        return Array(parsedNewestFirst.reversed())
    }
}
