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
                     + "works with no signal, and never declines."
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
    /// Returns nil when it declines or fails, having set `problem` — the caller
    /// can then offer the downloaded model instead, which does not refuse.
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
            return Prose.spoken(text)
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
    /// It is smaller and less able than Apple's, and it never refuses — which
    /// on balance is what this is for.
    func writeLocally(_ instruction: String,
                      using store: Store) async -> String? {
        problem = nil
        isWriting = true
        defer { isWriting = false }
        do {
            let text = try await store.write(Prose.asked(instruction), system: Writer.brief)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Prose.spoken(trimmed)
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }
}

/// Something to say, for people who did not come with anything prepared.
///
/// All public domain. Song lyrics and film dialogue are the obvious crowd
/// pleasers and both are still in copyright — shipping them inside an app is
/// not the same as humming them in the shower, so these are drawn from work
/// that is genuinely free to use.
struct Preset: Identifiable {
    let id = UUID()
    let label: String
    let source: String
    let text: String

    static let all: [Preset] = [
        Preset(label: "Hamlet", source: "Shakespeare, 1603",
               text: "To be, or not to be, that is the question. Whether it is "
                   + "nobler in the mind to suffer the slings and arrows of "
                   + "outrageous fortune, or to take arms against a sea of "
                   + "troubles, and by opposing, end them."),
        Preset(label: "The Moon", source: "Neil Armstrong, 1969",
               text: "That's one small step for man. One giant leap for mankind."),
        Preset(label: "Austen", source: "Pride and Prejudice, 1813",
               text: "It is a truth universally acknowledged, that a single man "
                   + "in possession of a good fortune must be in want of a wife."),
        Preset(label: "The Raven", source: "Edgar Allan Poe, 1845",
               text: "Once upon a midnight dreary, while I pondered, weak and "
                   + "weary, over many a quaint and curious volume of forgotten "
                   + "lore. While I nodded, nearly napping, suddenly there came "
                   + "a tapping, as of someone gently rapping at my chamber door."),
        Preset(label: "Dickens", source: "A Tale of Two Cities, 1859",
               text: "It was the best of times, it was the worst of times. It was "
                   + "the age of wisdom, it was the age of foolishness."),
        Preset(label: "Voicemail", source: "for testing on somebody",
               text: "Hi, it's me. I can't come to the phone right now, because "
                   + "I am not actually the one saying this. Leave a message and "
                   + "I'll think about it."),
    ]
}
