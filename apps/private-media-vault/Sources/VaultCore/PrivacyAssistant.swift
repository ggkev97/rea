import Crypto
import Foundation

public enum AutoLock: Equatable {
    case immediate
    case after(TimeInterval)
    case manual
}

public struct LockConfiguration: Equatable {
    public var autoLock: AutoLock
    public init(autoLock: AutoLock = .immediate) { self.autoLock = autoLock }
}

public enum PrivacyEvent: Equatable {
    case becameActive(Date)
    case resignedActive
    case enteredBackground(Date)
    case manualLock
    case didUnlock
    case tick(Date)
}

public struct PrivacyDecision: Equatable {
    public var coverVisible: Bool
    public var shouldLock: Bool
    public var shouldClearCaches: Bool
}

public struct PrivacyCoordinator {
    public var configuration: LockConfiguration
    public private(set) var coverVisible = false
    public private(set) var unlocked = false
    private var lockDeadline: Date?

    public init(configuration: LockConfiguration = LockConfiguration()) {
        self.configuration = configuration
    }

    public mutating func handle(_ event: PrivacyEvent) -> PrivacyDecision {
        switch event {
        case .resignedActive:
            coverVisible = true
        case .enteredBackground(let date):
            coverVisible = true
            switch configuration.autoLock {
            case .immediate:
                return lockNow()
            case .after(let interval):
                lockDeadline = date.addingTimeInterval(interval)
            case .manual:
                lockDeadline = nil
            }
        case .becameActive(let date):
            if let lockDeadline, date >= lockDeadline {
                return lockNow()
            }
            if unlocked { coverVisible = false }
        case .manualLock:
            return lockNow()
        case .didUnlock:
            unlocked = true
            coverVisible = false
            lockDeadline = nil
        case .tick(let now):
            if let lockDeadline, now >= lockDeadline {
                return lockNow()
            }
        }
        return PrivacyDecision(coverVisible: coverVisible, shouldLock: false, shouldClearCaches: false)
    }

    private mutating func lockNow() -> PrivacyDecision {
        unlocked = false
        coverVisible = true
        lockDeadline = nil
        return PrivacyDecision(coverVisible: true, shouldLock: true, shouldClearCaches: true)
    }
}

public struct PlaybackQueue: Equatable {
    public var itemIDs: [UUID]
    public var index: Int
    public var continuous: Bool

    public init(itemIDs: [UUID], index: Int = 0, continuous: Bool = true) {
        self.itemIDs = itemIDs
        self.index = index
        self.continuous = continuous
    }

    public var current: UUID? {
        guard itemIDs.indices.contains(index) else { return nil }
        return itemIDs[index]
    }

    public mutating func advance() -> UUID? {
        guard continuous else { return nil }
        let next = index + 1
        guard itemIDs.indices.contains(next) else { return nil }
        index = next
        return itemIDs[index]
    }
}

public struct LoopbackPlan: Equatable {
    public var host: String
    public var port: UInt16

    public static func loopback(port: UInt16 = 0) -> LoopbackPlan {
        LoopbackPlan(host: "127.0.0.1", port: port)
    }

    public static func validate(host: String) throws {
        guard host == "127.0.0.1" else { throw VaultError.pathRejected }
    }
}

public enum AssistantDenial: String, Equatable, Error {
    case sessionDisabled
    case expired
    case badToken
    case revoked
    case forbidden
    case locked
    case vaultNotRunning
}

public struct AlbumSummary: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var count: Int
}

public struct MetadataMatch: Codable, Equatable {
    public var id: UUID
    public var filename: String
    public var caption: String
    public var albumNames: [String]
}

public struct AssistantPayload: Codable, Equatable {
    public var kind: String
    public var locked: Bool?
    public var sessionEnabled: Bool?
    public var albums: [AlbumSummary]?
    public var matches: [MetadataMatch]?
}

public enum AssistantRequest: Equatable {
    case status
    case listAlbums
    case searchMetadata(String)
}

public struct AssistantSession: Equatable {
    public var enabled: Bool
    public private(set) var tokenHash: Data?
    public var expiresAt: Date?
    public private(set) var revoked = false

    public init() {
        enabled = false
    }

    public static func tokenHash(for token: String) -> Data {
        CryptoBox.sha256(Data(token.utf8))
    }

    public mutating func enable(now: Date, lifetime: TimeInterval) -> String {
        let token = RecoveryKeyCodec.grouped(RecoveryKeyCodec.encode([UInt8](randomBytes(count: 32))))
        tokenHash = Self.tokenHash(for: token)
        enabled = true
        revoked = false
        expiresAt = now.addingTimeInterval(lifetime)
        return token
    }

    public mutating func revoke() {
        enabled = false
        tokenHash = nil
        expiresAt = nil
        revoked = true
    }

    public func authorize(token: String, now: Date) -> AssistantDenial? {
        guard enabled, let tokenHash else {
            return revoked ? .revoked : .sessionDisabled
        }
        if let expiresAt, now >= expiresAt { return .expired }
        let presented = Self.tokenHash(for: token)
        guard SecretCompare.equal(presented, tokenHash) else { return .badToken }
        return nil
    }
}

public enum AssistantCommands {
    public static let forbidden: Set<String> = [
        "unlock", "delete", "export", "purge", "media", "blob", "thumbnail", "recover", "backup", "restore",
    ]

    public static func request(command: String, query: String?) -> Result<AssistantRequest, AssistantDenial> {
        let name = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if forbidden.contains(name) { return .failure(.forbidden) }
        switch name {
        case "status":
            return .success(.status)
        case "albums":
            return .success(.listAlbums)
        case "search":
            let text = query ?? ""
            guard !text.isEmpty, text.count <= 200 else { return .failure(.forbidden) }
            return .success(.searchMetadata(text))
        default:
            return .failure(.forbidden)
        }
    }
}

public enum AssistantHTTP {
    public static func respond(
        raw: String,
        session: AssistantSession,
        now: Date,
        vaultLocked: Bool,
        perform: (AssistantRequest) throws -> AssistantPayload
    ) -> String {
        guard raw.utf8.count <= 16 * 1024 else {
            return status(413, body: #"{"error":"too large"}"#)
        }
        guard let request = parse(raw) else {
            return status(400, body: #"{"error":"bad request"}"#)
        }
        if isForbiddenPath(request.path) {
            return status(403, body: #"{"error":"forbidden"}"#)
        }
        guard let token = bearer(request.headers) else {
            return status(401, body: #"{"error":"token required"}"#)
        }
        if let denial = session.authorize(token: token, now: now) {
            return status(401, body: #"{"error":"\#(denial.rawValue)"}"#)
        }
        if vaultLocked {
            return status(423, body: #"{"error":"locked"}"#)
        }
        let command: String
        let query: String?
        switch request.path {
        case "/v1/status":
            command = "status"
            query = nil
        case "/v1/albums":
            command = "albums"
            query = nil
        case "/v1/search":
            command = "search"
            query = request.bodyQuery
        default:
            return status(403, body: #"{"error":"forbidden"}"#)
        }
        switch AssistantCommands.request(command: command, query: query) {
        case .failure:
            return status(403, body: #"{"error":"forbidden"}"#)
        case .success(let assistantRequest):
            do {
                let payload = try perform(assistantRequest)
                let data = try JSONEncoder().encode(payload)
                return status(200, body: String(decoding: data, as: UTF8.self))
            } catch {
                return status(400, body: #"{"error":"rejected"}"#)
            }
        }
    }

    private struct Parsed {
        var path: String
        var headers: [String: String]
        var bodyQuery: String?
    }

    private static func parse(_ raw: String) -> Parsed? {
        let parts = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        guard let head = parts.first else { return nil }
        let lines = head.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.first?.split(separator: " "), start.count >= 2 else { return nil }
        let path = String(start[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.contains(":") {
            let pieces = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pieces.count == 2 { headers[pieces[0].lowercased()] = pieces[1] }
        }
        let body = parts.count > 1 ? parts.dropFirst().joined(separator: "\n\n") : ""
        var query: String?
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = object["query"] as? String {
            query = text
        }
        return Parsed(path: path, headers: headers, bodyQuery: query)
    }

    private static func bearer(_ headers: [String: String]) -> String? {
        guard let value = headers["authorization"] else { return nil }
        let prefix = "Bearer "
        guard value.hasPrefix(prefix) else { return nil }
        let token = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    private static func isForbiddenPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        let blocked = ["/v1/unlock", "/v1/delete", "/v1/export", "/v1/media", "/v1/blob", "/v1/purge", "/v1/restore", "/v1/backup"]
        return blocked.contains { lowered == $0 || lowered.hasPrefix($0 + "/") }
    }

    private static func status(_ code: Int, body: String) -> String {
        let reason: String
        switch code {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 413: reason = "Payload Too Large"
        case 423: reason = "Locked"
        default: reason = "Error"
        }
        let length = Data(body.utf8).count
        return "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n\(body)"
    }
}

public enum LinkReject: String, Equatable, Error {
    case notHTTPS
    case userInfo
    case unsupportedHost
    case htmlOrDocument
    case unsupportedType
    case tooLarge
    case insecureRedirect
    case tooManyRedirects
    case unrecognizedBytes
}

public enum LinkImportPolicy {
    public static let allowedTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/heic", "image/heif", "image/webp",
        "video/mp4", "video/quicktime",
    ]

    public static func validate(url: URL) -> Result<URL, LinkReject> {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return .failure(.notHTTPS) }
        if url.user != nil || url.password != nil { return .failure(.userInfo) }
        guard let host = url.host, !host.isEmpty, host != "localhost", host != "127.0.0.1" else {
            return .failure(.unsupportedHost)
        }
        return .success(url)
    }

    public static func validate(contentType: String?, byteCount: Int64?, maxBytes: Int64, redirectCount: Int) -> Result<Void, LinkReject> {
        if redirectCount > 5 { return .failure(.tooManyRedirects) }
        if let byteCount, byteCount > maxBytes { return .failure(.tooLarge) }
        let type = contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if let type {
            if type.hasPrefix("text/") || type == "application/xhtml+xml" || type == "text/html" {
                return .failure(.htmlOrDocument)
            }
            if type != "application/octet-stream" && !allowedTypes.contains(type) {
                return .failure(.unsupportedType)
            }
        }
        return .success(())
    }

    public static func sniff(_ prefix: Data) -> MediaKind? {
        if prefix.starts(with: [0xff, 0xd8, 0xff]) { return .image }
        if prefix.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return .image }
        if prefix.starts(with: Data("GIF8".utf8)) { return .image }
        if prefix.count >= 12, prefix.subdata(in: 4 ..< 8) == Data("ftyp".utf8) {
            let brand = String(data: prefix.subdata(in: 8 ..< min(prefix.count, 12)), encoding: .ascii) ?? ""
            if brand.hasPrefix("qt") { return .video }
            return .video
        }
        return nil
    }
}

public enum MediaSupportMatrix {
    public enum Level: String, Equatable {
        case originalStoredAndOpened
        case stillPlusSeparateMotion
        case rejected
    }

    public static func level(for kind: String) -> Level {
        switch kind {
        case "jpeg", "png", "gif", "heic", "webp", "mp4", "quicktime":
            return .originalStoredAndOpened
        case "livePhotoPair":
            return .stillPlusSeparateMotion
        case "livePhotoSystemPlayback", "cameraRaw", "drm", "pdf":
            return .rejected
        default:
            return .rejected
        }
    }
}
