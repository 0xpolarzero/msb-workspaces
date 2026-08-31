#!/usr/bin/env swift

import AppKit

struct IconSpecification {
    let filename: String
    let pixels: Int
}

let specifications = [
    IconSpecification(filename: "AppIcon-16.png", pixels: 16),
    IconSpecification(filename: "AppIcon-16@2x.png", pixels: 32),
    IconSpecification(filename: "AppIcon-32.png", pixels: 32),
    IconSpecification(filename: "AppIcon-32@2x.png", pixels: 64),
    IconSpecification(filename: "AppIcon-128.png", pixels: 128),
    IconSpecification(filename: "AppIcon-128@2x.png", pixels: 256),
    IconSpecification(filename: "AppIcon-256.png", pixels: 256),
    IconSpecification(filename: "AppIcon-256@2x.png", pixels: 512),
    IconSpecification(filename: "AppIcon-512.png", pixels: 512),
    IconSpecification(filename: "AppIcon-512@2x.png", pixels: 1024),
]

let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: workingDirectory).standardizedFileURL
let outputDirectory = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

func color(_ red: Int, _ green: Int, _ blue: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat(red) / 255,
        green: CGFloat(green) / 255,
        blue: CGFloat(blue) / 255,
        alpha: alpha
    )
}

func drawLevel(
    in context: CGContext,
    center: CGPoint,
    radius: CGFloat,
    start: CGFloat,
    sweep: CGFloat,
    width: CGFloat,
    color: NSColor
) {
    context.setStrokeColor(color.cgColor)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.addArc(
        center: center,
        radius: radius,
        startAngle: start * .pi / 180,
        endAngle: (start + sweep) * .pi / 180,
        clockwise: false
    )
    context.strokePath()
}

func makeIcon(pixels: Int) throws -> Data {
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: pixels * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    let side = CGFloat(pixels)
    context.setFillColor(color(17, 19, 23).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))

    let fieldInset = side * 4 / 128
    let field = CGPath(
        roundedRect: CGRect(x: fieldInset, y: fieldInset, width: side - 2 * fieldInset, height: side - 2 * fieldInset),
        cornerWidth: side * 27 / 128,
        cornerHeight: side * 27 / 128,
        transform: nil
    )
    context.setFillColor(color(23, 26, 30).cgColor)
    context.addPath(field)
    context.fillPath()

    let borderInset = side * 6 / 128
    let border = CGPath(
        roundedRect: CGRect(x: borderInset, y: borderInset, width: side - 2 * borderInset, height: side - 2 * borderInset),
        cornerWidth: side * 25 / 128,
        cornerHeight: side * 25 / 128,
        transform: nil
    )
    context.setStrokeColor(color(52, 56, 61).cgColor)
    context.setLineWidth(max(1, side * 2 / 128))
    context.addPath(border)
    context.strokePath()

    let center = CGPoint(x: side / 2, y: side / 2)
    let strokeWidth = max(1.1, side * 7 / 128)
    let ivory = color(243, 238, 228)
    drawLevel(in: context, center: center, radius: side * 39 / 128, start: -28, sweep: 360 * 200 / 246, width: strokeWidth, color: ivory)
    drawLevel(in: context, center: center, radius: side * 26 / 128, start: 63, sweep: 360 * 126 / 163, width: strokeWidth, color: ivory)
    drawLevel(in: context, center: center, radius: side * 13 / 128, start: 154, sweep: 360 * 58 / 82, width: strokeWidth, color: color(255, 159, 10))

    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

for specification in specifications {
    let data = try makeIcon(pixels: specification.pixels)
    let destination = outputDirectory.appendingPathComponent(specification.filename)
    print(destination.path)
    try data.write(to: destination, options: .atomic)
}
