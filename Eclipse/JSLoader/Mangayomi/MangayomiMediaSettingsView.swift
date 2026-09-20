import SwiftUI

struct MangayomiMediaSettingsView: View {
    @ObservedObject private var manager = MangayomiMediaManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var repositoryURL = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        NavigationView {
            List {
                if !manager.storeIsReadable {
                    Text("Saved Mangayomi settings could not be read. They have been preserved.")
                        .foregroundColor(.orange)
                }
                Section {
                    TextField("Anime repository URL", text: $repositoryURL)
                        .accessibilityIdentifier("mangayomi.repositoryURL")
                    Button(busy ? "Loading…" : "Add Repository") {
                        run { try await manager.addRepository(repositoryURL); repositoryURL = "" }
                    }
                    .disabled(busy || repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("mangayomi.addRepository")
                } footer: {
                    Text("Add a Mangayomi anime index, then install the sources you want to use. Source setup is included in backups; automatic cloud sync is not available yet.")
                }
                .eclipseExperimentalSettingsRows()
                Section("Repositories") {
                    ForEach(manager.state.repositories) { repository in
                        NavigationLink {
                            MangayomiMediaRepositoryView(repositoryURL: repository.url)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(string: repository.url)?.host ?? "Repository")
                                Text("\(repository.sources.count) anime sources")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let repositories = offsets.compactMap { manager.state.repositories.indices.contains($0) ? manager.state.repositories[$0] : nil }
                        for repository in repositories {
                            do { try manager.removeRepository(repository) } catch { failure = error.localizedDescription }
                        }
                    }
                }
                .eclipseExperimentalSettingsRows()
                Section("Installed Sources") {
                    ForEach(manager.state.installed) { source in
                        NavigationLink {
                            MangayomiMediaSourceView(sourceID: source.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name)
                                Text(manager.readySourceIDs.contains(source.id) ? (source.enabled ? "Enabled" : "Disabled") : "Code missing · repair required")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .eclipseExperimentalSettingsRows()
                if let failure { Text(failure).foregroundColor(.orange) }
            }
            .eclipseSettingsStyle()
            .navigationTitle("Mangayomi Media")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .disabled(ProfileManager.shared.isKidsModeActive)
        }
        .preferredColorScheme(.dark)
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        failure = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { failure = error.localizedDescription }
        }
    }
}

private struct MangayomiMediaRepositoryView: View {
    let repositoryURL: String
    @ObservedObject private var manager = MangayomiMediaManager.shared
    @State private var query = ""
    @State private var language = "all"
    @State private var busy: UUID?
    @State private var failure: String?

    private var sources: [MangayomiMediaSource] {
        manager.state.repositories.first(where: { $0.url == repositoryURL })?.sources ?? []
    }

    var body: some View {
        List {
            Section {
                TextField("Search sources", text: $query)
                Picker("Language", selection: $language) {
                    Text("All languages").tag("all")
                    ForEach(Array(Set(sources.map(\.language))).filter { $0 != "all" }.sorted(), id: \.self) { value in
                        Text(Locale.current.localizedString(forLanguageCode: value) ?? value).tag(value)
                    }
                }
                Button("Refresh Repository") {
                    failure = nil
                    Task { @MainActor in
                        do { try await manager.addRepository(repositoryURL) } catch { failure = error.localizedDescription }
                    }
                }
            }
            .eclipseExperimentalSettingsRows()
            Section {
                ForEach(sources.filter { source in
                    (language == "all" || source.language == language)
                        && (query.isEmpty || source.name.localizedCaseInsensitiveContains(query))
                }) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name)
                            Text("\(source.language.uppercased()) · \(source.version)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if manager.state.installed.contains(where: { $0.id == source.id && $0.version == source.version && manager.readySourceIDs.contains($0.id) }) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        } else {
                            Button(busy == source.id ? "Installing…" : "Install") {
                                busy = source.id
                                failure = nil
                                Task { @MainActor in
                                    defer { busy = nil }
                                    do { try await manager.install(source) } catch { failure = error.localizedDescription }
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(busy != nil)
                        }
                    }
                }
            }
            .eclipseExperimentalSettingsRows()
            if let failure { Text(failure).foregroundColor(.orange) }
        }
        .eclipseSettingsStyle()
        .navigationTitle("Anime Sources")
        .preferredColorScheme(.dark)
    }
}

struct MangayomiMediaSourceView: View {
    let sourceID: UUID
    @ObservedObject private var manager = MangayomiMediaManager.shared
    @State private var schema: [[String: Any]] = []
    @State private var failure: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    private var source: MangayomiMediaSource? { manager.state.installed.first { $0.id == sourceID } }

    var body: some View {
        List {
            if let source {
                Section {
                    Toggle("Enabled", isOn: Binding(get: { self.source?.enabled ?? false }, set: { value in
                        do { try manager.setEnabled(value, id: sourceID) } catch { failure = error.localizedDescription }
                    }))
                    Button(busy ? "Repairing…" : "Update or Repair Source") {
                        busy = true
                        Task { @MainActor in
                            defer { busy = false }
                            do { try await manager.install(source); await loadPreferences() } catch { failure = error.localizedDescription }
                        }
                    }
                    .disabled(busy)
                }
                .eclipseExperimentalSettingsRows()
                if !schema.isEmpty {
                    Section("Source Preferences") {
                        ForEach(schema.indices, id: \.self) { index in
                            preferenceRow(schema[index])
                        }
                    }
                    .eclipseExperimentalSettingsRows()
                }
                Section {
                    Button("Remove Source", role: .destructive) {
                        do { try manager.remove(id: sourceID); dismiss() } catch { failure = error.localizedDescription }
                    }
                }
                .eclipseExperimentalSettingsRows()
            }
            if let failure { Text(failure).foregroundColor(.orange) }
        }
        .eclipseSettingsStyle()
        .navigationTitle(source?.name ?? "Source")
        .preferredColorScheme(.dark)
        .task(id: sourceID) { await loadPreferences() }
    }

    @ViewBuilder
    private func preferenceRow(_ row: [String: Any]) -> some View {
        if let key = row["key"] as? String {
            if let setting = row["listPreference"] as? [String: Any],
               let values = setting["entryValues"] as? [String],
               let labels = setting["entries"] as? [String], values.count == labels.count {
                let index = setting["valueIndex"] as? Int ?? 0
                Picker(setting["title"] as? String ?? key, selection: Binding(
                    get: { manager.preferences(for: sourceID)[key] as? String ?? (values.indices.contains(index) ? values[index] : "") },
                    set: { save($0, key: key) }
                )) {
                    ForEach(values.indices, id: \.self) { item in Text(labels[item]).tag(values[item]) }
                }
            } else if let setting = (row["switchPreferenceCompat"] ?? row["checkBoxPreference"]) as? [String: Any] {
                Toggle(setting["title"] as? String ?? key, isOn: Binding(
                    get: { manager.preferences(for: sourceID)[key] as? Bool ?? setting["value"] as? Bool ?? false },
                    set: { save($0, key: key) }
                ))
            } else if let setting = row["editTextPreference"] as? [String: Any] {
                SecureField(setting["title"] as? String ?? key, text: Binding(
                    get: { manager.preferences(for: sourceID)[key] as? String ?? setting["text"] as? String ?? setting["value"] as? String ?? "" },
                    set: { save($0, key: key) }
                ))
            } else if let setting = row["multiSelectListPreference"] as? [String: Any],
                      let values = setting["entryValues"] as? [String],
                      let labels = setting["entries"] as? [String], values.count == labels.count {
                Section(setting["title"] as? String ?? key) {
                    ForEach(values.indices, id: \.self) { index in
                        Toggle(labels[index], isOn: Binding(
                            get: { selections(key: key, setting: setting).contains(values[index]) },
                            set: { selected in
                                var current = selections(key: key, setting: setting)
                                if selected { current.insert(values[index]) } else { current.remove(values[index]) }
                                save(current.sorted(), key: key)
                            }
                        ))
                    }
                }
            }
        }
    }

    private func selections(key: String, setting: [String: Any]) -> Set<String> {
        Set(manager.preferences(for: sourceID)[key] as? [String] ?? setting["values"] as? [String] ?? [])
    }

    private func save(_ value: Any, key: String) {
        do { try manager.setPreference(value, key: key, sourceID: sourceID) } catch { failure = error.localizedDescription }
    }

    private func loadPreferences() async {
        guard let source, manager.readySourceIDs.contains(source.id) else { return }
        do {
            let data = try await manager.execute(source: source, operation: "preferences", arguments: [:])
            schema = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        } catch { failure = error.localizedDescription }
    }
}
