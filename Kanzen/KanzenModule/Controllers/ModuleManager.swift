import Foundation
class ModuleManager: ObservableObject {
    static let shared = ModuleManager()
    @Published var modules: [ModuleDataContainer] = []
    private let fileManager = FileManager.default
    private let modulesFileName: String = "modules.json"
    private let maximumModuleMetadataBytes = 1_000_000
    private let maximumModuleScriptBytes = 10_000_000

    // MARK: - Auto-Update

    private static let autoUpdateKey = "kanzenAutoUpdateModules"
    private static let lastAutoUpdateKey = "kanzenLastModuleAutoUpdate"
    private let autoUpdateInterval: TimeInterval = 3600

    static var isAutoUpdateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoUpdateKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoUpdateKey) }
    }

    private var lastAutoUpdateDate: Date {
        get { UserDefaults.standard.object(forKey: ModuleManager.lastAutoUpdateKey) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: ModuleManager.lastAutoUpdateKey) }
    }

    private init()
    {
        UserDefaults.standard.register(defaults: [
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
            try? data.write(to: url, options: .atomic)
        }
    }
    func addModules(_ moduleUrL:String, metaData: ModuleData) async throws -> Void
    {
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
        if let fileUrl = validatedModuleScriptURL(for: module.localPath) {
            try? fileManager.removeItem(at: fileUrl)
        } else {
            ReaderLogger.shared.log("Skipped unsafe module file path: \(module.localPath)", type: "Error")
        }
        ModuleManager.shared.modules.removeAll(where: {$0.id == module.id})
        ModuleManager.shared.saveModules()
        
    }
    func getModulesFilePath() -> URL
    {
        getDocumentsDirectory().appendingPathComponent(modulesFileName)
    }
    func getModuleScript(module: ModuleDataContainer) throws -> String{
        guard let localUrl = validatedModuleScriptURL(for: module.localPath) else {
            throw ModuleLoadingError.missingScriptPath("Unsafe module script path")
        }
        return try String(contentsOf: localUrl, encoding: .utf8)
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
            let data = try Data(contentsOf: fileUrl)
            let decodedModules = try JSONDecoder().decode([ModuleDataContainer].self, from: data)
            modules = decodedModules
            
        }
        catch
        {
            modules = []
            ReaderLogger.shared.log(ModuleLoadingError.moduleDecodeError(error.localizedDescription).localizedDescription,type: "Error")
            
        }
        
    }
    func validateJSfile(_ url: String)  async throws -> String
    {
        guard let scriptUrl = validatedRemoteURL(url) else {
            throw ModuleLoadingError.invalidScriptFormat("Invalid HTTP(S) script URL")
        }

        let (scriptData, response) = try await URLSession.custom.boundedData(
            from: scriptUrl,
            maximumResponseBytes: maximumModuleScriptBytes
        )
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ModuleLoadingError.scriptDownloadError("Script request returned an invalid response")
        }
        guard let jsContent = String(data:scriptData, encoding: .utf8) else {
            throw ModuleLoadingError.invalidScriptFormat("Invalid Script Format")
        }

        return jsContent
    }
    func validateModuleUrl(_ urlString: String) async throws -> ModuleData
    {
        guard let url = validatedRemoteURL(urlString) else {
            throw ModuleCreationError.invalidScriptUrl("invalid HTTP(S) module URL")
        }
        let (rawData, response) = try await URLSession.custom.boundedData(
            from: url,
            maximumResponseBytes: maximumModuleMetadataBytes
        )
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ModuleCreationError.invalidScriptUrl("module request returned an invalid response")
        }
        return try JSONDecoder().decode(ModuleData.self, from: rawData)
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

    // MARK: - Auto-Update

    /// Re-downloads the JS scripts for installed modules whose version has changed.
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
