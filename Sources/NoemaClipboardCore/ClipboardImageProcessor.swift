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
        let (rawWidth, rawHeight, orientation) = try headerInfo(source)
        let isPNG = (CGImageSourceGetType(source) as String?) == "public.png"
        let png: Data
        let width: Int
        let height: Int
        if isPNG, orientation == 1 {
            png = data
            width = rawWidth
            height = rawHeight
        } else {
            let decodeOptions = [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false] as CFDictionary
            guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions) else { throw .imageDecodeFailed }
            let normalized = orientation == 1 ? decoded : try applyOrientation(orientation, to: decoded)
            png = try encodePNG(normalized)
            guard png.count <= quota.maxImageBytes else { throw .imageTooLarge(png.count) }
            width = normalized.width
            height = normalized.height
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

    /// The pixel size and EXIF orientation (1...8, default 1) from the image header; rejects
    /// zero, oversized, and excessive-pixel dimensions.
    static func headerInfo(_ source: CGImageSource) throws(ClipboardError) -> (width: Int, height: Int, orientation: Int) {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { throw .imageDecodeFailed }
        try validateDimensions(width: width, height: height)
        let topLevel = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        let tiff = (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFOrientation] as? NSNumber
        let rawOrientation = topLevel ?? tiff?.intValue ?? 1
        let orientation = (1...8).contains(rawOrientation) ? rawOrientation : 1
        return (width, height, orientation)
    }

    /// Renders `image` into upright orientation (EXIF 1) for EXIF orientations 2...8,
    /// handling both rotations and mirroring in CoreGraphics bottom-left coordinates.
    static func applyOrientation(_ orientation: Int, to image: CGImage) throws(ClipboardError) -> CGImage {
        let rawW = image.width
        let rawH = image.height
        let swapped = (5...8).contains(orientation)
        let outW = swapped ? rawH : rawW
        let outH = swapped ? rawW : rawH
        try validateDimensions(width: outW, height: outH)
        let w = CGFloat(rawW)
        let h = CGFloat(rawH)
        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: return image
        }
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let context = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo)
            ?? CGContext(
                data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)
        guard let context else { throw .imageDecodeFailed }
        context.interpolationQuality = .none
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let oriented = context.makeImage() else { throw .imageDecodeFailed }
        return oriented
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
