import AVFoundation
import Foundation
import VaultCore

final class EncryptedVideoLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let reader: ChunkedReader
    private let contentType: String
    private let queue = DispatchQueue(label: "pmv.video-loader")

    init(reader: ChunkedReader, contentType: String) {
        self.reader = reader
        self.contentType = contentType
    }

    func makeAsset(for id: UUID) -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "pmv://item/\(id.uuidString)")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let information = loadingRequest.contentInformationRequest {
            information.isByteRangeAccessSupported = true
            information.contentType = contentType
            information.contentLength = Int64(reader.plaintextLength)
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let start = Int(dataRequest.requestedOffset)
        let requested = dataRequest.requestedLength
        let end = dataRequest.requestsAllDataToEndOfResource
            ? reader.plaintextLength
            : min(reader.plaintextLength, start + requested)
        guard start >= 0, end >= start else {
            loadingRequest.finishLoading(with: VaultError.malformed)
            return true
        }
        var offset = start
        do {
            while offset < end {
                if loadingRequest.isCancelled { return true }
                let sliceEnd = min(end, offset + (1 << 20))
                let piece = try reader.plaintext(byteRange: offset ..< sliceEnd)
                dataRequest.respond(with: piece)
                offset = sliceEnd
            }
            loadingRequest.finishLoading()
        } catch {
            loadingRequest.finishLoading(with: error)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {}
}
