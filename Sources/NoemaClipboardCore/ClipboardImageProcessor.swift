import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// A copied image normalized for the store: canonical PNG bytes, a PNG thumbnail, the pixel
/// size, and the SHA-256 of the PNG (checked again after decryption).
public struct ClipboardImage: Sendable, Hashable {
    public var pngData: Data
    public var thumbnailData: Data
    public var width: Int
    public var height: Int
    public var sha256: String

    public var content: ClipboardEntryContent {
        .image(pngData: pngData, thumbnailData: thumbnailData, width: width, height: height)
    }
}

/// Validates and normalizes copied image bytes without trusting them:
/// 1. the raw byte count must be within `maxImageBytes` before ImageIO sees the data;
/// 2. the pixel size comes from the header only (a PNG's IHDR, then
///    `CGImageSourceCopyPropertiesAtIndex` for every format) and must be within `maxDimension` per side and `maxPixels` in total before any decode;
/// 3. anything but PNG is decoded once and re-encoded as PNG (the result is capped again);
/// 4. the thumbnail is drawn by `CGImageSourceCreateThumbnailAtIndex` (at most
///    `thumbnailMaxPixelSize`, EXIF orientation applied) and encoded as PNG.
public enum ClipboardImageProcessor {
    public static let maxDimension = 16_384
    public static let maxPixels: Int64 = 64_000_000
    public static let thumbnailMaxPixelSize = 512

    public static func process(_ data: Data, quota: ClipboardStorageQuota = .default) throws(ClipboardError) -> ClipboardImage {
        guard !data.isEmpty else { throw .emptyContent }
        guard data.count <= quota.maxImageBytes else { throw .imageTooLarge(data.count) }
        // PNG: the IHDR chunk is read directly, before ImageIO parses anything.
        if let (width, height) = pngHeaderDimensions(data) { try validateDimensions(width: width, height: height) }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) >= 1 else {
            throw .imageDecodeFailed
        }
        let (width, height) = try headerDimensions(source)
        let isPNG = (CGImageSourceGetType(source) as String?) == "public.png"
        let png: Data
        if isPNG {
            png = data
        } else {
            let decodeOptions = [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false] as CFDictionary
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions) else { throw .imageDecodeFailed }
            png = try encodePNG(image)
            guard png.count <= quota.maxImageBytes else { throw .imageTooLarge(png.count) }
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceShouldCache: false,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { throw .imageDecodeFailed }
        let thumbnailPNG = try encodePNG(thumbnail)
        return ClipboardImage(
            pngData: png, thumbnailData: thumbnailPNG, width: width, height: height,
            sha256: Data(SHA256.hash(data: png)).hexString)
    }

    /// The pixel size from the image header; rejects zero, oversized, and excessive-pixel dimensions.
    static func headerDimensions(_ source: CGImageSource) throws(ClipboardError) -> (Int, Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { throw .imageDecodeFailed }
        try validateDimensions(width: width, height: height)
        return (width, height)
    }

    /// Width and height from a PNG's IHDR chunk (bytes 16–23), or nil for other data.
    static func pngHeaderDimensions(_ data: Data) -> (Int, Int)? {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, bytes[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              bytes[12..<16].elementsEqual(Array("IHDR".utf8))
        else { return nil }
        func be(_ offset: Int) -> Int { bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        return (be(16), be(20))
    }

    public static func validateDimensions(width: Int, height: Int) throws(ClipboardError) {
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension,
              Int64(width) * Int64(height) <= maxPixels
        else { throw .imageDimensionsRejected(width: width, height: height) }
    }

    static func encodePNG(_ image: CGImage) throws(ClipboardError) -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil) else {
            throw .imageDecodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw .imageDecodeFailed }
        return output as Data
    }
}
