import Foundation

// The HTTP client can be exercised without booting the app or loading weights.
enum Install {
    struct Location { let python: URL; let root: URL }
    static func find() -> Location? { nil }
    static let advice = "No test engine found"
}

@main
struct EngineRegression {
    @MainActor
    static func main() async throws {
        let engine = Engine(port: Int(CommandLine.arguments[1])!)
        await engine.connect()
        check(engine.state.isReady, "connect to an existing engine without a checkout")
        check(engine.voices.count == 2, "load voices")
        check(engine.supportsStorage, "detect storage support in the connected engine")
        let name = "Me 100% #? café"
        let sample = try await engine.sample(name)
        check(String(decoding: sample, as: UTF8.self) == name, "encode voice names exactly once")
        engine.selected = "Other"
        try await engine.rename(name, to: "Renamed #2")
        check(engine.selected == "Other", "renaming another voice preserves selection")
        engine.selected = "Renamed #2"
        try await engine.rename("Renamed #2", to: name)
        check(engine.selected == name, "renaming the selected voice follows its new name")
        try await engine.delete(name)
        check(engine.selected == "Other", "deleting selected voice chooses an existing voice")
        var events: [String] = []
        try await engine.speakStream("good", voice: "Other") { events.append($0.type) }
        check(events == ["start", "chunk", "done"], "deliver streaming events in order")
        try await expectError(containing: "before the audio was complete") {
            try await engine.speakStream("truncated", voice: "Other") { _ in }
        }
        try await expectError(containing: "A useful conflict message") {
            try await engine.speakStream("http-error", voice: "Other") { _ in }
        }
        try await expectError(containing: "Model unavailable") {
            try await engine.speakStream("stream-error", voice: "Other") { event in
                check(event.type != "error", "error events do not reach the audio callback")
            }
        }
        var cancelledEvents: [String] = []
        let streaming = Task {
            try await engine.speakStream("cancel", voice: "Other") { cancelledEvents.append($0.type) }
        }
        while cancelledEvents.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        streaming.cancel()
        do { try await streaming.value; fatalError("Cancelled stream succeeded") }
        catch { check(cancelledEvents == ["start"], "cancel suppresses subsequent audio") }
        let malformed = try JSONDecoder().decode(StreamEvent.self, from: Data(#"{"type":"chunk","pcm":"AQ=="}"#.utf8))
        do { _ = try malformed.decodedSamples(); fatalError("Odd PCM accepted") }
        catch { check(true, "reject malformed PCM") }
        let pcm = try JSONDecoder().decode(StreamEvent.self, from: Data(#"{"type":"chunk","pcm":"AIAAQA=="}"#.utf8))
        let decoded = try pcm.decodedSamples()
        check(decoded == [-1, 0.5], "decode signed little-endian PCM")
        let usage = try await engine.storage()
        check(usage.total == 600, "read storage totals")
        try await engine.clearCache()
        let cleared = try await engine.storage()
        check(cleared.cache == 0, "clear cached audio")
        try await engine.unloadModel()
        print("All macOS engine regression checks passed.")
    }

    static func check(_ condition: Bool, _ label: String) {
        precondition(condition, label)
        print("✓ \(label)")
    }

    @MainActor
    static func expectError(containing message: String,
                            operation: () async throws -> Void) async throws {
        do { try await operation(); fatalError("Expected error: \(message)") }
        catch { check(error.localizedDescription.contains(message), "surface \(message)") }
    }
}
