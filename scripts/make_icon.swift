// Renders the Harbor app icon (terminal prompt glyph on a LIGHT rounded rect)
// at every macOS icon size into App/Assets.xcassets/AppIcon.appiconset.
//
// Usage: swift scripts/make_icon.swift   (run from the repo root)

import AppKit

// Resolve paths from the SCRIPT's own location (scripts/make_icon.swift), not
// the current working directory. Running from elsewhere previously created a
// stray App/Assets.xcassets tree under the wrong directory — silently, so the
// regenerated icons never reached the project.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // scripts/
    .deletingLastPathComponent() // repo root
    .path
let iconSetDir = repoRoot + "/App/Assets.xcassets/AppIcon.appiconset"

// Fail loudly if the expected project layout isn't there (wrong checkout, moved
// script) instead of writing assets into a phantom directory.
guard FileManager.default.fileExists(atPath: repoRoot + "/App/Assets.xcassets") else {
    FileHandle.standardError.write(Data(
        "make_icon: \(repoRoot)/App/Assets.xcassets not found — run from the Harbor repo.\n".utf8))
    exit(1)
}

func srgb(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

func renderIcon(pixels: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
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
    ) else {
        fatalError("could not create bitmap rep for \(pixels)px")
    }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let s = CGFloat(pixels)

    // Big Sur layout: the icon shape fills an 824/1024 rect centered on the canvas.
    let inset = s * (100.0 / 1024.0)
    let shapeRect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = shapeRect.width * (185.4 / 824.0)
    let shape = NSBezierPath(roundedRect: shapeRect, xRadius: radius, yRadius: radius)

    // Light gradient background (white → soft gray-blue).
    NSGradient(starting: srgb(0xFFFFFF), ending: srgb(0xE9EEF5))!
        .draw(in: shape, angle: -90)

    // Hairline border so the light icon stays defined on light backgrounds.
    if pixels >= 64 {
        NSGraphicsContext.current?.saveGraphicsState()
        shape.addClip()
        srgb(0xC2CCD9).withAlphaComponent(0.9).setStroke()
        let highlight = NSBezierPath(
            roundedRect: shapeRect.insetBy(dx: s * 0.004, dy: s * 0.004),
            xRadius: radius,
            yRadius: radius
        )
        highlight.lineWidth = s * 0.008
        highlight.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // Prompt glyph: cyan chevron + white cursor bar, optically centered.
    let fontSize = shapeRect.width * 0.46
    let font = NSFont(name: "Menlo-Bold", size: fontSize)
        ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let chevron = NSAttributedString(string: ">", attributes: [
        .font: font,
        .foregroundColor: srgb(0x2563EB),
    ])
    let chevronSize = chevron.size()

    let cursorWidth = chevronSize.width * 0.72
    let cursorHeight = shapeRect.height * 0.055
    let gap = chevronSize.width * 0.18

    let totalWidth = chevronSize.width + gap + cursorWidth
    let originX = shapeRect.midX - totalWidth / 2
    let chevronY = shapeRect.midY - chevronSize.height / 2

    chevron.draw(at: NSPoint(x: originX, y: chevronY))

    srgb(0x334155).setFill()
    let cursorRect = NSRect(
        x: originX + chevronSize.width + gap,
        y: shapeRect.midY - chevronSize.height * 0.30,
        width: cursorWidth,
        height: cursorHeight
    )
    NSBezierPath(
        roundedRect: cursorRect,
        xRadius: cursorHeight / 2,
        yRadius: cursorHeight / 2
    ).fill()

    return rep
}

func write(_ rep: NSBitmapImageRep, to filename: String) {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(filename)")
    }
    let url = URL(fileURLWithPath: iconSetDir + "/" + filename)
    try! png.write(to: url)
    print("wrote \(filename) (\(rep.pixelsWide)px)")
}

try! FileManager.default.createDirectory(
    atPath: iconSetDir, withIntermediateDirectories: true)

// (point size, scale) pairs required for a macOS app icon.
let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

var rendered: [Int: NSBitmapImageRep] = [:]
var imageEntries: [String] = []
for (points, scale) in variants {
    let pixels = points * scale
    let rep = rendered[pixels] ?? renderIcon(pixels: pixels)
    rendered[pixels] = rep
    let filename = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    write(rep, to: filename)
    imageEntries.append("""
        {
          "filename" : "\(filename)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(points)x\(points)"
        }
    """)
}

let contents = """
{
  "images" : [
\(imageEntries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try! contents.write(
    toFile: iconSetDir + "/Contents.json", atomically: true, encoding: .utf8)

let catalogContents = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try! catalogContents.write(
    toFile: repoRoot + "/App/Assets.xcassets/Contents.json",
    atomically: true,
    encoding: .utf8
)
print("done: \(iconSetDir)")
