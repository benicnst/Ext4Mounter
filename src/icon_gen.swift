#!/usr/bin/env swift
import AppKit
import Foundation

// MARK: - Icon Drawing

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return img }

    let s = size
    let r = s * 0.22  // macOS standard corner radius

    // ── Background gradient (dark navy, y-up CG coords) ──────────────────
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    let cs = CGColorSpaceCreateDeviceRGB()
    // top colour (#1B3F72) → bottom colour (#0D1E3A)
    let comps: [CGFloat] = [
        0.11, 0.24, 0.45, 1.0,   // y = size (top in screen)
        0.05, 0.12, 0.23, 1.0    // y = 0    (bottom in screen)
    ]
    if let grad = CGGradient(colorSpace: cs, colorComponents: comps,
                              locations: [0.0, 1.0], count: 2) {
        ctx.drawLinearGradient(grad,
            start: CGPoint(x: s / 2, y: s),
            end:   CGPoint(x: s / 2, y: 0),
            options: [])
    }
    ctx.restoreGState()

    // ── Subtle inner glow at top ──────────────────────────────────────────
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let glowComps: [CGFloat] = [
        0.40, 0.60, 0.90, 0.18,
        0.40, 0.60, 0.90, 0.00
    ]
    if let gGrad = CGGradient(colorSpace: cs, colorComponents: glowComps,
                               locations: [0.0, 1.0], count: 2) {
        ctx.drawRadialGradient(gGrad,
            startCenter: CGPoint(x: s * 0.50, y: s * 0.85), startRadius: 0,
            endCenter:   CGPoint(x: s * 0.50, y: s * 0.85), endRadius: s * 0.60,
            options: [])
    }
    ctx.restoreGState()

    // ── Hard drive body ───────────────────────────────────────────────────
    let hdW  = s * 0.60
    let hdH  = s * 0.50
    let hdX  = (s - hdW) / 2
    let hdY  = s * 0.27           // 27 % from bottom (drive sits upper-centre)
    let hdRx = hdW * 0.09
    let ins  = s * 0.032

    // Outer body (silver)
    let bodyPath = CGPath(roundedRect: CGRect(x: hdX, y: hdY, width: hdW, height: hdH),
                          cornerWidth: hdRx, cornerHeight: hdRx, transform: nil)
    ctx.setFillColor(CGColor(red: 0.72, green: 0.75, blue: 0.82, alpha: 1.0))
    ctx.addPath(bodyPath)
    ctx.fillPath()

    // Top-edge highlight
    let hilightPath = CGPath(roundedRect: CGRect(x: hdX + ins * 0.5, y: hdY + hdH - ins * 1.2,
                                                  width: hdW - ins, height: ins * 1.2),
                             cornerWidth: hdRx * 0.5, cornerHeight: hdRx * 0.5, transform: nil)
    ctx.setFillColor(CGColor(red: 0.92, green: 0.94, blue: 0.97, alpha: 0.70))
    ctx.addPath(hilightPath)
    ctx.fillPath()

    // Inner face (darker)
    let innerPath = CGPath(roundedRect: CGRect(x: hdX + ins, y: hdY + ins,
                                               width: hdW - ins * 2, height: hdH - ins * 2),
                           cornerWidth: hdRx * 0.65, cornerHeight: hdRx * 0.65, transform: nil)
    ctx.setFillColor(CGColor(red: 0.42, green: 0.46, blue: 0.56, alpha: 1.0))
    ctx.addPath(innerPath)
    ctx.fillPath()

    // ── Platter (circular) ────────────────────────────────────────────────
    let cx  = hdX + hdW * 0.42
    let cy  = hdY + hdH * 0.50
    let pr  = hdH * 0.30

    // Outer ring
    ctx.setFillColor(CGColor(red: 0.28, green: 0.32, blue: 0.42, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: cx - pr, y: cy - pr, width: pr * 2, height: pr * 2))

    // Mid ring
    let pr2 = pr * 0.62
    ctx.setFillColor(CGColor(red: 0.34, green: 0.38, blue: 0.50, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: cx - pr2, y: cy - pr2, width: pr2 * 2, height: pr2 * 2))

    // Reflective sheen on platter
    ctx.saveGState()
    ctx.beginPath()
    ctx.addEllipse(in: CGRect(x: cx - pr2, y: cy - pr2, width: pr2 * 2, height: pr2 * 2))
    ctx.clip()
    let sheenComps: [CGFloat] = [
        0.70, 0.80, 1.00, 0.22,
        0.70, 0.80, 1.00, 0.00
    ]
    if let sGrad = CGGradient(colorSpace: cs, colorComponents: sheenComps,
                               locations: [0.0, 1.0], count: 2) {
        ctx.drawLinearGradient(sGrad,
            start: CGPoint(x: cx - pr2 * 0.3, y: cy + pr2),
            end:   CGPoint(x: cx + pr2 * 0.3, y: cy - pr2),
            options: [])
    }
    ctx.restoreGState()

    // Hub
    let pr3 = pr * 0.22
    ctx.setFillColor(CGColor(red: 0.76, green: 0.80, blue: 0.88, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: cx - pr3, y: cy - pr3, width: pr3 * 2, height: pr3 * 2))

    // ── Read arm ──────────────────────────────────────────────────────────
    let armPath = CGMutablePath()
    let armW    = max(s * 0.018, 1.5)
    let armStartX = cx + pr * 0.88
    let armStartY = cy
    let armEndX   = hdX + hdW - ins * 2.0
    let armEndY   = cy + hdH * 0.14
    armPath.move(to: CGPoint(x: armStartX, y: armStartY))
    armPath.addLine(to: CGPoint(x: armEndX, y: armEndY))
    ctx.setStrokeColor(CGColor(red: 0.62, green: 0.66, blue: 0.75, alpha: 1.0))
    ctx.setLineWidth(armW)
    ctx.setLineCap(.round)
    ctx.addPath(armPath)
    ctx.strokePath()

    // Arm head
    let headR = armW * 1.5
    ctx.setFillColor(CGColor(red: 0.72, green: 0.76, blue: 0.85, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: armStartX - headR, y: armStartY - headR,
                               width: headR * 2, height: headR * 2))

    // ── Green badge (bottom-right, rounded rectangle) ─────────────────────
    let bW  = s * 0.42           // badge width
    let bH  = s * 0.19           // badge height
    let bCr = s * 0.045          // corner radius
    let bX  = s - bW - s * 0.04
    let bY  = s * 0.04
    let badgeRect = CGRect(x: bX, y: bY, width: bW, height: bH)
    let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: bCr, cornerHeight: bCr,
                           transform: nil)

    // Shadow under badge
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01),
                  blur: s * 0.03,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.setFillColor(CGColor(red: 0.14, green: 0.72, blue: 0.33, alpha: 1.0))
    ctx.addPath(badgePath)
    ctx.fillPath()
    ctx.restoreGState()

    // Badge gradient sheen (top lighter → bottom normal)
    ctx.saveGState()
    ctx.addPath(badgePath)
    ctx.clip()
    let bSheenComps: [CGFloat] = [
        0.55, 0.95, 0.60, 0.30,
        0.14, 0.72, 0.33, 0.00
    ]
    if let bGrad = CGGradient(colorSpace: cs, colorComponents: bSheenComps,
                               locations: [0.0, 1.0], count: 2) {
        ctx.drawLinearGradient(bGrad,
            start: CGPoint(x: bX + bW / 2, y: bY + bH),
            end:   CGPoint(x: bX + bW / 2, y: bY),
            options: [])
    }
    ctx.restoreGState()

    // "EXT4" text centred in badge
    let badgeCX = bX + bW / 2
    let badgeCY = bY + bH / 2
    let fontSize = bH * 0.58
    let str = "EXT4" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "Helvetica-Bold", size: fontSize)
              ?? NSFont.boldSystemFont(ofSize: fontSize),
        .foregroundColor: NSColor.white
    ]
    let strSize = str.size(withAttributes: attrs)
    // y-up coords: draw at bottom-left of text bounding box
    str.draw(at: NSPoint(x: badgeCX - strSize.width  / 2,
                         y: badgeCY - strSize.height / 2 - strSize.height * 0.04),
             withAttributes: attrs)

    return img
}

// MARK: - Save iconset

let projectDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

let iconsetDir = projectDir + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir,
                                         withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (sz, name) in sizes {
    let img = drawIcon(size: CGFloat(sz))
    guard let tiff   = img.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png    = bitmap.representation(using: .png, properties: [:]) else {
        fputs("⚠️  Failed: \(name)\n", stderr); continue
    }
    let path = iconsetDir + "/" + name
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("✓ \(name) (\(sz)×\(sz))")
    } catch {
        fputs("⚠️  Write failed \(name): \(error)\n", stderr)
    }
}

print("\nDone! Iconset at: \(iconsetDir)")
print("Next: iconutil -c icns \(iconsetDir)")
