import Foundation
import Tokenizers

/// Turns text plus a reference voice into the model's input grid.
///
/// The grid is [1 + numCodebooks] rows by however many tokens: row zero is the
/// text and the reference's semantic ids, and the rows beneath carry the
/// reference's codec codes, aligned under the semantic ids they belong to.
/// Everything else is zero.
public struct PromptBuilder {
    let tokenizer: any Tokenizer
    let semanticBeginID: Int
    let numCodebooks: Int

    public init(tokenizer: any Tokenizer, semanticBeginID: Int, numCodebooks: Int) {
        self.tokenizer = tokenizer
        self.semanticBeginID = semanticBeginID
        self.numCodebooks = numCodebooks
    }

    /// [rows][columns], row-major, as the graph wants it.
    public func build(target: String, voice: VoiceProfile) throws -> [[Int64]] {
        let prefixParts = [
            "<|im_start|>system\n",
            "convert the provided text to speech reference to the following:\n\nText:\n",
            PromptBuilder.formatReference(voice.referenceText),
            "\n\nSpeech:\n",
        ]
        let suffixParts = [
            "<|im_end|>\n",
            "<|im_start|>user\n",
            PromptBuilder.clean(target),
            "<|im_end|>\n",
            "<|im_start|>assistant\n<|voice|>",
        ]

        // Encoded part by part, exactly as the reference does. Joining first
        // and encoding once produces different tokens at the seams, and the
        // model was trained on the pieces.
        let prefix = prefixParts.flatMap { encode($0) }
        let suffix = suffixParts.flatMap { encode($0) }

        let semantic = voice.codes[0].map { Int64($0) + Int64(semanticBeginID) }
        let row0 = prefix.map(Int64.init) + semantic + suffix.map(Int64.init)

        var rows = [[Int64]](repeating: [Int64](repeating: 0, count: row0.count),
                             count: numCodebooks + 1)
        rows[0] = row0
        let begin = prefix.count
        for book in 0..<numCodebooks {
            for (offset, code) in voice.codes[book].enumerated() {
                rows[book + 1][begin + offset] = Int64(code)
            }
        }
        return rows
    }

    func encode(_ text: String) -> [Int] {
        tokenizer.encode(text: text, addSpecialTokens: false)
    }

    /// A reference transcript is expected to name its speaker; one that does
    /// not gets speaker zero.
    static func formatReference(_ text: String) -> String {
        let cleaned = clean(text)
        let hasSpeaker = cleaned.range(of: #"<\|speaker:\d+\|>"#, options: .regularExpression) != nil
        return hasSpeaker ? cleaned : "<|speaker:0|>\(cleaned)"
    }

    /// Drop control characters, then collapse whitespace.
    ///
    /// A line break between two CJK characters is removed rather than replaced
    /// with a space: those scripts do not put spaces between words, and a
    /// wrapped line would otherwise be read with a gap in the middle of one.
    static func clean(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { scalar in
            if scalar.properties.isWhitespace { return true }
            return !isControl(scalar)
        }
        return collapseWhitespace(String(String.UnicodeScalarView(kept)))
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned: return true
        default: return false
        }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index].properties.isWhitespace else {
                out.append(scalars[index])
                index += 1
                continue
            }
            var end = index
            var sawBreak = false
            while end < scalars.count, scalars[end].properties.isWhitespace {
                if isLineBreak(scalars[end]) { sawBreak = true }
                end += 1
            }
            let before = index > 0 ? scalars[index - 1] : nil
            let after = end < scalars.count ? scalars[end] : nil
            let joinsCJK = sawBreak && before.map(isCJK) == true && after.map(isCJK) == true
            if !joinsCJK { out.append(" ") }
            index = end
        }
        return String(String(out).trimmingCharacters(in: .whitespaces))
    }

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x1C...0x1E, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x303F, 0x3040...0x30FF,
             0x3100...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97F,
             0xAC00...0xD7A3, 0xD7B0...0xD7FF, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF01...0xFF9F, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
