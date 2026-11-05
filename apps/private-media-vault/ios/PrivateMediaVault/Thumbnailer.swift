import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VaultCore

enum Thumbnailer {
    static func make(for url: URL, kind: MediaKind) -> Data? {
        switch kind {
        case .video, .livePhoto:
            return videoThumbnail(url)
        case .image, .other:
            return imageThumbnail(url)
        }
    }

    static func make(data: Data, kind: MediaKind) -> Data? {
        guard kind == .image || kind == .other else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source)
    }

    private static func imageThumbnail(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source)
    }

    private static func thumbnail(from source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpeg(image)
    }

    private static func videoThumbnail(_ url: URL) -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: 0.2, preferredTimescale: 600)
        guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return jpeg(image)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
