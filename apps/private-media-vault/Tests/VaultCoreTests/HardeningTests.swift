import Foundation
import XCTest
@testable import VaultCore

final class HardeningTests: XCTestCase {
    func testRecoveryKeyRejectsNonCanonicalTextAndWipeRedacts() throws {
        let key = RecoveryKey.generate()
        let display = key.display
        XCTAssertThrowsError(try RecoveryKey.parse(display + "0"))
        XCTAssertThrowsError(try RecoveryKey.parse(String(display.dropLast())))
        var copy = key
        copy.wipe()
        XCTAssertFalse(String(describing: copy).contains(display))
        XCTAssertNotEqual(copy.display, display)
        XCTAssertTrue(copy.rawBytesForBackupWrap().isEmpty)
    }

    func testResumeAfterAutolockDeadlineLocks() {
        var coordinator = PrivacyCoordinator(configuration: LockConfiguration(autoLock: .after(60)))
        _ = coordinator.handle(.didUnlock)
        let backgrounded = coordinator.handle(.enteredBackground(Date(timeIntervalSince1970: 1_000)))
        XCTAssertFalse(backgrounded.shouldLock)
        let early = coordinator.handle(.becameActive(Date(timeIntervalSince1970: 1_030)))
        XCTAssertFalse(early.shouldLock)
        XCTAssertFalse(early.coverVisible)
        _ = coordinator.handle(.enteredBackground(Date(timeIntervalSince1970: 1_040)))
        let late = coordinator.handle(.becameActive(Date(timeIntervalSince1970: 1_100)))
        XCTAssertTrue(late.shouldLock)
        XCTAssertTrue(late.shouldClearCaches)
    }

    func testRangeReadIsBoundedAndOversizedRangeIsRejected() throws {
        let directory = try makeDirectory()
        let store = try VaultStore(directory: directory, masterKey: MasterKey.generate())
        var original = Data(repeating: 0x11, count: 2 * 1024 * 1024)
        original.replaceSubrange(1_000_000 ..< 1_000_032, with: Data("SLICE-MARKER-0123456789ABCDEF".utf8))
        let item = try store.importBytes(original, metadata: sample(name: "big.bin"), chunkSize: 64 * 1024)
        let reader = try store.reader(for: item.id)
        let slice = try reader.plaintext(byteRange: 1_000_000 ..< 1_000_032)
        XCTAssertEqual(slice.count, 32)
        XCTAssertEqual(slice, original.subdata(in: 1_000_000 ..< 1_000_032))
        XCTAssertThrowsError(
            try reader.plaintext(byteRange: 0 ..< (VaultFormats.maximumPlaintextRangeBytes + 1))
        ) { error in
            XCTAssertEqual(error as? VaultError, .limitExceeded)
        }
        reader.close()
    }

    func testBackupVersionRejectionLeavesNoVault() throws {
        let directory = try makeDirectory()
        let store = try VaultStore(directory: directory, masterKey: MasterKey.generate())
        _ = try store.importBytes(Data("versioned".utf8), metadata: sample(name: "a.jpg"), chunkSize: 16)
        let backup = directory.appendingPathComponent("vault.pmvb")
        let recovery = try store.createBackup(to: backup)
        var bytes = try Data(contentsOf: backup)
        bytes[4] = 99
        bytes[5] = 0
        let future = directory.appendingPathComponent("future.pmvb")
        try bytes.write(to: future)
        let destination = directory.appendingPathComponent("future-vault")
        XCTAssertThrowsError(try VaultStore.restoreBackup(from: future, recoveryKey: recovery, to: destination)) { error in
            XCTAssertEqual(error as? VaultError, .unsupportedVersion(99))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("catalog.pmvc").path))
    }

    func testMigrationIsIdempotentAndContainerVersionFailsClosed() throws {
        let directory = try makeDirectory()
        let key = MasterKey.generate()
        let store = try VaultStore(directory: directory, masterKey: key)
        let item = try store.importBytes(Data("migrate-me".utf8), metadata: sample(name: "old.jpg"), chunkSize: 16)
        let versionOne = """
        {"albums":[],"items":[{"blobName":"\(item.blobName)","byteCount":10,"createdAt":10,"id":"\(item.id.uuidString)","importedAt":10,"mediaKind":"image","originalFilename":"old.jpg","sha256Hex":"\(item.sha256Hex)","source":"files"}],"schemaVersion":1}
        """
        try store.testing_writeCatalogPlaintext(Data(versionOne.utf8))
        let once = try VaultStore(directory: directory, masterKey: key)
        XCTAssertEqual(try once.items().map(\.originalFilename), ["old.jpg"])
        XCTAssertEqual(try once.playlists().count, 0)
        let twice = try VaultStore(directory: directory, masterKey: key)
        XCTAssertEqual(try twice.items().count, 1)
        XCTAssertThrowsError(try CatalogMigrator.catalog(from: Data(#"{"schemaVersion":0,"items":[]}"#.utf8)))
        XCTAssertThrowsError(try CatalogMigrator.catalog(from: Data(#"{"schemaVersion":2}"#.utf8))) { error in
            XCTAssertEqual(error as? VaultError, .catalogCorrupt)
        }

        let catalog = directory.appendingPathComponent("catalog.pmvc")
        var raw = try Data(contentsOf: catalog)
        raw[4] = 9
        raw[5] = 0
        try raw.write(to: catalog)
        let blobs = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("blobs").path)
        XCTAssertThrowsError(try VaultStore(directory: directory, masterKey: key)) { error in
            XCTAssertEqual(error as? VaultError, .catalogCorrupt)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("blobs").path), blobs)
    }

    func testThumbnailSurvivesCrashAfterJournal() throws {
        let directory = try makeDirectory()
        let key = MasterKey.generate()
        let crashing = try VaultStore(directory: directory, masterKey: key, interruption: CrashAt(.journalReady))
        let thumb = Data("thumb-bytes".utf8)
        XCTAssertThrowsError(
            try crashing.importBytes(
                Data("original-bytes".utf8),
                metadata: ImportMetadata(
                    originalFilename: "pic.jpg",
                    mediaKind: .image,
                    contentTypeIdentifier: "public.jpeg",
                    source: .files,
                    thumbnail: thumb
                ),
                chunkSize: 16
            )
        )
        let reopened = try VaultStore(directory: directory, masterKey: key)
        let item = try XCTUnwrap(try reopened.items().first)
        XCTAssertEqual(try reopened.thumbnail(for: item.id), thumb)
    }

    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pmv-hardening-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func sample(name: String) -> ImportMetadata {
        ImportMetadata(
            originalFilename: name,
            mediaKind: .image,
            contentTypeIdentifier: "public.image",
            source: .files
        )
    }
}
