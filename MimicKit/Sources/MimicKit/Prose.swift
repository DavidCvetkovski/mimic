import Foundation

/// Tidying what a language model hands back, and noticing when it has refused.
///
/// Small, pure, and in the package rather than in the app so that it can be
/// tested — which matters more than it sounds. Every function here exists
/// because of something a model actually did, and each is one careless edit
/// away from silently not working again.
public enum Prose {

    /// Straight quotes, so patterns typed with an ASCII apostrophe match text
    /// written with a typographic one.
    ///
    /// This is the whole reason a refusal reached the screen: the check looked
    /// for "i'm sorry" and the model wrote "I’m sorry", which does not start
    /// with it. They are different characters and look identical in almost
    /// every typeface.
    public static func flattenedQuotes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    /// Whether a reply is the model declining rather than writing.
    ///
    /// Apple's system model refuses by replying, not by failing, so without
    /// this "I'm sorry, I can't write a poem" was pasted into the box and then
    /// read aloud in somebody's own cloned voice — which is a strange thing to
    /// hear yourself say.
    ///
    /// The markers are deliberately assistant-speak rather than ordinary
    /// English. A passage can contain "I can't"; a passage does not usually
    /// describe its own primary function. Being wrong in this direction costs
    /// a retry, and being wrong in the other costs somebody the illusion.
    public static func isRefusal(_ text: String) -> Bool {
        let flattened = flattenedQuotes(text).lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A long piece that happens to open this way is a piece, not a refusal.
        guard flattened.count < 400 else { return false }

        // Deliberately not a bare "i can't": plenty of good first-person writing
        // opens that way — "I can't believe how bright the morning is" is a
        // sentence, not a decline — and rejecting it would be the worse error
        // of the two. What gives a refusal away is that it talks about itself:
        // what it is able to do, what it is for, what it is.
        let tells = [
            "i can't write", "i cannot write", "i can not write",
            "i can't help with", "i cannot help with",
            "i can't assist", "i cannot assist",
            "i can't create", "i cannot create",
            "i can't generate", "i cannot generate",
            "i can't provide", "i cannot provide",
            "i'm unable to", "i am unable to",
            "i'm not able to", "i am not able to",
            "as an ai", "i'm just an ai", "i am just an ai",
            "my primary function", "i don't have the ability",
        ]
        return tells.contains { flattened.contains($0) }
    }

    /// Turn what somebody typed into something a model will act on.
    ///
    /// People type a noun phrase — "poem", "a toast" — and a small model does
    /// not read that as a request. Measured against Qwen2.5-0.5B, asked for a
    /// poem four ways:
    ///
    ///     "poem"                    an unrelated sentence about a fox
    ///     "Write poem."             the words "Write a poem." back again
    ///     "Please write me poem."   a refusal
    ///     "Please write me a poem." a poem
    ///
    /// The article is not decoration. Without it the model refuses; with it it
    /// writes. So the missing one is supplied, which is the whole difference
    /// between this button working and not.
    public static func asked(_ instruction: String) -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return trimmed }

        let verbs = ["write", "compose", "make", "give", "tell", "draft", "come up"]
        if verbs.contains(where: { trimmed.lowercased().hasPrefix($0) }) { return trimmed }
        // A whole sentence somebody typed themselves is left alone.
        if first.isUppercase, trimmed.hasSuffix(".") || trimmed.hasSuffix("?") {
            return trimmed
        }

        var body = article(for: trimmed) + trimmed
        if !".!?".contains(body.last ?? " ") { body += "." }
        return "Please write me \(body)"
    }

    /// "a " or "an " when the phrase is a bare singular noun, otherwise nothing.
    ///
    /// Kept deliberately shy: a wrong article reads worse than a missing one,
    /// so anything already determined, plural, or uncountable is left alone.
    private static func article(for phrase: String) -> String {
        let lower = phrase.lowercased()
        let determined = ["a ", "an ", "the ", "some ", "any ", "my ", "your ", "our ",
                          "their ", "his ", "her ", "this ", "that ", "these ", "those ",
                          "one ", "two ", "three ", "several ", "each ", "every ", "no ",
                          "something", "anything", "everything"]
        if determined.contains(where: { lower.hasPrefix($0) }) { return "" }

        guard let word = lower.split(whereSeparator: { $0 == " " }).first else { return "" }
        if word.count > 2, word.hasSuffix("s"), !word.hasSuffix("ss") { return "" }  // plural
        return "aeiou".contains(word.first ?? " ") ? "an " : "a "
    }

    /// Drop an opening line that announces the answer rather than being it.
    ///
    /// "Sure, here's a short poem:" is addressed to the person who asked, not
    /// to whoever is going to hear it — and read aloud in your own voice it is
    /// the giveaway that you did not write this.
    static func withoutPreamble(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let opening = lines.first else { return text }
        let head = flattenedQuotes(String(opening)).lowercased()
            .trimmingCharacters(in: .whitespaces)
        let announces = ["sure", "certainly", "of course", "here's", "here is",
                         "absolutely", "okay", "ok", "got it", "happy to"]
        guard head.hasSuffix(":"), head.count < 80,
              announces.contains(where: { head.hasPrefix($0) }) else { return text }
        return lines.dropFirst().joined(separator: "\n")
    }

    /// Strip a structural label from the front of a line.
    ///
    /// Small models label the parts of what they write — "Verse 1:", "Chorus:"
    /// — however plainly the instructions ask them not to. On the page it is
    /// merely untidy; read aloud, somebody's own voice announces "verse one"
    /// before each stanza.
    ///
    /// Only these words, and only followed by an optional number and a colon.
    /// "She said:" and "Dear Sir:" are writing and are left alone.
    static func withoutLabel(_ line: String) -> String {
        let labels = ["verse", "chorus", "bridge", "refrain", "stanza", "line",
                      "title", "intro", "outro", "part", "section"]
        let lower = line.lowercased()
        for label in labels where lower.hasPrefix(label) {
            var rest = Substring(line).dropFirst(label.count)
            rest = rest.drop { $0 == " " }
            rest = rest.drop { $0.isNumber }
            rest = rest.drop { $0 == " " }
            guard rest.first == ":" else { continue }
            return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    /// Tidy a reply into something a voice can read.
    public static func spoken(_ text: String) -> String {
        var cleaned = withoutPreamble(text)
        // Markdown emphasis is silent on the page and nonsense out loud.
        for marker in ["**", "*", "__", "_", "#"] {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "")
        }
        // A whole response wrapped in quotes is the model quoting itself.
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 2,
           let first = trimmed.first, let last = trimmed.last,
           "\"\u{201C}".contains(first), "\"\u{201D}".contains(last) {
            cleaned = String(trimmed.dropFirst().dropLast())
        }
        // Line breaks are kept — verse depends on them, and the engine flattens
        // whitespace before speaking anyway, so they cost nothing.
        return cleaned.split(whereSeparator: \.isNewline)
            .map { withoutLabel($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
