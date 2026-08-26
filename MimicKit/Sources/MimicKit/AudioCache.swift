import CryptoKit
import Foundation

/// Finished passages, kept on disk so that saying the same thing twice is free.
///
/// Synthesis is deterministic for a given seed, which is the whole reason this
/// is honest rather than a guess: the same voice, seed and words produce the
/// same samples, so a hit is not an approximation of the answer, it is the
/// answer. On a phone that matters more than on the Mac — generation runs
/// slower than real time, so re-rendering a passage someone just listened to
/// costs them the entire wait again for nothing.
///
/// Mirrors the Python engine's cache deliberately, down to the key and the
/// limit, so the two behave the same way and a bug in one is a bug you can find
/// in the other.
public final class AudioCache: @unchecked Sendable {

    private let directory: URL
    private let limit: Int
    private let lock = NSLock()

    /// - Parameter limitMB: how much disk to spend before the least recently
    ///   used entries are dropped. 200 MB is a little over fifteen minutes of
    ///   speech, which is far more than anyone replays.
    public init(directory: URL, limitMB: Int = 200) {
        self.directory = directory
        self.limit = limitMB * 1_024 * 1_024
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `voice-digest.wav` — the voice up front so that forgetting one voice is
    /// a prefix match rather than a read of every file.
    private func path(text: String, voice: String, seed: UInt64) -> URL {
        let digest = SHA256.hash(data: Data("\(voice)|\(seed)|\(text)".utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24)
        return directory.appending(path: "\(safe(voice))-\(digest).wav")
    }

    /// Voice names are typed by people and end up in a file name.
    private func safe(_ voice: String) -> String {
        let cleaned = voice.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(cleaned)
    }

    /// Whether `read` would hit, without paying to decode it. The caller needs
    /// this before it starts telling anyone how long they are about to wait.
    public func has(text: String, voice: String, seed: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return FileManager.default.fileExists(
            atPath: path(text: text, voice: voice, seed: seed).path)
    }

    public func read(text: String, voice: String, seed: UInt64) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        let url = path(text: text, voice: voice, seed: seed)
        guard let data = try? Data(contentsOf: url),
              let (samples, _) = Audio.samples(fromWav: data) else { return nil }
        // Touch it, so that pruning drops what nobody plays rather than what
        // happened to be written first.
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: url.path)
        return samples
    }

    public func write(_ samples: [Float], text: String, voice: String,
                      seed: UInt64, sampleRate: Int) {
        guard !samples.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let url = path(text: text, voice: voice, seed: seed)
        try? Audio.wav(samples, sampleRate: sampleRate).write(to: url, options: .atomic)
        prune()
    }

    /// Called when a voice is deleted or renamed. Its audio is now unreachable
    /// — and worse, a new voice reusing the name would answer with the old
    /// one's recordings.
    public func forget(voice: String) {
        lock.lock(); defer { lock.unlock() }
        let prefix = "\(safe(voice))-"
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func empty() {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Oldest first, until it fits. Caller holds the lock.
    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return }

        var entries: [(url: URL, date: Date, size: Int)] = []
        var total = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize else { continue }
            entries.append((file, values.contentModificationDate ?? .distantPast, size))
            total += size
        }
        guard total > limit else { return }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard total > limit else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
