import Foundation

/// Something to say, for people who did not come with anything prepared.
///
/// All public domain. Song lyrics and film dialogue are the obvious crowd
/// pleasers and both are still in copyright — shipping them inside an app is
/// not the same as humming them in the shower, so these are drawn from work
/// that is genuinely free to use.
public struct Preset: Identifiable, Sendable {
    public let id = UUID()
    public let label: String
    public let source: String
    public let text: String

    public init(label: String, source: String, text: String) {
        self.label = label
        self.source = source
        self.text = text
    }

    public static let all: [Preset] = [
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
