import Foundation
import SwiftUI
import UniformTypeIdentifiers
import VaultCore

@MainActor
@Observable
final class VaultModel {
    enum Phase: Equatable {
        case locked
        case unlocking
        case unlocked
        case failed(String)
    }

    var phase: Phase = .locked
    var coverVisible = false
    var items: [MediaItem] = []
    var albums: [Album] = []
    var playlists: [Playlist] = []
    var searchText = ""
    var statusMessage: String?
    var recoveryKeyDisplay: String?
    var backupFile: URL?
    var assistantToken: String?
    var assistantExpires: Date?
    var loopbackAddress: String?
    var continuousPlayback = true
    var autoLock: AutoLock = .immediate

    private var store: VaultStore?
    private var masterKey: MasterKey?
    private var coordinator = PrivacyCoordinator()
    private let keychain = KeychainMasterKeyStore()
    private let hooks = IOSFileHooks()
    private var loopback: LoopbackAssistantServer?
    private var session = AssistantSession()
    private let defaults = UserDefaults.standard

    init() {
        if let raw = defaults.string(forKey: "autolock") {
            autoLock = Self.decodeLock(raw)
        }
        continuousPlayback = defaults.object(forKey: "continuous") as? Bool ?? true
        coordinator.configuration.autoLock = autoLock
    }

    var vaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PrivateMediaVault", isDirectory: true)
    }

    var previousVaultDirectory: URL {
        vaultDirectory.deletingLastPathComponent().appendingPathComponent("PrivateMediaVault.previous", isDirectory: true)
    }

    func unlock() async {
        phase = .unlocking
        do {
            var key = try await keychain.loadOrCreate()
            do {
                let opened = try VaultStore(directory: vaultDirectory, masterKey: key, hooks: hooks)
                store = opened
                masterKey = key
                try refresh()
                importInbox()
                phase = .unlocked
                _ = coordinator.handle(.didUnlock)
                coverVisible = false
                statusMessage = nil
            } catch {
                key.wipe()
                throw error
            }
        } catch KeychainVaultError.passcodeRequired {
            phase = .failed(String(localized: "This vault needs a device passcode. Face ID is the shortcut. The passcode is the fallback, and anyone who knows it can unlock the vault.", comment: "Shown when the device has no passcode."))
        } catch KeychainVaultError.authenticationFailed {
            phase = .locked
            statusMessage = String(localized: "Unlock was cancelled.", comment: "Shown when Face ID or the device passcode prompt is cancelled.")
        } catch {
            phase = .failed(publicMessage(error))
        }
    }

    func lock() {
        loopback?.stop()
        loopbackAddress = nil
        session.revoke()
        assistantToken = nil
        assistantExpires = nil
        store?.lock()
        store = nil
        masterKey?.wipe()
        masterKey = nil
        items = []
        albums = []
        playlists = []
        recoveryKeyDisplay = nil
        phase = .locked
        coverVisible = true
    }

    func sceneChanged(_ phase: ScenePhase, now: Date = Date()) {
        let decision: PrivacyDecision
        switch phase {
        case .active:
            decision = coordinator.handle(.becameActive(now))
        case .inactive:
            decision = coordinator.handle(.resignedActive)
        case .background:
            decision = coordinator.handle(.enteredBackground(now))
        @unknown default:
            decision = coordinator.handle(.resignedActive)
        }
        if decision.shouldLock {
            lock()
        }
        coverVisible = phase != .active
    }

    func setAutoLock(_ value: AutoLock) {
        autoLock = value
        coordinator.configuration.autoLock = value
        defaults.set(Self.encodeLock(value), forKey: "autolock")
    }

    func setContinuous(_ value: Bool) {
        continuousPlayback = value
        defaults.set(value, forKey: "continuous")
    }

    func refresh() throws {
        guard let store else { return }
        items = try store.items()
        albums = try store.albums()
        playlists = try store.playlists()
    }

    func importFile(_ url: URL, source: ImportSource, liveMotion: URL? = nil) throws {
        guard let store else { throw VaultError.locked }
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .nameKey])
        let name = values.name ?? url.lastPathComponent
        let type = values.contentType?.identifier ?? "public.data"
        let kind = Self.kind(for: values.contentType, filename: name)
        let thumb = Thumbnailer.make(for: url, kind: kind)
        _ = try store.importFile(
            at: url,
            metadata: ImportMetadata(
                originalFilename: name,
                mediaKind: kind,
                contentTypeIdentifier: type,
                source: source,
                caption: "",
                thumbnail: thumb
            ),
            liveMotion: liveMotion
        )
        try refresh()
    }

    func importData(_ data: Data, filename: String, source: ImportSource, contentType: String) throws {
        guard let store else { throw VaultError.locked }
        let kind: MediaKind = contentType.hasPrefix("video/") ? .video : .image
        _ = try store.importBytes(
            data,
            metadata: ImportMetadata(
                originalFilename: filename,
                mediaKind: kind,
                contentTypeIdentifier: contentType,
                source: source,
                thumbnail: Thumbnailer.make(data: data, kind: kind)
            )
        )
        try refresh()
    }

    func importLink(_ text: String) async -> String {
        guard store != nil else { return "Unlock the vault before importing a link." }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return "That text is not a URL."
        }
        switch LinkImportPolicy.validate(url: url) {
        case .failure(let reason):
            return Self.linkMessage(reason)
        case .success(let clean):
            do {
                let file = try await LinkDownloader.download(clean)
                defer { try? FileManager.default.removeItem(at: file.url) }
                try importFile(file.url, source: .link)
                return "Imported the file that the server returned. The link text is untrusted and was not given Brave's cookies or private-tab state."
            } catch {
                return publicMessage(error)
            }
        }
    }

    func importOpenIn(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try importFile(url, source: .openIn)
            if url.path.contains("/Inbox/") {
                try? FileManager.default.removeItem(at: url)
            }
            statusMessage = "Imported a file opened from another app. The original was not deleted."
        } catch {
            statusMessage = publicMessage(error)
        }
    }

    func importInbox() {
        let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: inbox.path) else { return }
        var failed = 0
        for name in names {
            let url = inbox.appendingPathComponent(name)
            do {
                try importFile(url, source: .openIn)
                try? FileManager.default.removeItem(at: url)
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            statusMessage = String(localized: "Some files opened from another app could not be imported. The originals were left in place.", comment: "Shown when one or more Inbox files fail to import.")
        }
    }

    func toggleFavorite(_ ids: [UUID]) {
        guard let store else { return }
        do {
            for id in ids {
                let current = items.first { $0.id == id }?.favorite ?? false
                try store.setFavorite([id], !current)
            }
            try refresh()
        } catch {
            statusMessage = publicMessage(error)
        }
    }

    func trash(_ ids: [UUID]) {
        guard let store else { return }
        do {
            try store.trash(ids)
            try refresh()
            statusMessage = "Moved to trash. Restore it there until it is purged."
        } catch {
            statusMessage = publicMessage(error)
        }
    }

    func restore(_ ids: [UUID]) {
        guard let store else { return }
        do {
            try store.restoreFromTrash(ids)
            try refresh()
        } catch {
            statusMessage = publicMessage(error)
        }
    }

    func purge(_ ids: [UUID]) {
        guard let store else { return }
        do {
            try store.purgeTrash(ids: ids)
            try refresh()
        } catch {
            statusMessage = publicMessage(error)
        }
    }

    func createAlbum(_ name: String) {
        guard let store else { return }
        do {
            _ = try store.createAlbum(name: name)
            try refresh()
        } catch {
            statusMessage = publicMessage(error)
        }
    }

    func add(_ ids: [UUID], to album: UUID) {
        guard let store else { return }
        do {
            try store.add(ids, to: album)
            try refresh()
        } catch {
            statusMessage = publicMessage(error)
        }
    }

    func createPlaylist(_ name: String, ids: [UUID]) {
        guard let store else { return }
        do {
            _ = try store.createPlaylist(name: name, itemIDs: ids)
            try refresh()
        } catch {
            statusMessage = publicMessage(error)
        }
    }

    func searchResults() -> [MediaItem] {
        guard let store else { return [] }
        return (try? store.search(searchText)) ?? []
    }

    func sessionMetadata(query: String) -> [String]? {
        guard phase == .unlocked, session.enabled, let store else { return nil }
        return (try? store.search(query).map(\.originalFilename)) ?? []
    }

    func trashedItems() -> [MediaItem] {
        guard let store else { return [] }
        return (try? store.items(includingTrash: true).filter { $0.trashedAt != nil }) ?? []
    }

    func reader(for id: UUID) throws -> ChunkedReader {
        guard let store else { throw VaultError.locked }
        return try store.reader(for: id)
    }

    func liveMotion(for id: UUID) throws -> ChunkedReader? {
        guard let store else { throw VaultError.locked }
        return try store.liveMotionReader(for: id)
    }

    func imageData(for id: UUID) -> Data? {
        guard let store else { return nil }
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        guard item.mediaKind == .image || item.mediaKind == .other else { return nil }
        guard item.byteCount <= VaultFormats.maximumPlaintextRangeBytes else {
            statusMessage = String(localized: "This still is too large to open in memory. Export it to view it outside the vault.", comment: "Shown when a still image exceeds the in-memory limit.")
            return nil
        }
        guard let reader = try? store.reader(for: id) else { return nil }
        defer { reader.close() }
        return try? reader.plaintext(byteRange: 0 ..< reader.plaintextLength)
    }

    func thumbnail(for id: UUID) -> Data? {
        guard let store else { return nil }
        return try? store.thumbnail(for: id)
    }

    func saveResume(id: UUID, seconds: Double, duration: Double?) {
        try? store?.setResume(id: id, seconds: seconds, duration: duration)
    }

    func prepareBackup() throws {
        guard let store else { throw VaultError.locked }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString).pmvb")
        var recovery = try store.createBackup(to: url)
        backupFile = url
        recoveryKeyDisplay = recovery.display
        recovery.wipe()
    }

    func clearRecoveryDisplay() {
        recoveryKeyDisplay = nil
    }

    func discardUnsavedBackup() {
        if let backupFile { shredFile(backupFile) }
        backupFile = nil
        recoveryKeyDisplay = nil
    }

    func restoreBackup(from url: URL, keyText: String) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var recovery = try RecoveryKey.parse(keyText)
        defer { recovery.wipe() }
        let key = try VaultStore.replaceVault(from: url, recoveryKey: recovery, vaultDirectory: vaultDirectory)
        try await keychain.replace(key)
        store?.lock()
        store = try VaultStore(directory: vaultDirectory, masterKey: key, hooks: hooks)
        masterKey = key
        try refresh()
        statusMessage = "Restore finished. The previous vault folder was kept beside the new one until you delete it."
    }

    func deletePreviousCopy() throws {
        guard FileManager.default.fileExists(atPath: previousVaultDirectory.path) else { return }
        shredTree(previousVaultDirectory)
    }

    func eraseEverything() async throws {
        lock()
        if FileManager.default.fileExists(atPath: vaultDirectory.path) {
            shredTree(vaultDirectory)
        }
        try keychain.delete()
        phase = .locked
        statusMessage = "The vault files and the device key were removed. A portable backup is the only way to get that media back."
    }

    func enableAssistant(minutes: Int) throws -> String {
        guard phase == .unlocked else { throw VaultError.locked }
        let token = session.enable(now: Date(), lifetime: TimeInterval(minutes * 60))
        assistantToken = token
        assistantExpires = session.expiresAt
        return token
    }

    func revokeAssistant() {
        session.revoke()
        assistantToken = nil
        assistantExpires = nil
        loopback?.stop()
        loopback = nil
        loopbackAddress = nil
    }

    func setLoopback(enabled: Bool) {
        loopback?.stop()
        loopback = nil
        loopbackAddress = nil
        guard enabled, session.enabled, phase == .unlocked else { return }
        let server = LoopbackAssistantServer()
        do {
            let address = try server.start { [weak self] raw in
                guard let self else { return "HTTP/1.1 423 Locked\r\nContent-Length: 0\r\n\r\n" }
                return self.answer(raw)
            }
            loopback = server
            loopbackAddress = address
        } catch {
            statusMessage = "The loopback control port did not open."
        }
    }

    func answer(_ raw: String) -> String {
        let snapshot = session
        let locked = phase != .unlocked
        return AssistantHTTP.respond(raw: raw, session: snapshot, now: Date(), vaultLocked: locked) { [weak self] request in
            guard let self, let store = self.store else { throw VaultError.locked }
            switch request {
            case .status:
                return AssistantPayload(kind: "status", locked: false, sessionEnabled: true)
            case .listAlbums:
                let albums = try store.albums()
                let items = try store.items()
                return AssistantPayload(
                    kind: "albums",
                    albums: albums.map { album in
                        AlbumSummary(id: album.id, name: album.name, count: items.filter { $0.albumIDs.contains(album.id) }.count)
                    }
                )
            case .searchMetadata(let query):
                let albums = try store.albums()
                let names = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0.name) })
                let matches = try store.search(query).map { item in
                    MetadataMatch(
                        id: item.id,
                        filename: item.originalFilename,
                        caption: item.caption,
                        albumNames: item.albumIDs.compactMap { names[$0] }
                    )
                }
                return AssistantPayload(kind: "search", matches: matches)
            }
        }
    }

    func assistantStatusText() -> String {
        guard phase == .unlocked else { return "The vault is locked. This does not unlock it." }
        guard session.enabled else { return "No assistant session is enabled." }
        return "The vault is unlocked and an assistant session is on. Media bytes are not available through this status."
    }

    func assistantAlbumsText() -> String {
        guard phase == .unlocked, session.enabled, let store else {
            return "Album names are available only while the vault is unlocked and a session is enabled."
        }
        let names = (try? store.albums().map(\.name)) ?? []
        return names.isEmpty ? "No albums." : names.joined(separator: ", ")
    }

    private static func kind(for type: UTType?, filename: String) -> MediaKind {
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { return .video }
        if type?.conforms(to: .image) == true { return .image }
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["mov", "mp4", "m4v"].contains(ext) { return .video }
        return .image
    }

    private static func linkMessage(_ reason: LinkReject) -> String {
        switch reason {
        case .notHTTPS:
            return "Only https links are accepted."
        case .userInfo:
            return "Links that embed a username or password are rejected."
        case .unsupportedHost:
            return "That host is not accepted."
        case .htmlOrDocument:
            return "The server returned a web page, not a media file. Paywalled and signed-in pages are not bypassed."
        case .unsupportedType:
            return "The server did not return a supported image or video type."
        case .tooLarge:
            return "The file is larger than the import limit."
        case .insecureRedirect, .tooManyRedirects:
            return "The link redirected somewhere this importer will not follow."
        case .unrecognizedBytes:
            return "The downloaded bytes are not a recognized image or video."
        }
    }

    private static func encodeLock(_ value: AutoLock) -> String {
        switch value {
        case .immediate: return "immediate"
        case .manual: return "manual"
        case .after(let interval): return "after:\(Int(interval))"
        }
    }

    private static func decodeLock(_ raw: String) -> AutoLock {
        switch raw {
        case "manual": return .manual
        case "immediate": return .immediate
        default:
            if raw.hasPrefix("after:"), let seconds = TimeInterval(raw.dropFirst(6)) { return .after(seconds) }
            return .immediate
        }
    }
}

func publicMessage(_ error: Error) -> String {
    if let vault = error as? VaultError { return vault.description }
    if let link = error as? LinkReject { return String(describing: link) }
    return "The operation could not be completed."
}

@MainActor
enum AssistantRuntime {
    static weak var model: VaultModel?
    static func attach(_ model: VaultModel) { self.model = model }
}
