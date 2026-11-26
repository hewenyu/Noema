import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
@testable import NoemaClipboardCore

/// A fresh `0700` directory under the temporary directory, removed by `cleanup()`.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "noema-clipboard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// The store directory inside (created by the store itself).
    var store: URL { url.appending(path: "clipboard", directoryHint: .isDirectory) }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

enum TestImages {
    /// A `width`×`height` RGBA image whose pixels depend on `seed`, so different seeds give
    /// different bytes; `noise` makes the PNG large (incompressible).
    static func cgImage(width: Int, height: Int, seed: UInt8, noise: Bool = false) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var state = UInt32(seed) &* 2_654_435_761 &+ 1
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if noise {
                state = state &* 1_664_525 &+ 1_013_904_223
                pixels[index] = UInt8(truncatingIfNeeded: state >> 24)
                pixels[index + 1] = UInt8(truncatingIfNeeded: state >> 16)
                pixels[index + 2] = UInt8(truncatingIfNeeded: state >> 8)
            } else {
                pixels[index] = seed
                pixels[index + 1] = UInt8(truncatingIfNeeded: index / 4)
                pixels[index + 2] = 200
            }
            pixels[index + 3] = 255
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    static func encode(_ image: CGImage, type: String) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func png(width: Int = 64, height: Int = 48, seed: UInt8 = 1, noise: Bool = false) -> Data {
        encode(cgImage(width: width, height: height, seed: seed, noise: noise), type: "public.png")
    }

    static func tiff(width: Int = 40, height: Int = 30, seed: UInt8 = 2) -> Data {
        encode(cgImage(width: width, height: height, seed: seed), type: "public.tiff")
    }

    /// A PNG whose IHDR claims `width`×`height` with a tiny, bogus IDAT: decoding it would
    /// allocate width×height×4 bytes; only the header may be read.
    static func craftedPNGHeader(width: UInt32, height: UInt32) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ body: [UInt8]) {
            var length = UInt32(body.count).bigEndian
            data.append(Data(bytes: &length, count: 4))
            let typed = Array(type.utf8) + body
            data.append(contentsOf: typed)
            var crc = crc32(typed).bigEndian
            data.append(Data(bytes: &crc, count: 4))
        }
        func be(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
        chunk("IHDR", be(width) + be(height) + [8, 6, 0, 0, 0])
        chunk("IDAT", [0x78, 0x9C, 0x63, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01])
        chunk("IEND", [])
        return data
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}

enum RawDisk {
    /// Every regular file under `directory`, recursively.
    static func files(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    static func occurrences(of needle: Data, in haystack: Data) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var count = 0
        var start = haystack.startIndex
        while let range = haystack.range(of: needle, in: start..<haystack.endIndex) {
            count += 1
            start = range.upperBound
        }
        return count
    }

    /// Total occurrences of `needle` in every file under `directory`.
    static func scan(_ directory: URL, for needle: Data) -> Int {
        files(under: directory).reduce(0) { total, url in total + occurrences(of: needle, in: (try? Data(contentsOf: url)) ?? Data()) }
    }

    static func mode(_ url: URL) -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return -1 }
        return Int(info.st_mode & 0o777)
    }
}

let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])
