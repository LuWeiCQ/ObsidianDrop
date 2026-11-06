import AppKit

/// ObsidianDrop 的统一标记（1.7.0 重新设计）。
///
/// 造型只有两个几何：一块圆角「投递箱」+ 一个向下箭头。箭头用**负空间**挖空，
/// 不描边、不堆细节——这样 18pt 菜单栏、40pt 面板头部、1024pt 应用图标用的是
/// 同一条路径，小尺寸不会因为线条太密糊成一团。
///
/// 设计网格固定 100×100、左上原点，方便和三处输出的比例一一对应。
enum LogoMark {
    /// 100×100 网格的 U 形托盘（中线路径，用 12 单位圆头粗线描边）
    ///
    /// 与 tools/make-icon.swift 的几何逐点一致：菜单栏 18pt、面板 40pt、应用图标
    /// 1024pt 共用同一份坐标，改一处三处同步。
    static func trayPath() -> NSBezierPath {
        let p = NSBezierPath()
        p.lineWidth = 12
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.move(to: NSPoint(x: 20, y: 22))
        p.line(to: NSPoint(x: 20, y: 68))
        p.line(to: NSPoint(x: 80, y: 68))
        p.line(to: NSPoint(x: 80, y: 22))
        return p
    }

    /// 箭头是一笔画完的多边形，避免「杆 + 三角」两段重叠出接缝
    static func arrowPath() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 45, y: 18))
        p.line(to: NSPoint(x: 55, y: 18))
        p.line(to: NSPoint(x: 55, y: 40))
        p.line(to: NSPoint(x: 66, y: 40))
        p.line(to: NSPoint(x: 50, y: 60))
        p.line(to: NSPoint(x: 34, y: 40))
        p.line(to: NSPoint(x: 45, y: 40))
        p.close()
        return p
    }

    /// 画进 NSView 坐标（左下原点），自动翻转成设计网格的向下坐标。
    ///
    /// 按内容包围盒（x14…86，y18…70）缩放而不是整张 100 网格：网格四周本来
    /// 是给描边留的余量，直接按 100 缩放会让图形只占目标区域的一半，看起来
    /// 就是「图标被压缩了」。这里统一留 8% 内边距，三处输出的视觉重量一致。
    static func draw(in rect: NSRect, color: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pad = min(rect.width, rect.height) * 0.08
        let target = rect.insetBy(dx: pad, dy: pad)
        let s = min(target.width / 71, target.height / 57)
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: rect.width / 2 - 50 * s, y: rect.height / 2 - 45 * s)
        ctx.scaleBy(x: s, y: s)
        color.setStroke()
        color.setFill()
        trayPath().stroke()
        arrowPath().fill()
        ctx.restoreGState()
    }

    /// 矢量 NSImage：Retina 下按实际像素重绘，不会像位图缩放那样发虚
    static func image(pointSize: CGFloat, color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: pointSize, height: pointSize),
                          flipped: false) { r in
            draw(in: r, color: color)
            return true
        }
        img.isTemplate = false
        return img
    }
}
