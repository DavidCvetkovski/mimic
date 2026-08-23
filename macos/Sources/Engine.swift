import Foundation

/// Talks to the Mimic engine, and owns its lifetime.
///
/// The engine is the same `core/server.py` the web app uses. Rather than
/// reimplement inference in Swift, the app starts it as a child process and
/// speaks HTTP to it — so there is one engine, one set of behaviours, and a fix
/// lands everywhere at once. When the app quits, the child goes with it.
@MainActor
final class Engine: ObservableObject {

    enum State: Equatable {
        case idle
        case starting
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
        var message: String? {
            if case let .failed(reason) = self { return reason }
            return nil
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var voices: [Voice] = []
    @Published var selected: String?

    private var process: Process?
    private let port: Int
    private var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    init(port: Int = 8455) {
        self.port = port
    }

    /// Report a problem found before the engine could even be started.
    func fail(_ reason: String) {
        state = .failed(reason)
    }

    // MARK: - Lifetime

    /// Attach to an engine that is already up, or start one.
    ///
    /// Attaching first matters during development: the web app and this one use
    /// the same port, and quietly stealing it would be worse than sharing it.
    func start(python: URL, projectRoot: URL) async {
        state = .starting
        if await health() {
            state = .ready
            await refreshVoices()
            return
        }

        let task = Process()
        task.executableURL = python
        task.arguments = ["-m", "core.server", "--port", String(port)]
        task.currentDirectoryURL = projectRoot
        // Unbuffered, or the log arrives in 4 KB lumps long after the fact.
        task.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONUNBUFFERED": "1"]) { _, new in new }

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        // The handler runs on a background queue, so the buffer it appends to
        // has to be safe to touch from there as well as from here.
        let log = LogBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            log.append(String(decoding: handle.availableData, as: UTF8.self))
        }

        do {
            try task.run()
        } catch {
            state = .failed("Could not start the engine: \(error.localizedDescription)")
            return
        }
        process = task

        // Give it up to a minute: a first run has to load about a gigabyte.
        for _ in 0..<120 {
            if await health() {
                state = .ready
                await refreshVoices()
                return
            }
            if !task.isRunning { break }
            try? await Task.sleep(for: .milliseconds(500))
        }

        // Surface what the engine actually said rather than a timeout — nine
        // times in ten it is "the model has not been downloaded yet".
        let reason = log.lastLine ?? "the engine did not come up"
        state = .failed(reason)
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func health() async -> Bool {
        guard let data = try? await get("/api/health"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["ok"] as? Bool ?? false
    }

    // MARK: - Voices

    func refreshVoices() async {
        guard let data = try? await get("/api/voices"),
              let payload = try? JSONDecoder().decode(VoiceList.self, from: data)
        else { return }
        voices = payload.voices
        if selected == nil || !voices.contains(where: { $0.name == selected }) {
            selected = voices.first?.name
        }
    }

    func register(name: String, wav: Data, transcript: String) async throws {
        let body: [String: Any] = [
            "name": name,
            "transcript": transcript,
            "wav_hex": wav.map { String(format: "%02x", $0) }.joined(),
        ]
        _ = try await post("/api/voices", body: body)
        await refreshVoices()
        selected = name
    }

    func rename(_ old: String, to new: String) async throws {
        _ = try await post("/api/voices/\(escape(old))/rename", body: ["name": new])
        await refreshVoices()
        selected = new
    }

    func delete(_ name: String) async throws {
        var request = URLRequest(url: base.appending(path: "/api/voices/\(escape(name))"))
        request.httpMethod = "DELETE"
        _ = try await send(request)
        await refreshVoices()
    }

    func sampleURL(_ name: String) -> URL {
        base.appending(path: "/api/voices/\(escape(name))/sample.wav")
    }

    // MARK: - Speaking

    /// Synthesised audio, and whether it came from the cache.
    func speak(_ text: String, voice: String) async throws -> (Data, Bool) {
        var request = URLRequest(url: base.appending(path: "/api/speak"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["text": text, "voice": voice])
        // Synthesis runs a little slower than real time, so a long passage can
        // legitimately take minutes. The default 60s timeout cuts it off.
        request.timeoutInterval = 900

        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        let cached = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "X-Mimic-Cached") == "1"
        return (data, cached)
    }

    // MARK: - HTTP

    private func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text
    }

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: base.appending(path: path))
        request.timeoutInterval = 5
        return try await send(request)
    }

    @discardableResult
    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 900      // registering a voice loads the encoder
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return data
    }

    /// Turn the engine's own error text into the thrown error, so the UI can
    /// say "no such voice" rather than "the operation could not be completed".
    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw EngineError.server(json?["error"] as? String
                                     ?? "HTTP \(http.statusCode)")
        }
    }
}

/// Somewhere for the child process's output to accumulate, readable from the
/// main actor and writable from the pipe's queue.
private final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        text += chunk
    }

    /// The last thing it said, which is usually the reason it stopped saying
    /// anything.
    var lastLine: String? {
        lock.lock()
        defer { lock.unlock() }
        return text.split(separator: "\n")
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

enum EngineError: LocalizedError {
    case server(String)
    var errorDescription: String? {
        if case let .server(message) = self { return message }
        return nil
    }
}

struct Voice: Decodable, Identifiable, Hashable {
    let name: String
    let referenceText: String?
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case referenceText = "reference_text"
    }
}

private struct VoiceList: Decodable {
    let voices: [Voice]
}
