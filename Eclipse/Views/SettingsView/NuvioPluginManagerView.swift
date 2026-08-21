import SwiftUI

#if os(iOS) && !targetEnvironment(macCatalyst)
struct NuvioPluginManagerView: View {
    @Environment(\.presentationMode) private var presentationMode
    @StateObject private var manager = NuvioPluginManager.shared
    @StateObject private var accentColorManager = AccentColorManager.shared

    @State private var repositoryURL = ""
    @State private var isInstalling = false
    @State private var alert: NuvioManagerAlert?
    @State private var pendingRemoval: NuvioPluginRepository?

    private var accent: Color { accentColorManager.currentAccentColor }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 22) {
                    addRepositorySection
                    if let progress = manager.installProgress {
                        progressSection(progress)
                    }
                    if manager.repositories.isEmpty {
                        emptySection
                    } else {
                        repositoriesSection
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
                .background(EclipseScrollTracker())
            }
            .navigationTitle("Nuvio Plugins")
            .navigationBarTitleDisplayMode(.inline)
            .background(SettingsGradientBackground().ignoresSafeArea())
            .eclipseDarkToolbar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .alert(item: $alert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .confirmationDialog(
                "Remove Plugin Repository?",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Repository", role: .destructive) {
                    guard let repository = pendingRemoval else { return }
                    pendingRemoval = nil
                    manager.uninstall(repositoryID: repository.id)
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("This removes every provider in the repository and its downloaded code.")
            }
            .onAppear { manager.load() }
        }
        .navigationViewStyle(.stack)
    }

    private var addRepositorySection: some View {
        VStack(spacing: 8) {
            GlassSection(header: "Add Repository") {
                VStack(spacing: 0) {
                    TextField("Manifest URL", text: $repositoryURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundColor(.white)
                        .tint(accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                    GlassDivider(leadingInset: 16)

                    Button {
                        install()
                    } label: {
                        GlassDetailRow(icon: "plus.circle.fill", iconColor: .green, title: "Install Repository") {
                            if isInstalling {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white.opacity(0.6))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isInstalling || repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            GlassSectionFooter("Paste a Nuvio manifest URL. Every provider it lists becomes its own source in Services.")
        }
    }

    private func progressSection(_ progress: NuvioInstallProgress) -> some View {
        GlassSection {
            VStack(alignment: .leading, spacing: 10) {
                Text(progress.label)
                    .font(.subheadline)
                    .foregroundColor(.white)
                if progress.total > 0 {
                    ProgressView(value: progress.fractionCompleted)
                        .tint(accent)
                    Text("\(progress.completed) of \(progress.total)")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                } else {
                    ProgressView().progressViewStyle(.linear).tint(accent)
                }
            }
            .padding(16)
        }
    }

    private var emptySection: some View {
        GlassSection {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.4))
                Text("No Repositories")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("Providers from installed repositories appear in Services alongside your other sources.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .padding(.horizontal, 16)
        }
    }

    private var repositoriesSection: some View {
        VStack(spacing: 8) {
            GlassSection(header: "Installed") {
                VStack(spacing: 0) {
                    ForEach(Array(manager.repositories.enumerated()), id: \.element.id) { index, repository in
                        if index > 0 { GlassDivider(leadingInset: 16) }
                        NavigationLink {
                            NuvioRepositoryDetailView(repositoryID: repository.id, manager: manager)
                        } label: {
                            repositoryRow(repository)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            GlassSectionFooter("Pull to refresh in Services, or open a repository to refresh it and toggle individual providers.")
        }
    }

    private func repositoryRow(_ repository: NuvioPluginRepository) -> some View {
        GlassDetailRow(
            icon: "puzzlepiece.extension.fill",
            iconColor: .mint,
            title: repository.displayName,
            subtitle: subtitle(for: repository)
        ) {
            HStack(spacing: 10) {
                if repository.isRefreshing {
                    ProgressView().progressViewStyle(.circular).tint(.white.opacity(0.6))
                }
                Button {
                    pendingRemoval = repository
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }

    private func subtitle(for repository: NuvioPluginRepository) -> String {
        if let errorMessage = repository.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        let enabled = manager.scraperCount(forRepository: repository.id, runnableOnly: true)
        let total = manager.scraperCount(forRepository: repository.id, runnableOnly: false)
        return "\(enabled) of \(total) providers enabled · \(repository.hostLabel)"
    }

    private func install() {
        let url = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        isInstalling = true
        Task {
            do {
                try await manager.addRepository(rawURL: url)
                repositoryURL = ""
            } catch {
                alert = NuvioManagerAlert(
                    title: "Install Failed",
                    message: error.localizedDescription
                )
            }
            isInstalling = false
        }
    }
}

private struct NuvioManagerAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct NuvioProviderRow: View {
    let scraper: NuvioPluginScraper
    @ObservedObject var manager: NuvioPluginManager
    @ObservedObject var healthStore: SourceHealthStore

    private var currentScraper: NuvioPluginScraper {
        manager.scraper(withID: scraper.id) ?? scraper
    }

    private var healthState: SourceHealthDisplayState {
        guard currentScraper.isRunnable else { return .unchecked }
        return healthStore.displayStates[scraper.id] ?? .unchecked
    }

    var body: some View {
        Button {
            manager.setScraperEnabled(currentScraper.id, enabled: !currentScraper.isRunnable)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(currentScraper.isRunnable ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentScraper.displayName)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    healthLabel
                }
                Spacer()
                if currentScraper.isRunnable {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        var parts = ["Nuvio"]
        if let repository = manager.repository(withID: currentScraper.repositoryId) {
            parts.append(repository.displayName)
        }
        if !currentScraper.manifestEnabled {
            parts.append("disabled by repository")
        }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    private var healthLabel: some View {
        switch healthState {
        case .healthy:
            Label("Reachable", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.green)
        case .warning(let reason), .playbackIssue(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .stale:
            Label("Health check pending", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .unchecked:
            EmptyView()
        }
    }
}

struct NuvioRepositoryDetailView: View {
    let repositoryID: String
    @ObservedObject var manager: NuvioPluginManager
    @StateObject private var accentColorManager = AccentColorManager.shared
    @State private var searchText = ""

    private var accent: Color { accentColorManager.currentAccentColor }

    private var repository: NuvioPluginRepository? {
        manager.repository(withID: repositoryID)
    }

    private var scrapers: [NuvioPluginScraper] {
        let all = manager.scrapers(forRepository: repositoryID)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let repository {
                    overviewSection(repository)
                }
                providersSection
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
            .background(EclipseScrollTracker())
        }
        .navigationTitle(repository?.displayName ?? "Repository")
        .navigationBarTitleDisplayMode(.inline)
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        .searchable(text: $searchText, prompt: "Search providers")
    }

    private func overviewSection(_ repository: NuvioPluginRepository) -> some View {
        VStack(spacing: 8) {
            GlassSection {
                VStack(spacing: 0) {
                    GlassDetailRow(icon: "power", iconColor: .mint, title: "Enabled") {
                        Toggle("", isOn: Binding(
                            get: { repository.isEnabled },
                            set: { manager.setRepositoryEnabled(repository.id, enabled: $0) }
                        ))
                        .labelsHidden()
                        .tint(accent)
                    }

                    GlassDivider()

                    GlassDetailRow(icon: "number", iconColor: .cyan, title: "Version") {
                        Text(repository.version ?? "—")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.5))
                    }

                    GlassDivider()

                    Button {
                        Task { await manager.refreshRepository(repository.id) }
                    } label: {
                        GlassDetailRow(icon: "arrow.clockwise", iconColor: .blue, title: "Refresh Providers") {
                            if repository.isRefreshing {
                                ProgressView().progressViewStyle(.circular).tint(.white.opacity(0.6))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(repository.isRefreshing)

                    GlassDivider()

                    Button {
                        manager.setAllScrapersEnabled(true, inRepository: repository.id)
                    } label: {
                        GlassDetailRow(icon: "checkmark.circle", iconColor: .green, title: "Enable All Providers") { EmptyView() }
                    }
                    .buttonStyle(.plain)

                    GlassDivider()

                    Button {
                        manager.setAllScrapersEnabled(false, inRepository: repository.id)
                    } label: {
                        GlassDetailRow(icon: "xmark.circle", iconColor: .orange, title: "Disable All Providers") { EmptyView() }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let errorMessage = repository.errorMessage, !errorMessage.isEmpty {
                GlassSectionFooter(errorMessage)
            }
        }
    }

    private var providersSection: some View {
        GlassSection(header: "Providers") {
            VStack(spacing: 0) {
                ForEach(Array(scrapers.enumerated()), id: \.element.id) { index, scraper in
                    if index > 0 { GlassDivider(leadingInset: 16) }
                    providerRow(scraper)
                }
            }
        }
    }

    private func providerRow(_ scraper: NuvioPluginScraper) -> some View {
        HStack(spacing: 0) {
            NavigationLink {
                NuvioScraperSettingsView(scraper: scraper, manager: manager)
            } label: {
                GlassDetailRow(
                    icon: "puzzlepiece.extension",
                    iconColor: scraper.isRunnable ? .mint : .gray,
                    title: scraper.name,
                    subtitle: providerSubtitle(scraper)
                ) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { scraper.isRunnable },
                set: { manager.setScraperEnabled(scraper.id, enabled: $0) }
            ))
            .labelsHidden()
            .tint(accent)
            .disabled(!scraper.manifestEnabled)
            .padding(.trailing, 16)
        }
    }

    private func providerSubtitle(_ scraper: NuvioPluginScraper) -> String {
        var parts: [String] = []
        if !scraper.manifestEnabled {
            parts.append("Disabled by repository")
        }
        let types = scraper.supportedTypes
            .map(NuvioPluginSupport.normalizeType)
            .map { $0 == "tv" ? "TV" : $0.capitalized }
        if !types.isEmpty { parts.append(types.joined(separator: ", ")) }
        if !scraper.contentLanguage.isEmpty {
            parts.append(scraper.contentLanguage.prefix(4).joined(separator: "/").uppercased())
        }
        return parts.joined(separator: " · ")
    }
}
#endif
