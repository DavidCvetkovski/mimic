import Foundation
import MimicORT

/// Turns a recording into a reusable voice profile.
///
/// This is the other half of cloning, and it runs the codec *encoder* — a
/// second model, and the heaviest thing here: about 400 MB of weights, needed
/// once per voice and never again. It is therefore loaded for the call and
/// dropped immediately, rather than held for the life of the app the way the
/// synthesis sessions are.
public struct Registrar {
    let modelDirectory: URL
    let voicesDirectory: URL
    let manifest: Manifest

    public init(modelDirectory: URL, voicesDirectory: URL) throws {
        self.modelDirectory = modelDirectory
        self.voicesDirectory = voicesDirectory
        manifest = try Manifest.load(from: modelDirectory)
    }

    public var encoderPath: URL { modelDirectory.appending(path: "codec_encoder_fp16.onnx") }
    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: encoderPath.path)
    }

    /// `samples` is mono float in [-1, 1] at any sample rate.
    @discardableResult
    public func register(name: String, samples: [Float], sampleRate: Int,
                         transcript: String) throws -> VoiceProfile {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 64,
              !clean.contains("/"), clean != ".", clean != ".." else {
            throw MimicError.badVoice("a voice name must be one path component")
        }
        let text = transcript.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else {
            throw MimicError.badVoice("the transcript must not be empty")
        }
        guard isAvailable else {
            throw MimicError.modelMissing("codec_encoder_fp16.onnx")
        }

        var audio = samples
        if sampleRate != manifest.sampleRate {
            audio = Resample.linear(audio, from: sampleRate, to: manifest.sampleRate)
        }
        let seconds = Double(audio.count) / Double(manifest.sampleRate)
        guard seconds >= 0.5, seconds <= 30 else {
            throw MimicError.badVoice(
                String(format: "a reference must be between 0.5 and 30 seconds; this is %.1f",
                       seconds))
        }
        guard audio.allSatisfy({ $0.isFinite }) else {
            throw MimicError.badVoice("the recording contains invalid samples")
        }
        // The encoder consumes whole 2048-sample frames.
        let remainder = audio.count % 2048
        if remainder != 0 { audio.append(contentsOf: [Float](repeating: 0, count: 2048 - remainder)) }

        // Scoped so the session — and its 400 MB — is released before the
        // profile is written.
        let codes: [[Int32]] = try {
            let env = try ORT.Env()
            let session = try ORT.Session(env: env, path: encoderPath.path, threads: 4)
            let input = try ORT.Value.float16(audio.map(Float16.init),
                                              shape: [1, 1, audio.count])
            guard let output = try session.run(["audio": input]).first else {
                throw MimicError.inference("the encoder returned nothing")
            }
            let flat = output.int64s()
            let shape = output.shape
            // [1, codebooks, frames] or [codebooks, frames]
            let books = shape.count == 3 ? shape[1] : shape[0]
            let frames = shape.last ?? 0
            guard books == manifest.numCodebooks, frames > 0 else {
                throw MimicError.inference("the encoder returned codes shaped \(shape)")
            }
            return (0..<books).map { book in
                (0..<frames).map { Int32(flat[book * frames + $0]) }
            }
        }()

        try write(name: clean, transcript: text, codes: codes,
                  recording: audio, rate: manifest.sampleRate)
        return VoiceProfile(name: clean, referenceText: text, codes: codes)
    }

    /// Written to a temporary directory and moved into place, so a profile is
    /// never half-written if the app is killed partway.
    private func write(name: String, transcript: String, codes: [[Int32]],
                       recording: [Float], rate: Int) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: voicesDirectory, withIntermediateDirectories: true)
        let staging = voicesDirectory.appending(path: ".\(name).staging")
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)

        try NumpyWriter.write(codes, to: staging.appending(path: "codes.npy"))
        let meta: [String: Any] = [
            "name": name,
            "reference_text": transcript,
            "shape": [codes.count, codes.first?.count ?? 0],
            "dtype": "uint16",
            "sample_rate": manifest.sampleRate,
            "model_fingerprint": manifest.modelFingerprint ?? "",
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "source_kind": "on_device",
        ]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appending(path: "meta.json"))

        // Keep the recording. The Python side does, the layouts have to match,
        // and without it a voice cannot be played back to whoever made it —
        // which is the only way to tell two of your own voices apart in a list.
        try? Audio.wav(recording, sampleRate: rate)
            .write(to: staging.appending(path: "reference.wav"))

        let target = voicesDirectory.appending(path: name)
        try? manager.removeItem(at: target)
        try manager.moveItem(at: staging, to: target)
    }
}

/// Writes the same uint16 .npy the Python side does, so a voice registered on
/// a phone is readable on a Mac and the other way round.
enum NumpyWriter {
    static func write(_ rows: [[Int32]], to url: URL) throws {
        let books = rows.count
        let frames = rows.first?.count ?? 0
        var header = "{'descr': '<u2', 'fortran_order': False, 'shape': (\(books), \(frames)), }"
        // The header, magic included, is padded to a multiple of 64 bytes.
        let prelude = 10
        while (prelude + header.count + 1) % 64 != 0 { header += " " }
        header += "\n"

        var data = Data([0x93])
        data.append(contentsOf: Array("NUMPY".utf8))
        data.append(contentsOf: [1, 0])                        // version 1.0
        withUnsafeBytes(of: UInt16(header.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array(header.utf8))
        for row in rows {
            for value in row {
                withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian) {
                    data.append(contentsOf: $0)
                }
            }
        }
        try data.write(to: url)
    }
}

/// Linear resampling, which is enough here.
///
/// The reference implementation uses a polyphase filter; the difference on a
/// voice reference is inaudible and well below what the encoder is sensitive
/// to, and bringing in a DSP dependency to match it exactly would cost more
/// than it is worth.
enum Resample {
    static func linear(_ samples: [Float], from source: Int, to target: Int) -> [Float] {
        guard source != target, source > 0, !samples.isEmpty else { return samples }
        let ratio = Double(target) / Double(source)
        let count = Int((Double(samples.count) * ratio).rounded())
        return (0..<count).map { index in
            let position = Double(index) / ratio
            let left = Int(position)
            let right = min(left + 1, samples.count - 1)
            let fraction = Float(position - Double(left))
            return samples[left] * (1 - fraction) + samples[right] * fraction
        }
    }
}
