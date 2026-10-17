#!/usr/bin/env swift
import AppKit

// Builds every brand asset the app ships from the two approved masters in Design/logo-concepts.
// Nothing here invents artwork: it measures where the drawing actually sits inside its canvas and
// re-packages it at the sizes and proportions macOS expects.
//
//   Resources/Lumio.icns        the Dock, Finder and app switcher icon
//   Resources/Brand/mark.png    the in-app mark, trimmed and centred
//   Resources/Brand/menubar.png a flat silhouette for the menu bar, tinted by the system

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let concepts = root.appendingPathComponent("Design/logo-concepts")
let iconMaster = concepts.appendingPathComponent("lumio-blue-concept-v1.png")
let markMaster = concepts.appendingPathComponent("lumio-blue-mark-v1.png")

func load(_ url: URL) -> CGImage {
    guard let image = NSImage(contentsOf: url),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("missing master: \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    return cg
}

/// The rectangle the drawing actually occupies, so margins baked into a master do not become margins
/// baked into every size derived from it.
func contentBox(_ image: CGImage) -> CGRect {
    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
        return CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }
    let rowBytes = image.bytesPerRow, pixelBytes = image.bitsPerPixel / 8
    let first = image.alphaInfo == .premultipliedFirst || image.alphaInfo == .first || image.alphaInfo == .noneSkipFirst
    var minX = image.width, maxX = -1, minY = image.height, maxY = -1
    for y in 0..<image.height {
        for x in 0..<image.width {
            let offset = y * rowBytes + x * pixelBytes
            let alpha = Int(bytes[first ? offset : offset + 3])
            if alpha > 12 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return CGRect(x: 0, y: 0, width: image.width, height: image.height) }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// Draws a master into a square canvas so its drawing fills `coverage` of that canvas, centred, with
/// the rest left transparent. Every size is rendered from the full-resolution master rather than from
/// the size above it, which is what keeps the small ones crisp.
func render(_ image: CGImage, box: CGRect, side: Int, coverage: Double, silhouette: Bool = false) -> CGImage? {
    guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    let target = Double(side) * coverage
    let scale = min(target / box.width, target / box.height)
    let width = box.width * scale, height = box.height * scale
    // The master's own canvas is placed so that its content box lands in the middle of the new one.
    let drawn = CGRect(x: (Double(side) - width) / 2 - box.minX * scale,
                       y: (Double(side) - height) / 2 - (Double(image.height) - box.maxY) * scale,
                       width: Double(image.width) * scale, height: Double(image.height) * scale)
    context.draw(image, in: drawn)
    guard silhouette else { return context.makeImage() }
    // A menu bar image is a shape, not a picture: keep the coverage and throw the colour away, which is
    // what lets macOS tint it for light, dark and highlighted bars.
    guard let shape = context.makeImage(),
          let flat = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    flat.clip(to: CGRect(x: 0, y: 0, width: side, height: side), mask: shape)
    flat.setFillColor(CGColor(gray: 0, alpha: 1))
    flat.fill(CGRect(x: 0, y: 0, width: side, height: side))
    return flat.makeImage()
}

func write(_ image: CGImage, to url: URL) {
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url)
}

let icon = load(iconMaster), iconBox = contentBox(icon)
let mark = load(markMaster), markBox = contentBox(mark)

// macOS draws app icons on a grid where the shape covers 824 of 1024 points; a master that fills more
// than that looks oversized beside every other icon in the Dock.
let iconset = root.appendingPathComponent(".build/Lumio.iconset")
try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, side) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                     ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
                     ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    guard let rendered = render(icon, box: iconBox, side: side, coverage: 824.0 / 1024.0) else { continue }
    write(rendered, to: iconset.appendingPathComponent("\(name).png"))
}

// The in-app mark sits in small, tight places, so it is trimmed to its drawing and given a little room.
if let rendered = render(mark, box: markBox, side: 512, coverage: 0.94) {
    write(rendered, to: root.appendingPathComponent("Resources/Brand/mark.png"))
}
if let rendered = render(mark, box: markBox, side: 44, coverage: 0.88, silhouette: true) {
    write(rendered, to: root.appendingPathComponent("Resources/Brand/menubar.png"))
}
print("brand assets written from \(iconBox.width)x\(iconBox.height) icon and \(markBox.width)x\(markBox.height) mark")
