import Foundation

#if canImport(CrashReporter)
import CrashReporter
#endif

final class CrashReportManager {
    static let shared = CrashReportManager()

    private let fileQueue = DispatchQueue(label: "me.cranci.sora.crashreporter.file")
    private let crashReportURL: URL

#if canImport(CrashReporter)
    private var crashReporter: PLCrashReporter?
#endif

    private init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        crashReportURL = documentsURL.appendingPathComponent("last-native-crash-report.txt")
    }

    func start() {
#if canImport(CrashReporter)
        let symbolicationStrategy: PLCrashReporterSymbolicationStrategy
#if DEBUG
        symbolicationStrategy = .all
#else
        symbolicationStrategy = []
#endif

        let signalHandlerType: PLCrashReporterSignalHandlerType
#if os(tvOS)
        // PLCrashReporter exposes the BSD handler as raw value 0 on tvOS, but
        // this package version doesn't import the acronym as a Swift enum case.
        signalHandlerType = PLCrashReporterSignalHandlerType(rawValue: 0)!
#else
        signalHandlerType = .mach
#endif

        let config = PLCrashReporterConfig(
            signalHandlerType: signalHandlerType,
            symbolicationStrategy: symbolicationStrategy
        )

        guard let reporter = PLCrashReporter(configuration: config) else {
            Logger.shared.log("[CrashReporter] Failed to create PLCrashReporter instance", type: "CrashReporter")
            return
        }

        crashReporter = reporter

        do {
            try reporter.enableAndReturnError()
            Logger.shared.log("[CrashReporter] Native crash reporter enabled", type: "CrashReporter")
            collectPendingCrashReportIfNeeded(from: reporter)
        } catch {
            Logger.shared.log("[CrashReporter] Failed to enable native crash reporter: \(error.localizedDescription)", type: "CrashReporter")
        }
#else
        Logger.shared.log("[CrashReporter] CrashReporter module unavailable; native crash capture disabled", type: "CrashReporter")
#endif
    }

    func latestCrashReportText() -> String? {
        fileQueue.sync {
            guard FileManager.default.fileExists(atPath: crashReportURL.path) else { return nil }
            return try? String(contentsOf: crashReportURL, encoding: .utf8)
        }
    }

#if canImport(CrashReporter)
    private func collectPendingCrashReportIfNeeded(from reporter: PLCrashReporter) {
        guard reporter.hasPendingCrashReport() else { return }

        do {
            let data = try reporter.loadPendingCrashReportDataAndReturnError()
            let report = try PLCrashReport(data: data)
            let text = PLCrashReportTextFormatter.stringValue(
                for: report,
                with: PLCrashReportTextFormatiOS
            ) ?? "CrashReporter could not format pending crash report."

            fileQueue.sync {
                try? text.write(to: crashReportURL, atomically: true, encoding: .utf8)
            }

            Logger.shared.log("[CrashReporter] Captured pending native crash report bytes=\(data.count)", type: "CrashReporter")
        } catch {
            Logger.shared.log("[CrashReporter] Failed to load pending native crash report: \(error.localizedDescription)", type: "CrashReporter")
        }

        reporter.purgePendingCrashReport()
    }
#endif
}
