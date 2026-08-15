import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: GenerateIcon.swift <output.icns>\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

func drawIcon(pixels: Int) throws -> Data {
    let size = NSSize(width: pixels, height: pixels)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "IconGenerator", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }

    let bounds = NSRect(origin: .zero, size: size)
    let background = NSBezierPath(roundedRect: bounds.insetBy(dx: CGFloat(pixels) * 0.04, dy: CGFloat(pixels) * 0.04), xRadius: CGFloat(pixels) * 0.22, yRadius: CGFloat(pixels) * 0.22)
    NSColor(calibratedRed: 0.96, green: 0.71, blue: 0.78, alpha: 1).setFill()
    background.fill()

    let boxRect = NSRect(x: CGFloat(pixels) * 0.21, y: CGFloat(pixels) * 0.21, width: CGFloat(pixels) * 0.58, height: CGFloat(pixels) * 0.50)
    let box = NSBezierPath(roundedRect: boxRect, xRadius: CGFloat(pixels) * 0.07, yRadius: CGFloat(pixels) * 0.07)
    NSColor(calibratedRed: 0.98, green: 0.92, blue: 0.95, alpha: 1).setFill()
    box.fill()
    NSColor(calibratedRed: 0.57, green: 0.42, blue: 0.67, alpha: 1).setStroke()
    box.lineWidth = CGFloat(pixels) * 0.025
    box.stroke()

    let lid = NSBezierPath()
    lid.move(to: NSPoint(x: CGFloat(pixels) * 0.22, y: CGFloat(pixels) * 0.58))
    lid.line(to: NSPoint(x: CGFloat(pixels) * 0.50, y: CGFloat(pixels) * 0.76))
    lid.line(to: NSPoint(x: CGFloat(pixels) * 0.78, y: CGFloat(pixels) * 0.58))
    lid.lineWidth = CGFloat(pixels) * 0.035
    lid.lineCapStyle = .round
    NSColor(calibratedRed: 0.57, green: 0.42, blue: 0.67, alpha: 1).setStroke()
    lid.stroke()

    let heart = NSBezierPath()
    let center = NSPoint(x: CGFloat(pixels) * 0.5, y: CGFloat(pixels) * 0.43)
    let radius = CGFloat(pixels) * 0.085
    heart.move(to: NSPoint(x: center.x, y: center.y - radius))
    heart.curve(to: NSPoint(x: center.x - radius * 1.55, y: center.y + radius * 0.25), controlPoint1: NSPoint(x: center.x - radius * 0.75, y: center.y - radius * 0.45), controlPoint2: NSPoint(x: center.x - radius * 1.55, y: center.y - radius * 0.35))
    heart.curve(to: NSPoint(x: center.x, y: center.y + radius), controlPoint1: NSPoint(x: center.x - radius * 1.55, y: center.y + radius), controlPoint2: NSPoint(x: center.x - radius * 0.55, y: center.y + radius * 1.25))
    heart.curve(to: NSPoint(x: center.x + radius * 1.55, y: center.y + radius * 0.25), controlPoint1: NSPoint(x: center.x + radius * 0.55, y: center.y + radius * 1.25), controlPoint2: NSPoint(x: center.x + radius * 1.55, y: center.y + radius))
    heart.curve(to: NSPoint(x: center.x, y: center.y - radius), controlPoint1: NSPoint(x: center.x + radius * 1.55, y: center.y - radius * 0.35), controlPoint2: NSPoint(x: center.x + radius * 0.75, y: center.y - radius * 0.45))
    NSColor(calibratedRed: 0.51, green: 0.72, blue: 0.61, alpha: 1).setFill()
    heart.fill()

    context.flushGraphics()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGenerator", code: 2)
    }
    return png
}

func bigEndianData(_ value: UInt32) -> Data {
    var encoded = value.bigEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
}

let variants: [(String, Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024)
]

var chunks = Data()
for (type, pixels) in variants {
    let png = try drawIcon(pixels: pixels)
    guard let typeData = type.data(using: .ascii), typeData.count == 4 else {
        throw NSError(domain: "IconGenerator", code: 3)
    }
    chunks.append(typeData)
    chunks.append(bigEndianData(UInt32(png.count + 8)))
    chunks.append(png)
}

var icns = Data("icns".utf8)
icns.append(bigEndianData(UInt32(chunks.count + 8)))
icns.append(chunks)
try icns.write(to: output, options: .atomic)
