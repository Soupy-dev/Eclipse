//
//  Logging.swift
//  Sora
//
//  Created by seiike on 16/01/2025.
//

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
    private let maxLogEntries = 1000
    private let maxLogFileBytes = 2_000_000
    private let noisyTypes: Set<String> = ["AniList", "Tracker", "Progress", "Stream", "General", "Info", "TMDB", "MPV", "Matching"]
    private let noisyWindowDuration: TimeInterval = 20
    private let noisyTypeBurstLimit = 30
    private let repeatDedupWindow: TimeInterval = 2
    private var noisyWindowStart = Date()
    private var noisyTypeCounts: [String: Int] = [:]
    private var suppressedTypeCounts: [String: Int] = [:]
    private var lastEntryForRepeat: LogEntry?
    private var repeatCount = 0
    
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
        case "crashprobe", "matching", "animatch", "animap", "tmdbmatch", "mediamatch":
            return "Matching"
        default:
            return trimmed
        }
    }
    
    func log(_ message: String, type: String = "General") {
        let normalizedMessage = message.replacingOccurrences(of: "\n", with: " ")
        let entry = LogEntry(message: normalizedMessage, type: type, timestamp: Date())

        // Crash diagnostics must survive hard crashes immediately.
        if type == "CrashProbe" {
            appendToDisk(entry)

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
                try? FileManager.default.removeItem(at: self.logFileURL)
                self.ensureLogFileExists()
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
        let content = logs.isEmpty ? "No logs available." : logs
        guard let data = content.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = selectedCategory.map { "-\($0.lowercased().replacingOccurrences(of: " ", with: "-"))" } ?? ""
        let filename = "luna-logs\(suffix)-\(formatter.string(from: Date())).txt"
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
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM HH:mm:ss"
        let formattedMessage = "[\(dateFormatter.string(from: entry.timestamp))] [\(Self.displayCategory(for: entry.type))] \(entry.message)"
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
            type: "CrashProbe",
            timestamp: Date()
        )

        appendToDisk(entry)
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
        let category = Self.displayCategory(for: entry.type).lowercased()
        let message = entry.message.lowercased()

        if category == "error" {
            return true
        }

        if message.contains("playerheaderproxy") {
            return true
        }

        guard category == "mpv" else { return false }

        return message.contains("startup watchdog")
            || message.contains("declaring stalled")
            || message.contains("startup monitor armed")
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

        try? FileManager.default.removeItem(at: logFileURL)
        ensureLogFileExists()
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
