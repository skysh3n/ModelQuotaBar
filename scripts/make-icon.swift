// 生成应用图标。用法：swift make-icon.swift <输出目录>
//
// 画一个 Big Sur 风格圆角方块：蓝紫渐变底 + 一枚环形用量表，
// 表环填充比例对应「剩余 72%」，和小组件里的视觉语言一致。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024.0
let space = CGColorSpaceCreateDeviceRGB()

guard let context = CGContext(
    data: nil,
    width: Int(side),
    height: Int(side),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    FileHandle.standardError.write(Data("无法创建绘图上下文\n".utf8))
    exit(1)
}

// macOS 图标在画布里留白，圆角方块约占 80%。
let inset = side * 0.098
let square = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let radius = square.width * 0.2237

let shape = CGPath(
    roundedRect: square,
    cornerWidth: radius,
    cornerHeight: radius,
    transform: nil)

// 背景渐变
context.saveGState()
context.addPath(shape)
context.clip()
let gradient = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(red: 0.36, green: 0.51, blue: 1.00, alpha: 1),
        CGColor(red: 0.53, green: 0.32, blue: 0.96, alpha: 1),
    ] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: square.minX, y: square.maxY),
    end: CGPoint(x: square.maxX, y: square.minY),
    options: [])
context.restoreGState()

// 环形用量表
let center = CGPoint(x: side / 2, y: side / 2)
let ringRadius = square.width * 0.30
let lineWidth = square.width * 0.115
// 从左下 324° 起顺时针扫 252°，缺口落在正下方——和常见的仪表盘图标一致。
let startAngle = Double.pi * 1.8
let sweep = Double.pi * 1.4
let remaining = 0.72

func arc(_ from: Double, _ to: Double) -> CGPath {
    let path = CGMutablePath()
    path.addArc(
        center: center,
        radius: ringRadius,
        startAngle: from,
        endAngle: to,
        clockwise: false)
    return path
}

context.setLineCap(.round)

// 底环
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.25))
context.setLineWidth(lineWidth)
context.addPath(arc(startAngle, startAngle + sweep))
context.strokePath()

// 剩余部分
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.setLineWidth(lineWidth)
context.addPath(arc(startAngle, startAngle + sweep * remaining))
context.strokePath()

// 中心的小圆点，避免大片空白显得空
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.92))
let dot = square.width * 0.075
context.fillEllipse(in: CGRect(
    x: center.x - dot,
    y: center.y - dot,
    width: dot * 2,
    height: dot * 2))

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("无法生成位图\n".utf8))
    exit(1)
}

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let output = URL(fileURLWithPath: outputDirectory).appendingPathComponent("icon-1024.png")

guard let destination = CGImageDestinationCreateWithURL(
    output as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil)
else {
    FileHandle.standardError.write(Data("无法写入 \(output.path)\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("已生成 \(output.path)")