import Foundation
import CoreGraphics
import ImageIO

// 从确认后的 PNG 原稿生成全尺寸 ICNS，保留透明边缘。
// 用法：swift scripts/make-icon.swift [输出.icns]
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sourceURL = root.appendingPathComponent("Resources/AppIcon-source.png")
let outputURL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("Resources/AppIcon.icns")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width == image.height, image.width >= 1024 else {
    fail("图标原稿必须是至少 1024 × 1024 的正方形图片：\(sourceURL.path)")
}

let temporaryURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("send-word-icon-\(UUID().uuidString)")
let iconsetURL = temporaryURL.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryURL) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fail("无法创建 \(pixels) 像素图标") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let suffix = scale == 2 ? "@2x" : ""
        let url = iconsetURL.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        guard let resized = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { fail("无法生成 \(url.lastPathComponent)") }
        CGImageDestinationAddImage(destination, resized, nil)
        guard CGImageDestinationFinalize(destination) else { fail("无法写入 \(url.path)") }
    }
}

let generatedURL = temporaryURL.appendingPathComponent("AppIcon.icns")
let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["-c", "icns", iconsetURL.path, "-o", generatedURL.path]
try converter.run()
converter.waitUntilExit()
guard converter.terminationStatus == 0 else { fail("iconutil 生成图标失败") }
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data(contentsOf: generatedURL).write(to: outputURL, options: .atomic)
print("已生成 \(outputURL.path)")
