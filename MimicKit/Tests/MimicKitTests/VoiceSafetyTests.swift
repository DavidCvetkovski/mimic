import Foundation
import XCTest
@testable import MimicKit

final class VoiceSafetyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "mimic-voice-safety-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func read(_ data: Data) throws -> NumpyArray.Integers {
        let file = root.appending(path: "codes.npy")
        try data.write(to: file)
        return try NumpyArray.readInt(from: file)
    }

    private func array(shape: String = "1, 2", dtype: String = "<u2", body: Data = Data([1, 0, 2, 0])) -> Data {
        let header = Data("{'descr': '\(dtype)', 'fortran_order': False, 'shape': (\(shape)), }\n".utf8)
        var data = Data([0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59, 1, 0])
        withUnsafeBytes(of: UInt16(header.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(header)
        data.append(body)
        return data
    }

    func testEveryTruncatedHeaderThrowsInsteadOfCrashing() {
        let valid = array()
        let headerEnd = valid.count - 4
        for length in 0..<headerEnd {
            XCTAssertThrowsError(try read(Data(valid.prefix(length))), "accepted \(length) bytes")
        }
        // Version 2 needs a four-byte header length, even when its magic is valid.
        XCTAssertThrowsError(try read(Data([0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59, 2, 0, 1, 0, 0])))
    }

    func testInvalidDimensionsAndTruncatedSamplesAreRejected() {
        for shape in ["-1, 2", "0, 2", "1, broken", "9223372036854775807, 9", ""] {
            XCTAssertThrowsError(try read(array(shape: shape)), "accepted \(shape)")
        }
        XCTAssertThrowsError(try read(array(body: Data([1, 0, 2]))))
        XCTAssertThrowsError(try read(array(dtype: ">u2")))
    }

    func testIntegerOverflowDoesNotBecomeAValidVoiceCode() {
        var payload = Data()
        withUnsafeBytes(of: Int64.max.littleEndian) { payload.append(contentsOf: $0) }
        XCTAssertThrowsError(try read(array(shape: "1, 1", dtype: "<i8", body: payload)))
    }

    func testValidPortableVoiceCodesStillLoad() throws {
        let result = try read(array())
        XCTAssertEqual(result.shape, [1, 2])
        XCTAssertEqual(result.values, [1, 2])
    }

    func testLibraryHidesUnfinishedProfilesAndLinkedFolders() throws {
        let staging = root.appending(path: ".Me.staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: staging.appending(path: "meta.json"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Linked"), withDestinationURL: staging)
        let store = VoiceStore(root: root)
        XCTAssertTrue(store.names().isEmpty)
        XCTAssertThrowsError(try store.delete("Linked"))
        XCTAssertThrowsError(try store.delete("../outside"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    func testPythonFractionalTimestampKeepsItsDate() throws {
        let directory = root.appending(path: "Me")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = Data(#"{"reference_text":"hello","created_at":"2026-09-08T10:00:00.123456+00:00"}"#.utf8)
        try metadata.write(to: directory.appending(path: "meta.json"))
        XCTAssertNotNil(VoiceStore(root: root).summaries().first?.created)
    }

    func testInvalidMetadataDoesNotMoveVoiceDuringRename() throws {
        let directory = root.appending(path: "Me")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: directory.appending(path: "meta.json"))
        XCTAssertThrowsError(try VoiceStore(root: root).rename("Me", to: "Renamed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Renamed").path))
    }
}

final class PlaybackIntentTests: XCTestCase {
    func testPlaybackTimeDoesNotCarrySilenceIntoALateSentence() {
        // Two seconds played, then six seconds waiting for the next sentence.
        let caughtUp = StreamPlayer.advancedPosition(1, elapsed: 7, buffered: 2)
        XCTAssertEqual(caughtUp, 2)
        // The new sentence begins at 2s, even after that long wait.
        XCTAssertEqual(StreamPlayer.advancedPosition(caughtUp, elapsed: 0.5, buffered: 5), 2.5)
        XCTAssertEqual(StreamPlayer.advancedPosition(2, elapsed: -1, buffered: 5), 2)
    }

    @MainActor func testInterruptionBeforeFirstChunkSuppressesAutomaticPlayback() {
        let player = StreamPlayer()
        player.pause()
        XCTAssertFalse(player.allowsAutomaticPlayback)
        player.isComplete = true
        player.stop()
        XCTAssertFalse(player.isComplete)
        XCTAssertEqual(player.buffered, 0)
        player.reset()
        XCTAssertTrue(player.allowsAutomaticPlayback)
    }
}
