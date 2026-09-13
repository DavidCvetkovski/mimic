import CryptoKit
import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

public enum CloudSyncError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// A portable voice. Names and metadata are inside the encrypted payload.
public struct CloudVoiceArchive: Codable, Sendable {
    public var format: String
    public var version: Int
    public var name: String
    public var files: [String: Data]

    public init(name: String, files: [String: Data]) {
        self.format = "mimic.voice"; self.version = 1; self.name = name; self.files = files
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32 * 1024 * 1024 else { throw CloudSyncError.message("The voice file is too large.") }
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.format == "mimic.voice", archive.version == 1,
              !archive.name.isEmpty, archive.name.count <= 60, !archive.name.hasPrefix("."),
              !archive.name.contains(where: { "/\\:".contains($0) }),
              !archive.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              archive.files["meta.json"] != nil, archive.files["codes.npy"] != nil else {
            throw CloudSyncError.message("This is not a compatible Mimic voice file.")
        }
        let limits = ["meta.json": 1024 * 1024, "codes.npy": 4 * 1024 * 1024,
                      "reference.wav": 16 * 1024 * 1024]
        for (name, bytes) in archive.files {
            guard let limit = limits[name], !bytes.isEmpty, bytes.count <= limit else {
                throw CloudSyncError.message("The voice contains invalid or oversized data.")
            }
        }
        _ = try archive.fingerprint()
        return archive
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    public func fingerprint() throws -> Data {
        guard let meta = files["meta.json"], let codes = files["codes.npy"],
              let object = try JSONSerialization.jsonObject(with: meta) as? [String: Any],
              let text = object["reference_text"] as? String, !text.isEmpty else {
            throw CloudSyncError.message("The voice has no reference transcript.")
        }
        var data = codes; data.append(0); data.append(Data(text.utf8)); data.append(0)
        data.append(files["reference.wav"] ?? Data()); data.append(0); data.append(Data(name.utf8))
        return Data(SHA256.hash(data: data))
    }
}

/// The root key never leaves the device. Authentication and AES keys use
/// separate HKDF contexts; the server sees only an authentication derivative.
public struct CloudVault: Sendable {
    public static let endpoint = URL(string: "https://mimic.lyricstats.dev")!
    private let encryption: SymmetricKey
    private let token: String
    private let authorization: String
    public let recoveryKey: String
    public let journalSuffix: String
    private let base: URL
    private static let chunkSize = 512 * 1024

    public init(pairingKey: String, base: URL = Self.endpoint) throws {
        let input = pairingKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = input.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let isDevice = parts.count == 4 && parts[0] == "mimic2"
        if parts.count != 1 && !isDevice { throw CloudSyncError.message("Copy the complete device pairing code from the Mimic website.") }
        let text = isDevice ? parts[1] : input
        if isDevice {
            guard parts[2].count == 32, parts[3].count == 64,
                  (parts[2] + parts[3]).allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw CloudSyncError.message("This device pairing code is incomplete.")
            }
        }
        guard text.count == 64, text.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw CloudSyncError.message("Use the complete 64-character pairing key.")
        }
        let chars = Array(text)
        let data = Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! })
        let key = SymmetricKey(data: data)
        func derive(_ purpose: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data("mimic.sync.v1".utf8),
                                   info: Data(purpose.utf8), outputByteCount: 32)
        }
        encryption = derive("encryption")
        token = derive("authentication").withUnsafeBytes { Data($0).hex }
        authorization = isDevice ? "Device \(parts[2]).\(parts[3])" : "Bearer \(token)"
        recoveryKey = text
        journalSuffix = isDevice ? "." + parts[2] : ""
        self.base = base
    }
    public func objectID(_ data: Data) throws -> String {
        let archive = try CloudVoiceArchive.decode(data)
        return Data(HMAC<SHA256>.authenticationCode(for: try archive.fingerprint(), using: encryption)).hex
    }
    public func encrypt(_ data: Data) throws -> Data {
        _ = try CloudVoiceArchive.decode(data)
        guard let sealed = try AES.GCM.seal(data, using: encryption,
                                            authenticating: Data("mimic.voice.v1".utf8)).combined else {
            throw CloudSyncError.message("Could not encrypt the voice.")
        }
        return sealed
    }
    public func decrypt(_ data: Data) throws -> Data {
        guard data.count <= 32 * 1024 * 1024 + 28 else { throw CloudSyncError.message("The cloud voice is too large.") }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: encryption,
                                     authenticating: Data("mimic.voice.v1".utf8))
        _ = try CloudVoiceArchive.decode(plain)
        return plain
    }
    private func request(_ action: String, query: [String: String] = [:],
                         body: [String: Any]? = nil) async throws -> [String: Any] {
        try Task.checkCancellation()
        var url = URLComponents(url: base.appending(path: "api/sync"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "action", value: action)] + query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!); request.timeoutInterval = 60
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudSyncError.message("The sync service returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudSyncError.message(object["error"] as? String ?? "Sync could not finish. Try again later.")
        }
        return object
    }
    public func list() async throws -> [String] {
        var ids: [String] = []; var cursor: String?
        repeat {
            let response = try await request("list", query: cursor.map { ["cursor": $0] } ?? [:])
            guard let voices = response["voices"] as? [[String: Any]] else { throw CloudSyncError.message("The cloud library is unreadable.") }
            ids += voices.compactMap { $0["id"] as? String }; cursor = response["cursor"] as? String
            guard ids.count <= 10_000 else { throw CloudSyncError.message("The cloud library is too large to sync at once.") }
        } while cursor != nil
        return ids
    }
    public func upload(_ data: Data) async throws -> String {
        let id = try objectID(data), encrypted = try encrypt(data)
        let upload = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let parts = (encrypted.count + Self.chunkSize - 1) / Self.chunkSize
        let manifest: [String: Any] = ["id": id, "upload": upload, "parts": parts, "bytes": encrypted.count,
            "label": try AES.GCM.seal(Data(CloudVoiceArchive.decode(data).name.utf8), using: encryption,
                authenticating: Data("mimic.name.v1".utf8)).combined!.base64EncodedString()]
        let started = try await request("begin", body: manifest)
        if started["complete"] as? Bool == true { return id }
        for part in 0..<parts {
            let start = part * Self.chunkSize, end = min(start + Self.chunkSize, encrypted.count)
            _ = try await request("chunk", body: ["id": id, "upload": upload, "part": part,
                                                  "data": encrypted[start..<end].base64EncodedString()])
        }
        _ = try await request("commit", body: manifest)
        return id
    }
    public func download(_ id: String) async throws -> Data {
        let manifest = try await request("manifest", query: ["id": id])
        guard let parts = manifest["parts"] as? Int, let size = manifest["bytes"] as? Int,
              let upload = manifest["upload"] as? String, (1...65).contains(parts),
              (29...(32 * 1024 * 1024 + 28)).contains(size) else {
            throw CloudSyncError.message("The cloud voice has an invalid size.")
        }
        var encrypted = Data()
        for part in 0..<parts {
            let value = try await request("chunk", query: ["id": id, "part": String(part), "upload": upload])
            guard let encoded = value["data"] as? String, let chunk = Data(base64Encoded: encoded),
                  chunk.count <= Self.chunkSize, encrypted.count + chunk.count <= size else {
                throw CloudSyncError.message("The cloud voice is incomplete.")
            }
            encrypted.append(chunk)
        }
        guard encrypted.count == size else { throw CloudSyncError.message("The cloud voice is incomplete.") }
        let plain = try decrypt(encrypted)
        guard try objectID(plain) == id else { throw CloudSyncError.message("The cloud voice identity does not match.") }
        return plain
    }
}

private extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }

@MainActor
public final class CloudSyncController: ObservableObject {
    @Published public private(set) var connected = false
    @Published public private(set) var syncing = false
    @Published public private(set) var status = ""
    private var vault: CloudVault?
    private let service = "dev.mimic.encrypted-sync.v1"
    private let journalKey = "MimicCloudSeenObjects"
    public init() {
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "primary",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let key = String(data: data, encoding: .utf8),
           let found = try? CloudVault(pairingKey: key) { vault = found; connected = true }
    }
    public func connect(_ key: String) async {
        guard !syncing else { return }; syncing = true; defer { syncing = false }
        do {
            let next = try CloudVault(pairingKey: key); _ = try await next.list()
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: "primary"]
            let data = Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if update == errSecItemNotFound {
                var add = query; add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw CloudSyncError.message("Could not save the pairing key in Keychain.") }
            } else if update != errSecSuccess { throw CloudSyncError.message("Could not update the pairing key in Keychain.") }
            vault = next; connected = true; status = "Connected. Sync is ready."
        } catch { status = error.localizedDescription }
    }
    public func recoveryDocument() throws -> VoiceArchiveDocument {
        guard let vault else { throw CloudSyncError.message("Connect a library first.") }
        return VoiceArchiveDocument(data: Data(("Mimic recovery key\n\n" + vault.recoveryKey + "\n\nKeep this key private. Sign in at https://mimic.lyricstats.dev to unlock your encrypted voices.\n").utf8))
    }
    public func disconnect() {
        guard !syncing else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "primary"]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { status = "Could not remove the pairing key from Keychain."; return }
        vault = nil; connected = false; status = "Disconnected. Local voices are kept."
    }
    /// Additive sync protects local edits and never propagates a deletion.
    /// The journal remembers received snapshots, including locally removed ones.
    public func sync(export: () async throws -> [Data], install: (Data) async throws -> Void) async {
        guard let vault, !syncing else { return }; syncing = true; status = "Syncing encrypted voices…"
        defer { syncing = false }
        do {
            let journalKey = self.journalKey + vault.journalSuffix
            var seen = Set(UserDefaults.standard.stringArray(forKey: journalKey) ?? [])
            let remote = Set(try await vault.list()), local = try await export()
            var localIDs = Set<String>()
            for data in local { localIDs.insert(try vault.objectID(data)) }
            var received = 0, sent = 0
            for id in remote.subtracting(seen).subtracting(localIDs).sorted() {
                let data = try await vault.download(id); try await install(data)
                // Keep a conflict-copy's local identity from being uploaded again.
                for installed in try await export() {
                    let installedID = try vault.objectID(installed)
                    if !localIDs.contains(installedID) { seen.insert(installedID) }
                }
                seen.insert(id); UserDefaults.standard.set(Array(seen), forKey: journalKey); received += 1
            }
            for data in local {
                let id = try vault.objectID(data)
                if !remote.contains(id) && !seen.contains(id) { _ = try await vault.upload(data); sent += 1 }
                seen.insert(id)
            }
            UserDefaults.standard.set(Array(seen), forKey: journalKey)
            status = "Up to date · \(sent) sent, \(received) received"
        } catch { status = error.localizedDescription }
    }
}

public struct CloudSyncSection: View {
    @ObservedObject private var controller: CloudSyncController
    private let sync: () async -> Void
    @State private var key = ""
    @State private var savingRecovery = false
    @State private var recovery = VoiceArchiveDocument(data: Data())
    public init(controller: CloudSyncController, sync: @escaping () async -> Void) {
        self.controller = controller; self.sync = sync
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Encrypted voice sync", systemImage: "lock.icloud").font(.headline)
            Text("Sign in on the Mimic website, unlock your library, and create a pairing code for this device. Voices are encrypted before upload. New voices sync when the app opens; deletions stay local.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Link("Open account & device pairing", destination: CloudVault.endpoint)
            if controller.connected {
                Button("Save recovery key…") {
                    if let document = try? controller.recoveryDocument() { recovery = document; savingRecovery = true }
                }
                HStack {
                    Button("Sync now") { Task { await sync() } }
                    Button("Disconnect") { controller.disconnect() }
                }
            } else {
                SecureField("Device pairing code or original key", text: $key)
                    .textContentType(.password)
                Button("Connect and sync") {
                    Task { await controller.connect(key); if controller.connected { key = ""; await sync() } }
                }.disabled((try? CloudVault(pairingKey: key)) == nil)
            }
            if controller.syncing { ProgressView().controlSize(.small) }
            if !controller.status.isEmpty { Text(controller.status).font(.caption).fixedSize(horizontal: false, vertical: true) }
        }.disabled(controller.syncing)
        .fileExporter(isPresented: $savingRecovery, document: recovery, contentType: .plainText,
                      defaultFilename: "Mimic Recovery Key.txt") { _ in }
    }
}

// Kept alongside sync so both standalone Mac and package-based iOS use the same flow.
public struct VoiceArchiveDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.data] }
    public var data: Data
    public init(data: Data) { self.data = data }
    public init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CloudSyncError.message("Choose a voice file exported by Mimic.")
        }
        data = contents
    }
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

public struct VoiceTransferSection: View {
    private let selected: String?
    private let export: () async throws -> Data
    private let install: (Data) async throws -> Void
    @State private var importing = false
    @State private var exporting = false
    @State private var working = false
    @State private var document = VoiceArchiveDocument(data: Data())
    @State private var status = ""
    public init(selected: String?, export: @escaping () async throws -> Data,
                install: @escaping (Data) async throws -> Void) {
        self.selected = selected; self.export = export; self.install = install
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transfer voices").font(.headline)
            Text("Import a voice file, or export your selected voice to use on another device.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                Button("Import voice…") { importing = true }
                Button("Export voice…") {
                    working = true
                    Task {
                        defer { working = false }
                        do { document = VoiceArchiveDocument(data: try await export()); exporting = true }
                        catch { status = error.localizedDescription }
                    }
                }.disabled(selected == nil)
            }
            .buttonStyle(.borderless)
            .fixedSize(horizontal: false, vertical: true)
            if let selected {
                Text("Selected: \(selected)")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Voice files include the reference recording. Share them privately.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if working { ProgressView().controlSize(.small) }
            if !status.isEmpty { Text(status).font(.caption) }
        }.disabled(working)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            guard case let .success(url) = result else { return }
            working = true
            Task {
                defer { working = false }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 32 * 1024 * 1024 else { throw CloudSyncError.message("Choose a voice smaller than 32 MiB.") }
                    try await install(Data(contentsOf: url)); status = "Voice imported. Select it in Speak."
                } catch { status = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .data,
                      defaultFilename: (selected ?? "Voice") + ".mimicvoice") { result in
            switch result {
            case .success: status = "Voice exported."
            case let .failure(error): status = error.localizedDescription
            }
        }
    }
}
