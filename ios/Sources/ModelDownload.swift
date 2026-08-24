import Foundation

/// Fetches the weights on first run.
///
/// They are not bundled: the online files alone are 572 MiB and the encoder
/// another 400, which would make a download nobody expects and an app the App
/// Store would refuse over cellular. Downloading on first launch also means the
/// phone and the Mac can share the same published files.
enum ModelDownload {
    /// Hugging Face serves these directly, no token required.
    static let base = "https://huggingface.co/Audio8/Audio8-TTS-Preview-0.6B-ONNX-INT4/resolve/main"

    /// Where each published file has to end up.
    ///
    /// Not a straight copy of the remote layout: the runtime wants the model
    /// files flat but the tokenizer in its own directory, and the encoder is
    /// published under `registration/` while the runtime expects it alongside
    /// everything else. Stating both paths keeps that from being implied by
    /// two pieces of code that can disagree — which they did, and the result
    /// was an app that downloaded everything and still said the model was
    /// missing.
    struct File {
        let remote: String
        let local: String
        init(_ remote: String, as local: String? = nil) {
            self.remote = remote
            self.local = local ?? (remote as NSString).lastPathComponent
        }
    }

    /// Everything needed to speak. The codec *encoder* is fetched separately,
    /// the first time someone records a voice — it is 400 MB that a person who
    /// only ever imports a voice from their Mac never needs.
    static let speaking = [
        File("runtime_manifest.json"), File("config.json"),
        File("slow_ar_int4.onnx"), File("slow_ar_int4.onnx.data"),
        File("fast_ar_int4.onnx"), File("fast_ar_int4.onnx.data"),
        File("codec_decoder_fp16.onnx"), File("codec_decoder_fp16.onnx.data"),
        File("tokenizer/tokenizer.json", as: "tokenizer/tokenizer.json"),
    ]
    static let recording = [
        File("registration/codec_encoder_fp16.onnx"),
        File("registration/codec_encoder_fp16.onnx.data"),
        File("registration/registration_manifest.json"),
    ]

    static let approximateBytes: Int64 = 600 * 1024 * 1024

    static func isComplete(at directory: URL) -> Bool {
        speaking.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appending(path: $0.local).path)
        }
    }

    static func canRecord(at directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appending(path: "codec_encoder_fp16.onnx").path)
    }

    /// Yields progress from 0 to 1, each file landing at its declared path.
    static func run(into directory: URL, files: [File] = speaking) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for (index, file) in files.enumerated() {
                        let destination = directory.appending(path: file.local)
                        try FileManager.default.createDirectory(
                            at: destination.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        if FileManager.default.fileExists(atPath: destination.path) {
                            continuation.yield(Double(index + 1) / Double(files.count))
                            continue
                        }
                        guard let url = URL(string: "\(base)/\(file.remote)") else { continue }
                        let (temporary, response) = try await URLSession.shared.download(from: url)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                            throw MimicDownloadError.failed(file.local)
                        }
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: temporary, to: destination)
                        continuation.yield(Double(index + 1) / Double(files.count))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

enum MimicDownloadError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case let .failed(name) = self { return "Could not download \(name)" }
        return nil
    }
}
