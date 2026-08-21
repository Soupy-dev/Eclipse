//
//  KanzenAidokuMigrationView.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

import SwiftUI

#if !os(tvOS)
struct KanzenAidokuReconnectRequest: Identifiable, Hashable {
    let legacySourceID: String
    let title: String?

    init(legacySourceID: String, title: String? = nil) {
        self.legacySourceID = legacySourceID
        self.title = title
    }

    var id: String { legacySourceID }
}

struct KanzenAidokuMigrationJob: Identifiable, Hashable {
    let legacySourceID: String
    let legacySourceName: String
    let installedSourceID: ReaderExtensionSourceID
    let installedSourceName: String

    var id: String { "\(legacySourceID)\u{1f}\(installedSourceID.rawValue)" }
}

struct KanzenAidokuMigrationRun: Identifiable, Hashable {
    let jobs: [KanzenAidokuMigrationJob]

    var id: String { jobs.map(\.id).joined(separator: "|") }
}

struct KanzenAidokuSourceChoiceRequest: Identifiable {
    let sourcePlan: KanzenAidokuSourcePlan

    var id: String { sourcePlan.id }
}

enum KanzenAidokuMigrationCopy {
    static let safetyLine = "Nothing is ever deleted. Covers, titles and reading progress stay exactly where they are."

    static func counted(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }

    static func sourceCount(_ summary: KanzenAidokuMigrationSummary) -> Int {
        Set(summary.legacySourceIDs).union(summary.referencedSourceIDs).count
    }

    static func headline(_ summary: KanzenAidokuMigrationSummary) -> String {
        let sources = counted(sourceCount(summary), "older source", "older sources")
        guard summary.affectedEntryCount > 0 else {
            return "You still have \(sources) set up from before, but none of your saved manga uses them."
        }
        let titles = counted(summary.affectedEntryCount, "saved title", "saved titles")
        return "\(titles) came from \(sources) that Eclipse no longer uses."
    }

    static func progressLine(_ summary: KanzenAidokuMigrationSummary) -> String? {
        guard summary.libraryEntriesWithProgress > 0 else { return nil }
        return summary.libraryEntriesWithProgress == 1
            ? "One of them has reading progress saved."
            : "\(summary.libraryEntriesWithProgress) of them have reading progress saved."
    }

    static func friendlySourceName(forLegacySourceID identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.split(separator: ".").last.map(String.init) ?? trimmed
        guard let first = candidate.first else { return "An older source" }
        return String(first).uppercased() + String(candidate.dropFirst())
    }

    static func reasons(_ evidence: [KanzenAidokuMatchEvidence]) -> [String] {
        var found: [String] = []
        if evidence.contains(.upstreamSourceIdentifier)
            || evidence.contains(.providerHost)
            || evidence.contains(.identifierHost) {
            found.append("Same website")
        }
        if evidence.contains(.sourceName) {
            found.append("Same name")
        } else if evidence.contains(.identifierAffinity) {
            found.append("Similar name")
        }
        if evidence.contains(.language) {
            found.append("Same language")
        }
        return found
    }

    static func reasonText(_ evidence: [KanzenAidokuMatchEvidence]) -> String {
        let found = reasons(evidence)
        return found.isEmpty ? "No obvious match" : found.joined(separator: " · ")
    }

    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        let head = names.dropLast().joined(separator: ", ")
        return "\(head) and \(names.last ?? "")"
    }

    static func confirmMessage(_ run: KanzenAidokuMigrationRun) -> String {
        guard let single = run.jobs.first, run.jobs.count == 1 else {
            return "Eclipse checks every saved title first. Any source it can't match all the way through is left exactly as it is."
        }
        return "Eclipse checks every saved title from \(single.legacySourceName) against \(single.installedSourceName) first. If even one doesn't line up, nothing changes for it."
    }

    static func resultMessage(
        connectedSources: Int,
        connectedTitles: Int,
        unavailableTitles: Int = 0,
        failedNames: [String],
        interruptedNames: [String] = [],
        wasStopped: Bool
    ) -> String {
        if wasStopped {
            return "Eclipse stopped early to keep your saved manga safe, so nothing was changed."
        }
        var parts: [String] = []
        if connectedSources > 0 {
            parts.append(
                "Reconnected \(counted(connectedSources, "source", "sources")) and \(counted(connectedTitles, "saved title", "saved titles"))."
            )
        }
        if unavailableTitles > 0 {
            parts.append(
                "\(counted(unavailableTitles, "title", "titles")) couldn't be found on the new source, so \(unavailableTitles == 1 ? "it stays" : "they stay") in your library marked unavailable."
            )
        }
        if !interruptedNames.isEmpty {
            let names = list(interruptedNames)
            parts.append(
                interruptedNames.count == 1
                    ? "\(names) stopped answering part way through. Everything checked so far was saved, so trying again picks up where it left off."
                    : "\(names) stopped answering part way through. Everything checked so far was saved, so trying again picks up where they left off."
            )
        }
        if !failedNames.isEmpty {
            let names = list(failedNames)
            parts.append(
                failedNames.count == 1
                    ? "\(names) couldn't be matched all the way through, so nothing changed for it. Its saved titles are still in your library."
                    : "\(names) couldn't be matched all the way through, so nothing changed for them. Their saved titles are still in your library."
            )
        }
        guard !parts.isEmpty else {
            return "Nothing changed. Your saved manga is exactly as it was."
        }
        return parts.joined(separator: " ")
    }
}

struct KanzenAidokuMigrationView: View {
    var focusedLegacySourceID: String?
    var focusedTitle: String?

    @StateObject private var coordinator = KanzenAidokuMigrationCoordinator.shared
    @ObservedObject private var contentFilter = ReaderContentFilter.shared

    @State private var chooser: KanzenAidokuSourceChoiceRequest?
    @State private var pendingRun: KanzenAidokuMigrationRun?
    @State private var progressText: String?
    @State private var resultMessage: String?
    @State private var showsEverySource = false
    @State private var isWorking = false

    init(focusedLegacySourceID: String? = nil, focusedTitle: String? = nil) {
        self.focusedLegacySourceID = focusedLegacySourceID
        self.focusedTitle = focusedTitle
    }

    var body: some View {
        Group {
            if contentFilter.isKidsProfileActive {
                restrictedContent
            } else {
                migrationContent
            }
        }
        .preferredColorScheme(.dark)
    }

    private var restrictedContent: some View {
        List {
            Section {
                Text("This is a kids profile, so it can't change where saved manga comes from. Switch to a grown-up profile to sort this out.")
                    .foregroundColor(.secondary)
            }
            .eclipseExperimentalSettingsRows()
        }
        .navigationTitle("Saved Manga")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseSettingsStyle()
    }

    @ViewBuilder
    private var migrationContent: some View {
        if coordinator.summary.isBlocked {
            noticeContent(
                icon: "exclamationmark.circle",
                headline: "Eclipse left everything alone",
                message: "Your saved manga couldn't be read safely just now, so nothing was touched. Close Eclipse and open it again, then come back here."
            )
        } else if isWorking || !coordinator.plan.isEmpty {
            planContent
        } else if coordinator.phase == .detecting {
            noticeContent(
                icon: "hourglass",
                headline: "Having a look",
                message: "Checking which of your saved manga needs a new source."
            )
        } else {
            noticeContent(
                icon: "checkmark.circle",
                headline: "All sorted",
                message: resultMessage ?? "None of your saved manga is waiting on an older source."
            )
        }
    }

    private func noticeContent(icon: String, headline: String, message: String) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundColor(.orange)
                    Text(headline)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 6)
            }
            .eclipseExperimentalSettingsRows()
        }
        .navigationTitle("Saved Manga")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseSettingsStyle()
        .task { await refresh() }
    }

    private var planContent: some View {
        List {
            statusSection
            readySection
            chooseSection
            waitingSection
        }
        .navigationTitle("Saved Manga")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseSettingsStyle()
        .task { await refresh() }
        .sheet(item: $chooser) { request in
            KanzenAidokuSourceChooserView(request: request) { candidate in
                chooser = nil
                start(
                    KanzenAidokuMigrationRun(
                        jobs: [job(for: request.sourcePlan, candidate: candidate)]
                    )
                )
            }
        }
        .confirmationDialog(
            "Reconnect now?",
            isPresented: Binding(
                get: { pendingRun != nil },
                set: { if !$0 { pendingRun = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Reconnect") {
                guard let run = pendingRun else { return }
                pendingRun = nil
                start(run)
            }
            Button("Cancel", role: .cancel) { pendingRun = nil }
        } message: {
            Text(pendingRun.map(KanzenAidokuMigrationCopy.confirmMessage) ?? KanzenAidokuMigrationCopy.safetyLine)
        }
    }

    private var statusSection: some View {
        Section(header: Text("What We Found")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(KanzenAidokuMigrationCopy.headline(coordinator.summary))
                    .font(.subheadline)
                if let line = KanzenAidokuMigrationCopy.progressLine(coordinator.summary) {
                    Text(line)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(KanzenAidokuMigrationCopy.safetyLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)

            if let focusLine {
                VStack(alignment: .leading, spacing: 6) {
                    Text(focusLine)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Show Everything Else Too") {
                        showsEverySource = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
            }

            if let progressText {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(progressText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // Checking a large library takes minutes, and every
                        // answer is saved as it arrives, so the count is what
                        // tells the user an interrupted run will resume rather
                        // than start over.
                        if let progress = coordinator.applyProgress, progress.total > 0 {
                            Text("\(progress.checked) of \(progress.total) checked \u{00b7} \(progress.resolved) matched")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
            }

            if let resultMessage {
                Text(resultMessage)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
            }
        }
        .eclipseExperimentalSettingsRows()
        .background(EclipseScrollTracker())
    }

    @ViewBuilder
    private var readySection: some View {
        let ready = visible(coordinator.plan.confidentSources)
        if !ready.isEmpty {
            Section(
                header: Text("Ready To Reconnect"),
                footer: Text("Eclipse found a source you already have installed that looks like the right home for these.")
            ) {
                ForEach(ready) { sourcePlan in
                    KanzenAidokuReadyRow(sourcePlan: sourcePlan, isBusy: isWorking) { candidate in
                        pendingRun = KanzenAidokuMigrationRun(
                            jobs: [job(for: sourcePlan, candidate: candidate)]
                        )
                    }
                }

                if ready.count > 1 {
                    Button {
                        pendingRun = KanzenAidokuMigrationRun(
                            jobs: ready.compactMap { job(for: $0) }
                        )
                    } label: {
                        Label("Reconnect All", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isWorking)
                }
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())
        }
    }

    @ViewBuilder
    private var chooseSection: some View {
        let undecided = visible(coordinator.plan.ambiguousSources)
        if !undecided.isEmpty {
            Section(
                header: Text("Needs Your Choice"),
                footer: Text("Eclipse isn't sure which of your installed sources these belong to, so it won't guess.")
            ) {
                ForEach(undecided) { sourcePlan in
                    KanzenAidokuChoiceRow(sourcePlan: sourcePlan, isBusy: isWorking) {
                        chooser = KanzenAidokuSourceChoiceRequest(sourcePlan: sourcePlan)
                    }
                }
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())
        }
    }

    @ViewBuilder
    private var waitingSection: some View {
        let waiting = visible(coordinator.plan.unmatchedSources)
        let orphans = visibleOrphans
        if !waiting.isEmpty || !orphans.isEmpty {
            Section(
                header: Text("Waiting For A Source"),
                footer: Text("These stay in your library with a badge so you can spot them. Install a source that matches and Eclipse reconnects them for you.")
            ) {
                ForEach(waiting) { sourcePlan in
                    KanzenAidokuWaitingRow(
                        name: sourcePlan.legacySource.name,
                        entryCount: sourcePlan.entryCount
                    )
                }

                ForEach(orphans, id: \.self) { sourceID in
                    KanzenAidokuWaitingRow(
                        name: KanzenAidokuMigrationCopy.friendlySourceName(forLegacySourceID: sourceID),
                        entryCount: coordinator.legacyEntries(forLegacySourceID: sourceID).count
                    )
                }

                NavigationLink(destination: ReaderExtensionsSettingsView()) {
                    Label("Add A Reader Source", systemImage: "shippingbox.fill")
                }
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())
        }
    }

    private var activeFocusID: String? {
        guard !showsEverySource, let focusedLegacySourceID else { return nil }
        guard coordinator.plan.sources.contains(where: { $0.id == focusedLegacySourceID }) else {
            return nil
        }
        return focusedLegacySourceID
    }

    private var focusLine: String? {
        guard activeFocusID != nil else { return nil }
        guard let focusedTitle, !focusedTitle.isEmpty else {
            return "Showing just the source behind the title you tapped."
        }
        return "Showing just the source behind \u{201c}\(focusedTitle)\u{201d}."
    }

    private var visibleOrphans: [String] {
        guard let activeFocusID else { return coordinator.plan.orphanSourceIDs }
        return coordinator.plan.orphanSourceIDs.filter { $0 == activeFocusID }
    }

    private func visible(_ sources: [KanzenAidokuSourcePlan]) -> [KanzenAidokuSourcePlan] {
        guard let activeFocusID else { return sources }
        return sources.filter { $0.id == activeFocusID }
    }

    private func job(for sourcePlan: KanzenAidokuSourcePlan) -> KanzenAidokuMigrationJob? {
        guard let candidate = sourcePlan.match.confidentCandidate else { return nil }
        return job(for: sourcePlan, candidate: candidate)
    }

    private func job(
        for sourcePlan: KanzenAidokuSourcePlan,
        candidate: KanzenAidokuScoredCandidate
    ) -> KanzenAidokuMigrationJob {
        KanzenAidokuMigrationJob(
            legacySourceID: sourcePlan.id,
            legacySourceName: sourcePlan.legacySource.name,
            installedSourceID: candidate.installedSource.id,
            installedSourceName: candidate.installedSource.name
        )
    }

    private func refresh() async {
        guard !contentFilter.isKidsProfileActive, !isWorking else { return }
        await coordinator.markUnavailableEntries()
    }

    private func start(_ run: KanzenAidokuMigrationRun) {
        guard !isWorking, !run.jobs.isEmpty else { return }
        isWorking = true
        resultMessage = nil
        let jobs = run.jobs
        Task { @MainActor in
            var connectedSources = 0
            var connectedTitles = 0
            var unavailableTitles = 0
            var failedNames: [String] = []
            var interruptedNames: [String] = []
            var wasStopped = false

            for (index, step) in jobs.enumerated() {
                progressText = jobs.count == 1
                    ? "Checking saved titles from \(step.legacySourceName)\u{2026}"
                    : "Checking \(step.legacySourceName)\u{2026} (\(index + 1) of \(jobs.count))"
                let outcome = await coordinator.reconnect(
                    legacySourceID: step.legacySourceID,
                    to: step.installedSourceID
                )
                if outcome.status == .blockedByUnreadableStore || outcome.status == .blockedByKidsMode {
                    wasStopped = true
                    break
                }
                // A run already in flight from another entry point is not a
                // failed match. Reporting it as one tells the user nothing
                // changed while the first run is still working.
                if outcome.status == .alreadyRunning {
                    wasStopped = true
                    break
                }
                if outcome.reconnectedSourceIDs.contains(step.legacySourceID) {
                    connectedSources += 1
                    connectedTitles += outcome.reconnectedItemCount
                    unavailableTitles += outcome.retainedItemCount
                } else if outcome.hasResumableFailure {
                    interruptedNames.append(step.legacySourceName)
                } else {
                    failedNames.append(step.legacySourceName)
                }
            }

            progressText = nil
            isWorking = false
            resultMessage = KanzenAidokuMigrationCopy.resultMessage(
                connectedSources: connectedSources,
                connectedTitles: connectedTitles,
                unavailableTitles: unavailableTitles,
                failedNames: failedNames,
                interruptedNames: interruptedNames,
                wasStopped: wasStopped
            )
        }
    }
}

struct KanzenAidokuMigrationSheet: View {
    var focusedLegacySourceID: String?
    var focusedTitle: String?

    @Environment(\.dismiss) private var dismiss

    init(focusedLegacySourceID: String? = nil, focusedTitle: String? = nil) {
        self.focusedLegacySourceID = focusedLegacySourceID
        self.focusedTitle = focusedTitle
    }

    var body: some View {
        NavigationView {
            KanzenAidokuMigrationView(
                focusedLegacySourceID: focusedLegacySourceID,
                focusedTitle: focusedTitle
            )
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .preferredColorScheme(.dark)
    }
}

struct KanzenAidokuReadyRow: View {
    let sourcePlan: KanzenAidokuSourcePlan
    let isBusy: Bool
    let action: (KanzenAidokuScoredCandidate) -> Void

    var body: some View {
        if let candidate = sourcePlan.match.confidentCandidate {
            VStack(alignment: .leading, spacing: 5) {
                Text(sourcePlan.legacySource.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(detail(candidate))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    action(candidate)
                } label: {
                    Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                .disabled(isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        }
    }

    private func detail(_ candidate: KanzenAidokuScoredCandidate) -> String {
        let titles = KanzenAidokuMigrationCopy.counted(
            sourcePlan.entryCount,
            "saved title",
            "saved titles"
        )
        return "\(titles) \u{2192} \(candidate.installedSource.name)"
    }
}

struct KanzenAidokuChoiceRow: View {
    let sourcePlan: KanzenAidokuSourcePlan
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(sourcePlan.legacySource.name)
                .font(.subheadline)
                .fontWeight(.medium)

            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: action) {
                Label("Pick A Source\u{2026}", systemImage: "hand.tap")
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
            .disabled(isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private var detail: String {
        let titles = KanzenAidokuMigrationCopy.counted(
            sourcePlan.entryCount,
            "saved title",
            "saved titles"
        )
        let options = sourcePlan.match.reviewCandidates.count
        return "\(titles) · \(KanzenAidokuMigrationCopy.counted(options, "possible match", "possible matches"))"
    }
}

struct KanzenAidokuWaitingRow: View {
    let name: String
    let entryCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.subheadline)
                .fontWeight(.medium)

            Text("\(KanzenAidokuMigrationCopy.counted(entryCount, "saved title", "saved titles")) kept in your library")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }
}

struct KanzenAidokuSourceChooserView: View {
    let request: KanzenAidokuSourceChoiceRequest
    let onConfirm: (KanzenAidokuScoredCandidate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pending: KanzenAidokuScoredCandidate?

    var body: some View {
        NavigationView {
            List {
                Section(
                    header: Text("Where Should These Go?"),
                    footer: Text("Nothing is deleted whichever you pick. If the saved titles don't line up with the source you choose, Eclipse leaves them exactly as they are.")
                ) {
                    ForEach(request.sourcePlan.match.reviewCandidates) { candidate in
                        Button {
                            pending = candidate
                        } label: {
                            row(candidate)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!candidate.installedSource.isRunnable)
                    }
                }
                .eclipseExperimentalSettingsRows()
                .background(EclipseScrollTracker())
            }
            .navigationTitle(request.sourcePlan.legacySource.name)
            .navigationBarTitleDisplayMode(.inline)
            .eclipseSettingsStyle()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog(
                "Use this source?",
                isPresented: Binding(
                    get: { pending != nil },
                    set: { if !$0 { pending = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Check And Reconnect") {
                    guard let candidate = pending else { return }
                    pending = nil
                    onConfirm(candidate)
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text(confirmMessage)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .preferredColorScheme(.dark)
    }

    private func row(_ candidate: KanzenAidokuScoredCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(candidate.installedSource.name)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white)

            Text(subtitle(candidate))
                .font(.caption)
                .foregroundColor(.secondary)

            if !candidate.installedSource.isRunnable {
                Text("Turn this source on in Reader Sources before you can use it here.")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }

    private func subtitle(_ candidate: KanzenAidokuScoredCandidate) -> String {
        let language = ReaderExtensionLanguageInfo.displayName(candidate.installedSource.language)
        return "\(language) · \(KanzenAidokuMigrationCopy.reasonText(candidate.evidence))"
    }

    private var confirmMessage: String {
        let replacement = pending?.installedSource.name ?? "this source"
        return "Eclipse checks every saved title from \(request.sourcePlan.legacySource.name) against \(replacement) first. If even one doesn't line up, nothing changes."
    }
}
#endif
