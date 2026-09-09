import Foundation

public enum VoiceTransfer {
    public static func exportVoice(name: String, from root: URL) throws -> Data {
        if let problem = VoiceStore.problem(withName: name) { throw MimicError.badVoice(problem) }
        let folder = root.appending(path: name)
        guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw MimicError.badVoice("A voice cannot be a link to another folder.")
        }
        var files: [String: Data] = [:]
        for file in ["meta.json", "codes.npy", "reference.wav"] {
            let url = folder.appending(path: file)
            if file == "reference.wav", !FileManager.default.fileExists(atPath: url.path) { continue }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 16 * 1024 * 1024 else {
                throw MimicError.badVoice("The voice contains a linked or oversized file.")
            }
            files[file] = try Data(contentsOf: url)
        }
        let archive = CloudVoiceArchive(name: name, files: files)
        let data = try archive.encoded(); _ = try CloudVoiceArchive.decode(data)
        return data
    }

    @discardableResult
    public static func importVoice(data: Data, into root: URL, name: String? = nil) throws -> String {
        var archive = try CloudVoiceArchive.decode(data)
        if let name { archive.name = name }
        if let problem = VoiceStore.problem(withName: archive.name) { throw MimicError.badVoice(problem) }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = try manager.contentsOfDirectory(atPath: root.path)
        guard !entries.contains(where: { $0.caseInsensitiveCompare(archive.name) == .orderedSame }) else {
            throw MimicError.badVoice("A voice called \(archive.name) already exists. Choose another name.")
        }
        let staging = root.appending(path: ".import-\(UUID())")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        for (file, data) in archive.files { try data.write(to: staging.appending(path: file), options: .atomic) }
        let codes = try NumpyArray.readInt(from: staging.appending(path: "codes.npy"))
        guard codes.shape.count == 2, (1...64).contains(codes.shape[0]),
              (1...32768).contains(codes.shape[1]), codes.values.allSatisfy({ (0...65535).contains($0) }) else {
            throw MimicError.badVoice("The voice codes are incompatible with Mimic.")
        }
        if let wav = archive.files["reference.wav"], Audio.samples(fromWav: wav) == nil {
            throw MimicError.badVoice("The reference recording is not a supported WAV file.")
        }
        var meta = try JSONSerialization.jsonObject(with: archive.files["meta.json"]!) as! [String: Any]
        meta["name"] = archive.name
        try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
            .write(to: staging.appending(path: "meta.json"), options: .atomic)
        try manager.moveItem(at: staging, to: root.appending(path: archive.name))
        return archive.name
    }
}
