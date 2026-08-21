import Foundation

struct NuvioSecretRedactor {
    private let secrets: [String]

    static let placeholder = "<redacted>"

    private static let minimumSecretLength = 8

    init(settings: [String: Any]) {
        var collected: Set<String> = []
        Self.collectStringValues(from: settings, into: &collected)

        secrets = collected
            .filter { $0.count >= Self.minimumSecretLength }
            .sorted { $0.count > $1.count }
    }

    private static func collectStringValues(from value: Any, into result: inout Set<String>) {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.insert(trimmed) }
        case let dictionary as [String: Any]:
            for nested in dictionary.values {
                collectStringValues(from: nested, into: &result)
            }
        case let array as [Any]:
            for nested in array {
                collectStringValues(from: nested, into: &result)
            }
        default:
            break
        }
    }

    func redact(_ text: String) -> String {
        guard !secrets.isEmpty else { return text }
        var result = text
        for secret in secrets where result.contains(secret) {
            result = result.replacingOccurrences(of: secret, with: Self.placeholder)
        }
        return result
    }
}
