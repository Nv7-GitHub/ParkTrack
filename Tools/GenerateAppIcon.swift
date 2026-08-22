// Draws the ParkTrack app icon and writes the three appearance variants iOS 18 asks for.
//
// The icon is generated rather than hand-drawn so it stays in step with the palette in
// ParkTrack/Design/Theme.swift: the same canopy → moss → sky gradient the app's hero
// header uses, behind the two ideas the app is actually about — a tree, inside a
// completion ring that is deliberately not yet closed.
//
// Run from the repo root:  swift Tools/GenerateAppIcon.swift
// It writes into ParkTrack/Resources/Assets.xcassets/AppIcon.appiconset.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side: CGFloat = 1024
let center = CGPoint(x: side / 2, y: side / 2)

// Matching Theme.swift.
let canopy = (r: 0.106, g: 0.263, b: 0.196)   // 1B4332
let moss   = (r: 0.176, g: 0.416, b: 0.310)   // 2D6A4F
let sky    = (r: 0.114, g: 0.435, b: 0.620)   // 1D6F9E
let skyLit = (r: 0.498, g: 0.784, b: 0.941)   // 7FC8F0
let paper  = (r: 0.929, g: 0.965, b: 0.937)   // EDF6EF

enum Variant {
    case light, dark, tinted
}

/// Tinted icons are a mask and need their transparency; light and dark are full-bleed
/// artwork and must not have an alpha channel at all.
///
/// App Store Connect will not display an icon whose PNG contains alpha, even when every
/// pixel in it is opaque — which is what these were: a channel carried for no reason, and an
/// app with no picture next to it in the console. Nothing about the artwork changes here,
/// only whether a fourth channel is written out beside it.
func makeContext(_ variant: Variant) -> CGContext {
    let context = CGContext(
        data: nil,
        width: Int(side),
        height: Int(side),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: variant == .tinted
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    // Draw in top-left origin coordinates, which is easier to reason about.
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)
    return context
}

func drawBackground(_ context: CGContext, _ variant: Variant) {
    switch variant {
    case .tinted:
        // The system tints a grayscale image, so the art carries no colour of its own.
        return
    case .light, .dark:
        let stops: [(r: Double, g: Double, b: Double)] = variant == .light
            ? [canopy, moss, sky]
            : [(0.043, 0.078, 0.063), (0.071, 0.145, 0.110), (0.063, 0.169, 0.220)]
        let colors = stops.map {
            CGColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1)
        } as CFArray
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: colors,
            locations: [0, 0.55, 1]
        )!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: side, y: side),
            options: []
        )
    }
}

/// The completion ring: a full faint track with a bright arc over roughly three quarters
/// of it. Left open on purpose — there are always more parks to get to.
func drawRing(_ context: CGContext, _ variant: Variant) {
    let radius: CGFloat = 300
    let lineWidth: CGFloat = 58

    let trackAlpha: CGFloat = variant == .tinted ? 0.30 : 0.26
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: trackAlpha))
    context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    context.strokePath()

    let arcColor: CGColor = variant == .tinted
        ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        : CGColor(red: skyLit.r, green: skyLit.g, blue: skyLit.b, alpha: 1)
    context.setStrokeColor(arcColor)
    // Starts at twelve o'clock and sweeps 74% of the way round.
    let start = -CGFloat.pi / 2
    context.addArc(
        center: center,
        radius: radius,
        startAngle: start,
        endAngle: start + .pi * 2 * 0.74,
        clockwise: false
    )
    context.strokePath()
}

/// A tree as three overlapping canopy circles over a tapered trunk — the shape stays
/// readable when the icon is drawn at 40 points on a home screen.
func drawTree(_ context: CGContext, _ variant: Variant) {
    let color = variant == .tinted
        ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        : CGColor(red: paper.r, green: paper.g, blue: paper.b, alpha: 1)
    context.setFillColor(color)

    let trunk = CGMutablePath()
    trunk.move(to: CGPoint(x: 490, y: 540))
    trunk.addLine(to: CGPoint(x: 534, y: 540))
    trunk.addLine(to: CGPoint(x: 550, y: 726))
    trunk.addQuadCurve(to: CGPoint(x: 512, y: 742), control: CGPoint(x: 530, y: 742))
    trunk.addQuadCurve(to: CGPoint(x: 474, y: 726), control: CGPoint(x: 494, y: 742))
    trunk.closeSubpath()
    context.addPath(trunk)
    context.fillPath()

    for circle in [
        (x: CGFloat(512), y: CGFloat(418), r: CGFloat(124)),
        (x: CGFloat(430), y: CGFloat(482), r: CGFloat(100)),
        (x: CGFloat(594), y: CGFloat(482), r: CGFloat(100))
    ] {
        context.addEllipse(in: CGRect(
            x: circle.x - circle.r,
            y: circle.y - circle.r,
            width: circle.r * 2,
            height: circle.r * 2
        ))
    }
    context.fillPath()
}

func render(_ variant: Variant, to url: URL) {
    let context = makeContext(variant)
    drawBackground(context, variant)
    drawRing(context, variant)
    drawTree(context, variant)

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL, UTType.png.identifier as CFString, 1, nil
          ) else {
        fatalError("Could not create \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write \(url.lastPathComponent)")
    }
    print("wrote \(url.path)")
}

let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("ParkTrack/Resources/Assets.xcassets/AppIcon.appiconset")
try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

render(.light, to: output.appendingPathComponent("icon-light.png"))
render(.dark, to: output.appendingPathComponent("icon-dark.png"))
render(.tinted, to: output.appendingPathComponent("icon-tinted.png"))
