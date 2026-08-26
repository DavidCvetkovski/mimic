import AVFoundation
import Foundation

/// Turning a finished passage into a file somebody can keep or send.
///
/// Two formats, for two reasons. M4A because it is a tenth the size of the WAV
/// the engine produces and every app on the phone accepts it. And a video,
/// because the places people actually send things — a chat, a story, a camera
/// roll — take video everywhere and audio only sometimes. The picture is black
/// on purpose: the point is the voice.
public enum Export {

    public enum Failure: LocalizedError {
        case nothingToSave
        case writing(String)

        public var errorDescription: String? {
            switch self {
            case .nothingToSave:      return "There is no audio to save yet."
            case .writing(let what):  return "Could not write the file: \(what)"
            }
        }
    }

    /// A name a person would recognise in a list of files.
    public static func fileName(for text: String, voice: String,
                                extension suffix: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
            .prefix(5).joined(separator: " ")
        let safe = String(words.prefix(40)).filter { $0.isLetter || $0.isNumber || $0 == " " }
            .trimmingCharacters(in: .whitespaces)
        let stem = safe.isEmpty ? voice : "\(voice) — \(safe)"
        return "\(stem).\(suffix)"
    }

    // MARK: - Audio

    /// Write AAC in an M4A container.
    ///
    /// The engine works in 44.1 kHz float, which is about ten megabytes a
    /// minute as WAV. Nobody wants to send that, and several apps quietly
    /// refuse it.
    public static func m4a(samples: [Float], sampleRate: Int, to url: URL) throws {
        guard !samples.isEmpty else { throw Failure.nothingToSave }
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: source,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { throw Failure.writing("could not describe the audio") }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }

    // MARK: - Video

    /// A black picture for as long as the voice lasts, with the voice on it.
    ///
    /// Written in two passes rather than one. Interleaving video and audio
    /// through a single writer means converting float samples into sample
    /// buffers by hand and keeping two inputs fed in step; composing a silent
    /// black clip and then laying the audio over it is the same result out of
    /// parts that are each hard to get wrong.
    public static func video(samples: [Float], sampleRate: Int, to url: URL,
                             side: Int = 720) async throws {
        guard !samples.isEmpty else { throw Failure.nothingToSave }
        let seconds = Double(samples.count) / Double(sampleRate)

        let scratch = FileManager.default.temporaryDirectory
        let audioURL = scratch.appending(path: "mimic-\(UUID().uuidString).m4a")
        let blackURL = scratch.appending(path: "mimic-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: blackURL)
        }

        try m4a(samples: samples, sampleRate: sampleRate, to: audioURL)
        try await black(seconds: seconds, side: side, to: blackURL)

        let composition = AVMutableComposition()
        let picture = AVAsset(url: blackURL)
        let sound = AVAsset(url: audioURL)
        let span = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds,
                                                             preferredTimescale: 600))

        guard let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure.writing("could not build the composition") }

        guard let sourceVideo = try await picture.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await sound.loadTracks(withMediaType: .audio).first
        else { throw Failure.writing("the intermediate files are missing a track") }

        try videoTrack.insertTimeRange(span, of: sourceVideo, at: .zero)
        try audioTrack.insertTimeRange(span, of: sourceAudio, at: .zero)

        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality)
        else { throw Failure.writing("no exporter") }
        session.outputURL = url
        session.outputFileType = .mp4
        await session.export()
        if let error = session.error { throw Failure.writing(error.localizedDescription) }
    }

    /// A silent black clip of a given length.
    ///
    /// Six frames a second, because every one of them is the same black
    /// rectangle and nothing is moving. It keeps the file small and the write
    /// quick, and no player minds.
    private static func black(seconds: Double, side: Int, to url: URL) async throws {
        let fps = 6
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: side,
                kCVPixelBufferHeightKey as String: side,
            ])

        guard writer.canAdd(input) else { throw Failure.writing("cannot add a video track") }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            throw Failure.writing("no pixel buffer pool")
        }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { throw Failure.writing("no pixel buffer") }

        // Black, once. The same buffer is appended for every frame.
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(pixelBuffer) * side)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let total = max(Int((seconds * Double(fps)).rounded(.up)), 1)
        for frame in 0..<total {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            adaptor.append(pixelBuffer,
                           withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                        timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        // The last frame has to last until the audio stops, or the picture ends
        // early and the file is shorter than the voice on it.
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await writer.finishWriting()
        if let error = writer.error { throw Failure.writing(error.localizedDescription) }
    }
}
