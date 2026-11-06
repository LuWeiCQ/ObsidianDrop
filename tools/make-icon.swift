// ObsidianDrop 图标生成器（纯 AppKit / CoreGraphics，无第三方依赖）
//
// 1.7.0 重新设计：只保留两个几何——圆角「投递箱」+ 负空间向下箭头。
// 去掉了折角、内容线、落点光与多层高光，理由是它们在 18pt 菜单栏与 16px
// 列表里全部糊成一团，看起来像「被压缩」。同一条 100×100 路径同时产出：
//   · 1024 应用图标（深底 + 暖白标记，按 macOS 规范 824 圆角矩形）
//   · 18pt / 36pt 菜单栏模板（单色，isTemplate 由 App 侧设置）
// 面板头部的 40pt 标记由 App 内的 LogoMark 矢量绘制，不依赖位图。
//
//   xcrun swiftc -O tools/make-icon.swift -o /tmp/od-make-icon
//   /tmp/od-make-icon Resources
import Foundation
import AppKit

func makeCanvas(_ px: Int) -> (NSBitmapImageRep, CGContext) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    return (rep, ctx)
}

func pngData(_ rep: NSBitmapImageRep) -> Data {
    rep.representation(using: .png, properties: [:])!
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func rr(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
        _ r: CGFloat) {
    c.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                     cornerWidth: r, cornerHeight: r, transform: nil))
}

/// 100×100 设计网格：粗线 U 形托盘 + 悬在其上的实心箭头。
///
/// 不用「实心块 + 镂空箭头」：18pt 下那块实心区域会糊成一个白方块，
/// 镂空处只剩一个黑十字。U 形托盘用 12 单位圆头粗线描边，留白多，
/// 缩到 18px 仍然是两条竖边 + 一条底边，箭头也还看得出朝下。
func markTray(_ c: CGContext, lineWidth: CGFloat = 12) {
    c.saveGState()
    c.setLineWidth(lineWidth)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.move(to: CGPoint(x: 20, y: 22))
    c.addLine(to: CGPoint(x: 20, y: 68))
    c.addLine(to: CGPoint(x: 80, y: 68))
    c.addLine(to: CGPoint(x: 80, y: 22))
    c.strokePath()
    c.restoreGState()
}

/// 箭头是一个多边形（杆 + 三角一笔画完，避免两段重叠产生接缝）。
/// `simplified` 用于 16/32px 档：箭杆在那个尺寸只有 1px 多，会和托盘内壁
/// 糊成一团，所以直接去掉杆、把三角放大。
func markArrow(_ c: CGContext, simplified: Bool = false) {
    if simplified {
        c.move(to: CGPoint(x: 30, y: 36))
        c.addLine(to: CGPoint(x: 70, y: 36))
        c.addLine(to: CGPoint(x: 50, y: 56))
        c.closePath()
        c.fillPath()
        return
    }
    c.move(to: CGPoint(x: 45, y: 18))
    c.addLine(to: CGPoint(x: 55, y: 18))
    c.addLine(to: CGPoint(x: 55, y: 40))
    c.addLine(to: CGPoint(x: 66, y: 40))
    c.addLine(to: CGPoint(x: 50, y: 60))
    c.addLine(to: CGPoint(x: 34, y: 40))
    c.addLine(to: CGPoint(x: 45, y: 40))
    c.closePath()
    c.fillPath()
}

// MARK: - 应用图标（1024 母版；SVG 左上原点）

func drawAppIcon(_ c: CGContext, px: CGFloat) {
    let k = px / 1024
    c.saveGState()
    c.scaleBy(x: k, y: k)
    c.translateBy(x: 0, y: 1024)
    c.scaleBy(x: 1, y: -1)
    defer { c.restoreGState() }

    // 底板：macOS 规范 824×824、圆角 185，四周留 100
    c.saveGState()
    rr(c, 100, 100, 824, 824, 185)
    c.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [rgb(0x222741), rgb(0x10131F)] as CFArray,
                       locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 140, y: 140),
                         end: CGPoint(x: 884, y: 884), options: [])
    c.restoreGState()

    // 标记：按内容包围盒（x14…86，y18…70）缩放到 520 宽并居中，
    // 而不是按 100 网格整格缩放——网格四周有空隙，直接缩放会让图形偏小。
    let markW: CGFloat = 520
    let s = markW / 71
    c.saveGState()
    c.translateBy(x: 512 - 50 * s, y: 512 - 45 * s)
    c.scaleBy(x: s, y: s)
    c.setStrokeColor(rgb(0xF7F2E8))
    c.setFillColor(rgb(0xF7F2E8))
    let small = px <= 32
    markTray(c, lineWidth: small ? 15 : 12)
    markArrow(c, simplified: small)
    c.restoreGState()
}

// MARK: - 菜单栏模板（18 / 36 单色）

func drawMenuTemplate(_ c: CGContext, px: CGFloat) {
    let k = px / 18
    c.saveGState()
    c.scaleBy(x: k, y: k)
    c.translateBy(x: 0, y: 18)
    c.scaleBy(x: 1, y: -1)
    defer { c.restoreGState() }

    c.saveGState()
    // 内容包围盒缩放到 16pt、四周留 1pt：18px 里图形才有足够像素，不会被压成一条线
    let s = 15.0 / 71.0
    c.translateBy(x: 9 - 50 * s, y: 9 - 45 * s)
    c.scaleBy(x: s, y: s)
    c.setStrokeColor(rgb(0x000000))
    c.setFillColor(rgb(0x000000))
    markTray(c)
    markArrow(c)
    c.restoreGState()
}

// MARK: - 输出

let outDir: URL = {
    let a = CommandLine.arguments
    let p = a.count > 1 ? a[1] : "Resources"
    return URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
}()
let fm = FileManager.default
try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? fm.removeItem(at: iconset)
try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    let (rep, ctx) = makeCanvas(px)
    drawAppIcon(ctx, px: CGFloat(px))
    let d = pngData(rep)
    try? d.write(to: iconset.appendingPathComponent(name))
    if name == "icon_512x512@2x.png" {
        try? d.write(to: outDir.appendingPathComponent("AppIconSource.png"))
    }
}

for (name, px) in [("MenuBarTemplate.png", 18), ("MenuBarTemplate@2x.png", 36)] {
    let (rep, ctx) = makeCanvas(px)
    drawMenuTemplate(ctx, px: CGFloat(px))
    try? pngData(rep).write(to: outDir.appendingPathComponent(name))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o",
                  outDir.appendingPathComponent("AppIcon.icns").path]
try? task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败\n".data(using: .utf8)!)
    exit(1)
}
print("图标输出：\(outDir.path)")
print("  AppIconSource.png / AppIcon.iconset（10 档）/ AppIcon.icns")
print("  MenuBarTemplate.png / MenuBarTemplate@2x.png")
