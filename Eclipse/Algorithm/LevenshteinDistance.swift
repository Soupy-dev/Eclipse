//
//  LevenshteinDistance.swift
//  Sora
//
//  Created by Francesco on 09/08/25.
//

import Foundation

class LevenshteinDistance {
    public static func calculateSimilarity(original: String, result: String) -> Double {
        guard !original.isEmpty && !result.isEmpty else {
            return original.isEmpty && result.isEmpty ? 1.0 : 0.0
        }

        let normalizedOriginal = original.lowercased().replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
        let normalizedResult = result.lowercased().replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)

        guard !normalizedOriginal.isEmpty && !normalizedResult.isEmpty else {
            return normalizedOriginal.isEmpty && normalizedResult.isEmpty ? 1.0 : 0.0
        }

        let distance = levenshteinDistance(normalizedOriginal, normalizedResult)
        let maxLength = max(normalizedOriginal.count, normalizedResult.count)

        guard maxLength > 0 else { return 1.0 }

        return 1.0 - Double(distance) / Double(maxLength)
    }

    public static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        // Keep the shorter input in the row dimension. Provider titles are
        // bounded before ranking, but a result set can still contain hundreds
        // of long candidates; a full O(m*n) matrix creates avoidable memory
        // pressure for every comparison. Two rows produce the identical edit
        // distance with O(min(m, n)) storage.
        var rows = Array(s1)
        var columns = Array(s2)
        if rows.count < columns.count {
            swap(&rows, &columns)
        }

        guard !columns.isEmpty else { return rows.count }
        guard !rows.isEmpty else { return columns.count }

        var previous = Array(0...columns.count)
        var current = Array(repeating: 0, count: columns.count + 1)

        for (rowIndex, rowCharacter) in rows.enumerated() {
            current[0] = rowIndex + 1
            for (columnIndex, columnCharacter) in columns.enumerated() {
                let insertion = current[columnIndex] + 1
                let deletion = previous[columnIndex + 1] + 1
                let substitution = previous[columnIndex]
                    + (rowCharacter == columnCharacter ? 0 : 1)
                current[columnIndex + 1] = min(insertion, deletion, substitution)
            }
            swap(&previous, &current)
        }

        return previous[columns.count]
    }
}
