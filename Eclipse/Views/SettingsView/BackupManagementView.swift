//
//  BackupManagementView.swift
//  Eclipse
//
//  Created by Soupy-dev on 05/01/2026.
//

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
    @StateObject private var profileManager = ProfileManager.shared
    @State private var showRestoreConfirmation = false
    @State private var showSyncScopeChoice = false
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

    private var isAdministrable: Bool {
        profileManager.activeProfile?.isKidsProfile != true
    }

    private var cloudSyncCanPropagateRestore: Bool {
#if os(iOS)
        CloudSyncProvider.allCases.contains {
            UserDefaults.standard.bool(forKey: $0.syncEnabledKey)
        }
#else
        false
#endif
    }

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
                    .disabled(isProcessing || !isAdministrable)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                GlassSectionFooter(isAdministrable
                    ? "Create a backup file containing all your collections, settings, watch progress, tracker logins including MAL, and service configurations."
                    : "This is a kids profile, so it cannot create or export a backup containing other profiles and tracker logins. Switch to a grown-up profile to export one.")

                if isAdministrable {
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
                } else {
                    GlassSectionFooter("This is a kids profile, so it cannot restore a backup — a backup replaces every profile on this device. Switch to a grown-up profile to import one.")
                }

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
                beginRestore()
            }
        } message: {
            Text("This will overwrite your current settings, collections, watch progress, tracker logins including MAL, and service configurations with the backup data. Continue?")
        }
        .alert("Your Other Devices", isPresented: $showSyncScopeChoice) {
            Button("Cancel", role: .cancel) {
                clearSelectedBackup()
            }
            Button("This Device Only") {
                performRestore(scope: .thisDeviceOnly)
            }
            Button("Replace Everywhere", role: .destructive) {
                performRestore(scope: .replaceEverywhere)
            }
        } message: {
            Text("Cloud sync is on. \"This Device Only\" turns every cloud provider off on this device before restoring, keeps the complete restored backup here, and leaves the cloud copy and your other devices unchanged. Sync stays off here until you turn a provider on again. \"Replace Everywhere\" keeps your current provider choices and makes this backup authoritative after the restore finishes, replacing newer cloud changes, including progress recorded since the backup was made.")
        }
        .alert("Message", isPresented: $showMessageAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(backupMessage)
        }
    }

    private func createBackup() {
        guard isAdministrable else {
            backupMessage = "This is a kids profile, so it cannot create or export a backup."
            showMessageAlert = true
            return
        }
        isProcessing = true
        backupMessage = ""

        DispatchQueue.global(qos: .userInitiated).async {
            if let backupURL = BackupManager.shared.createBackup() {
                DispatchQueue.main.async {

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
                    backupMessage = BackupManager.shared.lastManualBackupFailureReason
                        ?? "Failed to create backup. Please try again."
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
        guard isAdministrable, !isProcessing else { return }
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

    private func beginRestore() {
        guard isAdministrable else {
            showRestoreConfirmation = false
            clearSelectedBackup()
            backupMessage = "This is a kids profile, so it cannot restore a backup."
            showMessageAlert = true
            return
        }

        guard selectedBackupURL != nil else {
            backupMessage = "No backup file selected"
            showMessageAlert = true
            return
        }

        if cloudSyncCanPropagateRestore {
            showSyncScopeChoice = true
            return
        }

        performRestore(scope: .replaceEverywhere)
    }

    private func performRestore(scope: ManualBackupRestoreScope) {
        guard isAdministrable else {
            showRestoreConfirmation = false
            showSyncScopeChoice = false
            clearSelectedBackup()
            backupMessage = "This is a kids profile, so it cannot restore a backup."
            showMessageAlert = true
            return
        }

        guard let backupURL = selectedBackupURL else {
            backupMessage = "No backup file selected"
            showMessageAlert = true
            return
        }

        isProcessing = true
        backupMessage = ""
        showRestoreConfirmation = false
        showSyncScopeChoice = false
        let shouldUseSecurityScope = !selectedBackupIsTemporary
        let shouldRemoveBackupAfterRestore = selectedBackupIsTemporary
        let cloudSyncWasEnabled = cloudSyncCanPropagateRestore

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

            let success = await BackupManager.shared.restoreManualBackup(
                from: backupURL,
                scope: scope
            )

            await MainActor.run {
                isProcessing = false
                selectedBackupURL = nil
                selectedBackupIsTemporary = false
                let cloudSyncRemainsEnabled = cloudSyncCanPropagateRestore
                if success {
                    if scope.keepsChangesOnThisDevice && cloudSyncWasEnabled {
                        backupMessage = "Backup restored on this device. Cloud sync is off here, and your cloud copy and other devices were not changed. Turn a provider on again when you want this device to rejoin sync."
                    } else if cloudSyncWasEnabled {
                        backupMessage = "Backup restored successfully. Eclipse queued the completed restore for your previously enabled cloud providers. Please restart the app to see all changes."
                    } else {
                        backupMessage = "Backup restored successfully! Please restart the app to see all changes."
                    }
                } else {
                    if cloudSyncWasEnabled && !cloudSyncRemainsEnabled {
                        backupMessage = "Failed to restore backup. Cloud sync was left off on this device to protect your other devices. The file may be corrupted or incompatible; wait for any cloud operation to finish, then try again."
                    } else if cloudSyncWasEnabled {
                        backupMessage = "Failed to restore backup before Eclipse could pause cloud sync. Cloud sync remains on and no restore was started. Switch to a grown-up profile if needed, wait for any cloud operation to finish, then try again."
                    } else {
                        backupMessage = "Failed to restore backup. The file may be corrupted or incompatible. If a cloud restore or sync was running, wait for it to finish and try again."
                    }
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
                let maximumBytes = BackupManager.maximumManualBackupFileBytes
                let values = try? coordinatedURL.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                )
                guard values?.isRegularFile != false,
                      values?.fileSize.map({ $0 <= maximumBytes }) ?? true else {
                    throw CocoaError(.fileReadTooLarge)
                }

                let handle = try FileHandle(forReadingFrom: coordinatedURL)
                defer { try? handle.close() }
                var bounded = Data()
                let chunkBytes = 1 * 1_024 * 1_024
                while bounded.count <= maximumBytes {
                    let remaining = maximumBytes + 1 - bounded.count
                    guard remaining > 0,
                          let chunk = try handle.read(upToCount: min(chunkBytes, remaining)),
                          !chunk.isEmpty else {
                        break
                    }
                    bounded.append(chunk)
                }
                guard bounded.count <= maximumBytes else {
                    throw CocoaError(.fileReadTooLarge)
                }
                data = bounded
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
