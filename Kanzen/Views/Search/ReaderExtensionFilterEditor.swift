//
//  ReaderExtensionFilterEditor.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

import SwiftUI

#if !os(tvOS)
struct ReaderExtensionFilterDisplayRow: Identifiable {
    var id: String { path.map(String.init).joined(separator: ".") }
    let path: [Int]
    let filter: ReaderExtensionFilter
    let depth: Int
}

enum ReaderExtensionFilterTree {
    static func rows(for filters: [ReaderExtensionFilter]) -> [ReaderExtensionFilterDisplayRow] {
        flatten(filters, parentPath: [], depth: 0)
    }

    static func flatten(
        _ filters: [ReaderExtensionFilter],
        parentPath: [Int],
        depth: Int
    ) -> [ReaderExtensionFilterDisplayRow] {
        guard depth < 8 else { return [] }
        return filters.indices.flatMap { index -> [ReaderExtensionFilterDisplayRow] in
            let path = parentPath + [index]
            let row = ReaderExtensionFilterDisplayRow(path: path, filter: filters[index], depth: depth)
            return [row] + flatten(filters[index].children, parentPath: path, depth: depth + 1)
        }
    }

    static func filter(
        in filters: [ReaderExtensionFilter],
        at path: ArraySlice<Int>
    ) -> ReaderExtensionFilter? {
        guard let index = path.first, filters.indices.contains(index) else { return nil }
        guard path.count > 1 else { return filters[index] }
        return filter(in: filters[index].children, at: path.dropFirst())
    }

    static func replacingValue(
        in filters: [ReaderExtensionFilter],
        at path: ArraySlice<Int>,
        with value: ReaderExtensionPreferenceValue,
        optionIndex: Int? = nil
    ) -> [ReaderExtensionFilter] {
        guard let index = path.first, filters.indices.contains(index) else { return filters }
        var copy = filters
        if path.count == 1 {
            copy[index].value = value
            if let optionIndex { copy[index].selectedOptionIndex = optionIndex }
        } else {
            copy[index].children = replacingValue(
                in: copy[index].children,
                at: path.dropFirst(),
                with: value,
                optionIndex: optionIndex
            )
        }
        return copy
    }

    static func replacingSortAscending(
        in filters: [ReaderExtensionFilter],
        at path: ArraySlice<Int>,
        with ascending: Bool
    ) -> [ReaderExtensionFilter] {
        guard let index = path.first, filters.indices.contains(index) else { return filters }
        var copy = filters
        if path.count == 1 {
            guard copy[index].kind == .sort else { return filters }
            copy[index].sortAscending = ascending
        } else {
            copy[index].children = replacingSortAscending(
                in: copy[index].children,
                at: path.dropFirst(),
                with: ascending
            )
        }
        return copy
    }
}

@MainActor
final class ReaderExtensionFilterEditorModel: ObservableObject {
    @Published var filters: [ReaderExtensionFilter] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var successfulLoadRevision = 0

    private var loadToken = UUID()
    private var loadTask: Task<Void, Never>?
    private var initialDefaults: [ReaderExtensionFilter]?

    var displayRows: [ReaderExtensionFilterDisplayRow] {
        ReaderExtensionFilterTree.rows(for: filters)
    }

    var canReset: Bool {
        guard let initialDefaults else { return false }
        return !isLoading && filters != initialDefaults
    }

    func load(sourceID: ReaderExtensionSourceID, label: String) {
        guard filters.isEmpty, !isLoading else { return }
        request(sourceID: sourceID, label: label, reason: "initial")
    }

    func reload(sourceID: ReaderExtensionSourceID, label: String) {
        request(sourceID: sourceID, label: label, reason: "refresh")
    }

    @discardableResult
    func reset() -> Bool {
        guard !isLoading,
              let initialDefaults,
              filters != initialDefaults else {
            return false
        }
        filters = initialDefaults
        errorMessage = nil
        ReaderLogger.shared.log("Reader filters reset to initial defaults", type: "ReaderSearch")
        return true
    }

    func filter(at path: [Int]) -> ReaderExtensionFilter? {
        ReaderExtensionFilterTree.filter(in: filters, at: ArraySlice(path))
    }

    func setValue(_ value: ReaderExtensionPreferenceValue, at path: [Int]) {
        filters = ReaderExtensionFilterTree.replacingValue(
            in: filters,
            at: ArraySlice(path),
            with: value
        )
    }

    /// Select and sort choices are positional. Option values repeat across
    /// entries in real catalogs, so the index has to travel with the value.
    func setSelectedOption(_ index: Int, value: ReaderExtensionPreferenceValue, at path: [Int]) {
        filters = ReaderExtensionFilterTree.replacingValue(
            in: filters,
            at: ArraySlice(path),
            with: value,
            optionIndex: index
        )
    }

    func setSortAscending(_ ascending: Bool, at path: [Int]) {
        filters = ReaderExtensionFilterTree.replacingSortAscending(
            in: filters,
            at: ArraySlice(path),
            with: ascending
        )
    }

    func reportUnavailableSource() {
        errorMessage = ReaderExtensionError.sourceNotFound.localizedDescription
    }

    func cancel() {
        let wasLoading = isLoading
        loadToken = UUID()
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        if wasLoading {
            ReaderLogger.shared.log("Reader filters cancelled reason=editor-dismissed", type: "ReaderSearch")
        }
    }

    private func request(sourceID: ReaderExtensionSourceID, label: String, reason: String) {
        loadTask?.cancel()
        let token = UUID()
        loadToken = token
        isLoading = true
        errorMessage = nil
        ReaderLogger.shared.log("Reader filters started source=\(label) reason=\(reason)", type: "ReaderSearch")

        loadTask = Task { @MainActor in
            let started = Date()
            do {
                try Task.checkCancellation()
                let provider = try ReaderExtensionManager.shared.provider(for: sourceID)
                let loadedFilters = try await provider.filters()
                try Task.checkCancellation()
                guard loadToken == token else { return }
                if initialDefaults == nil {
                    initialDefaults = loadedFilters
                }
                filters = loadedFilters
                successfulLoadRevision += 1
                isLoading = false
                loadTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Reader filters loaded source=\(label) reason=\(reason) count=\(loadedFilters.count) revision=\(successfulLoadRevision) elapsedMs=\(elapsed)", type: "ReaderSearch")
            } catch is CancellationError {
                guard loadToken == token else { return }
                isLoading = false
                loadTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Reader filters cancelled source=\(label) reason=\(reason) elapsedMs=\(elapsed)", type: "ReaderSearch")
            } catch {
                guard loadToken == token else { return }
                errorMessage = error.localizedDescription
                isLoading = false
                loadTask = nil
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log("Reader filters failed source=\(label) reason=\(reason) elapsedMs=\(elapsed) error=\(ReaderExtensionDiagnostics.errorCode(error))", type: "ReaderSearch")
            }
        }
    }
}

struct ReaderExtensionFilterEditorList: View {
    @Binding var filters: [ReaderExtensionFilter]
    var onEdit: () -> Void = {}

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(ReaderExtensionFilterTree.rows(for: filters)) { row in
                filterRow(row)
                    .padding(.leading, CGFloat(row.depth) * 12)
            }
        }
    }

    @ViewBuilder
    private func filterRow(_ row: ReaderExtensionFilterDisplayRow) -> some View {
        let filter = row.filter
        switch filter.kind {
        case .text:
            VStack(alignment: .leading, spacing: 6) {
                Text(filter.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white.opacity(0.72))
                TextField(
                    "",
                    text: stringBinding(at: row.path),
                    prompt: Text(filter.title).foregroundColor(.white.opacity(0.42))
                )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundColor(.white)
                    .tint(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .onChange(of: stringValue(at: row.path)) { _ in onEdit() }

        case .toggle:
            HStack(spacing: 12) {
                Text(filter.title)
                    .foregroundColor(.white)
                Spacer(minLength: 12)
                Toggle("", isOn: boolBinding(at: row.path))
                    .labelsHidden()
                    .accessibilityLabel(filter.title)
            }
                .onChange(of: boolValue(at: row.path)) { _ in onEdit() }

        case .triState:
            Button {
                cycleTriState(at: row.path)
                onEdit()
            } label: {
                HStack {
                    Image(systemName: triStateIcon(numberValue(at: row.path)))
                        .frame(width: 24)
                        .foregroundColor(triStateColor(numberValue(at: row.path)))
                    Text(filter.title)
                        .foregroundColor(.white)
                    Spacer()
                    Text(triStateLabel(numberValue(at: row.path)))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.62))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityValue(triStateLabel(numberValue(at: row.path)))

        case .select:
            selectionMenu(for: row)

        case .sort:
            VStack(alignment: .leading, spacing: 10) {
                selectionMenu(for: row)
                HStack(spacing: 10) {
                    Text("Direction")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.72))
                    Spacer(minLength: 10)
                    sortDirectionButton(
                        title: "Ascending",
                        systemImage: "arrow.up",
                        selected: sortAscending(at: row.path),
                        ascending: true,
                        path: row.path
                    )
                    sortDirectionButton(
                        title: "Descending",
                        systemImage: "arrow.down",
                        selected: !sortAscending(at: row.path),
                        ascending: false,
                        path: row.path
                    )
                }
            }

        case .group:
            Text(filter.title)
                .font(row.depth == 0 ? .headline : .subheadline.weight(.semibold))
                .foregroundColor(.white)
                .padding(.top, row.depth == 0 ? 4 : 0)

        case .header:
            Text(filter.title)
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .separator:
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                    .overlay(Color.white.opacity(0.12))
                if !filter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(filter.title)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.62))
                }
            }
        }
    }

    private func selectionMenu(for row: ReaderExtensionFilterDisplayRow) -> some View {
        let filter = row.filter
        return Menu {
            ForEach(Array(filter.options.enumerated()), id: \.offset) { offset, option in
                Button {
                    setSelectedOption(offset, value: .string(option.value), at: row.path)
                    onEdit()
                } label: {
                    if offset == selectedOptionIndex(for: filter, at: row.path) {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(filter.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Spacer(minLength: 12)
                Text(selectedOptionLabel(for: filter, at: row.path))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.68))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.62))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.borderless)
        .tint(.white)
        .disabled(filter.options.isEmpty)
    }

    private func sortDirectionButton(
        title: String,
        systemImage: String,
        selected: Bool,
        ascending: Bool,
        path: [Int]
    ) -> some View {
        Button {
            setSortAscending(ascending, at: path)
            onEdit()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(selected ? Color.white.opacity(0.22) : Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func setValue(_ value: ReaderExtensionPreferenceValue, at path: [Int]) {
        filters = ReaderExtensionFilterTree.replacingValue(
            in: filters,
            at: ArraySlice(path),
            with: value
        )
    }

    /// Select and sort choices are positional. Option values repeat across
    /// entries in real catalogs, so the index has to travel with the value.
    private func setSelectedOption(_ index: Int, value: ReaderExtensionPreferenceValue, at path: [Int]) {
        filters = ReaderExtensionFilterTree.replacingValue(
            in: filters,
            at: ArraySlice(path),
            with: value,
            optionIndex: index
        )
    }

    private func setSortAscending(_ ascending: Bool, at path: [Int]) {
        filters = ReaderExtensionFilterTree.replacingSortAscending(
            in: filters,
            at: ArraySlice(path),
            with: ascending
        )
    }

    private func stringBinding(at path: [Int]) -> Binding<String> {
        Binding(
            get: { stringValue(at: path) },
            set: { setValue(.string($0), at: path) }
        )
    }

    private func boolBinding(at path: [Int]) -> Binding<Bool> {
        Binding(
            get: { boolValue(at: path) },
            set: { setValue(.bool($0), at: path) }
        )
    }

    private func filterValue(at path: [Int]) -> ReaderExtensionPreferenceValue? {
        ReaderExtensionFilterTree.filter(in: filters, at: ArraySlice(path))?.value
    }

    private func stringValue(at path: [Int]) -> String {
        guard case .string(let value) = filterValue(at: path) else { return "" }
        return value
    }

    private func boolValue(at path: [Int]) -> Bool {
        guard case .bool(let value) = filterValue(at: path) else { return false }
        return value
    }

    private func numberValue(at path: [Int]) -> Double {
        guard case .number(let value) = filterValue(at: path) else { return 0 }
        return value
    }

    private func sortAscending(at path: [Int]) -> Bool {
        ReaderExtensionFilterTree.filter(in: filters, at: ArraySlice(path))?.sortAscending ?? false
    }

    /// The live filter carries the authoritative index; `filter` here is a
    /// display snapshot, so the current tree is consulted first.
    private func selectedOptionIndex(for filter: ReaderExtensionFilter, at path: [Int]) -> Int? {
        (ReaderExtensionFilterTree.filter(in: filters, at: ArraySlice(path)) ?? filter).resolvedOptionIndex
    }

    private func selectedOptionLabel(for filter: ReaderExtensionFilter, at path: [Int]) -> String {
        guard let index = selectedOptionIndex(for: filter, at: path),
              filter.options.indices.contains(index) else {
            return filter.options.first?.label ?? "Unavailable"
        }
        return filter.options[index].label
    }

    private func cycleTriState(at path: [Int]) {
        let current = numberValue(at: path)
        let next = current == 0 ? 1 : (current == 1 ? 2 : 0)
        setValue(.number(Double(next)), at: path)
    }

    private func triStateIcon(_ state: Double) -> String {
        state == 1 ? "checkmark.square.fill" : (state == 2 ? "xmark.square.fill" : "square")
    }

    private func triStateLabel(_ state: Double) -> String {
        state == 1 ? "Include" : (state == 2 ? "Exclude" : "Any")
    }

    private func triStateColor(_ state: Double) -> Color {
        state == 1 ? .green : (state == 2 ? .red : .white.opacity(0.72))
    }
}
#endif
