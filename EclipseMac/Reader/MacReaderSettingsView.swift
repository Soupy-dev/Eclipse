#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacReaderSettingsView: View {
    @ObservedObject var session: MacReaderSession
    @Environment(\.dismiss) private var dismiss
    @State private var revision = 0
    @State private var error: String?
    @State private var generation = UUID()
    @State private var modelPanel: NSOpenPanel?
    private var store: UserDefaults { session.settingsStore }
    private var novel: Bool { session.pages.allSatisfy(\.isText) && !session.pages.isEmpty }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Reader Settings").font(.title2.bold()); Spacer(); Button("Done") { session.applySettings(); dismiss() } }.padding()
            Form {
                if !novel {
                    Section("Navigation") {
                        Picker("Reading Direction", selection: string(session.reader?.readerModeStorageKey ?? "kanzenReaderMode", default: session.effectiveReadingMode.rawValue)) { ForEach(KanzenReaderMode.allCases) { Text($0.title).tag($0.rawValue) } }
                        Picker("Page Layout", selection: string("Reader.pagedPageLayout", default: "single")) { Text("Single Page").tag("single"); Text("Two Pages").tag("double"); Text("Automatic").tag("auto") }
                        Toggle("Offset First Page", isOn: bool(MacReaderSettingsPolicy.pageOffsetStorageKey(scopeKey: session.reader?.readerSettingsScopeKey)))
                        Toggle("Split Wide Pages", isOn: bool("Reader.splitWideImages"))
                        Toggle("Reverse Split Order", isOn: bool("Reader.reverseSplitOrder"))
                        Toggle("Continuous Chapter Navigation", isOn: bool("Reader.verticalInfiniteScroll", default: true))
                        Toggle("Double Click to Zoom", isOn: invertedBool("Reader.disableDoubleTap"))
                        Toggle("Page Context Menu", isOn: invertedBool("Reader.disableQuickActions"))
                        Toggle("Hide Controls While Scrolling", isOn: bool("Reader.hideBarsOnSwipe"))
                        Toggle("Animate Page Turns", isOn: bool("Reader.animatePageTransitions", default: true))
                        Text("Arrow keys change pages. Space and Shift-Space move down and up. Command-Left and Command-Right change chapters. Pinch, double click, or use Command-Plus and Command-Minus to zoom. Command-0 resets zoom.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Images") {
                        Picker("Background", selection: string("Reader.backgroundColor", default: "black")) { Text("Black").tag("black"); Text("Gray").tag("gray"); Text("White").tag("white"); Text("System").tag("system"); Text("Auto").tag("auto") }
                        Toggle("Downsample Images", isOn: bool("Reader.downsampleImages", default: true))
                        Toggle("Crop Borders", isOn: bool("Reader.cropBorders"))
                        Toggle("Text Recognition", isOn: bool("Reader.liveText"))
                        Stepper("Preload \(store.object(forKey: "Reader.pagesToPreload") as? Int ?? 3) Pages", value: integer("Reader.pagesToPreload", default: 3), in: 1...10)
                        Toggle("Constrain Page Width", isOn: bool("Reader.pillarbox"))
                        if store.bool(forKey: "Reader.pillarbox") {
                            Slider(value: number("Reader.pillarboxAmount", default: 15), in: 5...95) { Text("Side Margins") }
                            Picker("Window Shape", selection: string("Reader.pillarboxOrientation", default: "both")) { Text("All").tag("both"); Text("Tall").tag("portrait"); Text("Wide").tag("landscape") }
                        }
                    }
                    if PlatformCapabilities.current.intelMacCompatibility.supportsReaderImageUpscaling {
                        Section("Image Upscaling") {
                            Toggle("Upscale Images", isOn: bool("Reader.upscaleImages")).disabled(store.object(forKey: "Reader.downsampleImages") as? Bool ?? true)
                            Stepper("Maximum Source Height: \(store.object(forKey: "Reader.upscaleMaxHeight") as? Int ?? 2000) px", value: integer("Reader.upscaleMaxHeight", default: 2000), in: 800...6000, step: 200)
                            LabeledContent("Model", value: store.string(forKey: "Reader.upscaleModelName") ?? "None")
                            HStack { Button("Import Core ML Model…") { importModel() }; Button("Remove Model", role: .destructive) { removeModel() }.disabled(!FileManager.default.fileExists(atPath: KanzenReaderUpscaleModelStore.storedModelURL(forProfile: session.owner).path)) }
                            Text("Upscaling uses your model when downsampling is off. Larger models can use substantial memory.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Section("Intel Mac Compatibility") {
                            Text("Reader image upscaling is unavailable on Intel Macs. Your saved model and upscaling preferences are preserved.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Novel Typography") {
                    Picker("Font", selection: string("readerFontFamily", default: "-apple-system")) { Text("System").tag("-apple-system"); Text("Rounded").tag("ui-rounded"); Text("Monospace").tag("Menlo"); ForEach(["Georgia", "Times New Roman", "Helvetica", "Charter", "New York"], id: \.self) { Text($0).tag($0) } }
                    Slider(value: number("readerFontSize", default: 16), in: 12...32, step: 1) { Text("Font Size") }
                    Picker("Weight", selection: string("readerFontWeight", default: "normal")) { Text("Light").tag("300"); Text("Regular").tag("normal"); Text("Medium").tag("500"); Text("Semibold").tag("600"); Text("Bold").tag(store.string(forKey: "readerFontWeight") == "700" ? "700" : "bold") }
                    Picker("Alignment", selection: string("readerTextAlignment", default: "left")) { ForEach(["left", "center", "right", "justify"], id: \.self) { Text($0.capitalized).tag($0) } }
                    Slider(value: number("readerLineSpacing", default: 1.6), in: 1...3) { Text("Line Spacing") }
                    Slider(value: number("readerMargin", default: 4), in: 0...30) { Text("Page Margin") }
                    Picker("Colors", selection: integer("readerColorPreset", default: 0)) { Text("Pure").tag(0); Text("Warm").tag(1); Text("Slate").tag(2); Text("Off-Black").tag(3); Text("Dark").tag(4) }
                    Button("Reset Reader Text Settings") { resetReaderTextSettings() }
                }
                Section("Progress") {
                    Slider(value: number("readerReadThresholdPercent", default: 80), in: 50...100, step: 5) { Text("Mark Read at \(Int(store.object(forKey: "readerReadThresholdPercent") as? Double ?? 80))%") }
                }
            }.formStyle(.grouped)
        }
        .alert("Reader", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in cancelModelImport(); dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: .mediaStateWillChangeCurrentUser)) { _ in cancelModelImport(); dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: .macMainWindowClosed)) { _ in cancelModelImport(); dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in cancelModelImport() }
        .onDisappear { cancelModelImport(); session.applySettings() }
    }
    private func resetReaderTextSettings() {
        guard !MacLaunchProfileAccess.requiresUnlock, !MacLaunchProfileAccess.isTerminating,
              ProgressManager.shared.profileMutationAuthority(requiredOwner: session.owner) != nil else { return }
        let defaults: [String: Any] = ["readerFontSize": 16, "readerFontFamily": "-apple-system", "readerFontWeight": "normal", "readerColorPreset": 0, "readerTextAlignment": "left", "readerLineSpacing": 1.6, "readerMargin": 4]
        for (key, value) in defaults { store.set(value, forKey: key) }
        changed()
    }
    private func changed() { revision += 1; session.applySettings() }
    private func bool(_ key: String, default fallback: Bool = false) -> Binding<Bool> { Binding(get: { store.object(forKey: key) as? Bool ?? fallback }, set: { store.set($0, forKey: key); changed() }) }
    private func invertedBool(_ key: String) -> Binding<Bool> { Binding(get: { !store.bool(forKey: key) }, set: { store.set(!$0, forKey: key); changed() }) }
    private func string(_ key: String, default fallback: String) -> Binding<String> { Binding(get: { store.string(forKey: key) ?? fallback }, set: { store.set($0, forKey: key); changed() }) }
    private func integer(_ key: String, default fallback: Int) -> Binding<Int> { Binding(get: { store.object(forKey: key) as? Int ?? fallback }, set: { store.set($0, forKey: key); changed() }) }
    private func number(_ key: String, default fallback: Double) -> Binding<Double> { Binding(get: { store.object(forKey: key) as? Double ?? fallback }, set: { store.set($0, forKey: key); changed() }) }
    private func importModel() {
        guard PlatformCapabilities.current.intelMacCompatibility.supportsReaderImageUpscaling,
              modelPanel == nil, let authority = MacDownloadStorageAuthority.capture(), authority.profileID == session.owner,
              NSApp.isActive, let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible, !window.isMiniaturized else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mlmodel") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let token = generation
        let contentGeneration = session.contentGeneration
        let windowGeneration = MacLaunchProfileAccess.windowGeneration
        modelPanel = panel
        panel.beginSheetModal(for: window) { response in
            guard modelPanel === panel else { return }
            modelPanel = nil
            guard PlatformCapabilities.current.intelMacCompatibility.supportsReaderImageUpscaling,
                  response == .OK, token == generation, contentGeneration == session.contentGeneration,
                  windowGeneration == MacLaunchProfileAccess.windowGeneration, authority.isCurrent(), authority.profileID == session.owner,
                  NSApp.isActive, window.isVisible, !window.isMiniaturized, let url = panel.url else { return }
            do { try KanzenReaderUpscaleModelStore.importModel(from: url); changed() } catch { self.error = error.localizedDescription }
        }
    }
    private func removeModel() {
        guard PlatformCapabilities.current.intelMacCompatibility.supportsReaderImageUpscaling,
              let authority = MacDownloadStorageAuthority.capture(), authority.profileID == session.owner else { return }
        KanzenReaderUpscaleModelStore.clearModel()
        changed()
    }
    private func cancelModelImport() {
        generation = UUID()
        let panel = modelPanel
        modelPanel = nil
        panel?.cancel(nil)
    }
}
#endif
