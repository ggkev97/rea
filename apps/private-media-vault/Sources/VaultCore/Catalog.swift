import Crypto
import Foundation

public enum MediaKind: String, Codable, Equatable, CaseIterable {
    case image
    case video
    case livePhoto
    case other
}

public enum ImportSource: String, Codable, Equatable {
    case photosPicker
    case files
    case camera
    case openIn
    case link
    case shareInbox
}

public enum LibrarySort: String, Codable, Equatable {
    case newest
    case oldest
    case name
    case largest
}

public struct MediaItem: Codable, Equatable, Identifiable {
    public var id: UUID
    public var originalFilename: String
    public var mediaKind: MediaKind
    public var contentTypeIdentifier: String
    public var byteCount: Int64
    public var sha256Hex: String
    public var blobName: String
    public var thumbnailBlobName: String?
    public var liveVideoBlobName: String?
    public var createdAt: Date
    public var importedAt: Date
    public var favorite: Bool
    public var albumIDs: [UUID]
    public var caption: String
    public var source: ImportSource
    public var sourceURL: String?
    public var trashedAt: Date?
    public var resumeSeconds: Double?
    public var playbackDurationSeconds: Double?

    public init(
        id: UUID = UUID(),
        originalFilename: String,
        mediaKind: MediaKind,
        contentTypeIdentifier: String,
        byteCount: Int64,
        sha256Hex: String,
        blobName: String,
        thumbnailBlobName: String? = nil,
        liveVideoBlobName: String? = nil,
        createdAt: Date,
        importedAt: Date,
        favorite: Bool = false,
        albumIDs: [UUID] = [],
        caption: String = "",
        source: ImportSource,
        sourceURL: String? = nil,
        trashedAt: Date? = nil,
        resumeSeconds: Double? = nil,
        playbackDurationSeconds: Double? = nil
    ) {
        self.id = id
        self.originalFilename = originalFilename
        self.mediaKind = mediaKind
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.sha256Hex = sha256Hex
        self.blobName = blobName
        self.thumbnailBlobName = thumbnailBlobName
        self.liveVideoBlobName = liveVideoBlobName
        self.createdAt = createdAt
        self.importedAt = importedAt
        self.favorite = favorite
        self.albumIDs = albumIDs
        self.caption = caption
        self.source = source
        self.sourceURL = sourceURL
        self.trashedAt = trashedAt
        self.resumeSeconds = resumeSeconds
        self.playbackDurationSeconds = playbackDurationSeconds
    }

    enum CodingKeys: String, CodingKey {
        case id, originalFilename, mediaKind, contentTypeIdentifier, byteCount, sha256Hex
        case blobName, thumbnailBlobName, liveVideoBlobName, createdAt, importedAt, favorite
        case albumIDs, caption, source, sourceURL, trashedAt, resumeSeconds, playbackDurationSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        originalFilename = try container.decode(String.self, forKey: .originalFilename)
        mediaKind = try container.decode(MediaKind.self, forKey: .mediaKind)
        contentTypeIdentifier = try container.decodeIfPresent(String.self, forKey: .contentTypeIdentifier) ?? "public.data"
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        sha256Hex = try container.decode(String.self, forKey: .sha256Hex)
        blobName = try container.decode(String.self, forKey: .blobName)
        thumbnailBlobName = try container.decodeIfPresent(String.self, forKey: .thumbnailBlobName)
        liveVideoBlobName = try container.decodeIfPresent(String.self, forKey: .liveVideoBlobName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        albumIDs = try container.decodeIfPresent([UUID].self, forKey: .albumIDs) ?? []
        caption = try container.decodeIfPresent(String.self, forKey: .caption) ?? ""
        source = try container.decode(ImportSource.self, forKey: .source)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        trashedAt = try container.decodeIfPresent(Date.self, forKey: .trashedAt)
        resumeSeconds = try container.decodeIfPresent(Double.self, forKey: .resumeSeconds)
        playbackDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .playbackDurationSeconds)
    }
}

public struct Album: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

public struct Playlist: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var itemIDs: [UUID]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, itemIDs: [UUID], createdAt: Date) {
        self.id = id
        self.name = name
        self.itemIDs = itemIDs
        self.createdAt = createdAt
    }
}

public struct Catalog: Codable, Equatable {
    public static let currentSchema = 2

    public var schemaVersion: Int
    public var items: [MediaItem]
    public var albums: [Album]
    public var playlists: [Playlist]
    public var trashRetentionDays: Int?
    public var sort: LibrarySort

    public init(
        schemaVersion: Int = Catalog.currentSchema,
        items: [MediaItem] = [],
        albums: [Album] = [],
        playlists: [Playlist] = [],
        trashRetentionDays: Int? = 30,
        sort: LibrarySort = .newest
    ) {
        self.schemaVersion = schemaVersion
        self.items = items
        self.albums = albums
        self.playlists = playlists
        self.trashRetentionDays = trashRetentionDays
        self.sort = sort
    }
}

public enum CatalogMigrator {
    public static func catalog(from json: Data) throws -> Catalog {
        guard var object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw VaultError.catalogCorrupt
        }
        let version: Int
        if let number = object["schemaVersion"] as? NSNumber {
            version = number.intValue
        } else if let int = object["schemaVersion"] as? Int {
            version = int
        } else {
            throw VaultError.unsupportedVersion(-1)
        }
        guard version >= 1 else { throw VaultError.unsupportedVersion(version) }
        guard version <= Catalog.currentSchema else { throw VaultError.unsupportedVersion(version) }
        if version < 2 {
            object["schemaVersion"] = Catalog.currentSchema
            if object["playlists"] == nil { object["playlists"] = [] }
            if object["trashRetentionDays"] == nil { object["trashRetentionDays"] = 30 }
            if object["sort"] == nil { object["sort"] = LibrarySort.newest.rawValue }
        }
        let normalized = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(Catalog.self, from: normalized)
        } catch {
            throw VaultError.catalogCorrupt
        }
    }
}

enum CatalogCoding {
    static func data(from catalog: Catalog) throws -> Data {
        var copy = catalog
        copy.schemaVersion = Catalog.currentSchema
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(copy)
    }
}

enum SealedJSONFile {
    static func write(magic: String, info: String, plaintext: Data, key: MasterKey, to url: URL, quota: ByteQuota?) throws {
        let salt = randomBytes(count: 32)
        let derived = try key.withSymmetricKey { ikm in
            try CryptoBox.derive(ikm: ikm, salt: salt, info: info)
        }
        var aad = Data(magic.utf8)
        aad.append(salt)
        let sealed = try CryptoBox.seal(plaintext, key: derived, aad: aad)
        var blob = Data(magic.utf8)
        Binary.append(UInt16(1), to: &blob)
        blob.append(salt)
        blob.append(sealed.nonce)
        Binary.append(UInt32(sealed.ciphertext.count), to: &blob)
        blob.append(sealed.ciphertext)
        blob.append(sealed.tag)
        try quota?.reserve(blob.count)
        let temporary = url.appendingPathExtension("tmp")
        try blob.write(to: temporary, options: .atomic)
        let handle = try FileHandle(forWritingTo: temporary)
        try syncFile(handle)
        try handle.close()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    static func read(magic: String, info: String, from url: URL, key: MasterKey) throws -> Data {
        let blob: Data
        do {
            blob = try Data(contentsOf: url)
        } catch {
            throw VaultError.notFound
        }
        guard blob.count >= 4 + 2 + 32 + 12 + 4 + 16 else { throw VaultError.truncated }
        guard blob.prefix(4) == Data(magic.utf8) else { throw VaultError.malformed }
        var offset = 4
        let version = try Binary.readUInt16(blob, &offset)
        guard version == 1 else { throw VaultError.unsupportedVersion(Int(version)) }
        let salt = blob.subdata(in: offset ..< offset + 32)
        offset += 32
        let nonce = blob.subdata(in: offset ..< offset + 12)
        offset += 12
        let cipherLength = Int(try Binary.readUInt32(blob, &offset))
        guard cipherLength >= 0, offset + cipherLength + 16 == blob.count else { throw VaultError.malformed }
        let cipher = blob.subdata(in: offset ..< offset + cipherLength)
        offset += cipherLength
        let tag = blob.subdata(in: offset ..< offset + 16)
        let derived = try key.withSymmetricKey { ikm in
            try CryptoBox.derive(ikm: ikm, salt: salt, info: info)
        }
        var aad = Data(magic.utf8)
        aad.append(salt)
        do {
            return try CryptoBox.open(ciphertext: cipher, tag: tag, nonce: nonce, key: derived, aad: aad)
        } catch {
            throw VaultError.authenticationFailed
        }
    }
}

public enum SafeFileName {
    public static func exportName(raw: String, id: UUID) -> String {
        let filtered = raw.unicodeScalars.filter { scalar in
            scalar != "/" && scalar != "\\" && !CharacterSet.controlCharacters.contains(scalar)
        }
        var name = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix(".") { name = String(name.drop { $0 == "." }) }
        if name.isEmpty || name == "." || name == ".." { name = id.uuidString }
        if name.count > 120 { name = String(name.prefix(120)) }
        return name
    }
}

struct Journal: Codable, Equatable {
    var schemaVersion: Int
    var pending: PendingImport?

    struct PendingImport: Codable, Equatable {
        var phase: String
        var item: MediaItem
    }
}

enum VaultPaths {
    static let catalogName = "catalog.pmvc"
    static let journalName = "journal.pmvj"
    static let blobDirectory = "blobs"
    static let thumbDirectory = "thumbs"
    static let stagingDirectory = "staging"

    static func isSafeBlobName(_ name: String) -> Bool {
        guard let match = name.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.pmv1$"#, options: .regularExpression) else {
            return false
        }
        return match.lowerBound == name.startIndex && match.upperBound == name.endIndex
    }
}
