import SwiftUI

struct ReaderLoggerView: View {
    @StateObject private var loggerManager = ReaderLoggerManager.shared
    @State private var searchText = ""
    @State private var selectedCategory = "All"
#if !os(tvOS)
    @State private var exportItem: ExportItem?
#endif
    @State private var exportErrorMessage: String?

    private var filteredLogs: [LogEntry] {
        var logs = loggerManager.logs

        if selectedCategory != "All" {
            logs = logs.filter { $0.type == selectedCategory }
        }

        if !searchText.isEmpty {
            logs = logs.filter {
                $0.message.localizedCaseInsensitiveContains(searchText) ||
                $0.type.localizedCaseInsensitiveContains(searchText)
            }
        }

        return logs.sorted { $0.timestamp > $1.timestamp }
    }

    private var availableCategories: [String] {
        let categories = Set(loggerManager.logs.map { $0.type }).sorted()
        return ["All"] + categories
    }

    var body: some View {
        let visibleLogs = filteredLogs
        let categories = availableCategories

        ScrollView {
            VStack(spacing: 20) {
                GlassSection {
                    GlassDetailRow(icon: "line.3.horizontal.decrease.circle", iconColor: .blue, title: "Category") {
                        Menu {
                            ForEach(categories, id: \.self) { category in
                                Button {
                                    selectedCategory = category
                                } label: {
                                    if selectedCategory == category {
                                        Label(category, systemImage: "checkmark")
                                    } else {
                                        Text(category)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedCategory)
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.6))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                        }
                    }
                }

                if visibleLogs.isEmpty {
                    EclipseEmptyState(
                        icon: "doc.text",
                        title: "No reader logs found",
                        message: "Reader logs will appear here as activity is recorded."
                    )
                    .padding(.top, 32)
                } else {
                    GlassSection {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(visibleLogs.enumerated()), id: \.element.id) { index, log in
                                LogEntryRow(log: log)
                                    .id(log.id)

                                if index < visibleLogs.count - 1 {
                                    GlassDivider(leadingInset: 16)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
            .background(EclipseScrollTracker())
        }
        .navigationTitle("Reader Logs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(GlobalGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
#if !os(tvOS)
                    Button(action: {
                        Task {
                            do {
                                let exportCategory = selectedCategory == "All" ? nil : selectedCategory
                                let url = try await ReaderLogger.shared.exportLogsToTempFile(category: exportCategory)
                                exportItem = ExportItem(url: url)
                            } catch {
                                exportErrorMessage = "Failed to export reader logs."
                            }
                        }
                    }) {
                        Label("Export Reader Logs", systemImage: "square.and.arrow.up")
                    }
#endif
                    Button(action: {
                        loggerManager.clearLogs()
                    }) {
                        Label("Clear Reader Logs", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { _ in exportErrorMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
#if !os(tvOS)
        .sheet(item: $exportItem) { item in
            ActivityView(items: [item.url])
                .preferredColorScheme(.dark)
        }
#endif
    }
}

final class ReaderLoggerManager: ObservableObject {
    static let shared = ReaderLoggerManager()
    private static let logLineRegex = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\] \[([^\]]+)\] (.+)"#,
        options: []
    )

    @Published var logs: [LogEntry] = []
    private let maxLogs = 1000
    private var pendingLogEntries: [LogEntry] = []
    private var logFlushScheduled = false

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLogNotification),
            name: NSNotification.Name("ReaderLoggerNotification"),
            object: nil
        )

        DispatchQueue.main.async {
            self.loadExistingLogs()
        }
    }

    @MainActor
    private func loadExistingLogs() {
        Task { @MainActor in
            let existingLogsString = await ReaderLogger.shared.getLogsAsync()
            if !existingLogsString.isEmpty {
                let logEntries = await Task.detached(priority: .utility) {
                    Self.parseLogsString(existingLogsString)
                }.value
                self.logs = logEntries
            }
        }
    }

    private static func parseLogsString(_ logsString: String) -> [LogEntry] {
        let logLines = logsString
            .replacingOccurrences(of: "\n----\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
        var parsedLogs: [LogEntry] = []

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM HH:mm:ss"

        for line in logLines {
            let section = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !section.isEmpty else { continue }

            if let match = logLineRegex.firstMatch(
                in: section,
                options: [],
                range: NSRange(section.startIndex..., in: section)
            ) {

                let timestampRange = Range(match.range(at: 1), in: section)!
                let typeRange = Range(match.range(at: 2), in: section)!
                let messageRange = Range(match.range(at: 3), in: section)!

                let timestampString = String(section[timestampRange])
                let type = ReaderLogger.displayCategory(for: String(section[typeRange]))
                let message = String(section[messageRange])

                if let timestamp = dateFormatter.date(from: timestampString) {
                    parsedLogs.append(LogEntry(timestamp: timestamp, message: message, type: type))
                }
            }
        }

        return parsedLogs.sorted { $0.timestamp > $1.timestamp }
    }

    @objc private func handleLogNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let message = userInfo["message"] as? String,
              let type = userInfo["type"] as? String else { return }

        let entry = LogEntry(
            timestamp: notification.userInfo?["timestamp"] as? Date ?? Date(),
            message: message,
            type: ReaderLogger.displayCategory(for: type)
        )
        let enqueue = { [weak self] in
            guard let self else { return }
            self.pendingLogEntries.append(entry)
            self.schedulePendingLogFlush()
        }

        if Thread.isMainThread {
            enqueue()
        } else {
            DispatchQueue.main.async(execute: enqueue)
        }
    }

    func addLog(message: String, type: String) {
        let log = LogEntry(timestamp: Date(), message: message, type: ReaderLogger.displayCategory(for: type))
        logs.insert(log, at: 0)

        if logs.count > maxLogs {
            logs = Array(logs.prefix(maxLogs))
        }
    }

    func clearLogs() {
        pendingLogEntries.removeAll(keepingCapacity: true)
        logs.removeAll()
        Task {
            await ReaderLogger.shared.clearLogsAsync()
        }
    }

    private func schedulePendingLogFlush() {
        guard !logFlushScheduled else { return }
        logFlushScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logFlushScheduled = false
            guard !self.pendingLogEntries.isEmpty else { return }

            let entries = self.pendingLogEntries
            self.pendingLogEntries.removeAll(keepingCapacity: true)
            self.logs.insert(contentsOf: entries.reversed(), at: 0)
            if self.logs.count > self.maxLogs {
                self.logs = Array(self.logs.prefix(self.maxLogs))
            }
        }
    }
}
