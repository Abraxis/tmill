#!/usr/bin/env swift
// Generate MyMill app icon at all required sizes
// Design: dark rounded-rect background, speed gauge with two concentric arcs,
//         needle, speed readout "3.5", and activity pulse line

import Cocoa
import CoreGraphics
import Foundation

func generateIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        fatalError("No graphics context")
    }

    // --- Background: dark rounded rect ---
    let cornerRadius = s * 0.22
    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    // Dark gradient background
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let bgColors = [
        CGColor(red: 0.10, green: 0.12, blue: 0.18, alpha: 1.0),
        CGColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 1.0),
    ]
    let bgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: bgColors as CFArray,
                                 locations: [0.0, 1.0])!
    ctx.drawLinearGradient(bgGradient,
                           start: CGPoint(x: s/2, y: s),
                           end: CGPoint(x: s/2, y: 0),
                           options: [])
    ctx.restoreGState()

    // --- Gauge arcs ---
    // Both arcs share the SAME center and radius
    let centerX = s * 0.50
    let centerY = s * 0.52
    let arcRadius = s * 0.33
    let lineWidth = s * 0.045
    let startAngle = CGFloat.pi * 0.80   // ~216° from right (bottom-left area)
    let endAngle = CGFloat.pi * 0.20     // ~36° from right (top-right area)
    // The arc goes clockwise in CG coordinates (counterclockwise visually since y is flipped)
    // We want the arc to go from bottom-left to bottom-right across the top

    // Split point for blue->green transition (about 60% along the arc)
    let totalArcAngle = (2 * CGFloat.pi) - (startAngle - endAngle)
    let splitFraction: CGFloat = 0.55
    let splitAngle = startAngle + totalArcAngle * splitFraction

    // Blue arc (left portion)
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(lineWidth)
    let blueColor = CGColor(red: 0.20, green: 0.50, blue: 0.95, alpha: 1.0)
    ctx.setStrokeColor(blueColor)
    ctx.addArc(center: CGPoint(x: centerX, y: centerY),
               radius: arcRadius,
               startAngle: -startAngle,
               endAngle: -splitAngle,
               clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()

    // Green arc (right portion)
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(lineWidth)
    let greenColor = CGColor(red: 0.20, green: 0.85, blue: 0.45, alpha: 1.0)
    ctx.setStrokeColor(greenColor)
    ctx.addArc(center: CGPoint(x: centerX, y: centerY),
               radius: arcRadius,
               startAngle: -splitAngle,
               endAngle: -endAngle,
               clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()

    // --- Needle ---
    let needleAngle = startAngle + totalArcAngle * 0.62  // points slightly past center-right
    let needleLength = arcRadius * 0.85
    let needleEndX = centerX + needleLength * cos(-needleAngle)
    let needleEndY = centerY + needleLength * sin(-needleAngle)

    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(s * 0.025)
    ctx.setStrokeColor(greenColor)
    ctx.move(to: CGPoint(x: centerX, y: centerY))
    ctx.addLine(to: CGPoint(x: needleEndX, y: needleEndY))
    ctx.strokePath()

    // Needle center dot
    let dotRadius = s * 0.025
    ctx.setFillColor(greenColor)
    ctx.fillEllipse(in: CGRect(x: centerX - dotRadius, y: centerY - dotRadius,
                                width: dotRadius * 2, height: dotRadius * 2))
    ctx.restoreGState()

    // --- Speed text "3.5" ---
    let fontSize = s * 0.22
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let textAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let text = "3.5" as NSString
    let textSize = text.size(withAttributes: textAttributes)
    let textX = centerX - textSize.width / 2
    let textY = centerY - textSize.height * 1.1  // below center
    text.draw(at: NSPoint(x: textX, y: textY), withAttributes: textAttributes)

    // --- Pulse/activity line at bottom ---
    let pulseY = s * 0.18
    let pulseStartX = s * 0.15
    let pulseEndX = s * 0.85
    let pulseAmplitude = s * 0.06

    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(s * 0.02)

    // Create gradient for pulse line
    let pulsePath = CGMutablePath()
    pulsePath.move(to: CGPoint(x: pulseStartX, y: pulseY))

    // Flat line, then sharp peaks, then flat
    let segments: [(CGFloat, CGFloat)] = [
        (0.25, 0),          // flat
        (0.33, 0),          // flat
        (0.38, pulseAmplitude * 1.2),   // up
        (0.42, -pulseAmplitude * 0.6),  // down
        (0.46, pulseAmplitude * 1.8),   // big up
        (0.50, -pulseAmplitude * 1.4),  // big down
        (0.54, pulseAmplitude * 0.8),   // up
        (0.58, 0),          // back to baseline
        (0.65, 0),          // flat
        (1.0, 0),           // flat to end
    ]

    for (frac, yOffset) in segments {
        let x = pulseStartX + (pulseEndX - pulseStartX) * frac
        pulsePath.addLine(to: CGPoint(x: x, y: pulseY + yOffset))
    }

    // Stroke with blue-ish color
    let pulseColor = CGColor(red: 0.30, green: 0.55, blue: 0.80, alpha: 0.7)
    ctx.setStrokeColor(pulseColor)
    ctx.addPath(pulsePath)
    ctx.strokePath()
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

// Generate all sizes
let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] :
    FileManager.default.currentDirectoryPath + "/Treadmill/Assets.xcassets/AppIcon.appiconset"

let sizes = [16, 32, 64, 128, 256, 512, 1024]

for size in sizes {
    let image = generateIcon(size: size)

    // Convert to PNG
    guard let tiffData = image.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData),
          let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        print("Failed to create PNG for size \(size)")
        continue
    }

    let filename = "\(outputDir)/icon_\(size)x\(size).png"
    do {
        try pngData.write(to: URL(fileURLWithPath: filename))
        print("Generated: icon_\(size)x\(size).png")
    } catch {
        print("Error writing \(filename): \(error)")
    }
}

print("Done!")
