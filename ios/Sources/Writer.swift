import Foundation
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

    /// Whether there is a model to write with, and why not if there isn't.
    enum Readiness {
        case ready
        case missing(String)

        var isReady: Bool { if case .ready = self { return true }; return false }
        var reason: String? { if case .missing(let why) = self { return why }; return nil }
    }

    var readiness: Readiness {
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

    /// Turn an instruction into something worth hearing aloud.
    func write(_ instruction: String) async -> String? {
        problem = nil
        guard readiness.isReady else {
            problem = readiness.reason
            return nil
        }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return nil }

        isWriting = true
        defer { isWriting = false }

        // The instructions matter more than the prompt here. Left alone the
        // model writes for the page — headings, bullet points, asides in
        // brackets — none of which can be spoken. This asks for something a
        // person could read out.
        let session = LanguageModelSession(instructions: """
            You write short passages to be read aloud in someone's own voice.

            Write only the words to be spoken. No headings, no bullet points, \
            no stage directions, no notes about what you have written, and no \
            quotation marks around the whole thing. Use ordinary punctuation, \
            because it is what tells the voice where to breathe.

            Keep it under about eighty words unless asked for more. Write it so \
            it sounds like someone talking, not like a document.
            """)
        do {
            let response = try await session.respond(to: instruction)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Writer.spoken(text)
        } catch {
            problem = error.localizedDescription
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Tidy what came back into something the voice can read.
    static func spoken(_ text: String) -> String {
        var cleaned = text
        // Markdown emphasis is silent on the page and nonsense out loud.
        for marker in ["**", "*", "__", "_", "#"] {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "")
        }
        // A whole response wrapped in quotes is the model quoting itself.
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count > 2 {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        return cleaned.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
