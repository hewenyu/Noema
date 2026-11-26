import Foundation
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
}
