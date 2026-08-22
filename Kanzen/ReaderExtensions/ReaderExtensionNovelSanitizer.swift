// Copyright 2026 Eclipse contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftSoup

enum ReaderExtensionHTMLPreflight {
    private static let maximumAttributesPerTag = 256
    // A real 1,190-chapter WeebCentral list page carries 58,318 attributes
    // and 1.77 MiB of tag markup. The per-tag caps above stay tight; the
    // per-document aggregates must clear mainstream catalog pages.
    private static let maximumAttributesPerDocument = 524_288
    private static let maximumTagBytes = 64 * 1_024
    private static let maximumAggregateTagBytes = 8 * 1_024 * 1_024

    /// Bounds DOM construction before SwiftSoup sees attacker-controlled HTML.
    /// Deliberately count every raw `<` token candidate, including candidates
    /// inside comments and raw-text elements. This avoids maintaining a second
    /// HTML tokenizer whose recovery rules could diverge from SwiftSoup. A
    /// normal document may use roughly one opener and one closer per element;
    /// a small allowance covers declarations and ordinary literal text. False
    /// positives fail closed, while exact post-parse element caps remain the
    /// authority for accepted input.
    static func validate(_ html: String, maximumBytes: Int, maximumNodeTokens: Int) throws {
        let bytes = Array(html.utf8)
        guard bytes.count <= maximumBytes,
              maximumNodeTokens > 0,
              maximumNodeTokens <= (Int.max - 64) / 2 else {
            throw ReaderExtensionError.contentTooLarge
        }
        let maximumTokenCandidates = maximumNodeTokens * 2 + 64
        var tokenCandidates = 0
        for byte in bytes where byte == 0x3c { // <
            guard tokenCandidates < maximumTokenCandidates else {
                throw ReaderExtensionError.contentTooLarge
            }
            tokenCandidates += 1
        }
        try validateAttributeWork(bytes)
    }

    private static func validateAttributeWork(_ bytes: [UInt8]) throws {
        var cursor = 0
        var totalAttributes = 0
        var aggregateTagBytes = 0
        while cursor < bytes.count {
            guard bytes[cursor] == 0x3c else { cursor += 1; continue } // <
            let tagStart = cursor
            cursor += 1
            while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
            // SwiftSoup's tokenizer temporarily records attributes on end-tag
            // tokens before the tree builder discards them. They therefore
            // need the same pre-allocation bound as start tags.
            if cursor < bytes.count, bytes[cursor] == 0x2f {
                cursor += 1
                while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
            }
            guard cursor < bytes.count, isTagNameStartByte(bytes[cursor]) else { continue }

            while cursor < bytes.count, isTagNameByte(bytes[cursor]) { cursor += 1 }
            var tagAttributes = 0
            while cursor < bytes.count {
                guard cursor - tagStart <= maximumTagBytes else {
                    throw ReaderExtensionError.contentTooLarge
                }
                while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
                guard cursor < bytes.count else { throw ReaderExtensionError.contentTooLarge }
                if bytes[cursor] == 0x3e { // >
                    cursor += 1
                    break
                }
                if bytes[cursor] == 0x2f { // optional self-closing slash
                    cursor += 1
                    while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
                    guard cursor < bytes.count, bytes[cursor] == 0x3e else {
                        throw ReaderExtensionError.contentTooLarge
                    }
                    cursor += 1
                    break
                }

                let nameStart = cursor
                while cursor < bytes.count, !isAttributeDelimiter(bytes[cursor]) { cursor += 1 }
                guard cursor > nameStart else { throw ReaderExtensionError.contentTooLarge }
                tagAttributes += 1
                totalAttributes += 1
                guard tagAttributes <= maximumAttributesPerTag,
                      totalAttributes <= maximumAttributesPerDocument else {
                    throw ReaderExtensionError.contentTooLarge
                }

                while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
                if cursor < bytes.count, bytes[cursor] == 0x3d { // =
                    cursor += 1
                    while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }
                    guard cursor < bytes.count else { throw ReaderExtensionError.contentTooLarge }
                    if bytes[cursor] == 0x22 || bytes[cursor] == 0x27 { // quoted value
                        let quote = bytes[cursor]
                        cursor += 1
                        while cursor < bytes.count, bytes[cursor] != quote {
                            cursor += 1
                            guard cursor - tagStart <= maximumTagBytes else {
                                throw ReaderExtensionError.contentTooLarge
                            }
                        }
                        guard cursor < bytes.count else { throw ReaderExtensionError.contentTooLarge }
                        cursor += 1
                    } else { // quotes are ordinary parse-error bytes in unquoted values
                        while cursor < bytes.count,
                              !isWhitespace(bytes[cursor]),
                              bytes[cursor] != 0x3e {
                            cursor += 1
                            guard cursor - tagStart <= maximumTagBytes else {
                                throw ReaderExtensionError.contentTooLarge
                            }
                        }
                    }
                }
            }

            let tagBytes = cursor - tagStart
            guard tagBytes <= maximumTagBytes,
                  tagBytes <= maximumAggregateTagBytes - aggregateTagBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            aggregateTagBytes += tagBytes
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0a || byte == 0x0c || byte == 0x0d || byte == 0x20
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
    }

    private static func isTagNameStartByte(_ byte: UInt8) -> Bool {
        // SwiftSoup accepts non-ASCII HTML tag names. Treat every UTF-8 byte
        // in such a name as markup work so `<é a0=x ...>` cannot bypass the
        // same pre-allocation attribute limits applied to ordinary tags.
        isASCIILetter(byte) || byte >= 0x80
    }

    private static func isTagNameByte(_ byte: UInt8) -> Bool {
        isTagNameStartByte(byte) || (0x30...0x39).contains(byte) || byte == 0x2d || byte == 0x3a
    }

    private static func isAttributeDelimiter(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || byte == 0x2f || byte == 0x3e || byte == 0x3d
            || byte == 0x00 || byte == 0x22 || byte == 0x27 || byte == 0x3c
    }
}

enum ReaderExtensionNovelSanitizer {
    static let maximumInputBytes = 4 * 1_024 * 1_024
    static let maximumOutputBytes = 4 * 1_024 * 1_024
    static let maximumDOMElements = 4_096

    static func sanitize(
        _ html: String,
        baseURL _: URL,
        approvedDomains _: Set<String>
    ) throws -> String {
        guard html.utf8.count <= maximumInputBytes else { throw ReaderExtensionError.contentTooLarge }
        try ReaderExtensionHTMLPreflight.validate(
            html,
            maximumBytes: maximumInputBytes,
            maximumNodeTokens: maximumDOMElements - 4
        )
        // Sanitized novel chapters are display-only: the reader cancels every
        // navigation, and remote content is intentionally unavailable. Do not
        // resolve or DNS-validate attacker-controlled links here. The cleaner
        // traverses the complete DOM and removes every navigation-bearing
        // attribute that its relaxed policy would otherwise preserve.
        let dirty = try SwiftSoup.parse(html)
        guard try dirty.getAllElements().size() <= maximumDOMElements else {
            throw ReaderExtensionError.contentTooLarge
        }
        let whitelist = try Whitelist.relaxed()
            .removeAttributes("a", "href")
            .removeAttributes("blockquote", "cite")
            .removeAttributes("q", "cite")
            .removeAttributes("img", "src")
        let clean = try Cleaner(headWhitelist: nil, bodyWhitelist: whitelist).clean(dirty)
        // Reader-extension chapter documents are deliberately network-inert.
        // Remote images would otherwise be fetched by WebKit outside the
        // source-scoped, DNS-pinned HTTP client and would also make completed
        // novel downloads dependent on the provider remaining online.
        try clean.select("img, picture, form, input, button, textarea, select, option, iframe, frame, object, embed, audio, video, source, track, canvas, svg, math, script, noscript, style, link, meta, base").remove()

        guard let body = clean.body() else { return "" }
        let result = try body.html()
        guard result.utf8.count <= maximumOutputBytes else { throw ReaderExtensionError.contentTooLarge }
        return result
    }

    static func isolatedDocument(bodyHTML: String) throws -> String {
        guard bodyHTML.utf8.count <= maximumOutputBytes else { throw ReaderExtensionError.contentTooLarge }
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'none'; style-src 'unsafe-inline'; font-src 'none'; media-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; connect-src 'none'">
        </head>
        <body>\(bodyHTML)</body>
        </html>
        """
    }

}
