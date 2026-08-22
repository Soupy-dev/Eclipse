import Foundation
#if canImport(UIKit)
import UIKit
#endif

class ReaderLogger: @unchecked Sendable {
    static let shared = ReaderLogger()

    enum ExportError: Error {
        case encodingFailed
    }

    struct LogEntry {
        let message: String
        let type: String
        let timestamp: Date
    }

    private let queue = DispatchQueue(label: "me.cranci.sora.reader.logger", attributes: .concurrent)
    private let fileQueue = DispatchQueue(label: "me.cranci.sora.reader.logger.file")
    private var logs: [LogEntry] = []
    private let logFileURL: URL
    private let sessionMarkerURL: URL
    private let maxLogEntries = 1000
    private let maxLogFileBytes = 1_000_000
    private let noisyTypes: Set<String> = [
        "ReaderDebug", "AidokuRuntime", "AidokuNetwork", "ReaderNetwork", "ReaderProgress", "ReaderPerf",
        "ReaderExtensionRuntime", "ReaderExtensionCompatibility"
    ]
    private let noisyWindowDuration: TimeInterval = 20
    private let noisyTypeBurstLimit = 30
    private let repeatDedupWindow: TimeInterval = 2
    private var noisyWindowStart = Date()
    private var noisyTypeCounts: [String: Int] = [:]
    private var suppressedTypeCounts: [String: Int] = [:]
    private var lastEntryForRepeat: LogEntry?
    private var repeatCount = 0

    private init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFileURL = documentsURL.appendingPathComponent("reader-logs.txt")
        sessionMarkerURL = documentsURL.appendingPathComponent("reader-session.marker")
        ensureLogFileExists()
        logs = loadLogsFromDisk()
        detectPreviousUncleanShutdown()
        markSessionRunning()
        installLifecycleHooks()
    }

    static func displayCategory(for type: String) -> String {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Reader" }

        switch trimmed.lowercased() {
        case "aidoku", "aidokuruntime", "aidokusource", "aidokuhome", "aidokusearch":
            return "Aidoku"
        case "readerextensionlifecycle":
            return "Mangayomi Sources"
        case "readerextensionrepository":
            return "Mangayomi Repositories"
        case "readerextensionruntime":
            return "Mangayomi Runtime"
        case "readerextensionnetwork":
            return "Mangayomi Network"
        case "readerextensioncompatibility":
            return "Mangayomi Compatibility"
        case "readerextensionhome", "readerextensions":
            return "Mangayomi Runtime"
        case "readersearch":
            return "Reader Search"
        case "readerdebug", "readerprogress":
            return "Reader"
        case "readerperf":
            return "Reader Performance"
        case "readernetwork", "aidokunetwork":
            return "Reader Network"
        case "readersandbox":
            return "Mangayomi Sandbox"
        case "aidokusandbox":
            return "Aidoku"
        default:
            return trimmed
        }
    }

    func log(_ message: String, type: String = "Reader") {
        let normalizedMessage = Self.redact(message.replacingOccurrences(of: "\n", with: " "))
        let entry = LogEntry(message: normalizedMessage, type: type, timestamp: Date())

        queue.async(flags: .barrier) {
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

    func getLogsAsync(category: String? = nil) async -> String {
        await withCheckedContinuation { continuation in
            queue.async {
                let selectedCategory = category.flatMap { value -> String? in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty || trimmed == "All" ? nil : Self.displayCategory(for: trimmed)
                }
                let entries = selectedCategory.map { category in
                    self.logs.filter { Self.displayCategory(for: $0.type) == category }
                } ?? self.logs
                continuation.resume(returning: self.formatLogs(entries))
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
                    try? FileManager.default.removeItem(at: self.logFileURL)
                    self.ensureLogFileExists()
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
        let content = logs.isEmpty ? "No reader logs available." : logs
        guard let data = content.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = selectedCategory.map { "-\($0.lowercased().replacingOccurrences(of: " ", with: "-"))" } ?? ""
        let filename = "eclipse-reader-logs\(suffix)-\(formatter.string(from: Date())).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func redact(_ message: String) -> String {
        var result = message
        let patterns = [
            #"(?i)(?<![A-Za-z0-9])(authorization|cookie|set[-_]?cookie|token|access[-_]?token|refresh[-_]?token|session[-_]?cookie|client[-_]?secret|api[-_]?key|x[-_]?api[-_]?key|password|secret|credentials?)(?![A-Za-z0-9])\s*([:=])\s*["']?[^\s"',;]+["']?"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "$1$2<redacted>",
                options: .regularExpression
            )
        }

        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"'\)\]]+"#) else {
            return result
        }
        let nsRange = NSRange(result.startIndex..., in: result)
        for match in regex.matches(in: result, range: nsRange).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let rawURL = String(result[range])
            guard var components = URLComponents(string: rawURL),
                  components.scheme != nil,
                  components.host != nil else {
                continue
            }
            components.user = nil
            components.password = nil
            if !components.path.isEmpty, components.path != "/" {
                components.path = "/redacted"
            }
            components.queryItems = components.queryItems?.map {
                URLQueryItem(name: $0.name, value: "redacted")
            }
            components.fragment = nil
            if let redacted = components.string {
                result.replaceSubrange(range, with: redacted)
            }
        }
        return result
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
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM HH:mm:ss"
        print("[\(dateFormatter.string(from: entry.timestamp))] [\(Self.displayCategory(for: entry.type))] \(entry.message)")
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
            message: "Detected previous unclean reader shutdown.",
            type: "Shutdown",
            timestamp: Date()
        )
        appendToDisk(entry)
        queue.async(flags: .barrier) {
            self.logs.append(entry)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ReaderLoggerNotification"),
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

        appendToDisk(entry)
        debugLog(entry)

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: NSNotification.Name("ReaderLoggerNotification"),
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
                    type: "ReaderLogger",
                    timestamp: now
                )
            }

        noisyWindowStart = now
        noisyTypeCounts.removeAll(keepingCapacity: true)
        suppressedTypeCounts.removeAll(keepingCapacity: true)
        return summaries
    }

    private func shouldRecordInNoisyWindow(_ entry: LogEntry) -> Bool {
        let category = Self.displayCategory(for: entry.type).lowercased()
        if category == "error" || category.contains("sandbox") {
            return true
        }

        guard noisyTypes.contains(entry.type) else { return true }
        let next = noisyTypeCounts[entry.type, default: 0] + 1
        noisyTypeCounts[entry.type] = next
        return next <= noisyTypeBurstLimit
    }

    private func appendToDisk(_ entry: LogEntry) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM HH:mm:ss"
        let line = "[\(dateFormatter.string(from: entry.timestamp))] [\(entry.type)] \(entry.message)\n"

        guard let data = line.data(using: .utf8) else { return }

        fileQueue.sync {
            rotateLogFileIfNeeded(incomingBytes: data.count)

            guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
            defer { try? handle.close() }

            handle.seekToEndOfFile()
            handle.write(data)
            handle.synchronizeFile()
        }
    }

    private func rotateLogFileIfNeeded(incomingBytes: Int) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path)
        let currentSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if currentSize + incomingBytes <= maxLogFileBytes { return }

        guard let existing = try? String(contentsOf: logFileURL, encoding: .utf8) else {
            try? FileManager.default.removeItem(at: logFileURL)
            ensureLogFileExists()
            return
        }
        let target = max(0, maxLogFileBytes / 2 - incomingBytes)
        var retainedLines: [Substring] = []
        var retainedBytes = 0
        for line in existing.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let lineBytes = line.utf8.count + 1
            if retainedBytes + lineBytes > target { break }
            retainedBytes += lineBytes
            retainedLines.append(line)
        }
        guard !retainedLines.isEmpty else {
            try? FileManager.default.removeItem(at: logFileURL)
            ensureLogFileExists()
            return
        }
        var retained = retainedLines.reversed().joined(separator: "\n")
        if !retained.hasSuffix("\n") { retained.append("\n") }
        if (try? retained.write(to: logFileURL, atomically: true, encoding: .utf8)) == nil {
            try? FileManager.default.removeItem(at: logFileURL)
            ensureLogFileExists()
        }
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

        var parsed: [LogEntry] = []
        for line in content.split(separator: "\n") {
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

            parsed.append(
                LogEntry(
                    message: String(lineStr[messageRange]),
                    type: String(lineStr[typeRange]),
                    timestamp: timestamp
                )
            )
        }

        if parsed.count > maxLogEntries {
            return Array(parsed.suffix(maxLogEntries))
        }
        return parsed
    }
}
