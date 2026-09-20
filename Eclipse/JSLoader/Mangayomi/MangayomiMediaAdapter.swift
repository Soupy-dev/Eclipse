import Foundation

enum MangayomiMediaAdapter {
    static func searchItems(_ data: Data, source: MangayomiMediaSource) throws -> [SearchItem] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = result["list"] as? [[String: Any]] else { throw MangayomiMediaError.invalidData }
        return rows.prefix(1_200).compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty, name.utf8.count <= 512,
                  let link = row["link"] as? String, !link.isEmpty,
                  let href = MangayomiMediaKey(
                    source: source.id, kind: "title", value: link,
                    audio: audioHint(AutoModeStreamSelection.animeAudioReleaseHints(from: name))
                  ).encoded else { return nil }
            return SearchItem(title: name, imageUrl: row["imageUrl"] as? String ?? "", href: href)
        }
    }

    static func episodes(_ data: Data, source: MangayomiMediaSource, titleAudio: String? = nil) throws -> [EpisodeLink] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = (result["episodes"] ?? result["chapters"]) as? [[String: Any]] else {
            throw MangayomiMediaError.invalidData
        }
        var seen = Set<String>()
        return rows.prefix(8_192).flatMap { row -> [EpisodeLink] in
            guard let link = row["url"] as? String, !link.isEmpty else { return [] }
            let title = String((row["name"] as? String ?? "").prefix(512))
            let number = exactEpisodeNumber(row: row, link: link, title: title)
            var lanes: [(String, String?)] = [(link, audioHint([titleAudio, row["scanlator"] as? String].compactMap { $0 }))]
            if var value = try? JSONSerialization.jsonObject(with: Data(link.utf8)) as? [String: Any],
               let translations = value["translationType"] as? [String],
               value["episodeString"] is String, value["showId"] is String,
               !translations.isEmpty, translations.count <= 8 {
                lanes = translations.compactMap { translation in
                    value["translationType"] = [translation]
                    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
                    return (String(decoding: data, as: UTF8.self), translation)
                }
            }
            return lanes.compactMap { value, audio in
                let key = MangayomiMediaKey(
                    source: source.id, kind: "episode", value: value,
                    number: number.map { String($0) }, audio: audio
                )
                guard let href = key.encoded, seen.insert(href).inserted else { return nil }
                let integer = number.flatMap { $0.isFinite && $0 > 0 ? Int(exactly: $0) : nil } ?? -1
                let label = audio.map { $0.isEmpty ? title : title + " · " + $0 } ?? title
                return EpisodeLink(number: integer, title: label, href: href, duration: nil)
            }
        }
    }

    private static func audioHint(_ values: [String]) -> String? {
        let value = values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " · ")
        return value.isEmpty ? nil : String(value.prefix(512))
    }

    private static func exactEpisodeNumber(row: [String: Any], link: String, title: String) -> Double? {
        if let opaque = try? JSONSerialization.jsonObject(with: Data(link.utf8)) as? [String: Any],
           let value = opaque["episodeString"] as? String {
            return Double(value)
        }
        for key in ["episodeNumber", "number", "num"] {
            if let value = row[key] as? NSNumber,
               CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite { return value.doubleValue }
            if let value = row[key] as? String, let number = Double(value), number.isFinite { return number }
        }
        let pattern = #"(?i)^\s*(?:episode\s*|ep\.?\s*|episodio\s*|folge\s*|第\s*)?(\d+(?:\.\d+)?)(?:\s|\b|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range(at: 1), in: title) else { return nil }
        return Double(title[range])
    }

    @MainActor
    static func videos(key: MangayomiMediaKey, source: MangayomiMediaSource) async throws -> ServiceStreamExtractionResult {
        let data = try await MangayomiMediaManager.shared.execute(source: source, operation: "videos", arguments: ["url": key.value])
        return try streamExtraction(data, key: key)
    }

    static func streamExtraction(_ data: Data, key: MangayomiMediaKey) throws -> ServiceStreamExtractionResult {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw MangayomiMediaError.invalidData
        }
        let sources = rows.prefix(1_200).compactMap { row -> [String: Any]? in
            guard let value = row["url"] as? String,
                  NuvioPluginSupport.isDirectHTTPURL(value) else { return nil }
            let quality = row["quality"] as? String ?? "Auto"
            let label = key.audio.map { $0.isEmpty ? quality : quality + " · " + $0 } ?? quality
            var result: [String: Any] = [
                "streamUrl": value,
                "quality": quality,
                "name": label
            ]
            if let audio = key.audio { result["audio"] = audio }
            if let headers = row["headers"] as? [String: String] { result["headers"] = headers }
            if let rawAudio = row["audios"], !(rawAudio is NSNull) {
                guard let tracks = rawAudio as? [[String: Any]], tracks.count <= 32 else { return nil }
                let audioTracks = tracks.compactMap { track -> [String: Any]? in
                    guard let file = track["file"] as? String,
                          let url = URL(string: file, relativeTo: URL(string: value))?.absoluteURL,
                          NuvioPluginSupport.isDirectHTTPURL(url.absoluteString) else { return nil }
                    var item: [String: Any] = ["url": url.absoluteString, "label": track["label"] as? String ?? "Audio"]
                    if let headers = track["headers"] as? [String: String] ?? row["headers"] as? [String: String] {
                        item["headers"] = headers
                    }
                    return item
                }
                guard audioTracks.count == tracks.count else { return nil }
                result["externalAudioTracks"] = audioTracks
                result["audioLanguages"] = audioTracks.compactMap { $0["label"] as? String }
            }
            let subtitles = (row["subtitles"] as? [[String: Any]] ?? []).prefix(256).compactMap { track -> [String: Any]? in
                guard let file = track["file"] as? String,
                      let url = URL(string: file, relativeTo: URL(string: value))?.absoluteURL,
                      NuvioPluginSupport.isDirectHTTPURL(url.absoluteString) else { return nil }
                var item: [String: Any] = ["url": url.absoluteString, "label": track["label"] as? String ?? "Subtitle"]
                if let headers = track["headers"] as? [String: String] ?? row["headers"] as? [String: String] {
                    item["headers"] = headers
                }
                return item
            }
            result["subtitles"] = subtitles
            if let language = row["language"] as? String { result["language"] = language }
            if let languages = row["languages"] as? [String] { result["languages"] = languages }
            return result
        }
        let bounded = try JSONSerialization.data(withJSONObject: ["streams": sources])
        return try JSController.boundedStreamExtractionResult(from: bounded)
    }
}

extension JSController {
    @discardableResult
    func performMangayomi<Value>(
        source: MangayomiMediaSource,
        timeoutNanoseconds: UInt64,
        empty: Value,
        operation: @escaping @MainActor () async throws -> Value,
        completion: @escaping (Value) -> Void
    ) -> JSCallbackDeadline<Value> {
        let request = JSCallbackDeadline<Value> { value in
            DispatchQueue.main.async { completion(value) }
        }
        let task = Task { @MainActor in
            do {
                try Task.checkCancellation()
                let value = try await operation()
                try Task.checkCancellation()
                request.finish(with: value)
            } catch {
                if !(error is CancellationError) {
                    Logger.shared.log("Mangayomi source=\(source.name) operation failed", type: "Plugin")
                }
                request.finish(with: empty)
            }
        }
        installMangayomiOperation(task)
        request.setCancellationHandler { task.cancel() }
        request.armTimeout(nanoseconds: timeoutNanoseconds, value: empty) { task.cancel() }
        return request
    }
}
