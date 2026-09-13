import Foundation
import XCTest
@testable import MimicKit

final class CloudSyncTests: XCTestCase {
    private func fixture() throws -> (CloudVault, Data, Data, String) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/cloud-truth.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return (try CloudVault(pairingKey: json["pairingKey"] as! String),
                try JSONSerialization.data(withJSONObject: json["archive"]!),
                Data(base64Encoded: json["ciphertext"] as! String)!, json["id"] as! String)
    }
    func testBrowserAndSwiftUseTheSameEncryptionAndVoiceIdentity() throws {
        let (vault, archive, ciphertext, id) = try fixture()
        let decoded = try CloudVoiceArchive.decode(vault.decrypt(ciphertext))
        XCTAssertEqual(decoded.name, "Fixture voice")
        XCTAssertEqual(try vault.objectID(archive), id)
        XCTAssertEqual(try vault.objectID(decoded.encoded()), id)
    }
    func testDevicePairingPreservesEncryptionAndSeparatesTheSyncJournal() throws {
        let (_, archive, ciphertext, id) = try fixture()
        let key = String(repeating: "01", count: 32)
        let code = "mimic2." + key + "." + String(repeating: "ab", count: 16) + "." + String(repeating: "cd", count: 32)
        let device = try CloudVault(pairingKey: code)
        XCTAssertEqual(device.recoveryKey, key)
        XCTAssertEqual(device.journalSuffix, "." + String(repeating: "ab", count: 16))
        XCTAssertEqual(try device.objectID(archive), id)
        XCTAssertNoThrow(try device.decrypt(ciphertext))
        XCTAssertThrowsError(try CloudVault(pairingKey: code + ".extra"))
        XCTAssertThrowsError(try CloudVault(pairingKey: "mimic2." + key + ".short.secret"))
    }
    func testTamperingAndWrongKeysFailClosed() throws {
        let (vault, archive, ciphertext, _) = try fixture()
        var altered = ciphertext; altered[altered.count - 1] ^= 1
        XCTAssertThrowsError(try vault.decrypt(altered))
        let other = try CloudVault(pairingKey: String(repeating: "02", count: 32))
        XCTAssertThrowsError(try other.decrypt(ciphertext))
        XCTAssertNotEqual(try vault.encrypt(archive), try vault.encrypt(archive))
        XCTAssertThrowsError(try CloudVault(pairingKey: "short"))
    }
    func testVoiceTransferIsAtomicAndNeverReplacesAnExistingVoice() throws {
        let (_, archive, _, _) = try fixture()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = try VoiceTransfer.importVoice(data: archive, into: root)
        XCTAssertEqual(name, "Fixture voice")
        XCTAssertThrowsError(try VoiceTransfer.importVoice(data: archive, into: root))
        let exported = try CloudVoiceArchive.decode(VoiceTransfer.exportVoice(name: name, from: root))
        XCTAssertEqual(try exported.fingerprint(), try CloudVoiceArchive.decode(archive).fingerprint())
        XCTAssertThrowsError(try VoiceTransfer.importVoice(data: archive, into: root, name: "../bad"))
    }
}
