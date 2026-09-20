import Foundation

enum MangayomiMediaRuntime {
    static func execute(
        source: MangayomiMediaSource,
        script: String,
        operation: String,
        arguments: [String: Any],
        preferences: [String: Any],
        profileID: UUID,
        sharesServices: Bool
    ) async throws -> Data {
        try await executeWithPreferences(
            source: source, script: script, operation: operation, arguments: arguments,
            preferences: preferences, profileID: profileID, sharesServices: sharesServices
        ).data
    }

    static func executeWithPreferences(
        source: MangayomiMediaSource,
        script: String,
        operation: String,
        arguments: [String: Any],
        preferences: [String: Any],
        profileID: UUID,
        sharesServices: Bool,
        configurationPreferences: [String: Any]? = nil
    ) async throws -> (data: Data, preferenceWrites: [String: String]) {
        guard let metadata = try JSONSerialization.jsonObject(with: Data(source.metadataJSON.utf8)) as? [String: Any] else {
            throw MangayomiMediaError.invalidData
        }
        let request: [String: Any] = [
            "script": source.scriptLanguage == 0 ? script : "",
            "source": metadata,
            "operation": operation,
            "arguments": arguments,
            "preferences": preferences
        ]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .fragmentsAllowed])
        let literal = String(decoding: data, as: UTF8.self)
        let host = try resource("MangayomiMediaHost")
        let dart = try resource("MangayomiDartRuntime")
        let scriptBody = source.scriptLanguage == 1
            ? script + "\nglobalThis.__eclipseMangayomiExtension = DefaultExtension;"
            : ""
        let sourceLiteral = String(decoding: try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), as: UTF8.self)
        let preferencesLiteral = String(decoding: try JSONSerialization.data(withJSONObject: preferences, options: [.sortedKeys]), as: UTF8.self)
        let initialization = "globalThis.__eclipseMangayomiSource = " + sourceLiteral
            + "; Object.assign(globalThis.__eclipseMangayomiPreferences, " + preferencesLiteral + ");"
        let code = host + "\n" + initialization + "\n" + dart + "\n" + scriptBody
        let entry = source.scriptLanguage == 0 ? "__eclipseMangayomiDartRun" : "__eclipseMangayomiJSRun"
        let invocation = """
        Promise.resolve().then(function() {
            return \(entry)(JSON.stringify(\(literal)));
        }).then(function(value) {
            __capture_result(JSON.stringify({
                value: typeof value === 'string' ? JSON.parse(value) : value,
                preferenceWrites: globalThis.__eclipseMangayomiPreferenceWrites || {}
            }));
        }).catch(function(error) {
            __capture_error('Mangayomi source operation failed.');
        });
        """
        let result = try await NuvioPluginRuntime.executeMangayomi(
            code: code, invocation: invocation, source: source,
            preferences: preferences, profileID: profileID, sharesServices: sharesServices,
            configurationFingerprint: MangayomiMediaManager.digest(Data([
                source.metadataJSON, MangayomiMediaManager.digest(Data(script.utf8)),
                String(decoding: try JSONSerialization.data(withJSONObject: configurationPreferences ?? preferences, options: [.sortedKeys]), as: UTF8.self)
            ].joined(separator: "\u{0}").utf8))
        )
        try Task.checkCancellation()
        try SkyStreamJSONEnvelopeValidator.validate(result, limits: .init(
            maximumDepth: 24, maximumTokens: 400_000, maximumValuesPerContainer: 20_000,
            maximumStringBytes: 1_024 * 1_024, maximumScalarTokenBytes: 128
        ))
        guard let envelope = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let value = envelope["value"],
              let writes = envelope["preferenceWrites"] as? [String: String],
              writes.count <= 128,
              writes.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.utf8.count <= 65_536 }) else {
            throw MangayomiMediaError.invalidData
        }
        return (try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), writes)
    }

    private static func resource(_ name: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
            throw MangayomiMediaError.runtime("The Mangayomi runtime is missing from this build.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

final class MangayomiRuntimeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (() -> Void)?

    func install(_ handler: @escaping () -> Void) {
        lock.lock()
        let wasCancelled = cancelled
        if !wasCancelled { self.handler = handler }
        lock.unlock()
        if wasCancelled { handler() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let handler = handler
        self.handler = nil
        lock.unlock()
        handler?()
    }

    func clear() {
        lock.lock()
        handler = nil
        lock.unlock()
    }
}
