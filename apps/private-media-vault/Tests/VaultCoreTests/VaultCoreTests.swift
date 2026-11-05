import Foundation
import XCTest
@testable import VaultCore

final class VaultCoreTests: XCTestCase {
    func testRecoveryKeyRoundTripRedactsAndAcceptsConfusedCharacters() throws {
        let key = RecoveryKey.generate()
        XCTAssertEqual(String(describing: key), "RecoveryKey(redacted)")
        XCTAssertFalse(key.display.isEmpty)
        XCTAssertFalse(String(reflecting: key).contains(key.display))
        let parsed = try RecoveryKey.parse(key.display.lowercased())
        XCTAssertEqual(parsed.display, key.display)
        var confused = key.display
        confused = confused.replacingOccurrences(of: "0", with: "O")
        confused = confused.replacingOccurrences(of: "1", with: "L")
        XCTAssertEqual(try RecoveryKey.parse(confused).display, key.display)
        XCTAssertThrowsError(try RecoveryKey.parse("not a key")) { error in
            XCTAssertEqual(error as? VaultError, .authenticationFailed)
            XCTAssertFalse(String(describing: error).contains(key.display))
        }
    }

    func testBase32SingleByteVector() throws {
        XCTAssertEqual(RecoveryKeyCodec.encode([0x00]), "00")
        XCTAssertEqual(RecoveryKeyCodec.encode([0xff]), "ZW")
        let repeated = [UInt8](repeating: 0xff, count: 32)
        XCTAssertEqual(try RecoveryKeyCodec.decode(RecoveryKeyCodec.encode(repeated)), repeated)
    }

    func testWrongKeyTamperAndRanges() throws {
        let directory = try makeDirectory()
        let key = MasterKey.generate()
        let store = try VaultStore(directory: directory, masterKey: key, log: MemoryLog())
        let payload = Data(repeating: 0xab, count: 64) + Data("RANGE-MARKER".utf8) + Data(repeating: 0xcd, count: 70)
        let item = try store.importBytes(payload, metadata: sampleMetadata(name: "clip.bin"), chunkSize: 64)
        let reader = try store.reader(for: item.id)
        let middle = try reader.plaintext(byteRange: 60 ..< 80)
        XCTAssertEqual(middle, payload.subdata(in: 60 ..< 80))
        XCTAssertEqual(try reader.plaintext(byteRange: 64 ..< 64), Data())
        XCTAssertThrowsError(try reader.plaintext(byteRange: 0 ..< payload.count + 1))
        reader.close()

        let exact = try store.importBytes(Data(repeating: 1, count: 64), metadata: sampleMetadata(name: "exact.bin"), chunkSize: 64)
        let exactReader = try store.reader(for: exact.id)
        XCTAssertEqual(try exactReader.sha256(), CryptoBox.sha256(Data(repeating: 1, count: 64)))
        exactReader.close()
        let exactURL = try store.testing_blobURL(exact.id)
        var shortened = try Data(contentsOf: exactURL)
        shortened.removeLast(9)
        try shortened.write(to: exactURL)
        XCTAssertThrowsError(try store.reader(for: exact.id))

        let blob = try store.testing_blobURL(item.id)
        var raw = try Data(contentsOf: blob)
        raw[raw.count - 9] ^= 0xff
        try raw.write(to: blob)
        XCTAssertThrowsError(try store.verifyIntegrity(item.id)) { error in
            let vaultError = error as? VaultError
            XCTAssertTrue(vaultError == .authenticationFailed || vaultError == .integrityFailed || vaultError == .truncated)
        }
        let export = directory.appendingPathComponent("out.bin")
        XCTAssertThrowsError(try store.exportOriginal(item.id, to: export))
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.appendingPathExtension("partial").path))

        XCTAssertThrowsError(try VaultStore(directory: directory, masterKey: MasterKey.generate())) { error in
            XCTAssertEqual(error as? VaultError, .catalogCorrupt)
        }
        let untouched = try Data(contentsOf: blob)
        XCTAssertEqual(untouched, raw)
    }

    func testImportExportRoundTripLeavesSourceAndRollsBackFailures() throws {
        let directory = try makeDirectory()
        let source = directory.appendingPathComponent("source.mov")
        let original = Data("PLAINTEXT-MARKER-z9q-0123456789".utf8) + Data(repeating: 7, count: 300)
        try original.write(to: source)
        let log = MemoryLog()
        let store = try VaultStore(directory: directory, masterKey: MasterKey.generate(), log: log)
        let item = try store.importFile(
            at: source,
            metadata: sampleMetadata(name: "../secret/video.mov", caption: "CAPTION-MARKER-z9q"),
            chunkSize: 64
        )
        XCTAssertEqual(try Data(contentsOf: source), original)
        let exported = directory.appendingPathComponent("exported")
        _ = try store.exportAllOriginals(to: exported)
        let names = try FileManager.default.contentsOfDirectory(atPath: exported.path)
        XCTAssertEqual(names.count, 1)
        XCTAssertFalse(names[0].contains("/"))
        XCTAssertFalse(names[0].contains(".."))
        let exportedBytes = try Data(contentsOf: exported.appendingPathComponent(names[0]))
        XCTAssertEqual(exportedBytes, original)
        let cipher = try store.testing_catalogCiphertext()
        XCTAssertFalse(cipher.contains(Data("CAPTION-MARKER-z9q".utf8)))
        XCTAssertFalse(cipher.contains(Data("PLAINTEXT-MARKER-z9q".utf8)))
        XCTAssertTrue(try store.search("caption-marker").contains { $0.id == item.id })
        XCTAssertTrue(log.lines.allSatisfy { !$0.contains("CAPTION-MARKER") && !$0.contains("PLAINTEXT-MARKER") })

        try store.testing_setStoredSHA256(id: item.id, hex: "00")
        let badExport = directory.appendingPathComponent("bad.bin")
        XCTAssertThrowsError(try store.exportOriginal(item.id, to: badExport)) { error in
            XCTAssertEqual(error as? VaultError, .integrityFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: badExport.path))
    }

    func testDiskFullAndInterruptedImports() throws {
        let directory = try makeDirectory()
        let source = directory.appendingPathComponent("keep.dat")
        let original = Data(repeating: 3, count: 400)
        try original.write(to: source)
        let store = try VaultStore(directory: directory, masterKey: MasterKey.generate())
        store.quota = ByteQuota(bytes: 80)
        XCTAssertThrowsError(try store.importFile(at: source, metadata: sampleMetadata(name: "keep.dat"), chunkSize: 64)) { error in
            XCTAssertEqual(error as? VaultError, .diskFull)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try store.items().count, 0)
        let staging = directory.appendingPathComponent("staging")
        let stagingNames = try FileManager.default.contentsOfDirectory(atPath: staging.path)
        XCTAssertTrue(stagingNames.isEmpty)

        let key = MasterKey.generate()
        for point in [ImportPoint.beforeJournal, .journalReady, .catalogCommitted] {
            let vault = directory.appendingPathComponent(point.rawValue)
            let crashing = try VaultStore(
                directory: vault,
                masterKey: key,
                interruption: CrashAt(point)
            )
            XCTAssertThrowsError(
                try crashing.importBytes(original, metadata: sampleMetadata(name: "piece.bin"), chunkSize: 64)
            ) { error in
                XCTAssertEqual(error as? VaultError, .simulatedCrash)
            }
            let reopened = try VaultStore(directory: vault, masterKey: key)
            let items = try reopened.items(includingTrash: true)
            if point == .beforeJournal {
                XCTAssertEqual(items.count, 0)
                let names = try FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("staging").path)
                XCTAssertTrue(names.isEmpty)
            } else {
                XCTAssertEqual(items.count, 1)
                let destination = vault.appendingPathComponent("roundtrip.bin")
                try reopened.exportOriginal(items[0].id, to: destination)
                XCTAssertEqual(try Data(contentsOf: destination), original)
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testJournalAndCatalogCorruptionDoNotDeleteMedia() throws {
        let directory = try makeDirectory()
        let key = MasterKey.generate()
        let crashing = try VaultStore(directory: directory, masterKey: key, interruption: CrashAt(.journalReady))
        XCTAssertThrowsError(try crashing.importBytes(Data(repeating: 9, count: 40), metadata: sampleMetadata(name: "a.jpg"), chunkSize: 32))
        let journal = directory.appendingPathComponent("journal.pmvj")
        var journalBytes = try Data(contentsOf: journal)
        let blobBefore = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("staging").path)
        XCTAssertFalse(blobBefore.isEmpty)
        journalBytes[journalBytes.count - 1] ^= 0x5a
        try journalBytes.write(to: journal)
        XCTAssertThrowsError(try VaultStore(directory: directory, masterKey: key)) { error in
            XCTAssertEqual(error as? VaultError, .journalCorrupt)
        }
        let blobAfter = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("staging").path)
        XCTAssertEqual(blobBefore, blobAfter)

        let clean = try makeDirectory()
        let cleanKey = MasterKey.generate()
        let store = try VaultStore(directory: clean, masterKey: cleanKey)
        _ = try store.importBytes(Data(repeating: 4, count: 30), metadata: sampleMetadata(name: "b.jpg"), chunkSize: 16)
        let catalog = clean.appendingPathComponent("catalog.pmvc")
        var catalogBytes = try Data(contentsOf: catalog)
        catalogBytes[catalogBytes.count - 1] ^= 0xff
        try catalogBytes.write(to: catalog)
        let blobsBefore = try FileManager.default.contentsOfDirectory(atPath: clean.appendingPathComponent("blobs").path)
        XCTAssertThrowsError(try VaultStore(directory: clean, masterKey: cleanKey)) { error in
            XCTAssertEqual(error as? VaultError, .catalogCorrupt)
        }
        let blobsAfter = try FileManager.default.contentsOfDirectory(atPath: clean.appendingPathComponent("blobs").path)
        XCTAssertEqual(blobsBefore, blobsAfter)
    }

    func testBackupRestoreMigrationAndReplacement() throws {
        let directory = try makeDirectory()
        let log = MemoryLog()
        let store = try VaultStore(directory: directory, masterKey: MasterKey.generate(), log: log, clock: ManualClock(Date(timeIntervalSince1970: 1_700_000_000)))
        let payload = Data("PLAINTEXT-MARKER-z9q-backup".utf8)
        let item = try store.importBytes(
            payload,
            metadata: sampleMetadata(name: "photo.jpg", caption: "seaside"),
            liveMotion: Data("MOTION-MARKER".utf8),
            chunkSize: 16
        )
        try store.setResume(id: item.id, seconds: 1.5, duration: 4)
        let album = try store.createAlbum(name: "Trip")
        try store.add([item.id], to: album.id)
        try store.setFavorite([item.id], true)
        let backup = directory.appendingPathComponent("vault.pmvb")
        let recovery = try store.createBackup(to: backup)
        let backupBytes = try Data(contentsOf: backup)
        XCTAssertFalse(backupBytes.contains(Data("PLAINTEXT-MARKER-z9q-backup".utf8)))
        XCTAssertFalse(backupBytes.contains(Data(recovery.display.utf8)))
        XCTAssertFalse(log.lines.joined(separator: "\n").contains(recovery.display))
        XCTAssertEqual(String(describing: recovery), "RecoveryKey(redacted)")

        let restoredDir = directory.appendingPathComponent("restored")
        let restoredKey = try VaultStore.restoreBackup(from: backup, recoveryKey: recovery, to: restoredDir)
        let restored = try VaultStore(directory: restoredDir, masterKey: restoredKey)
        let restoredItems = try restored.items()
        XCTAssertEqual(restoredItems.count, 1)
        XCTAssertEqual(restoredItems[0].resumeSeconds, 1.5)
        XCTAssertTrue(restoredItems[0].favorite)
        XCTAssertEqual(try restored.albums().map(\.name), ["Trip"])
        let copy = restoredDir.appendingPathComponent("copy.jpg")
        try restored.exportOriginal(restoredItems[0].id, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), payload)
        let exportedAll = restoredDir.appendingPathComponent("all")
        let exportedURLs = try restored.exportAllOriginals(to: exportedAll)
        XCTAssertEqual(exportedURLs.count, 2)
        let motionExport = try XCTUnwrap(exportedURLs.first { $0.lastPathComponent.contains("motion") })
        XCTAssertEqual(try Data(contentsOf: motionExport), Data("MOTION-MARKER".utf8))
        let motion = try XCTUnwrap(try restored.liveMotionReader(for: restoredItems[0].id))
        XCTAssertEqual(try motion.plaintext(byteRange: 0 ..< motion.plaintextLength), Data("MOTION-MARKER".utf8))
        motion.close()

        var wrong = RecoveryKey.generate()
        XCTAssertThrowsError(try VaultStore.restoreBackup(from: backup, recoveryKey: wrong, to: directory.appendingPathComponent("wrong"))) { error in
            XCTAssertEqual(error as? VaultError, .authenticationFailed)
        }
        wrong.wipe()
        var tampered = backupBytes
        tampered[tampered.count / 2] ^= 0xff
        let tamperedURL = directory.appendingPathComponent("tampered.pmvb")
        try tampered.write(to: tamperedURL)
        XCTAssertThrowsError(try VaultStore.restoreBackup(from: tamperedURL, recoveryKey: recovery, to: directory.appendingPathComponent("tampered-vault")))

        let versionOne = """
        {"albums":[],"items":[{"albumIDs":[],"blobName":"\(restoredItems[0].blobName)","byteCount":\(payload.count),"createdAt":10,"id":"\(restoredItems[0].id.uuidString)","importedAt":10,"mediaKind":"image","originalFilename":"old.jpg","sha256Hex":"\(restoredItems[0].sha256Hex)","source":"files"}],"schemaVersion":1}
        """
        try restored.testing_writeCatalogPlaintext(Data(versionOne.utf8))
        let migrated = try VaultStore(directory: restoredDir, masterKey: restoredKey)
        let migratedItems = try migrated.items()
        XCTAssertEqual(migratedItems.count, 1)
        XCTAssertEqual(migratedItems[0].originalFilename, "old.jpg")
        XCTAssertEqual(try migrated.playlists().count, 0)
        let migratedJSON = try CatalogCoding.data(from: Catalog(schemaVersion: 2))
        XCTAssertThrowsError(try CatalogMigrator.catalog(from: Data(#"{"schemaVersion":99,"items":[]}"#.utf8))) { error in
            XCTAssertEqual(error as? VaultError, .unsupportedVersion(99))
        }
        _ = migratedJSON

        let replacedDir = directory.appendingPathComponent("replaced")
        let first = try VaultStore(directory: replacedDir, masterKey: MasterKey.generate())
        _ = try first.importBytes(Data("first".utf8), metadata: sampleMetadata(name: "first.jpg"), chunkSize: 16)
        let newKey = try VaultStore.replaceVault(from: backup, recoveryKey: recovery, vaultDirectory: replacedDir)
        let replaced = try VaultStore(directory: replacedDir, masterKey: newKey)
        XCTAssertEqual(try replaced.items().map(\.originalFilename), ["photo.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("replaced.previous").path))
        XCTAssertThrowsError(try VaultStore.replaceVault(from: backup, recoveryKey: recovery, vaultDirectory: replacedDir)) { error in
            XCTAssertEqual(error as? VaultError, .previousVaultExists)
        }
    }

    func testAlbumsTrashSearchPlaylistsAndPurge() throws {
        let clock = ManualClock(Date(timeIntervalSince1970: 1_000))
        let directory = try makeDirectory()
        let key = MasterKey.generate()
        let store = try VaultStore(directory: directory, masterKey: key, clock: clock)
        let first = try store.importBytes(Data("one".utf8), metadata: sampleMetadata(name: "One.jpg", caption: "alpha"), chunkSize: 16)
        let second = try store.importBytes(Data("two-two".utf8), metadata: sampleMetadata(name: "Two.jpg", caption: "beta"), chunkSize: 16)
        let album = try store.createAlbum(name: "Favorites Folder")
        try store.add([first.id, second.id], to: album.id)
        try store.setFavorite([second.id], true)
        XCTAssertEqual(try store.items(favoritesOnly: true).map(\.id), [second.id])
        XCTAssertEqual(try store.search("ALPHA").map(\.id), [first.id])
        XCTAssertEqual(try store.search("favorites folder").count, 2)
        let playlist = try store.createPlaylist(name: "Show", itemIDs: [first.id, second.id])
        var queue = PlaybackQueue(itemIDs: playlist.itemIDs, continuous: true)
        XCTAssertEqual(queue.current, first.id)
        XCTAssertEqual(queue.advance(), second.id)
        XCTAssertNil(queue.advance())
        try store.trash([first.id])
        XCTAssertEqual(try store.items().map(\.id), [second.id])
        try store.restoreFromTrash([first.id])
        XCTAssertEqual(Set(try store.items().map(\.id)), Set([first.id, second.id]))
        try store.trash([first.id])
        clock.date = Date(timeIntervalSince1970: 1_000 + 31 * 24 * 60 * 60)
        let later = try VaultStore(directory: directory, masterKey: key, clock: clock)
        XCTAssertFalse(try later.items(includingTrash: true).contains { $0.id == first.id })
        XCTAssertTrue(try later.items().contains { $0.id == second.id })
        _ = album
    }

    func testPrivacyLifecycleClearsUnlockedState() {
        var coordinator = PrivacyCoordinator(configuration: LockConfiguration(autoLock: .immediate))
        _ = coordinator.handle(.didUnlock)
        let inactive = coordinator.handle(.resignedActive)
        XCTAssertTrue(inactive.coverVisible)
        XCTAssertFalse(inactive.shouldLock)
        let background = coordinator.handle(.enteredBackground(Date(timeIntervalSince1970: 50)))
        XCTAssertTrue(background.shouldLock)
        XCTAssertTrue(background.shouldClearCaches)
        XCTAssertTrue(background.coverVisible)

        var timed = PrivacyCoordinator(configuration: LockConfiguration(autoLock: .after(30)))
        _ = timed.handle(.didUnlock)
        let armed = timed.handle(.enteredBackground(Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(armed.shouldLock)
        XCTAssertTrue(armed.coverVisible)
        let early = timed.handle(.tick(Date(timeIntervalSince1970: 120)))
        XCTAssertFalse(early.shouldLock)
        let due = timed.handle(.tick(Date(timeIntervalSince1970: 130)))
        XCTAssertTrue(due.shouldLock)
        XCTAssertTrue(due.shouldClearCaches)

        var manual = PrivacyCoordinator(configuration: LockConfiguration(autoLock: .manual))
        _ = manual.handle(.didUnlock)
        let left = manual.handle(.enteredBackground(Date(timeIntervalSince1970: 1)))
        XCTAssertFalse(left.shouldLock)
        XCTAssertTrue(left.coverVisible)
        let locked = manual.handle(.manualLock)
        XCTAssertTrue(locked.shouldLock)
        let returned = coordinator.handle(.becameActive)
        XCTAssertTrue(returned.coverVisible)
    }

    func testAssistantIsMetadataOnlyAndLoopbackRejectsOtherHosts() throws {
        var session = AssistantSession()
        XCTAssertEqual(session.authorize(token: "x", now: Date()), .sessionDisabled)
        let token = session.enable(now: Date(timeIntervalSince1970: 0), lifetime: 60)
        XCTAssertNil(session.authorize(token: token, now: Date(timeIntervalSince1970: 10)))
        XCTAssertEqual(session.authorize(token: "nope", now: Date(timeIntervalSince1970: 10)), .badToken)
        XCTAssertEqual(session.authorize(token: token, now: Date(timeIntervalSince1970: 60)), .expired)
        session.revoke()
        XCTAssertEqual(session.authorize(token: token, now: Date(timeIntervalSince1970: 10)), .revoked)
        XCTAssertEqual(AssistantCommands.request(command: "delete", query: nil), .failure(.forbidden))
        XCTAssertEqual(AssistantCommands.request(command: "export", query: nil), .failure(.forbidden))
        XCTAssertEqual(AssistantCommands.request(command: "unlock", query: nil), .failure(.forbidden))
        try LoopbackPlan.validate(host: "127.0.0.1")
        XCTAssertThrowsError(try LoopbackPlan.validate(host: "0.0.0.0"))
        XCTAssertThrowsError(try LoopbackPlan.validate(host: "10.0.0.8"))
        XCTAssertEqual(LoopbackPlan.loopback().host, "127.0.0.1")

        var live = AssistantSession()
        let liveToken = live.enable(now: Date(timeIntervalSince1970: 0), lifetime: 30)
        let forbidden = AssistantHTTP.respond(
            raw: "POST /v1/export HTTP/1.1\nAuthorization: Bearer \(liveToken)\n\n{}",
            session: live,
            now: Date(timeIntervalSince1970: 1),
            vaultLocked: false,
            perform: { _ in
                XCTFail("forbidden route must not reach the vault")
                return AssistantPayload(kind: "no")
            }
        )
        XCTAssertTrue(forbidden.contains("403"))
        let locked = AssistantHTTP.respond(
            raw: "GET /v1/albums HTTP/1.1\nAuthorization: Bearer \(liveToken)\n\n",
            session: live,
            now: Date(timeIntervalSince1970: 1),
            vaultLocked: true,
            perform: { _ in
                XCTFail("locked vault must not be queried")
                return AssistantPayload(kind: "no")
            }
        )
        XCTAssertTrue(locked.contains("423"))
        let allowed = AssistantHTTP.respond(
            raw: "POST /v1/search HTTP/1.1\nAuthorization: Bearer \(liveToken)\nContent-Length: 17\n\n{\"query\":\"cat\"}",
            session: live,
            now: Date(timeIntervalSince1970: 1),
            vaultLocked: false,
            perform: { request in
                guard case .searchMetadata(let query) = request else {
                    XCTFail("unexpected request")
                    return AssistantPayload(kind: "bad")
                }
                XCTAssertEqual(query, "cat")
                return AssistantPayload(
                    kind: "search",
                    matches: [MetadataMatch(id: UUID(), filename: "cat.jpg", caption: "cat", albumNames: [])]
                )
            }
        )
        XCTAssertTrue(allowed.contains("200"))
        XCTAssertTrue(allowed.contains("cat.jpg"))
        XCTAssertFalse(allowed.contains("pmv1"))
    }

    func testLinkPolicyAndSupportMatrix() {
        XCTAssertEqual(LinkImportPolicy.validate(url: URL(string: "http://example.com/a.jpg")!), .failure(.notHTTPS))
        XCTAssertEqual(LinkImportPolicy.validate(url: URL(string: "https://user:pass@example.com/a.jpg")!), .failure(.userInfo))
        XCTAssertEqual(LinkImportPolicy.validate(url: URL(string: "https://example.com/a.jpg")!).isSuccess, true)
        XCTAssertEqual(failure(LinkImportPolicy.validate(contentType: "text/html", byteCount: 10, maxBytes: 100, redirectCount: 0)), .htmlOrDocument)
        XCTAssertEqual(failure(LinkImportPolicy.validate(contentType: "video/mp4", byteCount: 101, maxBytes: 100, redirectCount: 1)), .tooLarge)
        XCTAssertEqual(LinkImportPolicy.sniff(Data([0xff, 0xd8, 0xff, 0x00])), .image)
        XCTAssertNil(LinkImportPolicy.sniff(Data("<html>".utf8)))
        XCTAssertEqual(MediaSupportMatrix.level(for: "jpeg"), .originalStoredAndOpened)
        XCTAssertEqual(MediaSupportMatrix.level(for: "livePhotoPair"), .stillPlusSeparateMotion)
        XCTAssertEqual(MediaSupportMatrix.level(for: "livePhotoSystemPlayback"), .rejected)
        XCTAssertEqual(MediaSupportMatrix.level(for: "drm"), .rejected)
    }

    func testLockWipesStoreAndEmptyImportIsRejected() throws {
        let directory = try makeDirectory()
        var key = MasterKey.generate()
        let store = try VaultStore(directory: directory, masterKey: key)
        _ = try store.importBytes(Data("abc".utf8), metadata: sampleMetadata(name: "a.jpg"), chunkSize: 16)
        XCTAssertThrowsError(try store.importBytes(Data(), metadata: sampleMetadata(name: "empty.jpg"))) { error in
            XCTAssertEqual(error as? VaultError, .emptyImport)
        }
        store.lock()
        XCTAssertTrue(store.isLocked)
        XCTAssertThrowsError(try store.items()) { error in
            XCTAssertEqual(error as? VaultError, .locked)
        }
        key.wipe()
        XCTAssertTrue(key.isWiped)
    }

    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pmv-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func sampleMetadata(name: String, caption: String = "") -> ImportMetadata {
        ImportMetadata(
            originalFilename: name,
            mediaKind: .image,
            contentTypeIdentifier: "public.image",
            source: .files,
            caption: caption
        )
    }

}

private extension Result where Failure == LinkReject {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

private func failure<T>(_ result: Result<T, LinkReject>) -> LinkReject? {
    if case .failure(let error) = result { return error }
    return nil
}
