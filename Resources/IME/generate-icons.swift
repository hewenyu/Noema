// Generates the NoemaIME.app and Noema.app icons in code, so the repository carries no
// binary art and no .xcassets. Uses only CoreGraphics, ImageIO, and UniformTypeIdentifiers.
//
// Usage: swift Resources/IME/generate-icons.swift <output-dir>
// Writes <output-dir>/NoemaIME.iconset/ and <output-dir>/Noema.iconset/ (the ten standard
// PNG sizes each, for `iconutil -c icns`) and <output-dir>/menu-icon.pdf (an 18x18 pt
// template image, shared by the input menu and the agent's status item).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-icons: \(message)\n".utf8))
    exit(1)
}

/// The Noema mark: an "N" of three rounded strokes inside a unit square (0...1).
func markPath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }
    path.move(to: point(0.28, 0.24))
    path.addLine(to: point(0.28, 0.76))
    path.addLine(to: point(0.72, 0.24))
    path.addLine(to: point(0.72, 0.76))
    return path
}

/// The two ends of an icon's background gradient, sRGB components.
struct Palette {
    let start: [CGFloat]
    let end: [CGFloat]

    /// NoemaIME.app: indigo.
    static let inputMethod = Palette(start: [0.16, 0.20, 0.38, 1], end: [0.30, 0.42, 0.78, 1])
    /// Noema.app, the companion agent: teal.
    static let agent = Palette(start: [0.05, 0.27, 0.30, 1], end: [0.16, 0.62, 0.60, 1])
}

/// Full-colour application icon at `pixels` x `pixels`.
func drawAppIcon(_ context: CGContext, pixels: CGFloat, palette: Palette) {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let inset = pixels * 0.08
    let tile = CGRect(x: inset, y: inset, width: pixels - 2 * inset, height: pixels - 2 * inset)
    let radius = tile.width * 0.225
    let background = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.addPath(background)
    context.clip()
    let colors = [
        CGColor(colorSpace: colorSpace, components: palette.start)!,
        CGColor(colorSpace: colorSpace, components: palette.end)!,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
    context.restoreGState()

    context.addPath(markPath(in: tile))
    context.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
    context.setLineWidth(tile.width * 0.1)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
}

func writePNG(pixels: Int, palette: Palette, to url: URL) {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("cannot create a \(pixels)px bitmap context") }
    drawAppIcon(context, pixels: CGFloat(pixels), palette: palette)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot encode \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

/// Black-on-clear template image for the menu bar; macOS tints it.
func writeMenuIconPDF(to url: URL) {
    var box = CGRect(x: 0, y: 0, width: 18, height: 18)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { fail("cannot create \(url.path)") }
    context.beginPDFPage(nil)
    let black = CGColor(gray: 0, alpha: 1)
    let tile = box.insetBy(dx: 1.5, dy: 1.5)
    context.addPath(CGPath(roundedRect: tile, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
    context.setStrokeColor(black)
    context.setLineWidth(1.25)
    context.strokePath()
    context.addPath(markPath(in: tile))
    context.setLineWidth(1.6)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
    context.endPDFPage()
    context.closePDF()
}

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 1, let outputPath = arguments.first, !outputPath.isEmpty else {
    fail("usage: swift generate-icons.swift <output-dir>")
}
let output = URL(fileURLWithPath: outputPath, isDirectory: true)
for (name, palette) in [("NoemaIME", Palette.inputMethod), ("Noema", Palette.agent)] {
    let iconset = output.appendingPathComponent("\(name).iconset", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    } catch {
        fail("cannot create \(iconset.path): \(error)")
    }
    for points in [16, 32, 128, 256, 512] {
        writePNG(pixels: points, palette: palette, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        writePNG(pixels: points * 2, palette: palette, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
}
writeMenuIconPDF(to: output.appendingPathComponent("menu-icon.pdf"))
