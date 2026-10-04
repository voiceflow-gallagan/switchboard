import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct IconVariant {
  let name: String
  let pixels: Int
}

enum IconError: Error {
  case contextCreationFailed
  case gradientCreationFailed
  case imageCreationFailed
  case destinationCreationFailed
  case writeFailed
  case usage
}

let variants: [IconVariant] = [
  IconVariant(name: "icon_16x16.png", pixels: 16),
  IconVariant(name: "icon_16x16@2x.png", pixels: 32),
  IconVariant(name: "icon_32x32.png", pixels: 32),
  IconVariant(name: "icon_32x32@2x.png", pixels: 64),
  IconVariant(name: "icon_128x128.png", pixels: 128),
  IconVariant(name: "icon_128x128@2x.png", pixels: 256),
  IconVariant(name: "icon_256x256.png", pixels: 256),
  IconVariant(name: "icon_256x256@2x.png", pixels: 512),
  IconVariant(name: "icon_512x512.png", pixels: 512),
  IconVariant(name: "icon_512x512@2x.png", pixels: 1024),
]

let canvasSize: CGFloat = 1024
let squareSize: CGFloat = 824
let squareCornerRadius: CGFloat = 185
let designSize: CGFloat = 160
let designScale: CGFloat = squareSize / designSize

let pillWidth: CGFloat = 34
let pillHeight: CGFloat = 18
let pillRadius: CGFloat = 9
let knobRadius: CGFloat = 6
let rowOrigins: [CGFloat] = [48, 94]
let columnOrigins: [CGFloat] = [24, 63, 102]
let offPills: Set<[Int]> = [[0, 1], [1, 2]]

func color(_ hex: UInt32, alpha: CGFloat = 1, in space: CGColorSpace) -> CGColor {
  let red = CGFloat((hex >> 16) & 0xFF) / 255
  let green = CGFloat((hex >> 8) & 0xFF) / 255
  let blue = CGFloat(hex & 0xFF) / 255
  return CGColor(colorSpace: space, components: [red, green, blue, alpha])
    ?? CGColor(gray: 0, alpha: alpha)
}

func drawIcon(pixels: Int) throws -> CGImage {
  guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
    throw IconError.contextCreationFailed
  }
  guard
    let context = CGContext(
      data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { throw IconError.contextCreationFailed }

  let scale = CGFloat(pixels) / canvasSize
  // Flip to a top-left origin so coordinates match the design space.
  context.translateBy(x: 0, y: CGFloat(pixels))
  context.scaleBy(x: scale, y: -scale)
  context.interpolationQuality = .high
  context.setShouldAntialias(true)

  let margin = (canvasSize - squareSize) / 2
  context.translateBy(x: margin, y: margin)
  context.scaleBy(x: designScale, y: designScale)

  let squareRect = CGRect(x: 0, y: 0, width: designSize, height: designSize)
  let squarePath = CGPath(
    roundedRect: squareRect, cornerWidth: squareCornerRadius / designScale,
    cornerHeight: squareCornerRadius / designScale, transform: nil)

  context.saveGState()
  context.addPath(squarePath)
  context.clip()

  guard
    let background = CGGradient(
      colorsSpace: space,
      colors: [color(0x4F46E5, in: space), color(0x8B5CF6, in: space)] as CFArray,
      locations: [0, 1])
  else { throw IconError.gradientCreationFailed }
  context.drawLinearGradient(
    background, start: CGPoint(x: 0, y: 0), end: CGPoint(x: designSize, y: designSize), options: [])

  guard
    let sheen = CGGradient(
      colorsSpace: space,
      colors: [color(0xFFFFFF, alpha: 0.22, in: space), color(0xFFFFFF, alpha: 0, in: space)]
        as CFArray,
      locations: [0, 1])
  else { throw IconError.gradientCreationFailed }
  context.drawLinearGradient(
    sheen, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: designSize / 2), options: [])
  context.restoreGState()

  for (row, originY) in rowOrigins.enumerated() {
    for (column, originX) in columnOrigins.enumerated() {
      let isOff = offPills.contains([row, column])
      let pillRect = CGRect(x: originX, y: originY, width: pillWidth, height: pillHeight)
      let pillPath = CGPath(
        roundedRect: pillRect, cornerWidth: pillRadius, cornerHeight: pillRadius, transform: nil)
      context.setFillColor(color(0xFFFFFF, alpha: isOff ? 0.35 : 1, in: space))
      context.addPath(pillPath)
      context.fillPath()

      let knobCenterX = originX + (isOff ? 9 : 25)
      let knobCenterY = originY + 9
      let knobRect = CGRect(
        x: knobCenterX - knobRadius, y: knobCenterY - knobRadius,
        width: knobRadius * 2, height: knobRadius * 2)
      context.setFillColor(color(isOff ? 0xFFFFFF : 0x4F46E5, in: space))
      context.fillEllipse(in: knobRect)
    }
  }

  guard let image = context.makeImage() else { throw IconError.imageCreationFailed }
  return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
  guard
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { throw IconError.destinationCreationFailed }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { throw IconError.writeFailed }
}

func run() throws {
  let arguments = CommandLine.arguments
  guard arguments.count == 2 else { throw IconError.usage }
  let outputFolder = URL(fileURLWithPath: arguments[1], isDirectory: true)
  try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
  for variant in variants {
    let image = try drawIcon(pixels: variant.pixels)
    try writePNG(image, to: outputFolder.appendingPathComponent(variant.name))
  }
}

do {
  try run()
} catch IconError.usage {
  FileHandle.standardError.write(Data("usage: swift Tools/make-icon.swift <output folder>\n".utf8))
  exit(64)
} catch {
  FileHandle.standardError.write(Data("make-icon failed: \(error)\n".utf8))
  exit(1)
}
