import CoreGraphics
import Foundation
import ImageIO
@testable import NoemaClipboardCore
import Testing

@Suite struct ClipboardTokenizerTests {
    @Test func indexFormSplitsEveryCJKScalar() {
        #expect(ClipboardTokenizer.indexForm("你好swift世界") == " 你  好 swift 世  界 ")
        #expect(ClipboardTokenizer.indexForm("こんにちは").split(separator: " ").count == 5)
        #expect(ClipboardTokenizer.indexForm("안녕").split(separator: " ") == ["안", "녕"])
        #expect(ClipboardTokenizer.indexForm("𠀀㐀") == " 𠀀  㐀 ")
        #expect(ClipboardTokenizer.indexForm("hello world 42") == "hello world 42")
    }

    @Test func queriesQuoteEveryTerm() {
        #expect(ClipboardTokenizer.compileFTSQuery("你好") == "\"你 好\"")
        #expect(ClipboardTokenizer.compileFTSQuery("你好 swift") == "\"你 好\" AND \"swift\"*")
        #expect(ClipboardTokenizer.compileFTSQuery("swift你好") == "\"swift\"* AND \"你 好\"")
        #expect(ClipboardTokenizer.compileFTSQuery("foo:bar") == "\"foo\"* AND \"bar\"*")
        #expect(ClipboardTokenizer.compileFTSQuery("a OR b") == "\"a\"* AND \"OR\"* AND \"b\"*")
        #expect(ClipboardTokenizer.compileFTSQuery("NEAR/5") == "\"NEAR\"* AND \"5\"*")
        for hostile in ["\"", "*", "(((", ")", ":", "\"\"\"", "   ", "^", "-", "+", ""] {
            #expect(ClipboardTokenizer.compileFTSQuery(hostile) == nil, "\(hostile)")
        }
    }
}

@Suite struct ClipboardImageProcessorTests {
    @Test func pngIsKeptAndThumbnailed() throws {
        let png = TestImages.png(width: 1_024, height: 600, seed: 3)
        let image = try ClipboardImageProcessor.process(png)
        #expect(image.pngData == png && image.width == 1_024 && image.height == 600)
        #expect(image.thumbnailData.prefix(4) == pngMagic)
        let thumbnail = try ClipboardImageProcessor.process(image.thumbnailData)
        #expect(max(thumbnail.width, thumbnail.height) <= ClipboardImageProcessor.thumbnailMaxPixelSize)
        #expect(image.sha256.count == 64)
    }

    @Test func tiffIsTranscodedToPNG() throws {
        let tiff = TestImages.tiff(width: 40, height: 30)
        #expect(tiff.prefix(4) != pngMagic)
        let image = try ClipboardImageProcessor.process(tiff)
        #expect(image.pngData.prefix(4) == pngMagic && image.width == 40 && image.height == 30)
    }

    /// The header claims 20 000 × 20 000 (1.6 GB of pixels): rejected from the header,
    /// before any decode.
    @Test func decompressionBombIsRejectedFromTheHeader() {
        let oversizedHeader = TestImages.craftedPNGHeader(width: 20_000, height: 20_000)
        #expect(oversizedHeader.count < 100)
        #expect(throws: ClipboardError.imageDimensionsRejected(width: 20_000, height: 20_000)) {
            try ClipboardImageProcessor.process(oversizedHeader)
        }
        #expect(throws: ClipboardError.imageDimensionsRejected(width: 16_000, height: 4_001)) {
            try ClipboardImageProcessor.process(TestImages.craftedPNGHeader(width: 16_000, height: 4_001))
        }
        #expect(throws: ClipboardError.imageDimensionsRejected(width: 16_385, height: 1)) {
            try ClipboardImageProcessor.process(TestImages.craftedPNGHeader(width: 16_385, height: 1))
        }
    }

    /// Real (valid) images over the side limit: rejected through ImageIO's header for TIFF.
    @Test func oversizedRealImagesAreRejected() {
        let wide = TestImages.encode(TestImages.cgImage(width: 16_385, height: 2, seed: 1), type: "public.tiff")
        #expect(throws: ClipboardError.imageDimensionsRejected(width: 16_385, height: 2)) { try ClipboardImageProcessor.process(wide) }
        let tall = TestImages.png(width: 1, height: 16_385)
        #expect(throws: ClipboardError.imageDimensionsRejected(width: 1, height: 16_385)) { try ClipboardImageProcessor.process(tall) }
    }

    @Test func byteCapAppliesBeforeDecoding() {
        let quota = ClipboardStorageQuota(maxImageBytes: 1_000)
        let data = Data(repeating: 0xAB, count: 1_001)
        #expect(throws: ClipboardError.imageTooLarge(1_001)) { try ClipboardImageProcessor.process(data, quota: quota) }
        #expect(throws: ClipboardError.emptyContent) { try ClipboardImageProcessor.process(Data()) }
        #expect(throws: ClipboardError.imageDecodeFailed) { try ClipboardImageProcessor.process(Data("not an image".utf8)) }
    }

    /// Codex PR #23 round 1: JPEG/HEIC images carrying EXIF orientations 1...8 (rotations and
    /// mirrors) are normalized upright when transcoded to PNG so full-image dimensions and
    /// corner pixels match the ImageIO-transformed thumbnail.
    @Test func jpegWithAllEightExifOrientationsMatchesThumbnailOrientation() throws {
        // 40×20 asymmetric 4-quadrant image (TL=red, TR=green, BL=blue, BR=yellow).
        let rawW = 40
        let rawH = 20
        var pixels = [UInt8](repeating: 0, count: rawW * rawH * 4)
        for y in 0..<rawH {
            for x in 0..<rawW {
                let offset = (y * rawW + x) * 4
                let top = y < rawH / 2
                let left = x < rawW / 2
                let rgb: (UInt8, UInt8, UInt8) = switch (top, left) {
                case (true, true): (240, 20, 20)     // red
                case (true, false): (20, 240, 20)    // green
                case (false, true): (20, 20, 240)    // blue
                case (false, false): (240, 240, 20)  // yellow
                }
                pixels[offset] = rgb.0
                pixels[offset + 1] = rgb.1
                pixels[offset + 2] = rgb.2
                pixels[offset + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let base = try #require(CGImage(
            width: rawW, height: rawH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rawW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))

        func encodeJPEG(_ cgImage: CGImage, orientation: Int) throws -> Data {
            let output = NSMutableData()
            let dest = try #require(CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil))
            let props = [
                kCGImagePropertyOrientation: orientation,
                kCGImageDestinationLossyCompressionQuality: 1.0,
            ] as CFDictionary
            CGImageDestinationAddImage(dest, cgImage, props)
            #expect(CGImageDestinationFinalize(dest))
            return output as Data
        }

        func cornerRGBs(_ pngData: Data) throws -> (width: Int, height: Int, corners: [(Int, Int, Int)]) {
            let source = try #require(CGImageSourceCreateWithData(pngData as CFData, nil))
            let cg = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            var buf = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let ctx = try #require(CGContext(
                data: &buf, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            // Sample 4 pixels well inside each quadrant (top-left, top-right, bottom-left, bottom-right).
            let pts = [(3, 3), (cg.width - 4, 3), (3, cg.height - 4), (cg.width - 4, cg.height - 4)]
            let corners = pts.map { (x, y) -> (Int, Int, Int) in
                let i = (y * cg.width + x) * 4
                return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
            }
            return (cg.width, cg.height, corners)
        }

        for orientation in 1...8 {
            let jpeg = try encodeJPEG(base, orientation: orientation)
            let processed = try ClipboardImageProcessor.process(jpeg)
            let expectedW = (5...8).contains(orientation) ? rawH : rawW
            let expectedH = (5...8).contains(orientation) ? rawW : rawH
            #expect(processed.width == expectedW && processed.height == expectedH, "orientation \(orientation)")
            let full = try cornerRGBs(processed.pngData)
            let thumb = try cornerRGBs(processed.thumbnailData)
            #expect(full.width == expectedW && full.height == expectedH, "decoded PNG dims for orientation \(orientation)")
            #expect(thumb.width == expectedW && thumb.height == expectedH, "thumb dims for orientation \(orientation)")
            for (index, (f, t)) in zip(full.corners, thumb.corners).enumerated() {
                #expect(
                    abs(f.0 - t.0) < 30 && abs(f.1 - t.1) < 30 && abs(f.2 - t.2) < 30,
                    "orientation \(orientation) corner \(index) mismatch: full=\(f) thumb=\(t)")
            }
        }
    }
}
