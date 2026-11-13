import Foundation

/// Local text chunking for retrieval (spec §7): fixed-size chunks with overlap,
/// preserving character offsets so citations can point back into the document.
public struct TextChunker: Sendable {
    public let maxCharacters: Int
    public let overlapCharacters: Int

    /// Defaults sized for AFM's measured 8192-token context (docs/capabilities.md):
    /// keep retrieved material a small fraction of the budget.
    public init(maxCharacters: Int = 1600, overlapCharacters: Int = 150) {
        self.maxCharacters = max(64, maxCharacters)
        self.overlapCharacters = max(0, min(overlapCharacters, maxCharacters / 2))
    }

    /// Split text into chunks with byte-accurate character offsets into `text`.
    public func chunk(_ text: String) -> [Chunk] {
        guard !text.isEmpty else { return [] }
        var chunks: [Chunk] = []
        var offset = 0
        let total = text.count
        while offset < total {
            let end = min(offset + maxCharacters, total)
            let startForSlice = text.index(text.startIndex, offsetBy: offset)
            let endForSlice = text.index(text.startIndex, offsetBy: end)
            var slice = String(text[startForSlice..<endForSlice])
            // Trim trailing partial word to avoid splitting mid-word when possible,
            // but only when more text follows this window.
            if end < total, let lastSpace = slice.lastIndex(of: " ") {
                let cut = slice.distance(from: slice.startIndex, to: lastSpace)
                if cut > maxCharacters / 3 {
                    slice = String(slice[..<lastSpace])
                }
            }
            chunks.append(Chunk(charOffset: offset, charLength: slice.count, text: slice))
            // The window reaching the end of text is final; overlap rewind only
            // applies when there is remaining text to cover.
            if end >= total { break }
            offset += max(1, slice.count - overlapCharacters)
        }
        return chunks
    }

    public struct Chunk: Codable, Sendable, Hashable {
        public var charOffset: Int
        public var charLength: Int
        public var text: String
    }
}

/// Token-budget estimation for retrieval. Uses characters/4 as a rough proxy
/// ONLY where no native counting exists, and labels the result as estimated.
/// The Apple path uses the native `tokenCount(for:)` API instead (native).
public enum ContextBudget {
    public static let defaultAppleReserveTokens = 1024 // room for output

    /// How many characters of retrieved passages fit in Apple's measured context.
    public static func appleCharacterBudget(contextSize: Int?, historyTokens: Int?) -> Int {
        guard let contextSize, contextSize > 0 else { return 3200 } // conservative fallback
        let used = (historyTokens ?? 0) + defaultAppleReserveTokens
        let remainingTokens = max(256, contextSize - used)
        // AFM tokenizer averages ~4 chars/token for English; estimate labeled.
        return remainingTokens * 4
    }

    /// LM Studio context is not exposed by /v1/models; without a configured
    /// context length, use half of a conservative 4096-token default. When the
    /// user DID configure the model's context, budget the full measured value —
    /// history/reserve are subtracted by the caller.
    public static func lmStudioCharacterBudget(contextSize: Int?) -> Int {
        let tokens = max(512, contextSize ?? (4096 / 2))
        return tokens * 4
    }
}
