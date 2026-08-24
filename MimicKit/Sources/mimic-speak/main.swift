import Foundation
import MimicKit

// A command line around MimicKit, so the Swift engine can be exercised on a Mac
// — where it can be timed, compared against the Python one, and listened to —
// rather than only on a phone.
//
//   mimic-speak "some words" --voice David --out out.wav
//   mimic-speak --register Me --from recording.wav --says "what I read"

let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String, _ fallback: String) -> String {
    guard let index = arguments.firstIndex(of: "--\(name)"),
          index + 1 < arguments.count else { return fallback }
    return arguments[index + 1]
}

func fail(_ message: String) -> Never {
    print("  \(message)")
    exit(1)
}

let home = URL(filePath: NSHomeDirectory()).appending(path: ".mimic")
let modelDirectory = home.appending(path: "model")
let voicesDirectory = home.appending(path: "voices")

/// A 16-bit mono WAV, which is all this needs to read.
func readWav(_ url: URL) -> (samples: [Float], sampleRate: Int)? {
    guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
    let rate = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) }
    let samples = data.dropFirst(44).withUnsafeBytes { raw -> [Float] in
        (0..<(raw.count / 2)).map {
            Float(raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) / 32_768
        }
    }
    return (samples, Int(rate))
}

// ---- registering a voice ---------------------------------------------------

if let index = arguments.firstIndex(of: "--register") {
    guard index + 1 < arguments.count else { fail("--register needs a name") }
    let name = arguments[index + 1]
    let source = URL(filePath: option("from", ""))
    guard let recording = readWav(source) else { fail("could not read \(source.path)") }

    do {
        let registrar = try Registrar(modelDirectory: modelDirectory,
                                      voicesDirectory: voicesDirectory)
        let began = Date()
        let profile = try registrar.register(name: name,
                                             samples: recording.samples,
                                             sampleRate: recording.sampleRate,
                                             transcript: option("says", ""))
        let elapsed = Date().timeIntervalSince(began)
        print(String(format: "  registered %@ — %d frames in %.1fs",
                     name, profile.frames, elapsed))
    } catch {
        fail("failed: \(error.localizedDescription)")
    }
    exit(0)
}

// ---- speaking --------------------------------------------------------------

guard let text = arguments.first, !text.hasPrefix("--") else {
    print("""
    usage:
      mimic-speak "text" [--voice NAME] [--out FILE] [--seed N]
      mimic-speak --register NAME --from recording.wav --says "the transcript"
    """)
    exit(2)
}

do {
    var began = Date()
    let runtime = try Runtime(modelDirectory: modelDirectory,
                              voicesDirectory: voicesDirectory, threads: 5)
    print(String(format: "  load      %5.1fs", Date().timeIntervalSince(began)))

    var options = Runtime.Options()
    options.seed = UInt64(option("seed", "42")) ?? 42

    began = Date()
    var lastReport = Date()
    let samples = try runtime.synthesize(text: text,
                                         voice: option("voice", "David"),
                                         options: options) { frames in
        if Date().timeIntervalSince(lastReport) > 1 {
            lastReport = Date()
            print(String(format: "            %5.1fs of audio so far",
                         Double(frames) * 2048 / 44_100))
        }
        return true
    }

    let elapsed = Date().timeIntervalSince(began)
    let duration = Double(samples.count) / Double(runtime.manifest.sampleRate)
    print(String(format: "  generate  %5.1fs -> %.1fs of audio   RTF %.2fx",
                 elapsed, duration, elapsed / max(duration, 0.01)))

    let output = option("out", "mimic-swift.wav")
    try Audio.wav(samples, sampleRate: runtime.manifest.sampleRate)
        .write(to: URL(filePath: output))
    print("  wrote     \(output)")
} catch {
    fail("failed: \(error.localizedDescription)")
}
