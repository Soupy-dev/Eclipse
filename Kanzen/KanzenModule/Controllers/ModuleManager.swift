//
//  ModuleManager.swift
//  Kanzen
//
//  Created by Dawud Osman on 13/05/2025.
//
import Foundation
class ModuleManager: ObservableObject {
    static let shared = ModuleManager()
    @Published var modules: [ModuleDataContainer] = []
    private let fileManager = FileManager.default
    private let modulesFileName: String = "modules.json"
    private let maximumModuleMetadataBytes = 1_000_000
    private let maximumModuleScriptBytes = 10_000_000
    private var metadataLoadFailed = false

    var metadataStoreFailedToLoad: Bool { metadataLoadFailed }

    private static let autoUpdateKey = "kanzenAutoUpdateModules"
    private static let lastAutoUpdateKey = "kanzenLastModuleAutoUpdate"
    private let autoUpdateInterval: TimeInterval = 3600

    static var isAutoUpdateEnabled: Bool {
        get { ProfileSettingsStore.services.bool(forKey: autoUpdateKey) }
        set { ProfileSettingsStore.services.set(newValue, forKey: autoUpdateKey) }
    }

    private var lastAutoUpdateDate: Date {
        get { ProfileSettingsStore.services.object(forKey: ModuleManager.lastAutoUpdateKey) as? Date ?? .distantPast }
        set { ProfileSettingsStore.services.set(newValue, forKey: ModuleManager.lastAutoUpdateKey) }
    }

    private init()
    {
        ProfileSettingsStore.services.register(defaults: [
            ModuleManager.autoUpdateKey: true
        ])

        createModuleFile()
        loadModules()
        for module in modules {
            validateModule(module){isValid in
                if !isValid {
                    ReaderLogger.shared.log("Module \(module.moduleData.sourceName) is not valid", type: "Error")
                }
            }
        }
    }
    func saveModules()
    {
        DispatchQueue.main.async {
            let url = ModuleManager.shared.getModulesFilePath()
            guard let data = try? JSONEncoder().encode(self.modules) else {return}
            guard Self.persistMetadataData(
                data,
                to: url,
                maximumBytes: self.maximumModuleMetadataBytes,
                storeLoadFailed: self.metadataLoadFailed
            ) else {
                ReaderLogger.shared.log(
                    self.metadataLoadFailed
                        ? "Refused to overwrite module metadata that failed to load"
                        : "Refused to save oversized or unavailable module metadata",
                    type: "Error"
                )
                return
            }
        }
    }

    @discardableResult
    static func persistMetadataData(
        _ data: Data,
        to url: URL,
        maximumBytes: Int,
        storeLoadFailed: Bool
    ) -> Bool {
        guard !storeLoadFailed,
              maximumBytes >= 0,
              data.count <= maximumBytes else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func replaceWithAccountNeutralMetadata() -> Bool {
        let url = getModulesFilePath()
        do {
            let data = try JSONEncoder().encode([ModuleDataContainer]())
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            modules = []
            metadataLoadFailed = false
            return true
        } catch {
            ReaderLogger.shared.log(
                "Failed to clear module metadata at account boundary: \(error.localizedDescription)",
                type: "Error"
            )
            return false
        }
    }
    func addModules(_ moduleUrL:String, metaData: ModuleData) async throws -> Void
    {
        guard !metadataLoadFailed else {
            throw ModuleCreationError.invalidModuleName(
                "Module metadata could not be loaded; recover or explicitly reset it before adding modules"
            )
        }
        if modules.contains(where: {$0.moduleurl == moduleUrL})
        {
            throw  ModuleCreationError.moduleAlreadyExists("module already exists")
        }

        let jsContent = try await validateJSfile(metaData.scriptURL)
        let fileName = "\(UUID().uuidString).js"
        let localUrl = getDocumentsDirectory().appendingPathComponent(fileName)
        try jsContent.write(to: localUrl, atomically: true, encoding: .utf8)
        let module = ModuleDataContainer( moduleData: metaData, localPath: fileName, moduleurl: moduleUrL)
        DispatchQueue.main.async {
            ModuleManager.shared.modules.append(module)
            ModuleManager.shared.saveModules()
        }

    }
    func deleteModule(_ module: ModuleDataContainer)
    {
        guard !metadataLoadFailed else {
            ReaderLogger.shared.log(
                "Refused to delete a module while module metadata is unreadable",
                type: "Error"
            )
            return
        }

        let remainingModules = modules.filter { $0.id != module.id }
        guard let metadata = try? JSONEncoder().encode(remainingModules) else {
            ReaderLogger.shared.log(
                "Refused to delete a module because updated metadata could not be encoded",
                type: "Error"
            )
            return
        }
        let metadataRemovalPersisted = Self.persistMetadataData(
                metadata,
                to: getModulesFilePath(),
                maximumBytes: maximumModuleMetadataBytes,
                storeLoadFailed: metadataLoadFailed
              )
        guard metadataRemovalPersisted else {
            ReaderLogger.shared.log(
                "Refused to delete a module because updated metadata could not be saved",
                type: "Error"
            )
            return
        }
        modules = remainingModules

        if let fileUrl = validatedModuleScriptURL(for: module.localPath) {
            try? fileManager.removeItem(at: fileUrl)
        } else {
            ReaderLogger.shared.log("Skipped unsafe module file path: \(module.localPath)", type: "Error")
        }
        // Clear execution health only after the stable module UUID has been
        // durably removed from metadata. A failed removal must remain
        // quarantined rather than silently reopening hostile code.
        KanzenLegacyJavaScriptQuarantineStore.shared.clearAfterDurableModuleRemoval(
            moduleID: module.id,
            metadataRemovalPersisted: metadataRemovalPersisted
        )

    }
    func getModulesFilePath() -> URL
    {
        getDocumentsDirectory().appendingPathComponent(modulesFileName)
    }
    func getModuleScript(module: ModuleDataContainer) throws -> String{
        guard let localUrl = validatedModuleScriptURL(for: module.localPath) else {
            throw ModuleLoadingError.missingScriptPath("Unsafe module script path")
        }
        let data = try BoundedLocalStoreReader.read(
            from: localUrl,
            maximumBytes: maximumModuleScriptBytes
        )
        guard let script = String(data: data, encoding: .utf8) else {
            throw ModuleLoadingError.invalidScriptFormat("Module script is not valid UTF-8")
        }
        return script
    }
    private func validatedModuleScriptURL(for localPath: String) -> URL? {
        let fileName = (localPath as NSString).lastPathComponent
        guard !fileName.isEmpty,
              fileName == localPath,
              (fileName as NSString).pathExtension.lowercased() == "js" else {
            return nil
        }
        return getDocumentsDirectory().appendingPathComponent(fileName, isDirectory: false)
    }
    func createModuleFile()
    {
        let fileUrl = getDocumentsDirectory().appendingPathComponent(modulesFileName)
        if(!fileManager.fileExists(atPath: fileUrl.path))
        {
            do {
                try "[]".write(to:fileUrl,atomically: true,encoding: .utf8)
                ReaderLogger.shared.log("Created new modules file",type: "Info")
            }
            catch {
                ReaderLogger.shared.log("Failed to create modules file: \(error.localizedDescription)", type: "Error")
            }
        }
    }
    func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
    func loadModules()
    {
        let fileUrl = getDocumentsDirectory().appendingPathComponent(modulesFileName)
        do
        {
            let data = try BoundedLocalStoreReader.read(
                from: fileUrl,
                maximumBytes: maximumModuleMetadataBytes
            )
            let decodedModules = try JSONDecoder().decode([ModuleDataContainer].self, from: data)
            modules = decodedModules
            metadataLoadFailed = false

        }
        catch
        {
            metadataLoadFailed = true
            ReaderLogger.shared.log(ModuleLoadingError.moduleDecodeError(error.localizedDescription).localizedDescription,type: "Error")

        }

    }
    func validateJSfile(_ url: String)  async throws -> String
    {
        guard let scriptUrl = validatedRemoteURL(url) else {
            throw ModuleLoadingError.invalidScriptFormat("Invalid HTTP(S) script URL")
        }
        let result: SkyStreamPinnedHTTPClient.Response
        do {
            result = try await SkyStreamPinnedHTTPClient().fetch(
                scriptUrl.absoluteString,
                purpose: .pluginRequest,
                allowsCookies: false,
                followsRedirects: true,
                maximumRedirects: 10,
                maximumResponseBytes: maximumModuleScriptBytes,
                maximumRequestBodyBytes: 0,
                timeout: 30
            )
        } catch {
            throw ModuleLoadingError.scriptDownloadError(
                "Script network request failed (\(servicePinnedNetworkErrorToken(error)))"
            )
        }
        guard (200...299).contains(result.response.statusCode) else {
            throw ModuleLoadingError.scriptDownloadError("Script request returned an invalid response")
        }
        guard let jsContent = String(data: result.data, encoding: .utf8) else {
            throw ModuleLoadingError.invalidScriptFormat("Invalid Script Format")
        }

        return jsContent
    }
    func validateModuleUrl(_ urlString: String) async throws -> ModuleData
    {
        guard let url = validatedRemoteURL(urlString) else {
            throw ModuleCreationError.invalidScriptUrl("invalid HTTP(S) module URL")
        }
        let result: SkyStreamPinnedHTTPClient.Response
        do {
            result = try await SkyStreamPinnedHTTPClient().fetch(
                url.absoluteString,
                purpose: .pluginRequest,
                allowsCookies: false,
                followsRedirects: true,
                maximumRedirects: 10,
                maximumResponseBytes: maximumModuleMetadataBytes,
                maximumRequestBodyBytes: 0,
                timeout: 30
            )
        } catch {
            throw ModuleCreationError.invalidScriptUrl(
                "Module network request failed (\(servicePinnedNetworkErrorToken(error)))"
            )
        }
        guard (200...299).contains(result.response.statusCode) else {
            throw ModuleCreationError.invalidScriptUrl("module request returned an invalid response")
        }
        return try JSONDecoder().decode(ModuleData.self, from: result.data)
    }

    private func validatedRemoteURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
    func validateModule(_ module: ModuleDataContainer, completion: @escaping (Bool) -> Void)
    { Task
        {
            do  {
                guard let fileUrl = validatedModuleScriptURL(for: module.localPath) else {
                    throw ModuleLoadingError.missingScriptPath("Unsafe module script path")
                }

                let validFilePath =  fileManager.fileExists(atPath: fileUrl.path)

                if(!validFilePath)
                {
                    ReaderLogger.shared.log("downloading js file for: \(module.moduleData.sourceName)")
                    let validJsContent = try await validateJSfile(module.moduleData.scriptURL)
                    try validJsContent.write(to:fileUrl,atomically: true, encoding: .utf8 )
                }
                completion(true)

            }
            catch  {
                ReaderLogger.shared.log("Module Validation Error: (\(module.moduleData.sourceName)) \(error.localizedDescription)",type: "Error")
                completion(false)

            }

        }
        }
    func getModule(_ moduleId: UUID) -> ModuleDataContainer?
    {
        return ModuleManager.shared.modules.first { $0.id == moduleId }
    }

    func updateModules() async {
        ReaderLogger.shared.log("ModuleManager: Starting module auto-update for \(modules.count) modules", type: "Info")
        for module in modules {
            do {
                let metaData = try await validateModuleUrl(module.moduleurl)

                if metaData.version == module.moduleData.version {
                    ReaderLogger.shared.log("ModuleManager: \(module.moduleData.sourceName) is already up to date (v\(metaData.version))", type: "Info")
                    continue
                }

                let jsContent = try await validateJSfile(metaData.scriptURL)
                guard let localUrl = validatedModuleScriptURL(for: module.localPath) else {
                    throw ModuleLoadingError.missingScriptPath("Unsafe module script path")
                }
                try jsContent.write(to: localUrl, atomically: true, encoding: .utf8)

                if let index = modules.firstIndex(where: { $0.id == module.id }) {
                    let updated = ModuleDataContainer(
                        id: module.id,
                        moduleData: metaData,
                        localPath: module.localPath,
                        moduleurl: module.moduleurl,
                        isActive: module.isActive
                    )
                    await MainActor.run {
                        self.modules[index] = updated
                    }
                }
                ReaderLogger.shared.log("ModuleManager: Updated \(module.moduleData.sourceName) to v\(metaData.version)", type: "Info")
            } catch {
                ReaderLogger.shared.log("ModuleManager: Failed to update \(module.moduleData.sourceName): \(error.localizedDescription)", type: "Error")
            }
        }
        saveModules()
        lastAutoUpdateDate = Date()
        ReaderLogger.shared.log("ModuleManager: Auto-update complete", type: "Info")
    }

    func autoUpdateModulesIfNeeded() async {
        guard ModuleManager.isAutoUpdateEnabled, !modules.isEmpty else { return }

        let elapsed = Date().timeIntervalSince(lastAutoUpdateDate)
        guard elapsed >= autoUpdateInterval else {
            ReaderLogger.shared.log("ModuleManager: Skipping auto-update, last update was \(Int(elapsed))s ago", type: "Info")
            return
        }

        ReaderLogger.shared.log("ModuleManager: Starting automatic module update", type: "Info")
        await updateModules()
        ReaderLogger.shared.log("ModuleManager: Automatic module update completed", type: "Info")
    }

}
