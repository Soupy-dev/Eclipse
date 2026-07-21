import SwiftUI
import UniformTypeIdentifiers

#if !os(tvOS)
struct BackupDocument: FileDocument {
    var data: Data
    
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }
    static var importableContentTypes: [UTType] { [.json, .plainText, .text, .data] }
    
    init(data: Data) {
        self.data = data
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: data)
    }
}
#endif

struct BackupManagementView: View {
    @State private var showRestoreConfirmation = false
    @State private var showMessageAlert = false
    @State private var backupMessage = ""
    @State private var isProcessing = false
    @State private var showDocumentPicker = false
    @State private var showBackupExporter = false
    @State private var selectedBackupURL: URL? = nil
    @State private var selectedBackupIsTemporary = false
    @State private var backupFileToExport: Data? = nil
    @State private var backupFileName = ""
    @State private var importContentTypes: [UTType] = [.json]
    #if !os(tvOS)
    @State private var pendingImportMode: ImportMode = .direct
    #endif
    
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "Export") {
                    Button(action: createBackup) {
                        GlassDetailRow(icon: "arrow.up.doc.fill", iconColor: .teal, title: "Create Backup") {
                            if isProcessing {
                                EclipseLoadingIndicator()
                                    .tint(.white.opacity(0.6))
                            } else {
                                EmptyView()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .backupActionHitArea()
                    .disabled(isProcessing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                GlassSectionFooter("Create a backup file containing all your collections, settings, watch progress, tracker logins including MAL, and service configurations.")

                GlassSection(header: "Import") {
                    VStack(spacing: 0) {
                        Button(action: {
                            #if !os(tvOS)
                            startImport(mode: .direct)
                            #endif
                        }) {
                            GlassDetailRow(icon: "arrow.down.doc.fill", iconColor: .blue, title: "Import Backup") {
                                if isProcessing {
                                    EclipseLoadingIndicator()
                                        .tint(.white.opacity(0.6))
                                } else {
                                    EmptyView()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .backupActionHitArea()
                        .disabled(isProcessing)

                        GlassDivider()

                        Button(action: {
                            #if !os(tvOS)
                            startImport(mode: .coordinatedCopy)
                            #endif
                        }) {
                            GlassDetailRow(icon: "arrow.down.doc", iconColor: .indigo, title: "Alternative Import Backup") {
                                if isProcessing {
                                    EclipseLoadingIndicator()
                                        .tint(.white.opacity(0.6))
                                } else {
                                    EmptyView()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .backupActionHitArea()
                        .disabled(isProcessing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                GlassSectionFooter("Restore all data from a previously saved backup file. This will overwrite your current settings and progress.")

                if !backupMessage.isEmpty {
                    GlassSection {
                        HStack(spacing: 10) {
                            Image(systemName: backupMessage.contains("Success") || backupMessage.contains("created") ? "checkmark.circle.fill" : "info.circle.fill")
                                .foregroundColor(backupMessage.contains("Success") || backupMessage.contains("created") ? .green : .blue)
                            Text(backupMessage)
                                .font(.footnote)
                                .foregroundColor(.white.opacity(0.8))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(EclipseScrollTracker())
        }
        .navigationTitle("Backup & Import")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        #if !os(tvOS)
        .fileImporter(
            isPresented: $showDocumentPicker,
            allowedContentTypes: importContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result, mode: pendingImportMode)
        }
        .fileExporter(
            isPresented: $showBackupExporter,
            document: BackupDocument(data: backupFileToExport ?? Data()),
            contentType: .json,
            defaultFilename: backupFileName
        ) { result in
            isProcessing = false
            switch result {
            case .success:
                backupMessage = "Backup saved successfully!"
                showMessageAlert = true
                Logger.shared.log("Backup saved successfully", type: "Info")
            case .failure(let error):
                backupMessage = "Failed to save backup: \(error.localizedDescription)"
                showMessageAlert = true
                Logger.shared.log("Backup save failed: \(error.localizedDescription)", type: "Error")
            }
        }
        #endif
        .alert("Restore Confirmation", isPresented: $showRestoreConfirmation) {
            Button("Cancel", role: .cancel) {
                clearSelectedBackup()
            }
            Button("Restore", role: .destructive) {
                performRestore()
            }
        } message: {
            Text("This will overwrite your current settings, collections, watch progress, tracker logins including MAL, and service configurations with the backup data. Continue?")
        }
        .alert("Message", isPresented: $showMessageAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(backupMessage)
        }
    }
    
    private func createBackup() {
        isProcessing = true
        backupMessage = ""
        
        DispatchQueue.global(qos: .userInitiated).async {
            if let backupURL = BackupManager.shared.createBackup() {
                DispatchQueue.main.async {
                    // Prepare file for export and show file exporter
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                    backupFileName = "Eclipse_Backup_\(dateFormatter.string(from: Date())).json"
                    
                    if let fileData = try? Data(contentsOf: backupURL) {
                        backupFileToExport = fileData
                        showBackupExporter = true
                    } else {
                        backupMessage = "Failed to read backup file."
                    }
                    isProcessing = false
                }
            } else {
                DispatchQueue.main.async {
                    isProcessing = false
                    backupMessage = "Failed to create backup. Please try again."
                }
            }
        }
    }
    
    #if !os(tvOS)
    private enum ImportMode {
        case direct
        case coordinatedCopy
    }

    private func startImport(mode: ImportMode) {
        guard !isProcessing else { return }
        pendingImportMode = mode
        importContentTypes = mode == .direct ? [.json] : BackupDocument.importableContentTypes
        showDocumentPicker = true
    }

    private func handleImportResult(_ result: Result<[URL], Error>, mode: ImportMode) {
        switch result {
        case .success(let urls):
            guard let selectedFile = urls.first else {
                backupMessage = "No backup file selected"
                showMessageAlert = true
                return
            }

            do {
                clearSelectedBackup()
                switch mode {
                case .direct:
                    self.selectedBackupURL = selectedFile
                    self.selectedBackupIsTemporary = false
                case .coordinatedCopy:
                    self.selectedBackupURL = try prepareSelectedBackupForRestore(from: selectedFile)
                    self.selectedBackupIsTemporary = true
                }
                // Ask for confirmation before restoring
                showRestoreConfirmation = true
            } catch {
                backupMessage = "Failed to select file: \(error.localizedDescription)"
                showMessageAlert = true
                Logger.shared.log("Import file preparation failed: \(error.localizedDescription)", type: "Error")
            }
            
        case .failure(let error):
            backupMessage = "Failed to select file: \(error.localizedDescription)"
            showMessageAlert = true
            Logger.shared.log("Import error: \(error.localizedDescription)", type: "Error")
        }
    }
    #endif
    
    private func performRestore() {
        guard let backupURL = selectedBackupURL else {
            backupMessage = "No backup file selected"
            showMessageAlert = true
            return
        }
        
        isProcessing = true
        backupMessage = ""
        showRestoreConfirmation = false
        let shouldUseSecurityScope = !selectedBackupIsTemporary
        let shouldRemoveBackupAfterRestore = selectedBackupIsTemporary
        
        Task.detached(priority: .userInitiated) {
            var accessGranted = false
            if shouldUseSecurityScope {
                accessGranted = backupURL.startAccessingSecurityScopedResource()
            }
            defer {
                if accessGranted {
                    backupURL.stopAccessingSecurityScopedResource()
                }
                if shouldRemoveBackupAfterRestore {
                    try? FileManager.default.removeItem(at: backupURL)
                }
            }

            let success = await BackupManager.shared.restoreBackup(from: backupURL)
            
            await MainActor.run {
                isProcessing = false
                selectedBackupURL = nil
                selectedBackupIsTemporary = false
                if success {
                    backupMessage = "Backup restored successfully! Please restart the app to see all changes."
                } else {
                    backupMessage = "Failed to restore backup. The file may be corrupted or completely incompatible."
                }
                showMessageAlert = true
            }
        }
    }

    private func clearSelectedBackup() {
        if selectedBackupIsTemporary, let selectedBackupURL {
            try? FileManager.default.removeItem(at: selectedBackupURL)
        }
        selectedBackupURL = nil
        selectedBackupIsTemporary = false
    }

    #if !os(tvOS)
    private func prepareSelectedBackupForRestore(from sourceURL: URL) throws -> URL {
        let accessGranted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let values = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true {
            throw CocoaError(.fileReadCorruptFile)
        }

        let data = try coordinatedDataContents(of: sourceURL)
        guard !data.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let importDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EclipseBackupImports", isDirectory: true)
        try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)

        let localURL = importDirectory
            .appendingPathComponent("selected-backup-\(UUID().uuidString)")
            .appendingPathExtension("json")
        try data.write(to: localURL, options: .atomic)
        Logger.shared.log("Prepared selected backup for restore: \(sourceURL.lastPathComponent)", type: "Info")
        return localURL
    }

    private func coordinatedDataContents(of sourceURL: URL) throws -> Data {
        var coordinationError: NSError?
        var readError: Error?
        var data: Data?

        NSFileCoordinator().coordinate(readingItemAt: sourceURL, options: [], error: &coordinationError) { coordinatedURL in
            do {
                data = try Data(contentsOf: coordinatedURL)
            } catch {
                readError = error
            }
        }

        if let readError = readError {
            throw readError
        }
        if let coordinationError = coordinationError {
            throw coordinationError
        }
        guard let data = data else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }
    #endif
}

private extension View {
    func backupActionHitArea() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.001))
            .contentShape(Rectangle())
    }
}

#Preview {
    if #available(iOS 16.0, *) {
        NavigationStack {
            BackupManagementView()
        }
    } else {
        NavigationView {
            BackupManagementView()
        }
    }
}
