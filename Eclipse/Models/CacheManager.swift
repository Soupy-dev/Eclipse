//
//  CacheManager.swift
//  Eclipse
//
//  Created by Soupy-dev on 01/11/26.
//

import Foundation

final class CacheManager {
    static let shared = CacheManager()
    static let defaultAutoClearThresholdMB = 500.0
    static let autoClearThresholdRange = 100.0...5_000.0

    private init() {}

    func checkAndAutoClearIfNeeded() {
        let autoClearEnabled = UserDefaults.standard.bool(forKey: "autoClearCacheEnabled")
        guard autoClearEnabled else { return }

        let storedThresholdMB = UserDefaults.standard.double(forKey: "autoClearCacheThresholdMB")
        let thresholdMB = Self.sanitizedAutoClearThresholdMB(storedThresholdMB)
        if thresholdMB != storedThresholdMB {
            UserDefaults.standard.set(thresholdMB, forKey: "autoClearCacheThresholdMB")
        }
        let thresholdBytes = Self.autoClearThresholdBytes(for: thresholdMB)

        let cacheSize = calculateCacheSize()

        if cacheSize > thresholdBytes {
            Logger.shared.log("Cache size (\(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))) exceeds auto-clear threshold (\(formatThreshold(thresholdMB))). Auto-clearing...", type: "Storage")
            clearCache()
        }
    }

    static func sanitizedAutoClearThresholdMB(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return defaultAutoClearThresholdMB }
        return min(max(value, autoClearThresholdRange.lowerBound), autoClearThresholdRange.upperBound)
    }

    static func autoClearThresholdBytes(for value: Double) -> Int64 {
        Int64(sanitizedAutoClearThresholdMB(value) * 1_000_000)
    }

    private func calculateCacheSize() -> Int64 {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var total: Int64 = 0

        guard let enumerator = fileManager.enumerator(at: cacheDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
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

    private func clearCache() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let fileManager = FileManager.default

        do {
            let items = try fileManager.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil, options: [])
            for url in items {
                try? fileManager.removeItem(at: url)
            }

            URLCache.shared.removeAllCachedResponses()

            let newSize = calculateCacheSize()
            Logger.shared.log("Auto-clear completed. New cache size: \(ByteCountFormatter.string(fromByteCount: newSize, countStyle: .file))", type: "Storage")
        } catch {
            Logger.shared.log("Failed to auto-clear cache: \(error.localizedDescription)", type: "Error")
        }
    }

    private func formatThreshold(_ mb: Double) -> String {
        if mb >= 1000 {
            return String(format: "%.1f GB", mb / 1000)
        }
        return String(format: "%.0f MB", mb)
    }
}
