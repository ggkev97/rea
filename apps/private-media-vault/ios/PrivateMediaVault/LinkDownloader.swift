import Foundation
import VaultCore

enum LinkDownloader {
    struct DownloadedFile {
        var url: URL
    }

    static func download(_ url: URL) async throws -> DownloadedFile {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        let (temporary, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporary)
            throw LinkReject.unsupportedType
        }
        if let final = http.url {
            if case .failure(let error) = LinkImportPolicy.validate(url: final) {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value
        let header = http.value(forHTTPHeaderField: "Content-Type")
        if case .failure(let error) = LinkImportPolicy.validate(
            contentType: header,
            byteCount: size,
            maxBytes: 8 * 1024 * 1024 * 1024,
            redirectCount: 0
        ) {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        let handle = try FileHandle(forReadingFrom: temporary)
        let prefix = try handle.read(upToCount: 64) ?? Data()
        try handle.close()
        guard LinkImportPolicy.sniff(prefix) != nil else {
            try? FileManager.default.removeItem(at: temporary)
            throw LinkReject.unrecognizedBytes
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return DownloadedFile(url: destination)
    }
}
