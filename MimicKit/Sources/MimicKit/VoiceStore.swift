import Foundation

/// A registered voice: the codec codes for the reference recording, and the
/// transcript of what was said in it.
public struct VoiceProfile: Sendable {
    public let name: String
    public let referenceText: String
    /// [numCodebooks][frames]
    public let codes: [[Int32]]

    public var frames: Int { codes.first?.count ?? 0 }
}

/// Reads the voice profiles written by the Python side.
///
/// Deliberately the same on-disk layout, so a voice registered on a Mac can be
/// copied to a phone and used there unchanged — the profile is the expensive
/// part to produce and there is no reason to make it twice.
public struct VoiceStore: Sendable {
    let root: URL
    let numCodebooks: Int

    public init(root: URL, numCodebooks: Int) {
        self.root = root
        self.numCodebooks = numCodebooks
    }

    /// For listing, renaming and deleting, none of which read a profile.
    ///
    /// The codebook count describes the model and is only checked when codes
    /// are actually loaded — so a library can be managed without one, which
    /// matters because the app can show the list before the engine is up.
    public init(root: URL) {
        self.init(root: root, numCodebooks: 0)
    }

    /// What a person needs to see about a voice without loading it.
    ///
    /// Loading a profile reads a megabyte of codes and is only worth doing to
    /// speak with it. A list wants the name, when it was made, and whether
    /// there is a recording to play back.
    public struct Summary: Identifiable, Sendable, Hashable {
        public let name: String
        public let created: Date?
        public let referenceText: String
        /// The original recording, when one was kept.
        public let recording: URL?
        public let bytes: Int

        public var id: String { name }
    }

    public func summaries() -> [Summary] {
        names().map { name in
            let directory = root.appending(path: name)
            let meta = (try? JSONDecoder().decode(
                Meta.self, from: Data(contentsOf: directory.appending(path: "meta.json"))))
            let wav = directory.appending(path: "reference.wav")
            let kept = FileManager.default.fileExists(atPath: wav.path)
            return Summary(name: name,
                           created: meta?.created,
                           referenceText: meta?.referenceText ?? "",
                           recording: kept ? wav : nil,
                           bytes: VoiceStore.size(of: directory))
        }
        .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    static func size(of directory: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Whether a name can be a voice.
    ///
    /// It becomes a directory, so the rules are the file system's rather than
    /// anybody's taste — but they have to be explained to a person, which is
    /// why the reason comes back rather than just a no.
    public static func problem(withName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "A voice needs a name." }
        if trimmed.count > 60 { return "That name is too long." }
        if trimmed.hasPrefix(".") { return "A name cannot start with a full stop." }
        if trimmed.contains("/") || trimmed.contains(":") {
            return "A name cannot contain a slash or a colon."
        }
        return nil
    }

    public func rename(_ name: String, to fresh: String) throws {
        let trimmed = fresh.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = VoiceStore.problem(withName: trimmed) {
            throw MimicError.badVoice(problem)
        }
        guard trimmed != name else { return }
        let source = root.appending(path: name)
        let target = root.appending(path: trimmed)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw MimicError.badVoice("There is no voice called \(name).")
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw MimicError.badVoice("There is already a voice called \(trimmed).")
        }
        try FileManager.default.moveItem(at: source, to: target)

        // meta.json carries the name too, and a profile whose folder and file
        // disagree is the sort of thing that works until something reads it.
        let metaURL = target.appending(path: "meta.json")
        if let data = try? Data(contentsOf: metaURL),
           var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            object["name"] = trimmed
            try? JSONSerialization
                .data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: metaURL)
        }
    }

    public func delete(_ name: String) throws {
        try FileManager.default.removeItem(at: root.appending(path: name))
    }

    public func names() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { FileManager.default.fileExists(
                atPath: $0.appending(path: "meta.json").path) }
            .map(\.lastPathComponent)
            .sorted()
    }

    public func load(_ name: String) throws -> VoiceProfile {
        let directory = root.appending(path: name)
        let meta = try JSONDecoder().decode(
            Meta.self, from: Data(contentsOf: directory.appending(path: "meta.json")))
        let codes = try NumpyArray.readInt(
            from: directory.appending(path: "codes.npy"))

        guard codes.shape.count == 2, codes.shape[0] == numCodebooks, codes.shape[1] > 0 else {
            throw MimicError.badVoice(
                "codes for \(name) are \(codes.shape), expected [\(numCodebooks), frames]")
        }
        let frames = codes.shape[1]
        let rows = (0..<numCodebooks).map { row in
            Array(codes.values[(row * frames)..<((row + 1) * frames)])
        }
        guard !meta.referenceText.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MimicError.badVoice("\(name) has no reference text")
        }
        return VoiceProfile(name: name, referenceText: meta.referenceText, codes: rows)
    }

    struct Meta: Decodable {
        let referenceText: String
        let created: Date?

        enum CodingKeys: String, CodingKey {
            case referenceText = "reference_text"
            case created = "created_at"
        }

        init(from decoder: any Swift.Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            referenceText = (try? values.decode(String.self, forKey: .referenceText)) ?? ""
            let stamp = try? values.decode(String.self, forKey: .created)
            created = stamp.flatMap { ISO8601DateFormatter().date(from: $0) }
        }
    }
}

/// Just enough .npy to read one array of integers.
///
/// The profiles are written by NumPy, and reproducing that side to avoid this
/// would mean a bespoke format that only Mimic can read. Forty lines here buys
/// interoperability with everything else that speaks .npy.
enum NumpyArray {
    struct Integers {
        let shape: [Int]
        let values: [Int32]
    }

    static func readInt(from url: URL) throws -> Integers {
        let data = try Data(contentsOf: url)
        guard data.count > 10, data[0] == 0x93,
              String(decoding: data[1...5], as: UTF8.self) == "NUMPY" else {
            throw MimicError.badVoice("not a .npy file: \(url.lastPathComponent)")
        }
        let major = data[6]
        let headerLength: Int
        let headerStart: Int
        if major == 1 {
            headerLength = Int(data[8]) | (Int(data[9]) << 8)
            headerStart = 10
        } else {
            headerLength = Int(data[8]) | (Int(data[9]) << 8)
                | (Int(data[10]) << 16) | (Int(data[11]) << 24)
            headerStart = 12
        }
        let header = String(decoding: data[headerStart..<(headerStart + headerLength)],
                            as: UTF8.self)

        guard let descr = header.capture(#"'descr':\s*'([^']+)'"#) else {
            throw MimicError.badVoice("no dtype in .npy header")
        }
        guard header.capture(#"'fortran_order':\s*(True|False)"#) == "False" else {
            throw MimicError.badVoice("Fortran-ordered .npy is not supported")
        }
        let shape = (header.capture(#"'shape':\s*\(([^)]*)\)"#) ?? "")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        let body = data[(headerStart + headerLength)...]
        let count = shape.reduce(1, *)
        let values: [Int32]
        switch descr.dropFirst() {          // drop the byte-order character
        case "u2": values = decode(body, count: count, as: UInt16.self) { Int32($0) }
        case "i2": values = decode(body, count: count, as: Int16.self)  { Int32($0) }
        case "i4": values = decode(body, count: count, as: Int32.self)  { $0 }
        case "i8": values = decode(body, count: count, as: Int64.self)  { Int32(truncatingIfNeeded: $0) }
        default:
            throw MimicError.badVoice("unsupported .npy dtype: \(descr)")
        }
        guard values.count == count else {
            throw MimicError.badVoice("truncated .npy: \(values.count) of \(count)")
        }
        return Integers(shape: shape, values: values)
    }

    private static func decode<T>(_ data: Data, count: Int, as: T.Type,
                                  _ convert: (T) -> Int32) -> [Int32] {
        let stride = MemoryLayout<T>.size
        guard data.count >= count * stride else { return [] }
        return data.withUnsafeBytes { raw in
            (0..<count).map { convert(raw.loadUnaligned(fromByteOffset: $0 * stride, as: T.self)) }
        }
    }
}

private extension String {
    func capture(_ pattern: String) -> String? {
        guard let match = try? NSRegularExpression(pattern: pattern)
            .firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}

public enum MimicError: LocalizedError {
    case modelMissing(String)
    case badVoice(String)
    case inference(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let what): return "Model not available: \(what)"
        case .badVoice(let why):      return "That voice could not be read: \(why)"
        case .inference(let why):     return why
        }
    }
}
