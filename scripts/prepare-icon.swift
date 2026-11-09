import Foundation
import CoreGraphics
import ImageIO

// 将满幅、不透明插画裁成居中的 macOS 连续圆角图标。
// 用法：swift scripts/prepare-icon.swift [满幅插画.png]
// 输出：Resources/AppIcon-source.png（1024 × 1024，四边各留 100 px）
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let inputURL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("Resources/AppIcon-artwork.png")
let outputURL = root.appendingPathComponent("Resources/AppIcon-source.png")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
      artwork.width == artwork.height, artwork.width >= 1024 else {
    fail("满幅插画必须是至少 1024 × 1024 的正方形图片：\(inputURL.path)")
}

let canvasSize = 1024
let tileSize = 824
let inset = 100
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

// 先缩放至 824 px，并在无 Alpha 的缓冲区中合成，确保圆角内完全不透明。
guard let tileContext = CGContext(
    data: nil, width: tileSize, height: tileSize, bitsPerComponent: 8,
    bytesPerRow: tileSize * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fail("无法创建插画缩放画布") }
tileContext.setFillColor(CGColor(colorSpace: colorSpace, components: [77 / 255.0, 163 / 255.0, 1, 1])!)
tileContext.fill(CGRect(x: 0, y: 0, width: tileSize, height: tileSize))
tileContext.interpolationQuality = .high
tileContext.draw(artwork, in: CGRect(x: 0, y: 0, width: tileSize, height: tileSize))
guard let tile = tileContext.makeImage() else { fail("无法缩放插画") }

guard let context = CGContext(
    data: nil, width: canvasSize, height: canvasSize, bitsPerComponent: 8,
    bytesPerRow: canvasSize * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fail("无法创建透明图标画布") }
context.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
context.setAllowsAntialiasing(true)
context.setShouldAntialias(true)

// |x/a|^5 + |y/a|^5 = 1，以 n = 5 超椭圆近似 macOS 连续圆角。
// 密集采样仅定义裁切轮廓；边缘的像素覆盖率由 CoreGraphics 抗锯齿处理。
let outline = CGMutablePath()
let half = Double(tileSize) / 2
let center = Double(inset) + half
let segments = 4096
func signedPower(_ value: Double) -> Double {
    (value < 0 ? -1 : 1) * pow(abs(value), 2.0 / 5.0)
}
for index in 0..<segments {
    let angle = Double(index) / Double(segments) * 2 * Double.pi
    let point = CGPoint(
        x: center + half * signedPower(cos(angle)),
        y: center + half * signedPower(sin(angle))
    )
    if index == 0 {
        outline.move(to: point)
    } else {
        outline.addLine(to: point)
    }
}
outline.closeSubpath()

let tileRect = CGRect(x: inset, y: inset, width: tileSize, height: tileSize)
context.clip(to: tileRect)
context.addPath(outline)
context.clip()
context.draw(tile, in: tileRect)

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL, "public.png" as CFString, 1, nil
      ) else { fail("无法创建 PNG 输出") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fail("无法写入 \(outputURL.path)") }
print("已生成 \(outputURL.path)（824 × 824，n = 5，透明边距 100 px）")
