import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.10, green: 0.19, blue: 0.31, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.saveGState(); context.translateBy(x: 512, y: 512); context.rotate(by: -.pi / 14)
context.setFillColor(CGColor(red: 0.47, green: 0.73, blue: 0.75, alpha: 1))
context.addPath(CGPath(roundedRect: CGRect(x: -265, y: -275, width: 460, height: 570), cornerWidth: 65, cornerHeight: 65, transform: nil)); context.fillPath(); context.restoreGState()
context.setFillColor(CGColor(red: 0.94, green: 0.97, blue: 1, alpha: 1))
context.addPath(CGPath(roundedRect: CGRect(x: 350, y: 235, width: 430, height: 570), cornerWidth: 65, cornerHeight: 65, transform: nil)); context.fillPath()
context.setStrokeColor(CGColor(red: 0.12, green: 0.47, blue: 0.39, alpha: 1)); context.setLineWidth(45); context.setLineCap(.round); context.setLineJoin(.round)
context.move(to: CGPoint(x: 455, y: 520)); context.addLine(to: CGPoint(x: 535, y: 440)); context.addLine(to: CGPoint(x: 675, y: 610)); context.strokePath()
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
