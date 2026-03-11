//
//  StorageView.swift
//  Luna
//
//  Created by Francesco on 04/11/25.
//

import SwiftUI

struct StorageView: View {
    @State private var cacheSizeBytes: Int64 = 0
    @State private var isLoading: Bool = true
    @State private var isClearing: Bool = false
    @State private var showConfirmClear: Bool = false
    @State private var errorMessage: String?
    
    @AppStorage("autoClearCacheEnabled") private var autoClearCacheEnabled = false
    @AppStorage("autoClearCacheThresholdMB") private var autoClearCacheThresholdMB: Double = 500
    
    private let cacheThresholdOptions: [Double] = [100, 250, 500, 1000, 2000, 5000]
    
    var body: some View {
        List {
            Section(header: Text("APP CACHE"), footer: Text("Cache includes images and other temporary files that can be removed.")) {
                HStack {
                    Text("Cache Size")
                    Spacer()
                    if isLoading {
                        ProgressView()
                    } else {
                        Text(formattedCacheSize)
                            .foregroundColor(.secondary)
                    }
                }
                
                Button(role: .destructive) {
                    showConfirmClear = true
                } label: {
                    if isClearing {
                        HStack {
                            ProgressView()
                            Text("Clearing Cache…")
                        }
                    } else {
                        Text("Clear Cache")
                    }
                }
                .disabled(isClearing || (isLoading && cacheSizeBytes == 0))
            }
            
            Section(header: Text("AUTO-CLEAR CACHE"), footer: Text("Automatically clear cache when it exceeds the specified size.")) {
                Toggle("Enable Auto-Clear", isOn: $autoClearCacheEnabled)
                
                if autoClearCacheEnabled {
                    HStack {
                        Text("Threshold")
                        Spacer()
                        Picker("", selection: $autoClearCacheThresholdMB) {
                            ForEach(cacheThresholdOptions, id: \.self) { value in
                                Text(formatThreshold(value)).tag(value)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    
                    Text("Cache will be cleared when size exceeds \(formatThreshold(autoClearCacheThresholdMB))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if let errorMessage {
                Section(header: Text("ERROR")) {
                    Text(errorMessage).foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Storage")
        .lunaSettingsStyle()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: refreshCacheSize) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading || isClearing)
                .help("Recalculate cache size")
            }
        }
        .onAppear {
            refreshCacheSize()
        }
        .onChange(of: autoClearCacheEnabled) { enabled in
            if enabled {
                Logger.shared.log("Auto-clear cache enabled with threshold: \(formatThreshold(autoClearCacheThresholdMB))", type: "Storage")
            }
        }
        .alert("Clear Cache?", isPresented: $showConfirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { clearCache() }
        } message: {
            Text("This will remove cached files. You may need to re-download some content later.")
        }
    }
    
    private var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: cacheSizeBytes, countStyle: .file)
    }
    
    private func formatThreshold(_ mb: Double) -> String {
        if mb >= 1000 {
            return String(format: "%.1f GB", mb / 1000)
        }
        return String(format: "%.0f MB", mb)
    }
    
    private func refreshCacheSize() {
        errorMessage = nil
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let size = calculateDirectorySize(at: cachesDirectory())
            DispatchQueue.main.async {
                self.cacheSizeBytes = size
                self.isLoading = false
                
                // Check if auto-clear should be triggered
                if self.autoClearCacheEnabled {
                    let thresholdBytes = Int64(self.autoClearCacheThresholdMB * 1_000_000)
                    if size > thresholdBytes {
                        Logger.shared.log("Cache size (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) exceeds threshold (\(self.formatThreshold(self.autoClearCacheThresholdMB))). Auto-clearing...", type: "Storage")
                        self.autoClearCache()
                    }
                }
            }
        }
    }
    
    private func clearCache() {
        errorMessage = nil
        isClearing = true
        performCacheClear { size in
            self.cacheSizeBytes = size
            self.isClearing = false
            self.isLoading = false
        }
    }
    
    private func autoClearCache() {
        performCacheClear { size in
            self.cacheSizeBytes = size
            Logger.shared.log("Auto-clear completed. New cache size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))", type: "Storage")
        }
    }
    
    private func performCacheClear(completion: @escaping (Int64) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dir = cachesDirectory()
                let fileManager = FileManager.default
                let items = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])
                for url in items {
                    try? fileManager.removeItem(at: url)
                }
                
                URLCache.shared.removeAllCachedResponses()
                
                let size = calculateDirectorySize(at: dir)
                DispatchQueue.main.async {
                    completion(size)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isClearing = false
                    self.isLoading = false
                }
            }
        }
    }

    
    private func calculateDirectorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var total: Int64 = 0
        
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return 0
        }
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(keys))
                if resourceValues.isRegularFile == true, let fileSize = resourceValues.fileSize {
                    total += Int64(fileSize)
                }
            } catch {
                continue
            }
        }
        return total
    }
    
    private func cachesDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }
}

#Preview {
    StorageView()
}
