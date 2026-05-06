#!/usr/bin/env swift
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let outPath = "Buddy/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil,
                    width: Int(size),
                    height: Int(size),
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Background — warm cream → soft amber gradient (the Buddy palette)
let bgColors = [
    CGColor(red: 0.97, green: 0.94, blue: 0.88, alpha: 1.0), // cream
    CGColor(red: 0.93, green: 0.83, blue: 0.65, alpha: 1.0)  // soft amber
] as CFArray
let bgGradient = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1])!
ctx.drawLinearGradient(bgGradient,
                       start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: size, y: 0),
                       options: [])

// Soft top-right glow
ctx.saveGState()
ctx.setBlendMode(.screen)
let glow = CGGradient(colorsSpace: cs,
                      colors: [
                        CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
                        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
                      ] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: size * 0.7, y: size * 0.75),
                       startRadius: 0,
                       endCenter: CGPoint(x: size * 0.7, y: size * 0.75),
                       endRadius: size * 0.6,
                       options: [])
ctx.restoreGState()

// Dog face — golden retriever colors. Centered, slightly down to make room
// for ears.
let furFill = CGColor(red: 0.78, green: 0.55, blue: 0.32, alpha: 1.0)        // dogFur
let furShade = CGColor(red: 0.62, green: 0.42, blue: 0.22, alpha: 1.0)
let inkColor = CGColor(red: 0.18, green: 0.14, blue: 0.10, alpha: 1.0)        // ink
let snoutColor = CGColor(red: 0.88, green: 0.74, blue: 0.55, alpha: 1.0)      // tan-ish
let cx = size / 2
let cy = size * 0.50

// Helper: rounded ear (drooping). Given anchor point at the top of the head.
func drawEar(centerX: CGFloat, isLeft: Bool) {
    let earWidth = size * 0.20
    let earHeight = size * 0.34
    let baseY = cy - size * 0.18                        // anchor at upper head
    let dir: CGFloat = isLeft ? -1 : 1
    let rect = CGRect(x: centerX + dir * (size * 0.10) - earWidth / 2,
                      y: baseY - earHeight,
                      width: earWidth,
                      height: earHeight)
    let path = CGPath(ellipseIn: rect, transform: nil)
    ctx.saveGState()
    ctx.setFillColor(furShade)
    ctx.addPath(path)
    ctx.fillPath()
    // inner ear highlight
    let inner = CGRect(x: rect.midX - earWidth * 0.22,
                       y: rect.midY - earHeight * 0.28,
                       width: earWidth * 0.44,
                       height: earHeight * 0.55)
    ctx.setFillColor(CGColor(red: 0.95, green: 0.78, blue: 0.62, alpha: 0.7))
    ctx.addPath(CGPath(ellipseIn: inner, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
}

drawEar(centerX: cx, isLeft: true)
drawEar(centerX: cx, isLeft: false)

// Head — circle
let headRadius: CGFloat = size * 0.30
let headRect = CGRect(x: cx - headRadius,
                      y: cy - headRadius,
                      width: headRadius * 2,
                      height: headRadius * 2)
ctx.setFillColor(furFill)
ctx.addPath(CGPath(ellipseIn: headRect, transform: nil))
ctx.fillPath()

// Snout — lighter oval at the lower-front
let snoutWidth: CGFloat = size * 0.30
let snoutHeight: CGFloat = size * 0.22
let snoutRect = CGRect(x: cx - snoutWidth / 2,
                       y: cy - headRadius * 0.55,
                       width: snoutWidth,
                       height: snoutHeight)
ctx.setFillColor(snoutColor)
ctx.addPath(CGPath(ellipseIn: snoutRect, transform: nil))
ctx.fillPath()

// Nose — small black rounded rect
let noseWidth: CGFloat = size * 0.10
let noseHeight: CGFloat = size * 0.07
let noseRect = CGRect(x: cx - noseWidth / 2,
                      y: snoutRect.maxY - noseHeight - size * 0.012,
                      width: noseWidth,
                      height: noseHeight)
ctx.setFillColor(inkColor)
ctx.addPath(CGPath(roundedRect: noseRect,
                   cornerWidth: noseWidth * 0.4,
                   cornerHeight: noseHeight * 0.4,
                   transform: nil))
ctx.fillPath()

// Eyes — two ink circles
let eyeRadius: CGFloat = size * 0.030
for dx in [-1.0, 1.0] as [CGFloat] {
    let ex = cx + dx * size * 0.08
    let ey = cy + size * 0.08
    let r = CGRect(x: ex - eyeRadius, y: ey - eyeRadius,
                   width: eyeRadius * 2, height: eyeRadius * 2)
    ctx.setFillColor(inkColor)
    ctx.addPath(CGPath(ellipseIn: r, transform: nil))
    ctx.fillPath()
    // tiny catchlight
    let highlight = CGRect(x: ex - eyeRadius * 0.35,
                           y: ey + eyeRadius * 0.15,
                           width: eyeRadius * 0.5,
                           height: eyeRadius * 0.5)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
    ctx.addPath(CGPath(ellipseIn: highlight, transform: nil))
    ctx.fillPath()
}

// Smile — small open arc under the nose
ctx.saveGState()
ctx.setStrokeColor(inkColor)
ctx.setLineWidth(size * 0.012)
ctx.setLineCap(.round)
let mouthY = noseRect.minY - size * 0.06
ctx.move(to: CGPoint(x: cx - size * 0.045, y: mouthY))
ctx.addQuadCurve(to: CGPoint(x: cx + size * 0.045, y: mouthY),
                 control: CGPoint(x: cx, y: mouthY - size * 0.04))
ctx.strokePath()
ctx.restoreGState()

// Tongue — small pink tab
let tongueRect = CGRect(x: cx - size * 0.025,
                        y: mouthY - size * 0.04,
                        width: size * 0.05,
                        height: size * 0.04)
ctx.setFillColor(CGColor(red: 0.94, green: 0.55, blue: 0.55, alpha: 1.0))
ctx.addPath(CGPath(roundedRect: tongueRect,
                   cornerWidth: tongueRect.width * 0.3,
                   cornerHeight: tongueRect.height * 0.3,
                   transform: nil))
ctx.fillPath()

guard let cgImage = ctx.makeImage() else { fatalError("Failed to make image") }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
let url = URL(fileURLWithPath: outPath)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try data.write(to: url)
print("Wrote \(outPath)")
