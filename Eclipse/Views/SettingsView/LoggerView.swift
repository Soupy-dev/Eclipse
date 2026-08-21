//
//  LoggerView.swift
//  Sora
//
//  Created by Francesco on 10/08/25.
//

import SwiftUI

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let type: String

    var typeColor: Color {
        switch type.lowercased() {
        case "error":
            return .red
        case "warning":
            return .orange
        case "stream":
            return .blue
        case "servicemanager":
            return .purple
        case "matching":
            return .teal
        case "mpv":
            return .indigo
        case "performance":
            return .cyan
        case "debug":
            return .gray
        default:
            return .white
        }
    }

    var typeIcon: String {
        switch type.lowercased() {
        case "error":
            return "exclamationmark.triangle.fill"
        case "warning":
            return "exclamationmark.triangle"
        case "stream":
            return "play.circle"
        case "servicemanager":
            return "gear.circle"
        case "matching":
            return "point.3.connected.trianglepath.dotted"
        case "mpv":
            return "play.tv"
        case "performance":
            return "gauge.with.dots.needle.67percent"
        case "debug":
            return "ladybug"
        default:
            return "info.circle"
        }
    }
}

struct LoggerView: View {
    @StateObject private var loggerManager = LoggerManager.shared
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

#if os(tvOS)

                HStack {
                    Button(role: .destructive) {
                        loggerManager.clearLogs()
                    } label: {
                        Label("Clear All Logs", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(loggerManager.logs.isEmpty)
                    .accessibilityIdentifier("tv.settings.logger.clear")

                    Spacer()
                }
                .padding(.horizontal, 60)
#endif

                if visibleLogs.isEmpty {
                    EclipseEmptyState(
                        icon: "doc.text",
                        title: "No logs found",
                        message: "Logs will appear here as the app records activity."
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
        .navigationTitle(NSLocalizedString("Logs", comment: ""))
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
#if !os(tvOS)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: {
                        Task {
                            do {
                                let exportCategory = selectedCategory == "All" ? nil : selectedCategory
                                let url = try await Logger.shared.exportLogsToTempFile(category: exportCategory)
                                exportItem = ExportItem(url: url)
                            } catch {
                                exportErrorMessage = "Failed to export logs."
                            }
                        }
                    }) {
                        Label("Export Logs", systemImage: "square.and.arrow.up")
                    }
                    Button(action: {
                        loggerManager.clearLogs()
                    }) {
                        Label("Clear All Logs", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
#else
        .accessibilityIdentifier("tv.settings.logger.screen")
#endif
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
        }
    #endif
    }
}

#if !os(tvOS)
struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

struct LogEntryRow: View {
    let log: LogEntry
    #if !os(tvOS)
    @State private var isExpanded = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: log.typeIcon)
                    .foregroundColor(log.typeColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(log.type)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(log.typeColor.opacity(0.2))
                            .foregroundColor(log.typeColor)
                            .cornerRadius(4)

                        Spacer()

                        Text(DateFormatter.logTimeFormatter.string(from: log.timestamp))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                    }

                    Text(log.message)
                        .font(.body)
                        .foregroundColor(.white.opacity(0.9))
#if os(tvOS)
                        .lineLimit(nil)
#else
                        .lineLimit(isExpanded ? nil : 3)
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
#endif

#if !os(tvOS)
                    if log.message.count > 100 {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        }) {
                            Text(isExpanded ? "Show Less" : "Show More")
                                .font(.caption)
                        }
                    }
#endif
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
#if os(tvOS)

        .focusable()
#else
        .onTapGesture {
            if log.message.count > 100 {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }
        }
        .contextMenu {
            Button(action: {
                UIPasteboard.general.string = log.message
            }) {
                Label("Copy Log Message", systemImage: "doc.on.doc")
            }
        }
#endif
    }
}

class LoggerManager: ObservableObject {
    static let shared = LoggerManager()
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
            name: NSNotification.Name("LoggerNotification"),
            object: nil
        )

        DispatchQueue.main.async {
            self.loadExistingLogs()
        }
    }

    @MainActor
    private func loadExistingLogs() {
        Task { @MainActor in
            let existingLogsString = await Logger.shared.getLogsAsync()
            if !existingLogsString.isEmpty {
                let logEntries = await Task.detached(priority: .utility) {
                    Self.parseLogsString(existingLogsString)
                }.value
                self.logs = logEntries
            }
        }
    }

    private static func parseLogsString(_ logsString: String) -> [LogEntry] {
        let logSections = logsString.components(separatedBy: "\n----\n")
        var parsedLogs: [LogEntry] = []

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM HH:mm:ss"

        for section in logSections {
            guard !section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            if let match = logLineRegex.firstMatch(
                in: section,
                options: [],
                range: NSRange(section.startIndex..., in: section)
            ) {

                let timestampRange = Range(match.range(at: 1), in: section)!
                let typeRange = Range(match.range(at: 2), in: section)!
                let messageRange = Range(match.range(at: 3), in: section)!

                let timestampString = String(section[timestampRange])
                let type = Logger.displayCategory(for: String(section[typeRange]))
                let message = String(section[messageRange])

                if let timestamp = dateFormatter.date(from: timestampString) {
                    let logEntry = LogEntry(timestamp: timestamp, message: message, type: type)
                    parsedLogs.append(logEntry)
                }
            }
        }

        return parsedLogs.sorted { $0.timestamp > $1.timestamp }
    }

    @objc private func handleLogNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let message = userInfo["message"] as? String,
              let type = userInfo["type"] as? String else { return }

        let timestamp = userInfo["timestamp"] as? Date ?? Date()
        let entry = LogEntry(
            timestamp: timestamp,
            message: message,
            type: Logger.displayCategory(for: type)
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
        let log = LogEntry(timestamp: Date(), message: message, type: Logger.displayCategory(for: type))
        logs.insert(log, at: 0)

        if logs.count > maxLogs {
            logs = Array(logs.prefix(maxLogs))
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

    func clearLogs() {
        pendingLogEntries.removeAll(keepingCapacity: true)
        logs.removeAll()
        Task {
            await Logger.shared.clearLogsAsync()
        }
    }
}

extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
