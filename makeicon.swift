// makeicon.swift — renders QGuard's app icon (1024px PNG) with CoreGraphics.
// Usage: swift makeicon.swift out.png

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S: CGFloat = 1024

guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}

let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = nsctx

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: 1)
}

// --- squircle background with a deep slate gradient -------------------------
let inset: CGFloat = S * 0.085
let rect = CGRect(x: inset, y: inset, width: S - inset*2, height: S - inset*2)
let squircle = CGPath(roundedRect: rect, cornerWidth: S * 0.225, cornerHeight: S * 0.225, transform: nil)

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [rgb(44, 52, 74), rgb(20, 24, 36)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

// subtle top sheen
let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.13),
                                CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: S * 0.45), options: [])
ctx.restoreGState()

// --- shield ----------------------------------------------------------------
let cx = S / 2
let shieldTop = S * 0.80
let shieldW = S * 0.52
let shieldBottom = S * 0.20

let shield = CGMutablePath()
shield.move(to: CGPoint(x: cx, y: shieldTop))
shield.addLine(to: CGPoint(x: cx + shieldW/2, y: shieldTop - S * 0.11))
shield.addCurve(to: CGPoint(x: cx, y: shieldBottom),
                control1: CGPoint(x: cx + shieldW/2, y: S * 0.42),
                control2: CGPoint(x: cx + shieldW * 0.30, y: S * 0.26))
shield.addCurve(to: CGPoint(x: cx - shieldW/2, y: shieldTop - S * 0.11),
                control1: CGPoint(x: cx - shieldW * 0.30, y: S * 0.26),
                control2: CGPoint(x: cx - shieldW/2, y: S * 0.42))
shield.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.05,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
ctx.addPath(shield)
ctx.clip()
let shieldGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [rgb(255, 214, 110), rgb(242, 150, 54)] as CFArray,
                            locations: [0, 1])!
ctx.drawLinearGradient(shieldGrad, start: CGPoint(x: cx, y: shieldTop),
                       end: CGPoint(x: cx, y: shieldBottom), options: [])
ctx.restoreGState()

// --- command glyph inside the shield ---------------------------------------
let glyph = "\u{2318}" // ⌘
let fontSize = S * 0.30
let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(red: 26/255, green: 30/255, blue: 44/255, alpha: 1),
]
let str = NSAttributedString(string: glyph, attributes: attrs)
let size = str.size()
str.draw(at: NSPoint(x: cx - size.width/2, y: S * 0.44 - size.height/2))

// --- red "no" slash across the glyph --------------------------------------
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineWidth(S * 0.055)
// dark outline so the slash reads on the gold shield
ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
ctx.move(to: CGPoint(x: cx - S * 0.145, y: S * 0.335))
ctx.addLine(to: CGPoint(x: cx + S * 0.145, y: S * 0.545))
ctx.strokePath()
ctx.setLineWidth(S * 0.040)
ctx.setStrokeColor(rgb(226, 54, 54))
ctx.move(to: CGPoint(x: cx - S * 0.145, y: S * 0.335))
ctx.addLine(to: CGPoint(x: cx + S * 0.145, y: S * 0.545))
ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.current = nil

guard let img = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: img)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
