import Foundation

/// WAV, without a dependency — the same 16-bit mono format the engine writes.
public enum Audio {
    public static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16))
        put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2))
        put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            put(Int16(clamped * (clamped < 0 ? 32_768 : 32_767)))
        }
        return data
    }

    /// Read back what `wav` wrote.
    ///
    /// Walks the chunk list rather than assuming a 44-byte header, because
    /// anything that has been through another tool may carry a `LIST` before
    /// the audio. Returns nil for anything that is not 16-bit mono PCM, which
    /// is the only thing written here.
    public static func samples(fromWav data: Data) -> (samples: [Float], sampleRate: Int)? {
        guard data.count >= 44,
              data.prefix(4) == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8) else { return nil }

        func integer<T: FixedWidthInteger>(at offset: Int, as: T.Type) -> T? {
            let end = offset + MemoryLayout<T>.size
            guard offset >= 0, end <= data.count else { return nil }
            return data[offset..<end].withUnsafeBytes {
                T(littleEndian: $0.loadUnaligned(as: T.self))
            }
        }

        var offset = 12
        var sampleRate = 0
        while offset + 8 <= data.count {
            let identifier = data[offset..<offset + 4]
            guard let size = integer(at: offset + 4, as: UInt32.self) else { return nil }
            let body = offset + 8

            if identifier == Data("fmt ".utf8) {
                guard let format = integer(at: body, as: UInt16.self), format == 1,
                      let channels = integer(at: body + 2, as: UInt16.self), channels == 1,
                      let rate = integer(at: body + 4, as: UInt32.self),
                      let bits = integer(at: body + 14, as: UInt16.self), bits == 16
                else { return nil }
                sampleRate = Int(rate)
            } else if identifier == Data("data".utf8) {
                guard sampleRate > 0 else { return nil }
                let count = min(Int(size), data.count - body) / 2
                var samples = [Float](repeating: 0, count: count)
                for index in 0..<count {
                    guard let raw = integer(at: body + index * 2, as: Int16.self) else { break }
                    samples[index] = Float(raw) / (raw < 0 ? 32_768 : 32_767)
                }
                return (samples, sampleRate)
            }
            // Chunks are padded to an even length.
            offset = body + Int(size) + (Int(size) % 2)
        }
        return nil
    }
}
