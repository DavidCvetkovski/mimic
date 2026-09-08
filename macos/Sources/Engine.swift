import Combine
import Foundation

/// Owns an engine it starts, or shares the one already serving the web app.
@MainActor
final class Engine: ObservableObject {
    enum State: Equatable {
        case idle, starting, ready, failed(String)
        var isReady: Bool { self == .ready }
        var message: String? {
            if case let .failed(reason) = self { return reason }
            return nil
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var voices: [Voice] = []
    @Published var selected: String? {
        didSet { UserDefaults.standard.set(selected, forKey: "MimicSelectedVoice") }
    }
    @Published var activity: String?
    @Published private(set) var libraryError: String?
    @Published private(set) var supportsStorage = false
    private var process: Process?
    private let port: Int
    private var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var webURL: URL { base }

    init(port: Int = 8455) {
        self.port = port
        selected = UserDefaults.standard.string(forKey: "MimicSelectedVoice")
    }

    func connect() async {
        guard state != .starting else { return }
        state = .starting
        // An existing engine does not require the app to locate its checkout.
        if await health() {
            state = .ready
            await refreshVoices()
            return
        }
        guard let install = Install.find() else {
            state = .failed(Install.advice)
            return
        }
        await start(python: install.python, projectRoot: install.root)
    }

    func start(python: URL, projectRoot: URL) async {
        state = .starting
        if await health() {
            state = .ready
            await refreshVoices()
            return
        }
        if let process, process.isRunning { process.terminate() }
        let child = Process()
        child.executableURL = python
        child.arguments = ["-m", "core.server", "--port", String(port)]
        child.currentDirectoryURL = projectRoot
        child.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONUNBUFFERED": "1"]) { _, new in new }
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        let log = LogBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { log.append(String(decoding: data, as: UTF8.self)) }
        }
        child.terminationHandler = { [weak self] ended in
            Task { @MainActor [weak self] in
                guard let self, self.process === ended else { return }
                self.process = nil
                self.state = .failed(log.lastLine ?? "The engine stopped. Try reconnecting.")
            }
        }
        do { try child.run() }
        catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            state = .failed("Could not start the engine: \(error.localizedDescription)")
            return
        }
        process = child
        for _ in 0..<120 {
            if Task.isCancelled { stop(); return }
            if await health() {
                state = .ready
                await refreshVoices()
                return
            }
            if !child.isRunning { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        state = .failed(log.lastLine ?? "The engine did not start. Try reconnecting.")
    }

    func stop() {
        let child = process
        process = nil
        if child?.isRunning == true { child?.terminate() }
        state = .idle
    }

    private func health() async -> Bool {
        guard let data = try? await get("/api/health"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        supportsStorage = (json["capabilities"] as? [String])?.contains("storage") == true
        return json["ok"] as? Bool ?? false
    }

    func refreshVoices() async {
        do {
            let data = try await get("/api/voices")
            voices = try JSONDecoder().decode(VoiceList.self, from: data).voices
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if !voices.contains(where: { $0.name == selected }) { selected = voices.first?.name }
            libraryError = nil
        } catch {
            libraryError = "Could not refresh voices: \(error.localizedDescription)"
        }
    }

    func register(name: String, wav: Data, transcript: String) async throws {
        _ = try await post("/api/voices", body: [
            "name": name, "transcript": transcript,
            "wav_hex": wav.map { String(format: "%02x", $0) }.joined(),
        ])
        await refreshVoices()
        selected = name
    }

    func rename(_ old: String, to new: String) async throws {
        let wasSelected = selected == old
        var request = URLRequest(url: endpoint(["api", "voices", old, "rename"]))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": new])
        _ = try await send(request)
        if wasSelected { selected = new }
        await refreshVoices()
    }

    func delete(_ name: String) async throws {
        var request = URLRequest(url: endpoint(["api", "voices", name]))
        request.httpMethod = "DELETE"
        _ = try await send(request)
        await refreshVoices()
    }

    func sample(_ name: String) async throws -> Data {
        try await send(URLRequest(url: endpoint(["api", "voices", name, "sample.wav"])))
    }

    func storage() async throws -> StorageUsage {
        try JSONDecoder().decode(StorageUsage.self, from: await get("/api/storage"))
    }

    func clearCache() async throws {
        var request = URLRequest(url: endpoint(["api", "cache"]))
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    func unloadModel() async throws { _ = try await post("/api/model/unload", body: [:]) }

    /// Require a terminal event: a dropped connection must never become a
    /// successful, exportable passage. Cancellation is checked before callbacks.
    func speakStream(_ text: String, voice: String,
                     onEvent: @MainActor (StreamEvent) throws -> Void) async throws {
        var request = URLRequest(url: endpoint(["api", "speak", "stream"]))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "voice": voice])
        request.timeoutInterval = 900
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 16_384 { break }
            }
            try check(response, data)
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard !line.isEmpty else { continue }
            let event = try JSONDecoder().decode(StreamEvent.self, from: Data(line.utf8))
            if event.type == "error" { throw EngineError.server(event.message ?? "The engine failed.") }
            try onEvent(event)
            if event.type == "done" { return }
        }
        try Task.checkCancellation()
        throw EngineError.server("The connection ended before the audio was complete. Try speaking again.")
    }

    // Encode each path component exactly once, including %, #, ?, and Unicode.
    // URL.appending(path:) on an already escaped name turned spaces into %2520.
    private func endpoint(_ components: [String]) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var url = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        url.percentEncodedPath = "/" + components.map {
            $0.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "/")
        return url.url!
    }

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: endpoint(path.split(separator: "/").map(String.init)))
        request.timeoutInterval = 5
        return try await send(request)
    }

    @discardableResult
    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: endpoint(path.split(separator: "/").map(String.init)))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 900
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)
        return data
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.server("The engine sent an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw EngineError.server(json?["error"] as? String ?? "HTTP \(http.statusCode)")
        }
    }
}

private final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        text = String((text + chunk).suffix(32_768))
    }
    var lastLine: String? {
        lock.lock(); defer { lock.unlock() }
        return text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
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

struct StreamEvent: Decodable {
    let type: String
    let estimate: Double?
    let sentences: Int?
    let sampleRate: Int?
    let index: Int?
    let of: Int?
    let seconds: Double?
    let rtf: Double?
    let pcm: String?
    let cached: Bool?
    let elapsed: Double?
    let wav: String?
    let message: String?
    enum CodingKeys: String, CodingKey {
        case type, estimate, sentences, index, of, seconds, rtf, pcm, cached, elapsed, wav, message
        case sampleRate = "sample_rate"
    }
    func decodedSamples() throws -> [Float] {
        guard let pcm, let data = Data(base64Encoded: pcm), !data.isEmpty, data.count.isMultiple(of: 2) else {
            throw EngineError.server("The engine sent an unreadable audio chunk. Try speaking again.")
        }
        return data.withUnsafeBytes { raw in
            (0..<(raw.count / 2)).map {
                Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32_768
            }
        }
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

struct StorageUsage: Decodable {
    let model: Int64
    let voices: Int64
    let cache: Int64
    let total: Int64
}

private struct VoiceList: Decodable { let voices: [Voice] }
