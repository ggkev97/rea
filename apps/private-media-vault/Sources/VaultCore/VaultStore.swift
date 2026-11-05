import Crypto
import Foundation

public struct ImportMetadata: Equatable {
    public var originalFilename: String
    public var mediaKind: MediaKind
    public var contentTypeIdentifier: String
    public var source: ImportSource
    public var sourceURL: String?
    public var caption: String
    public var thumbnail: Data?
    public var createdAt: Date?

    public init(
        originalFilename: String,
        mediaKind: MediaKind,
        contentTypeIdentifier: String,
        source: ImportSource,
        sourceURL: String? = nil,
        caption: String = "",
        thumbnail: Data? = nil,
        createdAt: Date? = nil
    ) {
        self.originalFilename = originalFilename
        self.mediaKind = mediaKind
        self.contentTypeIdentifier = contentTypeIdentifier
        self.source = source
        self.sourceURL = sourceURL
        self.caption = caption
        self.thumbnail = thumbnail
        self.createdAt = createdAt
    }
}

public final class VaultStore {
    public let directory: URL
    public private(set) var isLocked = false
    public var maximumImportBytes: Int64

    private var masterKey: MasterKey
    private var catalog: Catalog
    private let log: VaultLog
    public var quota: ByteQuota?
    private let interruption: ImportInterruption
    private let clock: VaultClock
    private let hooks: VaultFileHooks
    private var openReaders: [ChunkedReader] = []
    private var didRecover = false

    public init(
        directory: URL,
        masterKey: MasterKey,
        log: VaultLog = SilentLog(),
        quota: ByteQuota? = nil,
        interruption: ImportInterruption = NoImportInterruption(),
        clock: VaultClock = SystemClock(),
        hooks: VaultFileHooks = NoVaultFileHooks(),
        maximumImportBytes: Int64 = 32 * 1024 * 1024 * 1024
    ) throws {
        self.directory = directory
        self.masterKey = masterKey
        self.log = log
        self.quota = quota
        self.interruption = interruption
        self.clock = clock
        self.hooks = hooks
        self.maximumImportBytes = maximumImportBytes
        try Self.prepareDirectories(directory, hooks: hooks)
        if FileManager.default.fileExists(atPath: Self.catalogURL(directory).path) {
            let raw = try Self.readCatalog(directory: directory, key: masterKey)
            let version = try Self.schemaVersion(in: raw)
            catalog = try CatalogMigrator.catalog(from: raw)
            if version != Catalog.currentSchema {
                try Self.persist(catalog, directory: directory, key: masterKey, quota: quota, hooks: hooks)
            }
        } else {
            catalog = Catalog()
            try Self.persist(catalog, directory: directory, key: masterKey, quota: quota, hooks: hooks)
        }
        try recoverIfNeeded()
    }

    public func lock() {
        let readers = openReaders
        openReaders.removeAll()
        readers.forEach { $0.close() }
        masterKey.wipe()
        isLocked = true
        log.log("vault locked")
    }

    public func items(includingTrash: Bool = false, albumID: UUID? = nil, favoritesOnly: Bool = false) throws -> [MediaItem] {
        try requireUnlocked()
        var result = catalog.items.filter { item in
            if !includingTrash && item.trashedAt != nil { return false }
            if favoritesOnly && !item.favorite { return false }
            if let albumID, !item.albumIDs.contains(albumID) { return false }
            return true
        }
        switch catalog.sort {
        case .newest:
            result.sort { $0.importedAt > $1.importedAt }
        case .oldest:
            result.sort { $0.importedAt < $1.importedAt }
        case .name:
            result.sort { $0.originalFilename.localizedStandardCompare($1.originalFilename) == .orderedAscending }
        case .largest:
            result.sort { $0.byteCount > $1.byteCount }
        }
        return result
    }

    public func albums() throws -> [Album] {
        try requireUnlocked()
        return catalog.albums.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func playlists() throws -> [Playlist] {
        try requireUnlocked()
        return catalog.playlists
    }

    public func setSort(_ sort: LibrarySort) throws {
        try requireUnlocked()
        catalog.sort = sort
        try saveCatalog()
    }

    public func setTrashRetention(days: Int?) throws {
        try requireUnlocked()
        if let days, days < 1 || days > 3650 { throw VaultError.invalidName }
        catalog.trashRetentionDays = days
        try saveCatalog()
    }

    public func importBytes(_ data: Data, metadata: ImportMetadata, liveMotion: Data? = nil, chunkSize: Int = 1 << 20) throws -> MediaItem {
        try importSource(DataByteSource(data), metadata: metadata, liveMotion: liveMotion.map { DataByteSource($0) }, chunkSize: chunkSize)
    }

    public func importFile(at url: URL, metadata: ImportMetadata, liveMotion: URL? = nil, chunkSize: Int = 1 << 20) throws -> MediaItem {
        let source = try FileByteSource(url)
        defer { source.close() }
        let motion = try liveMotion.map { try FileByteSource($0) }
        defer { motion?.close() }
        return try importSource(source, metadata: metadata, liveMotion: motion, chunkSize: chunkSize)
    }

    public func importSource(
        _ source: any ByteSource,
        metadata: ImportMetadata,
        liveMotion: (any ByteSource)? = nil,
        chunkSize: Int = 1 << 20
    ) throws -> MediaItem {
        try requireUnlocked()
        let itemID = UUID()
        let blobName = itemID.uuidString + ".pmv1"
        guard VaultPaths.isSafeBlobName(blobName) else { throw VaultError.pathRejected }
        let originalStaging = stagingURL(blobName)
        var created: [URL] = []
        var journalWritten = false
        do {
            let written = try ChunkContainer.encrypt(
                source: source,
                to: originalStaging,
                masterKey: masterKey,
                chunkSize: chunkSize,
                quota: quota
            )
            if Int64(written.plaintextLength) > maximumImportBytes {
                shredFile(originalStaging)
                throw VaultError.limitExceeded
            }
            try hooks.didCreate(originalStaging)
            created.append(originalStaging)
            try interruption.after(.beforeJournal)

            var thumbnailName: String?
            if let thumbnail = metadata.thumbnail, !thumbnail.isEmpty {
                let name = UUID().uuidString + ".pmv1"
                let url = stagingURL(name, thumbs: true)
                _ = try ChunkContainer.encrypt(
                    source: DataByteSource(thumbnail),
                    to: url,
                    masterKey: masterKey,
                    chunkSize: chunkSize,
                    quota: quota
                )
                try hooks.didCreate(url)
                created.append(url)
                thumbnailName = name
            }

            var liveName: String?
            if let liveMotion {
                let name = UUID().uuidString + ".pmv1"
                let url = stagingURL(name)
                let motionWritten = try ChunkContainer.encrypt(
                    source: liveMotion,
                    to: url,
                    masterKey: masterKey,
                    chunkSize: chunkSize,
                    quota: quota
                )
                if Int64(motionWritten.plaintextLength) > maximumImportBytes {
                    throw VaultError.limitExceeded
                }
                try hooks.didCreate(url)
                created.append(url)
                liveName = name
            }

            let now = clock.now()
            var kind = metadata.mediaKind
            if liveName != nil { kind = .livePhoto }
            let item = MediaItem(
                id: itemID,
                originalFilename: metadata.originalFilename,
                mediaKind: kind,
                contentTypeIdentifier: metadata.contentTypeIdentifier,
                byteCount: Int64(written.plaintextLength),
                sha256Hex: hex(written.sha256),
                blobName: blobName,
                thumbnailBlobName: thumbnailName,
                liveVideoBlobName: liveName,
                createdAt: metadata.createdAt ?? now,
                importedAt: now,
                caption: metadata.caption,
                source: metadata.source,
                sourceURL: metadata.sourceURL
            )
            try writeJournal(Journal(schemaVersion: 1, pending: .init(phase: "blobReady", item: item)))
            journalWritten = true
            try interruption.after(.journalReady)
            try promote(item)
            catalog.items.append(item)
            try saveCatalog()
            try interruption.after(.catalogCommitted)
            try clearJournal()
            log.log("import committed")
            return item
        } catch VaultError.simulatedCrash {
            log.log("import interrupted")
            throw VaultError.simulatedCrash
        } catch {
            if journalWritten { try? clearJournal() }
            for url in created { shredFile(url) }
            log.log("import rolled back")
            throw error
        }
    }

    public func thumbnail(for id: UUID) throws -> Data? {
        try requireUnlocked()
        guard let item = catalog.items.first(where: { $0.id == id }) else { throw VaultError.notFound }
        guard let name = item.thumbnailBlobName else { return nil }
        let reader = try makeReader(finalURL(name, thumbs: true))
        defer { reader.close() }
        return try reader.plaintext(byteRange: 0 ..< reader.plaintextLength)
    }

    public func reader(for id: UUID) throws -> ChunkedReader {
        try requireUnlocked()
        guard let item = catalog.items.first(where: { $0.id == id }), item.trashedAt == nil else {
            throw VaultError.notFound
        }
        return try makeReader(finalURL(item.blobName, thumbs: false))
    }

    public func liveMotionReader(for id: UUID) throws -> ChunkedReader? {
        try requireUnlocked()
        guard let item = catalog.items.first(where: { $0.id == id }) else { throw VaultError.notFound }
        guard let name = item.liveVideoBlobName else { return nil }
        return try makeReader(finalURL(name, thumbs: false))
    }

    public func exportOriginal(_ id: UUID, to destination: URL) throws {
        try requireUnlocked()
        guard let item = catalog.items.first(where: { $0.id == id }) else { throw VaultError.notFound }
        if FileManager.default.fileExists(atPath: destination.path) { throw VaultError.alreadyExists }
        let partial = destination.appendingPathExtension("partial")
        if FileManager.default.fileExists(atPath: partial.path) { shredFile(partial) }
        let reader = try makeReader(finalURL(item.blobName, thumbs: false))
        defer { reader.close() }
        _ = FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        var hasher = SHA256()
        do {
            var offset = 0
            while offset < reader.plaintextLength {
                let end = min(reader.plaintextLength, offset + ChunkContainer.defaultChunkSize)
                let piece = try reader.plaintext(byteRange: offset ..< end)
                hasher.update(data: piece)
                try quota?.reserve(piece.count)
                try handle.write(contentsOf: piece)
                offset = end
            }
            try syncFile(handle)
            try handle.close()
            let digest = Data(hasher.finalize())
            guard hex(digest) == item.sha256Hex.lowercased() else {
                shredFile(partial)
                log.log("integrity failed")
                throw VaultError.integrityFailed
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            log.log("export wrote")
        } catch {
            try? handle.close()
            shredFile(partial)
            throw error
        }
    }

    public func exportAllOriginals(to directory: URL, includingTrash: Bool = true) throws -> [URL] {
        try requireUnlocked()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var used = Set<String>()
        var written: [URL] = []
        for item in catalog.items where includingTrash || item.trashedAt == nil {
            var name = SafeFileName.exportName(raw: item.originalFilename, id: item.id)
            if used.contains(name.lowercased()) {
                let suffix = item.id.uuidString.prefix(8)
                let ext = (name as NSString).pathExtension
                let base = (name as NSString).deletingPathExtension
                name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            }
            used.insert(name.lowercased())
            let destination = directory.appendingPathComponent(name)
            let resolved = destination.standardizedFileURL
            let root = directory.standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") || resolved.path == root.path else {
                throw VaultError.pathRejected
            }
            try exportOriginal(item.id, to: destination)
            written.append(destination)
            if item.liveVideoBlobName != nil {
                let motionName = "\(item.id.uuidString)-motion.mov"
                let motionURL = directory.appendingPathComponent(motionName)
                try exportBlob(named: item.liveVideoBlobName ?? "", to: motionURL, expectedSHA256: nil)
                written.append(motionURL)
            }
        }
        return written
    }

    private func exportBlob(named name: String, to destination: URL, expectedSHA256: String?) throws {
        if FileManager.default.fileExists(atPath: destination.path) { throw VaultError.alreadyExists }
        let partial = destination.appendingPathExtension("partial")
        let reader = try makeReader(finalURL(name, thumbs: false))
        defer { reader.close() }
        _ = FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        var hasher = SHA256()
        do {
            var offset = 0
            while offset < reader.plaintextLength {
                let end = min(reader.plaintextLength, offset + (1 << 20))
                let piece = try reader.plaintext(byteRange: offset ..< end)
                hasher.update(data: piece)
                try handle.write(contentsOf: piece)
                offset = end
            }
            try syncFile(handle)
            try handle.close()
            if let expectedSHA256, hex(Data(hasher.finalize())) != expectedSHA256.lowercased() {
                shredFile(partial)
                throw VaultError.integrityFailed
            }
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? handle.close()
            shredFile(partial)
            throw error
        }
    }

    public func verifyIntegrity(_ id: UUID) throws {
        try requireUnlocked()
        guard let item = catalog.items.first(where: { $0.id == id }) else { throw VaultError.notFound }
        let reader = try makeReader(finalURL(item.blobName, thumbs: false))
        defer { reader.close() }
        let digest = try reader.sha256()
        guard hex(digest) == item.sha256Hex.lowercased() else {
            log.log("integrity failed")
            throw VaultError.integrityFailed
        }
        if let thumb = item.thumbnailBlobName {
            let thumbReader = try makeReader(finalURL(thumb, thumbs: true))
            defer { thumbReader.close() }
            _ = try thumbReader.plaintext(byteRange: 0 ..< thumbReader.plaintextLength)
        }
        if let live = item.liveVideoBlobName {
            let liveReader = try makeReader(finalURL(live, thumbs: false))
            defer { liveReader.close() }
            _ = try liveReader.sha256()
        }
    }

    public func setFavorite(_ ids: [UUID], _ favorite: Bool) throws {
        try requireUnlocked()
        try mutate(ids) { $0.favorite = favorite }
    }

    public func trash(_ ids: [UUID]) throws {
        try requireUnlocked()
        let now = clock.now()
        try mutate(ids) { item in
            if item.trashedAt == nil { item.trashedAt = now }
        }
    }

    public func restoreFromTrash(_ ids: [UUID]) throws {
        try requireUnlocked()
        try mutate(ids) { $0.trashedAt = nil }
    }

    public func purgeTrash(ids: [UUID]? = nil) throws {
        try requireUnlocked()
        let targets = catalog.items.filter { item in
            guard item.trashedAt != nil else { return false }
            if let ids { return ids.contains(item.id) }
            return true
        }
        let doomed = Set(targets.map(\.id))
        guard !doomed.isEmpty else { return }
        catalog.items.removeAll { doomed.contains($0.id) }
        for index in catalog.playlists.indices {
            catalog.playlists[index].itemIDs.removeAll { doomed.contains($0) }
        }
        try saveCatalog()
        try deleteUnreferenced()
    }

    public func purgeExpiredTrash() throws {
        try requireUnlocked()
        guard let days = catalog.trashRetentionDays else { return }
        let limit = TimeInterval(days * 24 * 60 * 60)
        let now = clock.now()
        let expired = catalog.items.filter { item in
            guard let trashedAt = item.trashedAt else { return false }
            return now.timeIntervalSince(trashedAt) >= limit
        }.map(\.id)
        if !expired.isEmpty { try purgeTrash(ids: expired) }
    }

    public func createAlbum(name: String) throws -> Album {
        try requireUnlocked()
        let trimmed = try Self.validateName(name)
        let album = Album(name: trimmed, createdAt: clock.now())
        catalog.albums.append(album)
        try saveCatalog()
        return album
    }

    public func renameAlbum(_ id: UUID, name: String) throws {
        try requireUnlocked()
        let trimmed = try Self.validateName(name)
        guard let index = catalog.albums.firstIndex(where: { $0.id == id }) else { throw VaultError.notFound }
        catalog.albums[index].name = trimmed
        try saveCatalog()
    }

    public func deleteAlbum(_ id: UUID) throws {
        try requireUnlocked()
        catalog.albums.removeAll { $0.id == id }
        for index in catalog.items.indices {
            catalog.items[index].albumIDs.removeAll { $0 == id }
        }
        try saveCatalog()
    }

    public func add(_ ids: [UUID], to albumID: UUID) throws {
        try requireUnlocked()
        guard catalog.albums.contains(where: { $0.id == albumID }) else { throw VaultError.notFound }
        try mutate(ids) { item in
            if !item.albumIDs.contains(albumID) { item.albumIDs.append(albumID) }
        }
    }

    public func remove(_ ids: [UUID], from albumID: UUID) throws {
        try requireUnlocked()
        try mutate(ids) { item in
            item.albumIDs.removeAll { $0 == albumID }
        }
    }

    public func search(_ query: String, limit: Int = 200) throws -> [MediaItem] {
        try requireUnlocked()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let capped = min(max(limit, 1), 200)
        let albumsByID = Dictionary(uniqueKeysWithValues: catalog.albums.map { ($0.id, $0.name) })
        let matches = catalog.items.filter { item in
            guard item.trashedAt == nil else { return false }
            if item.originalFilename.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return true
            }
            if item.caption.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return true
            }
            return item.albumIDs.contains { id in
                (albumsByID[id] ?? "").range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        return Array(matches.prefix(capped))
    }

    public func createPlaylist(name: String, itemIDs: [UUID]) throws -> Playlist {
        try requireUnlocked()
        let trimmed = try Self.validateName(name)
        let known = Set(catalog.items.map(\.id))
        let playlist = Playlist(name: trimmed, itemIDs: itemIDs.filter { known.contains($0) }, createdAt: clock.now())
        catalog.playlists.append(playlist)
        try saveCatalog()
        return playlist
    }

    public func setResume(id: UUID, seconds: Double, duration: Double?) throws {
        try requireUnlocked()
        guard seconds.isFinite, seconds >= 0 else { throw VaultError.invalidName }
        try mutate([id]) { item in
            item.resumeSeconds = seconds
            if let duration, duration.isFinite, duration >= 0 {
                item.playbackDurationSeconds = duration
            }
        }
    }

    public func createBackup(to destination: URL) throws -> RecoveryKey {
        try requireUnlocked()
        let key = try BackupArchive.create(
            vaultDirectory: directory,
            masterKey: masterKey,
            to: destination,
            quota: quota
        )
        log.log("backup wrote")
        return key
    }

    public static func restoreBackup(from backup: URL, recoveryKey: RecoveryKey, to vaultDirectory: URL) throws -> MasterKey {
        if FileManager.default.fileExists(atPath: vaultDirectory.path) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: vaultDirectory.path)
            if !contents.isEmpty { throw VaultError.alreadyExists }
        }
        return try BackupArchive.restore(from: backup, recoveryKey: recoveryKey, to: vaultDirectory)
    }

    public static func replaceVault(from backup: URL, recoveryKey: RecoveryKey, vaultDirectory: URL) throws -> MasterKey {
        let parent = vaultDirectory.deletingLastPathComponent()
        let token = UUID().uuidString
        let staging = parent.appendingPathComponent(".\(vaultDirectory.lastPathComponent).restore-\(token)")
        let previous = parent.appendingPathComponent("\(vaultDirectory.lastPathComponent).previous")
        if FileManager.default.fileExists(atPath: previous.path) {
            throw VaultError.previousVaultExists
        }
        let key = try BackupArchive.restore(from: backup, recoveryKey: recoveryKey, to: staging)
        let currentExists = FileManager.default.fileExists(atPath: vaultDirectory.path)
        if currentExists {
            try FileManager.default.moveItem(at: vaultDirectory, to: previous)
        }
        do {
            try FileManager.default.moveItem(at: staging, to: vaultDirectory)
        } catch {
            if currentExists {
                try? FileManager.default.moveItem(at: previous, to: vaultDirectory)
            }
            shredTree(staging)
            throw error
        }
        return key
    }

    public func testing_writeCatalogPlaintext(_ json: Data) throws {
        try requireUnlocked()
        try SealedJSONFile.write(
            magic: "PMVC",
            info: "pmv-catalog-v1",
            plaintext: json,
            key: masterKey,
            to: Self.catalogURL(directory),
            quota: nil
        )
    }

    public func testing_catalogCiphertext() throws -> Data {
        try requireUnlocked()
        return try Data(contentsOf: Self.catalogURL(directory))
    }

    public func testing_setStoredSHA256(id: UUID, hex: String) throws {
        try requireUnlocked()
        guard let index = catalog.items.firstIndex(where: { $0.id == id }) else { throw VaultError.notFound }
        catalog.items[index].sha256Hex = hex
        try saveCatalog()
    }

    public func testing_blobURL(_ id: UUID) throws -> URL {
        try requireUnlocked()
        guard let item = catalog.items.first(where: { $0.id == id }) else { throw VaultError.notFound }
        return finalURL(item.blobName, thumbs: false)
    }

    private func recoverIfNeeded() throws {
        guard !didRecover else { return }
        didRecover = true
        let journal = try loadJournal()
        if let pending = journal?.pending {
            guard pending.phase == "blobReady" else { throw VaultError.journalCorrupt }
            if catalog.items.contains(where: { $0.id == pending.item.id }) {
                try deleteStagingCopies(pending.item)
                try clearJournal()
            } else if stagedOrFinalExists(pending.item) {
                try promote(pending.item)
                catalog.items.append(pending.item)
                try saveCatalog()
                try clearJournal()
                log.log("import recovered")
            } else {
                try deleteStagingCopies(pending.item)
                try clearJournal()
                log.log("import discarded")
            }
        }
        try deleteUnreferenced()
        try purgeExpiredTrash()
    }

    private func stagedOrFinalExists(_ item: MediaItem) -> Bool {
        for (name, thumbs) in blobLocations(item) {
            if FileManager.default.fileExists(atPath: stagingURL(name, thumbs: thumbs).path) { continue }
            if FileManager.default.fileExists(atPath: finalURL(name, thumbs: thumbs).path) { continue }
            return false
        }
        return true
    }

    private func promote(_ item: MediaItem) throws {
        for (name, thumbs) in blobLocations(item) {
            let staging = stagingURL(name, thumbs: thumbs)
            let final = finalURL(name, thumbs: thumbs)
            if FileManager.default.fileExists(atPath: staging.path) {
                if FileManager.default.fileExists(atPath: final.path) {
                    shredFile(staging)
                } else {
                    try FileManager.default.moveItem(at: staging, to: final)
                    try hooks.didCreate(final)
                }
            } else if !FileManager.default.fileExists(atPath: final.path) {
                throw VaultError.interrupted
            }
        }
    }

    private func deleteStagingCopies(_ item: MediaItem) throws {
        for (name, thumbs) in blobLocations(item) {
            shredFile(stagingURL(name, thumbs: thumbs))
        }
    }

    private func blobLocations(_ item: MediaItem) -> [(String, Bool)] {
        var locations: [(String, Bool)] = [(item.blobName, false)]
        if let thumb = item.thumbnailBlobName { locations.append((thumb, true)) }
        if let live = item.liveVideoBlobName { locations.append((live, false)) }
        return locations
    }

    private func deleteUnreferenced() throws {
        let referencedBlobs = Set(catalog.items.map(\.blobName) + catalog.items.compactMap(\.liveVideoBlobName))
        let referencedThumbs = Set(catalog.items.compactMap(\.thumbnailBlobName))
        try deleteUnreferenced(in: blobDirectory(), referenced: referencedBlobs)
        try deleteUnreferenced(in: thumbDirectory(), referenced: referencedThumbs)
        let staging = directory.appendingPathComponent(VaultPaths.stagingDirectory, isDirectory: true)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: staging.path) {
            for name in names where name != "." && name != ".." {
                shredFile(staging.appendingPathComponent(name))
            }
        }
    }

    private func deleteUnreferenced(in directory: URL, referenced: Set<String>) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for name in names where !referenced.contains(name) {
            shredFile(directory.appendingPathComponent(name))
        }
    }

    private func mutate(_ ids: [UUID], _ body: (inout MediaItem) -> Void) throws {
        let wanted = Set(ids)
        var seen = Set<UUID>()
        for index in catalog.items.indices where wanted.contains(catalog.items[index].id) {
            body(&catalog.items[index])
            seen.insert(catalog.items[index].id)
        }
        guard seen.count == wanted.count else { throw VaultError.notFound }
        try saveCatalog()
    }

    private func makeReader(_ url: URL) throws -> ChunkedReader {
        openReaders.removeAll { $0.isClosed }
        let reader = try ChunkedReader(url: url, masterKey: masterKey)
        openReaders.append(reader)
        return reader
    }

    private func saveCatalog() throws {
        try Self.persist(catalog, directory: directory, key: masterKey, quota: quota, hooks: hooks)
    }

    private func writeJournal(_ journal: Journal) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(journal)
        try SealedJSONFile.write(
            magic: "PMVJ",
            info: "pmv-journal-v1",
            plaintext: data,
            key: masterKey,
            to: Self.journalURL(directory),
            quota: quota
        )
        try hooks.didCreate(Self.journalURL(directory))
    }

    private func loadJournal() throws -> Journal? {
        let url = Self.journalURL(directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try SealedJSONFile.read(magic: "PMVJ", info: "pmv-journal-v1", from: url, key: masterKey)
        } catch VaultError.notFound {
            return nil
        } catch VaultError.authenticationFailed, VaultError.malformed, VaultError.truncated, VaultError.unsupportedVersion {
            throw VaultError.journalCorrupt
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let journal = try? decoder.decode(Journal.self, from: data) else {
            throw VaultError.journalCorrupt
        }
        return journal
    }

    private func clearJournal() throws {
        let url = Self.journalURL(directory)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func requireUnlocked() throws {
        if isLocked || masterKey.isWiped { throw VaultError.locked }
    }

    private func stagingURL(_ name: String, thumbs: Bool = false) -> URL {
        directory
            .appendingPathComponent(VaultPaths.stagingDirectory, isDirectory: true)
            .appendingPathComponent((thumbs ? "thumb-" : "blob-") + name)
    }

    private func finalURL(_ name: String, thumbs: Bool) -> URL {
        (thumbs ? thumbDirectory() : blobDirectory()).appendingPathComponent(name)
    }

    private func blobDirectory() -> URL {
        directory.appendingPathComponent(VaultPaths.blobDirectory, isDirectory: true)
    }

    private func thumbDirectory() -> URL {
        directory.appendingPathComponent(VaultPaths.thumbDirectory, isDirectory: true)
    }

    private static func catalogURL(_ directory: URL) -> URL {
        directory.appendingPathComponent(VaultPaths.catalogName)
    }

    private static func journalURL(_ directory: URL) -> URL {
        directory.appendingPathComponent(VaultPaths.journalName)
    }

    private static func prepareDirectories(_ directory: URL, hooks: VaultFileHooks) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try hooks.didCreate(directory)
        for name in [VaultPaths.blobDirectory, VaultPaths.thumbDirectory, VaultPaths.stagingDirectory] {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            try hooks.didCreate(url)
        }
    }

    private static func readCatalog(directory: URL, key: MasterKey) throws -> Data {
        do {
            return try SealedJSONFile.read(
                magic: "PMVC",
                info: "pmv-catalog-v1",
                from: catalogURL(directory),
                key: key
            )
        } catch VaultError.authenticationFailed, VaultError.malformed, VaultError.truncated, VaultError.unsupportedVersion {
            throw VaultError.catalogCorrupt
        }
    }

    private static func persist(_ catalog: Catalog, directory: URL, key: MasterKey, quota: ByteQuota?, hooks: VaultFileHooks) throws {
        let data = try CatalogCoding.data(from: catalog)
        try SealedJSONFile.write(
            magic: "PMVC",
            info: "pmv-catalog-v1",
            plaintext: data,
            key: key,
            to: catalogURL(directory),
            quota: quota
        )
        try hooks.didCreate(catalogURL(directory))
    }

    private static func schemaVersion(in json: Data) throws -> Int {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw VaultError.catalogCorrupt
        }
        if let number = object["schemaVersion"] as? NSNumber { return number.intValue }
        if let version = object["schemaVersion"] as? Int { return version }
        throw VaultError.catalogCorrupt
    }

    private static func validateName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { throw VaultError.invalidName }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.newlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }) else {
            throw VaultError.invalidName
        }
        return trimmed
    }
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

public func shredTree(_ url: URL) {
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
        shredFile(url)
        return
    }
    var files: [URL] = []
    for case let file as URL in enumerator {
        files.append(file)
    }
    for file in files.reversed() {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            shredFile(file)
        }
    }
    try? FileManager.default.removeItem(at: url)
}
