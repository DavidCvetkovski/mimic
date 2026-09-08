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
        .sorted {
            let first = $0.created ?? .distantPast
            let second = $1.created ?? .distantPast
            return first == second ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                                   : first > second
        }
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
        if trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return "A name cannot contain line breaks or control characters."
        }
        return nil
    }

    private func directory(for name: String) throws -> URL {
        if let issue = Self.problem(withName: name) { throw MimicError.badVoice(issue) }
        let directory = root.appending(path: name)
        if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw MimicError.badVoice("A voice cannot be a link to another folder.")
        }
        return directory
    }

    public func rename(_ name: String, to fresh: String) throws {
        let trimmed = fresh.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = VoiceStore.problem(withName: trimmed) {
            throw MimicError.badVoice(problem)
        }
        guard trimmed != name else { return }
        let source = try directory(for: name)
        let target = root.appending(path: trimmed)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw MimicError.badVoice("There is no voice called \(name).")
        }
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw MimicError.badVoice("There is already a voice called \(trimmed).")
        }
        // meta.json carries the name too, and a profile whose folder and file
        // disagree is the sort of thing that works until something reads it.
        let data = try Data(contentsOf: source.appending(path: "meta.json"))
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MimicError.badVoice("The voice profile is damaged.")
        }
        object["name"] = trimmed
        let updated = try JSONSerialization.data(withJSONObject: object,
                                                  options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.moveItem(at: source, to: target)
        do {
            try updated.write(to: target.appending(path: "meta.json"), options: .atomic)
        } catch {
            try? FileManager.default.moveItem(at: target, to: source)
            throw error
        }
    }

    public func delete(_ name: String) throws {
        try FileManager.default.removeItem(at: directory(for: name))
    }

    public func names() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
                    && FileManager.default.fileExists(atPath: $0.appending(path: "meta.json").path)
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    public func load(_ name: String) throws -> VoiceProfile {
        let directory = try directory(for: name)
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
        guard !meta.referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
            created = stamp.flatMap { value in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
            }
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
        guard data.count >= 10, data[0] == 0x93,
              String(decoding: data[1...5], as: UTF8.self) == "NUMPY" else {
            throw MimicError.badVoice("not a .npy file: \(url.lastPathComponent)")
        }
        let major = data[6]
        let headerLength: Int
        let headerStart: Int
        if major == 1 {
            headerLength = Int(data[8]) | (Int(data[9]) << 8)
            headerStart = 10
        } else if (major == 2 || major == 3), data.count >= 12 {
            headerLength = Int(data[8]) | (Int(data[9]) << 8)
                | (Int(data[10]) << 16) | (Int(data[11]) << 24)
            headerStart = 12
        } else {
            throw MimicError.badVoice("unsupported or truncated .npy version")
        }
        guard headerLength > 0, headerLength <= data.count - headerStart else {
            throw MimicError.badVoice("truncated .npy header")
        }
        let header = String(decoding: data[headerStart..<(headerStart + headerLength)],
                            as: UTF8.self)

        guard let descr = header.capture(#"'descr':\s*'([^']+)'"#) else {
            throw MimicError.badVoice("no dtype in .npy header")
        }
        guard header.capture(#"'fortran_order':\s*(True|False)"#) == "False" else {
            throw MimicError.badVoice("Fortran-ordered .npy is not supported")
        }
        let dimensions = (header.capture(#"'shape':\s*\(([^)]*)\)"#) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let shape = dimensions.compactMap(Int.init)
        guard !shape.isEmpty, shape.count == dimensions.count, shape.allSatisfy({ $0 > 0 }) else {
            throw MimicError.badVoice("invalid .npy shape")
        }
        let body = data[(headerStart + headerLength)...]
        var count = 1
        for dimension in shape {
            let multiplied = count.multipliedReportingOverflow(by: dimension)
            guard !multiplied.overflow, multiplied.partialValue <= body.count else {
                throw MimicError.badVoice("truncated or oversized .npy array")
            }
            count = multiplied.partialValue
        }
        guard descr.first == "<" || descr.first == "=" else {
            throw MimicError.badVoice("unsupported .npy byte order: \(descr)")
        }
        let values: [Int32]
        switch descr.dropFirst() {          // drop the byte-order character
        case "u2": values = decode(body, count: count, as: UInt16.self) { Int32($0) }
        case "i2": values = decode(body, count: count, as: Int16.self)  { Int32($0) }
        case "i4": values = decode(body, count: count, as: Int32.self)  { $0 }
        case "i8":
            var overflow = false
            values = decode(body, count: count, as: Int64.self) {
                guard let value = Int32(exactly: $0) else { overflow = true; return 0 }
                return value
            }
            if overflow { throw MimicError.badVoice("a voice code is out of range") }
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
        guard count >= 0, count <= data.count / stride else { return [] }
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
