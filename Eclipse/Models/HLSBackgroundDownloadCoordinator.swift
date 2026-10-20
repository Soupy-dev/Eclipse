import Foundation

enum HLSBackgroundDownloadSettings {
    static let enabledKey = "hlsBackgroundDownloadsEnabled"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }
}

protocol HLSBackgroundDownloadScheduling: AnyObject {
    func request(
        attemptID: UUID,
        title: String,
        onGranted: @escaping () -> Bool,
        onExpiration: @escaping () -> Void,
        onRejected: @escaping () -> Void
    )
    func updateProgress(attemptID: UUID, completed: Int64, total: Int64, subtitle: String)
    func finish(attemptID: UUID, success: Bool)
}

#if os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks

@available(iOS 26.0, *)
final class HLSBackgroundDownloadCoordinator: HLSBackgroundDownloadScheduling {
    static let shared = HLSBackgroundDownloadCoordinator()

    private final class Request {
        let token = UUID()
        var attemptID: UUID?
        var onGranted: (() -> Bool)?
        var onExpiration: (() -> Void)?
        var onRejected: (() -> Void)?
        var task: BGContinuedProcessingTask?
        var expired = false

        init(
            attemptID: UUID,
            onGranted: @escaping () -> Bool,
            onExpiration: @escaping () -> Void,
            onRejected: @escaping () -> Void
        ) {
            self.attemptID = attemptID
            self.onGranted = onGranted
            self.onExpiration = onExpiration
            self.onRejected = onRejected
        }

        func retire() {
            attemptID = nil
            onGranted = nil
            onExpiration = nil
            onRejected = nil
        }
    }

    private final class Slot {
        let identifier: String
        var registered = false
        var request: Request?

        init(identifier: String) {
            self.identifier = identifier
        }
    }

    private let slots: [Slot]

    private init() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            slots = []
            return
        }
        slots = (0..<4).map { Slot(identifier: "\(bundleIdentifier).hls-download.\($0)") }
        for slot in slots {
            slot.registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: slot.identifier, using: .main) { [weak self, weak slot] task in
                guard let self, let slot, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.receive(task, in: slot)
            }
        }
    }

    func request(
        attemptID: UUID,
        title: String,
        onGranted: @escaping () -> Bool,
        onExpiration: @escaping () -> Void,
        onRejected: @escaping () -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !slots.contains(where: { $0.request?.attemptID == attemptID }) else { return }
        guard let slot = slots.first(where: { $0.registered && $0.request == nil }) else {
            onRejected()
            return
        }
        let request = Request(attemptID: attemptID, onGranted: onGranted, onExpiration: onExpiration, onRejected: onRejected)
        slot.request = request
        log("requested", request: request, slot: slot)
        let taskRequest = BGContinuedProcessingTaskRequest(identifier: slot.identifier, title: "Downloading video", subtitle: "Preparing download")
        taskRequest.strategy = .fail
        if #available(iOS 27.0, *) {
            let token = request.token
            DispatchQueue.global(qos: .utility).async { [weak self, weak slot] in
                BGTaskScheduler.shared.submitTaskRequest(taskRequest) { error in
                    DispatchQueue.main.async {
                        guard let self, let slot else { return }
                        self.submissionFinished(in: slot, token: token, error: error)
                    }
                }
            }
        } else {
            do {
                try BGTaskScheduler.shared.submit(taskRequest)
            } catch {
                submissionFinished(in: slot, token: request.token, error: error)
            }
        }
    }

    func updateProgress(attemptID: UUID, completed: Int64, total: Int64, subtitle: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let request = slots.compactMap(\.request).first(where: { $0.attemptID == attemptID }),
              !request.expired,
              let task = request.task else { return }
        let boundedTotal = max(1, total)
        task.progress.totalUnitCount = boundedTotal
        task.progress.completedUnitCount = min(max(0, completed), boundedTotal)
        let displaySubtitle = subtitle.contains("://") ? "Downloading video" : String(subtitle.prefix(120))
        task.updateTitle("Downloading video", subtitle: displaySubtitle)
    }

    func finish(attemptID: UUID, success: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let slot = slots.first(where: { $0.request?.attemptID == attemptID }),
              let request = slot.request else { return }
        log("finished success=\(success && !request.expired)", request: request, slot: slot)
        request.retire()
        if let task = request.task {
            slot.request = nil
            task.expirationHandler = nil
            task.setTaskCompleted(success: success && !request.expired)
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: slot.identifier)
        }
    }

    private func submissionFinished(in slot: Slot, token: UUID, error: Error?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let request = slot.request, request.token == token else { return }
        if let error {
            let failure = error as NSError
            let domain = failure.domain == BGTaskScheduler.errorDomain ? "BGTaskScheduler" : "other"
            log("rejected domain=\(domain) code=\(failure.code)", request: request, slot: slot)
            if request.task != nil {
                expire(request, in: slot)
                return
            }
            let onRejected = request.onRejected
            request.retire()
            slot.request = nil
            onRejected?()
        } else if request.attemptID == nil {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: slot.identifier)
        }
    }

    private func receive(_ task: BGContinuedProcessingTask, in slot: Slot) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let request = slot.request else {
            task.setTaskCompleted(success: false)
            return
        }
        guard request.task == nil else {
            task.setTaskCompleted(success: false)
            return
        }
        guard request.attemptID != nil else {
            slot.request = nil
            task.setTaskCompleted(success: false)
            return
        }
        request.task = task
        task.progress.totalUnitCount = 1
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self, weak slot, weak request] in
            DispatchQueue.main.async {
                guard let self, let slot, let request else { return }
                self.expire(request, in: slot)
            }
        }
        let granted = request.onGranted?() == true
        log("granted accepted=\(granted)", request: request, slot: slot)
        guard slot.request === request, request.task === task else { return }
        request.onGranted = nil
        if !granted {
            let onRejected = request.onRejected
            request.retire()
            slot.request = nil
            task.expirationHandler = nil
            task.setTaskCompleted(success: false)
            onRejected?()
        }
    }

    private func log(_ event: String, request: Request, slot: Slot) {
        let attempt = request.attemptID?.uuidString ?? "retired"
        let index = slots.firstIndex(where: { $0 === slot }) ?? -1
        Logger.shared.log("HLSBackground attempt=\(attempt) slot=\(index) \(event)", type: "Download")
    }

    private func expire(_ request: Request, in slot: Slot) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard slot.request === request, request.attemptID != nil, !request.expired else { return }
        log("expired", request: request, slot: slot)
        request.expired = true
        let onExpiration = request.onExpiration
        request.onExpiration = nil
        onExpiration?()
    }
}
#endif
