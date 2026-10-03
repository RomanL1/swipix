import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Synthetic landscapes, with invented metadata; never use personal library images in QA.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for variant in 0..<4 {
    let width = 1024, height = 768
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    var seed: UInt64 = UInt64(variant + 1)
    for y in 0..<height {
        for x in 0..<width {
            seed = seed &* 6364136223846793005 &+ 1
            let noise = Int((seed >> 32) % 23) - 11
            let ridge = 310 + Int(90 * sin(Double(x) / 170 + Double(variant))) + abs(x - 600) / 5
            let foreground = 580 + Int(45 * sin(Double(x) / 250))
            let color: [Int]
            if y < ridge { color = [130 + y / 12, 187 + y / 16, 220 + y / 20] }
            else if y < foreground { color = [75 + variant * 18 + y / 18, 119 + y / 20, 134 + y / 22] }
            else { color = [48 + variant * 16, 89 + x / 60, 69 + y / 32] }
            for c in 0..<3 { pixels[(y * width + x) * 4 + c] = UInt8(max(0, min(255, color[c] + noise))) }
        }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    let url = directory.appendingPathComponent("landscape-\(variant).jpg")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [
        kCGImageDestinationLossyCompressionQuality: 0.99,
        kCGImagePropertyOrientation: 1,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:0\(variant + 1) 12:00:00"],
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "Synthetic Swipix QA landscape"]
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("Fixture encoding failed") }
    print(url.path)
}
