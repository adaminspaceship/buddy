#!/usr/bin/env swift
import AppKit
import CoreGraphics
import CoreText

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

// Warm cream → soft amber gradient — same warmth as the in-app palette.
let bgColors = [
    CGColor(red: 0.97, green: 0.94, blue: 0.88, alpha: 1.0), // cream
    CGColor(red: 0.93, green: 0.83, blue: 0.65, alpha: 1.0)  // soft amber
] as CFArray
let bgGradient = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1])!
ctx.drawLinearGradient(bgGradient,
                       start: CGPoint(x: 0, y: size),
                       end: CGPoint(x: size, y: 0),
                       options: [])

// Soft top-right glow for depth.
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

// Typewriter-serif lowercase "b" monogram in deep ink.
let inkColor = NSColor(red: 0.18, green: 0.14, blue: 0.10, alpha: 1.0)
let fontSize: CGFloat = 720
let font = NSFont(name: "AmericanTypewriter-Bold", size: fontSize)
    ?? NSFont(name: "AmericanTypewriter", size: fontSize)
    ?? NSFont.boldSystemFont(ofSize: fontSize)

let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: inkColor
]
let attributedString = NSAttributedString(string: "b", attributes: attrs)
let line = CTLineCreateWithAttributedString(attributedString)
let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

// Center the glyph in the canvas.
let glyphX = (size - bounds.width) / 2 - bounds.origin.x
let glyphY = (size - bounds.height) / 2 - bounds.origin.y

ctx.saveGState()
ctx.textPosition = CGPoint(x: glyphX, y: glyphY)
CTLineDraw(line, ctx)
ctx.restoreGState()

// A small soft pulse dot in the lower-right corner — subtle hint at the
// always-listening rolling-buffer concept without being a full mic icon.
let dotRadius: CGFloat = size * 0.04
let dotCenter = CGPoint(x: size * 0.78, y: size * 0.22)
ctx.setFillColor(CGColor(red: 0.78, green: 0.42, blue: 0.32, alpha: 0.9))
ctx.addPath(CGPath(ellipseIn: CGRect(
    x: dotCenter.x - dotRadius,
    y: dotCenter.y - dotRadius,
    width: dotRadius * 2,
    height: dotRadius * 2), transform: nil))
ctx.fillPath()

guard let cgImage = ctx.makeImage() else { fatalError("Failed to make image") }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
let url = URL(fileURLWithPath: outPath)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try data.write(to: url)
print("Wrote \(outPath)")
