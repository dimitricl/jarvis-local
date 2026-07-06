import Cocoa

let iconSet = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconSet, withIntermediateDirectories: true)

let sizes: [(Int, Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (64, 1), (64, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
    (1024, 1),
]

for (size, scale) in sizes {
    let px = size * scale
    let suffix = scale > 1 ? "@\(scale)x" : ""
    let filename = "icon_\(size)x\(size)\(suffix).png"
    let url = URL(fileURLWithPath: "\(iconSet)/\(filename)")

    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocusFlipped(false)

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        print("Erreur : impossible d'obtenir le contexte graphique")
        exit(1)
    }

    // Background arrondi (dark theme)
    let bgRect = CGRect(x: 0, y: 0, width: px, height: px)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: CGFloat(px) / 5, cornerHeight: CGFloat(px) / 5, transform: nil)
    ctx.addPath(bgPath)
    ctx.setFillColor(CGColor(red: 0.08, green: 0.12, blue: 0.22, alpha: 1.0))
    ctx.fillPath()

    // Cercle cyan
    let margin = CGFloat(px) * 0.18
    let circleRect = CGRect(x: margin, y: margin, width: CGFloat(px) - 2 * margin, height: CGFloat(px) - 2 * margin)
    let circlePath = CGPath(ellipseIn: circleRect, transform: nil)
    ctx.addPath(circlePath)
    ctx.setStrokeColor(CGColor(red: 0.0, green: 0.8, blue: 0.9, alpha: 1.0))
    ctx.setLineWidth(CGFloat(px) * 0.04)
    ctx.strokePath()

    // Lettre "J"
    let text = "J" as NSString
    let fontSize = CGFloat(px) * 0.48
    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(red: 0.0, green: 0.8, blue: 0.9, alpha: 1.0)
    ]
    let textSize = text.size(withAttributes: attrs)
    let textOrigin = CGPoint(
        x: (CGFloat(px) - textSize.width) / 2,
        y: (CGFloat(px) - textSize.height) / 2 - CGFloat(px) * 0.02
    )
    text.draw(at: textOrigin, withAttributes: attrs)

    image.unlockFocus()

    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("Erreur : impossible de créer CGImage pour size \(px)")
        exit(1)
    }

    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("Erreur : impossible de créer PNG pour size \(px)")
        exit(1)
    }

    try pngData.write(to: url)
    print("✓ \(filename) (\(px)x\(px))")
}

// Convertir en .icns via iconutil
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconSet, "-o", "AppIcon.icns"]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    print("Erreur : iconutil a échoué")
    exit(1)
}

print("✓ AppIcon.icns créé")
