import Foundation
import MimicKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Text to say, without having to think of any.
///
/// Two sources. The presets are fixed and always there. The writer is Apple's
/// on-device model, which ships with the system — no download, nothing to host,
/// and the prompt never leaves the phone, which is the same promise the rest of
/// the app makes.
@MainActor
final class Writer: ObservableObject {

    @Published private(set) var isWriting = false
    @Published var problem: String?

    /// Whether there is a model to write with, and what to do if there isn't.
    enum Readiness {
        /// Apple's, which ships with the system and costs nothing.
        case system
        /// The one on this phone because somebody asked for it.
        case downloaded
        /// Neither, but the second can be fetched.
        case offerDownload
        case missing(String)

        var isReady: Bool {
            switch self { case .system, .downloaded: return true; default: return false }
        }
        var reason: String? { if case .missing(let why) = self { return why }; return nil }
    }

    /// Which model writes it. A preference, not a fact about the device.
    enum Choice: String, CaseIterable, Identifiable {
        case mimic
        case apple

        var id: String { rawValue }
        var name: String { self == .mimic ? "Mimic's" : "Apple's" }
        var note: String {
            switch self {
            case .mimic:
                return "Mimic's own model, on this phone. Smaller and plainer, "
                     + "and works with no signal."
            case .apple:
                return "Apple's system model. Better written when it agrees to "
                     + "write, and it declines more than you would expect."
            }
        }
    }

    var isAppleAvailable: Bool {
        if case .ready = appleReadiness { return true }
        return false
    }

    /// Write with whichever model was chosen.
    func write(_ instruction: String, with choice: Choice,
               store: Store) async -> String? {
        switch choice {
        case .apple:  return await writeWithSystemModel(instruction)
        case .mimic:  return await writeLocally(instruction, using: store)
        }
    }

    /// Where the writing actually happens.
    ///
    /// Apple's model is free and needs no download, so it is used when it is
    /// there. It is also absent on most devices and declines more than it
    /// should, so the app carries its own — and once that is installed it is
    /// preferred, because it does the job the same way every time.
    func readiness(canWrite: Bool) -> Readiness {
        if canWrite { return .downloaded }
        if case .ready = appleReadiness { return .system }
        return .offerDownload
    }

    /// The instructions both backends work from.
    static let brief = """
        You write short pieces of text for someone to hear read aloud.

        Write only the words to be spoken. No headings, no bullet points, no \
        stage directions, no preamble, and no note about what you have \
        written. Use ordinary punctuation — it is what tells a synthetic voice \
        where to breathe.

        Poems and verse are welcome; keep their line breaks. Anything else, \
        write the way a person talks rather than the way a document reads. \
        Around eighty words unless more is asked for.
        """

    /// What the downloaded model is told on top of the brief. Apple's model
    /// has guardrails of its own; this one has only what it is told here and
    /// the check in `ContentCheck` afterwards.
    static let localBrief = brief + "\n\n" + """
        Keep it short, clean and family-friendly: no swearing, no slurs, and \
        nothing sexual, violent or hateful. If you are asked for something \
        that is not, write something harmless on the same subject instead.
        """

    /// Apple's model only. `Readiness` above is about the app as a whole.
    enum AppleReadiness {
        case ready
        case missing(String)
        var reason: String? { if case .missing(let why) = self { return why }; return nil }
    }

    var appleReadiness: AppleReadiness {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .ready
            case .unavailable(.deviceNotEligible):
                return .missing("This device does not have Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return .missing("Turn on Apple Intelligence in Settings to write with it.")
            case .unavailable(.modelNotReady):
                return .missing("The system model is still downloading. Try again shortly.")
            case .unavailable:
                return .missing("The system model is not available right now.")
            @unknown default:
                return .missing("The system model is not available right now.")
            }
        }
        return .missing("Writing needs iOS 26 or newer.")
        #else
        return .missing("Writing is not available in this build.")
        #endif
    }

    /// Write with Apple's model.
    ///
    /// Returns nil when it declines or fails, or when what it wrote does not
    /// pass `ContentCheck`, having set `problem`.
    func writeWithSystemModel(_ instruction: String) async -> String? {
        problem = nil
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }
        if case .missing(let why) = appleReadiness { problem = why; return nil }

        isWriting = true
        defer { isWriting = false }

        // The instructions matter more than the prompt here. Left alone the
        // model writes for the page — headings, bullet points, asides in
        // brackets — none of which can be spoken. This asks for something a
        // person could read out.
        let session = LanguageModelSession(instructions: Writer.brief)
        do {
            let response = try await session.respond(to: Prose.asked(instruction))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // A refusal comes back as an ordinary reply, not an error, so
            // without this "I can't help with that" was pasted into the box and
            // then read aloud in your own voice, which is a strange thing to
            // hear yourself say.
            guard !Prose.isRefusal(text) else {
                problem = "The system model would not write that one."
                return nil
            }
            let spoken = Prose.spoken(text)
            guard ContentCheck.isClean(spoken) else {
                problem = ContentCheck.rejection
                return nil
            }
            return spoken
        } catch {
            problem = error.localizedDescription
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Write with the model this app downloaded.
    ///
    /// It is smaller and less able than Apple's. It is asked for something
    /// clean, and what it writes is checked before anyone hears it.
    func writeLocally(_ instruction: String,
                      using store: Store) async -> String? {
        problem = nil
        isWriting = true
        defer { isWriting = false }
        do {
            let text = try await store.write(Prose.asked(instruction), system: Writer.localBrief)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Told to keep it clean, a small model sometimes declines outright
            // instead, and a refusal read aloud in your own voice is no better
            // from this one than from Apple's.
            guard !Prose.isRefusal(trimmed) else {
                problem = "Mimic's writer would not write that one. Try asking for something else."
                return nil
            }
            let spoken = Prose.spoken(trimmed)
            guard ContentCheck.isClean(spoken) else {
                problem = ContentCheck.rejection
                return nil
            }
            return spoken
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }
}

/// A last look at what a writer produced, before it reaches the text box.
///
/// Basic by design: whole words against a short list, so "Scunthorpe" and
/// "assess" pass. The instructions do most of the work; this catches what gets
/// past them. Nothing is sent anywhere to decide.
enum ContentCheck {

    static let rejection = "That one came back with words Mimic will not read out. "
                         + "Try asking for something else."

    /// Clearly offensive words and slurs, matched as whole words. Only words
    /// with no everyday innocent meaning are here, so a passage about a
    /// donkey, a rooster or a cat is not caught by accident.
    static let offensiveWords: Set<String> = [
        // Swearing and crude
        "shit", "shits", "shitty", "shitting", "shithead", "bullshit",
        "horseshit", "dipshit", "cunt", "cunts", "asshole", "assholes",
        "arsehole", "arseholes", "bitch", "bitches", "bitchy", "bastard",
        "bastards", "twat", "twats", "wanker", "wankers", "dickhead",
        "dickheads", "cocksucker", "cocksuckers", "whore", "whores", "slut",
        "sluts", "slutty", "porn", "porno",
        // Slurs
        "nigger", "niggers", "nigga", "niggas", "kike", "kikes", "spic",
        "spics", "wetback", "wetbacks", "gook", "gooks", "faggot", "faggots",
        "tranny", "trannies", "retard", "retards", "retarded", "paki", "pakis",
        "raghead", "ragheads", "towelhead", "towelheads", "beaner", "beaners",
    ]

    /// Matched anywhere inside a word, because no ordinary word contains them.
    static let offensiveFragments = ["fuck"]

    static func isClean(_ text: String) -> Bool {
        let words = Prose.flattenedQuotes(text).lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !$0.isLetter })
        return !words.contains { word in
            offensiveWords.contains(String(word))
                || offensiveFragments.contains { word.contains($0) }
        }
    }
}
