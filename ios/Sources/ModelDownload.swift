import Foundation

/// Fetches the weights on first run.
///
/// They are not bundled: the online files alone are 572 MiB and the encoder
/// another 400, which would make a download nobody expects and an app the App
/// Store would refuse over cellular. Downloading on first launch also means the
/// phone and the Mac can share the same published files.
enum ModelDownload {
    /// Hugging Face serves these directly, no token required.
    ///
    /// Pinned to a commit, not `main`. The repository has moved once already —
    /// the Audio8/ address now redirects here — and a download that takes
    /// whatever is newest takes a rename, a gate or an incompatible export the
    /// day it lands. A commit stays what it was.
    static let base = "https://huggingface.co/Edge0/Audio8-TTS-Preview-0.6B-ONNX-INT4"
        + "/resolve/818569c6b832118ad68d61bbd873abe250fcd68a"

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
        /// Which repository it comes from. The speaking model and the writer
        /// are published separately, by different people.
        let base: String
        /// Its size at the pinned commit. Progress is counted in these, the
        /// space check adds them up, and a file that arrives any other size
        /// is not kept.
        let bytes: Int64
        init(_ remote: String, as local: String? = nil,
             from base: String = ModelDownload.base, bytes: Int64) {
            self.remote = remote
            self.local = local ?? (remote as NSString).lastPathComponent
            self.base = base
            self.bytes = bytes
        }
    }

    /// Everything needed to speak. The codec *encoder* is fetched separately,
    /// the first time someone records a voice — it is 400 MB that a person who
    /// only ever imports a voice from their Mac never needs.
    static let speaking = [
        File("runtime_manifest.json", bytes: 1_080),
        File("config.json", bytes: 3),
        File("slow_ar_int4.onnx", bytes: 900_218),
        File("slow_ar_int4.onnx.data", bytes: 290_267_090),
        File("fast_ar_int4.onnx", bytes: 156_318),
        File("fast_ar_int4.onnx.data", bytes: 35_055_104),
        File("codec_decoder_fp16.onnx", bytes: 594_319),
        File("codec_decoder_fp16.onnx.data", bytes: 260_741_440),
        File("tokenizer/tokenizer.json", as: "tokenizer/tokenizer.json", bytes: 12_217_872),
    ]
    static let recording = [
        File("registration/codec_encoder_fp16.onnx", bytes: 940_787),
        File("registration/codec_encoder_fp16.onnx.data", bytes: 414_425_088),
        File("registration/registration_manifest.json", bytes: 165),
    ]

    /// The writer is a different model from a different repository, and is only
    /// fetched when somebody asks for it — most people arrive with something to
    /// say, and half a gigabyte to write a limerick is not a fair default.
    ///
    /// Qwen2.5-0.5B-Instruct, INT4. Apache 2.0, which rules out most of the
    /// small models usually recommended for this: the popular ones are
    /// non-commercial. Pinned to a commit for the same reason as the voice.
    static let writerBase = "https://huggingface.co/onnx-community/Qwen2.5-0.5B-Instruct"
        + "/resolve/cc5cc01a65cc3ff17bdb73a7de33d879f62599b0"
    static let writing = [
        File("onnx/model_q4f16.onnx", as: "writer.onnx", from: writerBase, bytes: 483_003_582),
        File("tokenizer.json", as: "writer_tokenizer.json", from: writerBase, bytes: 7_031_673),
        File("config.json", as: "writer_config.json", from: writerBase, bytes: 678),
    ]
    static let writerBytes = bytes(of: writing)

    static let approximateBytes = bytes(of: speaking)

    static func bytes(of files: [File]) -> Int64 {
        files.reduce(0) { $0 + $1.bytes }
    }

    static func isComplete(at directory: URL) -> Bool {
        speaking.allSatisfy { isPresent(directory.appending(path: $0.local)) }
    }

    static func canWrite(at directory: URL) -> Bool {
        writing.allSatisfy { isPresent(directory.appending(path: $0.local)) }
    }

    static func canRecord(at directory: URL) -> Bool {
        recording.allSatisfy { isPresent(directory.appending(path: $0.local)) }
    }

    private static func isPresent(_ file: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }

    // MARK: - Room for it

    /// What is left over once the files are in: voices, cached audio, and
    /// whatever the phone itself needs next.
    static let headroom: Int64 = 200_000_000

    /// Throws, with the numbers, when the files still missing will not fit.
    ///
    /// Better said before anything starts than found out at 90%. When the
    /// phone will not say how much room it has, the download goes ahead as it
    /// always did.
    static func checkSpace(for files: [File], in directory: URL) throws {
        let missing = files.filter { !isPresent(directory.appending(path: $0.local)) }
        guard !missing.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = URLResourceKey.volumeAvailableCapacityForImportantUsageKey
        guard let free = try? directory.resourceValues(forKeys: [key])
                .volumeAvailableCapacityForImportantUsage,
              free > 0 else { return }
        let needed = bytes(of: missing) + headroom
        guard free >= needed else {
            throw MimicDownloadError.noSpace(needed: needed, free: free)
        }
    }

    // MARK: - Out of backups

    /// Keeps a folder, and everything in it, out of iCloud and computer backups.
    ///
    /// All of it can be downloaded again, and a gigabyte of model weights has
    /// no business in somebody's iCloud storage. Apple's storage guidelines
    /// ask for exactly this. Voices are left alone: they are the person's own.
    static func keepOutOfBackups(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Fetching

    /// Yields progress from 0 to 1, by bytes, each file landing at its
    /// declared path.
    static func run(into directory: URL, files: [File] = speaking) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try FileManager.default.createDirectory(at: directory,
                                                            withIntermediateDirectories: true)
                    keepOutOfBackups(directory)
                    let total = Double(max(bytes(of: files), 1))
                    var done: Int64 = 0
                    for file in files {
                        try Task.checkCancellation()
                        let destination = directory.appending(path: file.local)
                        try FileManager.default.createDirectory(
                            at: destination.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        if isPresent(destination) {
                            done += file.bytes
                            continuation.yield(Double(done) / total)
                            continue
                        }
                        guard let url = URL(string: "\(file.base)/\(file.remote)") else {
                            throw MimicDownloadError.failed(file.local)
                        }

                        // The file arrives all at once at the end, so its
                        // progress is read off the task while it runs. Without
                        // this the bar sat still through the two big files.
                        let watcher = Watcher()
                        let start = done
                        let ticker = Task {
                            var best: Int64 = 0
                            while !Task.isCancelled {
                                try? await Task.sleep(for: .milliseconds(250))
                                best = max(best, min(watcher.received, file.bytes))
                                continuation.yield(Double(start + best) / total)
                            }
                        }
                        defer { ticker.cancel() }

                        let (temporary, response) = try await fetch(url, watcher: watcher)
                        ticker.cancel()
                        _ = await ticker.value
                        try Task.checkCancellation()
                        let status = (response as? HTTPURLResponse)?.statusCode
                        guard status == 200 || status == 206,
                              size(of: temporary) == file.bytes else {
                            try? FileManager.default.removeItem(at: temporary)
                            throw MimicDownloadError.failed(file.local)
                        }
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: temporary, to: destination)
                        done += file.bytes
                        continuation.yield(Double(done) / total)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The connection went, as opposed to the file not being there.
    private static let dropped: Set<URLError.Code> = [
        .networkConnectionLost, .notConnectedToInternet, .timedOut,
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
    ]

    /// One file, with two more tries if the connection drops.
    ///
    /// Changing network, or a moment outside the app, drops the connection,
    /// and a 290 MB file starting again from nothing is often the difference
    /// between a download that finishes and one that does not. When URLSession
    /// hands back what it already had, the next try carries on from there.
    private static func fetch(_ url: URL, watcher: Watcher) async throws -> (URL, URLResponse) {
        var partial: Data?
        var attempt = 1
        while true {
            do {
                if let partial {
                    return try await URLSession.shared.download(resumeFrom: partial,
                                                                delegate: watcher)
                }
                return try await URLSession.shared.download(from: url, delegate: watcher)
            } catch let error as URLError where attempt < 3 && dropped.contains(error.code) {
                partial = error.downloadTaskResumeData
                try await Task.sleep(for: .seconds(2 * attempt))
                attempt += 1
            }
        }
    }

    private static func size(of file: URL) -> Int64 {
        Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
    }
}

/// Keeps hold of the task an async download creates, so its byte count can be
/// read while it runs.
private final class Watcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?

    var received: Int64 {
        lock.lock(); defer { lock.unlock() }
        return task?.countOfBytesReceived ?? 0
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
    }
}

enum MimicDownloadError: LocalizedError {
    case failed(String)
    case noSpace(needed: Int64, free: Int64)
    var errorDescription: String? {
        switch self {
        case let .failed(name):
            return "Could not download \(name)"
        case let .noSpace(needed, free):
            let size: (Int64) -> String = {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            }
            return "Not enough space. The download needs \(size(needed)) free, "
                + "and this phone has \(size(free)). Free up \(size(needed - free)) and try again."
        }
    }
}
