import AppKit

// MARK: - 1.7.0 下拉面板组件层（规格 B2 / B3 / B4）
//
// 所有 frame 由 PanelLayout 一处算出来，事件处理里不写新魔数。
// docked（160×176）完全不用这一层，保留 1.6.0 外观。

enum UIWorkState {
    case idle, working, done, skipped, failed
}

enum PanelPalette {
    static func isDark(_ v: NSView) -> Bool {
        v.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func surface(_ v: NSView) -> NSColor {
        // B4.1：浅色 #FFFFFF alpha 0.66 / 深色 #FFFFFF alpha 0.055。
        // 两种模式底色都是白色，只改透明度；曾经在这里写了 isDark ? 1 : 0，
        // 导致浅色模式头部变成 66% 黑块，文字对比度全丢。
        NSColor(calibratedWhite: 1, alpha: isDark(v) ? 0.055 : 0.66)
    }

    static func selected(_ v: NSView) -> NSColor {
        NSColor.controlAccentColor.withAlphaComponent(isDark(v) ? 0.20 : 0.12)
    }

    static func hover(_ v: NSView) -> NSColor {
        NSColor.labelColor.withAlphaComponent(isDark(v) ? 0.08 : 0.055)
    }

    static func border(_ v: NSView) -> NSColor {
        NSColor(calibratedWhite: isDark(v) ? 1 : 0, alpha: isDark(v) ? 0.14 : 0.10)
    }

    static let success = NSColor(srgbRed: 0x24 / 255, green: 0x8A / 255, blue: 0x3D / 255, alpha: 1)
    static let successDark = NSColor(srgbRed: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255, alpha: 1)
    static let error = NSColor(srgbRed: 0xD7 / 255, green: 0x00 / 255, blue: 0x15 / 255, alpha: 1)
    static let errorDark = NSColor(srgbRed: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)
    static let warning = NSColor(srgbRed: 0xC9 / 255, green: 0x34 / 255, blue: 0x00 / 255, alpha: 1)
    static let warningDark = NSColor(srgbRed: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)

    static func stateColor(_ s: UIWorkState, _ v: NSView) -> NSColor {
        switch s {
        // 复核修补：规格 B4 的 tertiaryLabelColor 在深色上几乎看不见，
        // secondaryLabelColor 经徽标底色 alpha 混合后仍偏灰。按用户反馈直接用
        // 固定高对比色，深浅两种外观都保证「就绪」一眼可读。
        case .idle:
            return isDark(v) ? NSColor(calibratedWhite: 0.88, alpha: 1)
                             : NSColor(calibratedWhite: 0.28, alpha: 1)
        case .working: return .controlAccentColor
        case .done: return isDark(v) ? successDark : success
        case .skipped: return isDark(v) ? warningDark : warning
        case .failed: return isDark(v) ? errorDark : error
        }
    }
}

/// 纯函数布局：默认 400×520 时与 B2 坐标表逐项一致（±1pt）。
/// 右下原点。W/H 变化时按规格的夹取规则缩放。
enum PanelLayout {
    struct Frames {
        var surface, header, icon, title, subtitle, badge, hint, shot, memo: NSRect
        var headSep, search, activity, resultsSep, results, footer, border, ring: NSRect
        var open, targetPill, shortcut: NSRect   // footer 局部坐标
        var visibleRows: Int
        var compact: Bool
    }

    static func frames(_ b: NSRect) -> Frames {
        let W = b.width, H = b.height
        let compact = H < 460
        let narrow = W < 360
        let surface = NSRect(x: 12, y: H - 124, width: W - 24, height: 108)
        let icon = NSRect(x: 20, y: H - 72, width: 40, height: 40)
        let title = NSRect(x: 76, y: H - 54, width: max(80, W - 188), height: 20)
        let subtitle = NSRect(x: 76, y: H - 76, width: max(80, W - 112), height: 16)
        let badge = NSRect(x: W - (narrow ? 44 : 100), y: H - 54,
                           width: narrow ? 28 : 80, height: 20)
        let hint = NSRect(x: 20, y: H - 110, width: min(180, W - 200), height: 16)
        let bw: CGFloat = narrow ? 64 : 76
        let mw: CGFloat = narrow ? 64 : 72
        // B2：头部表面右边界是 W-12，按钮组再内缩 8pt，所以右端落在 W-20，
        // 默认 400 宽时 shot.x=224 / memo.x=308。以前用 W-16 会整体右移 4pt，
        // 只剩 4pt 贴边留白。
        let shot = NSRect(x: W - 20 - mw - 8 - bw, y: H - 114, width: bw, height: 30)
        let memo = NSRect(x: W - 20 - mw, y: H - 114, width: mw, height: 30)
        let headSep = NSRect(x: 12, y: H - 132, width: W - 24, height: 1)
        let search = NSRect(x: 16, y: H - 176, width: W - 32, height: 32)
        let activity = NSRect(x: 16, y: H - 206, width: W - 32, height: 22)
        let resultsSep = NSRect(x: 12, y: H - 218, width: W - 32, height: 1)
        let resultsH = max(88, H - 286)
        let results = NSRect(x: 16, y: 60, width: W - 32, height: resultsH)
        let footer = NSRect(x: 12, y: 12, width: W - 24, height: 36)
        let visibleRows = max(2, min(5, Int((resultsH - 4) / PanelMetrics.rowHeight)))
        let ringSize: CGFloat = 52
        let ring = NSRect(x: icon.midX - ringSize / 2, y: icon.midY - ringSize / 2,
                          width: ringSize, height: ringSize)
        return Frames(
            surface: surface, header: surface, icon: icon, title: title,
            subtitle: subtitle, badge: badge, hint: hint, shot: shot, memo: memo,
            headSep: headSep, search: search, activity: activity, resultsSep: resultsSep,
            results: results, footer: footer, border: b, ring: ring,
            open: NSRect(x: 4, y: 4, width: 104, height: 28),
            targetPill: NSRect(x: 116, y: 4, width: 112, height: 28),
            // B2：底栏局部右端再留 4pt，默认 400 宽时全局 x=248、右端 384
            shortcut: NSRect(x: (W - 24) - 4 - 136, y: 4, width: 136, height: 28),
            visibleRows: visibleRows, compact: compact)
    }
}

// MARK: - 自绘组件

/// 规格 B4.2：自定义色必须在 effectiveAppearance 变化后重绘，
/// 不能缓存只算过一次的浅色 CGColor。所有自绘组件统一继承它。
class PaletteRedrawView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class DropSurfaceView: PaletteRedrawView {
    var dragging = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        PanelPalette.surface(self).setFill()
        path.fill()
        if dragging {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 2
        } else {
            NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1
        }
        path.stroke()
    }
}

/// 头部容器：只承担头部表面的一层柔和底色，交互仍归 DropView。
final class SceneHeaderView: PaletteRedrawView {
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).addClip()
        let g = NSGradient(starting: NSColor.controlAccentColor.withAlphaComponent(0.07),
                           ending: NSColor.clear)
        g?.draw(in: r, angle: 90)
    }
}

final class SceneBadgeView: PaletteRedrawView {
    var scene: AIScene = .legacy { didSet { needsDisplay = true } }
    var state: UIWorkState = .idle { didSet { needsDisplay = true } }
    var iconOnly = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        PanelPalette.hover(self).setFill()
        path.fill()
        let color = PanelPalette.stateColor(state, self)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: color,
        ]
        let text: String
        if iconOnly {
            text = "●"
        } else {
            switch state {
            case .idle: text = "就绪"
            case .working: text = scene.label
            case .done: text = "已整理"
            case .skipped: text = "AI 跳过"
            case .failed: text = "失败"
            }
        }
        let s = (text as NSString).size(withAttributes: attrs)
        let p = NSPoint(x: bounds.midX - s.width / 2,
                        y: bounds.midY - s.height / 2 + 1)
        (text as NSString).draw(at: p, withAttributes: attrs)
    }
}

final class ActivityStripView: PaletteRedrawView {
    private(set) var state: UIWorkState = .idle
    private var phase = "", detail = ""
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(_ state: UIWorkState, phase: String, detail: String) {
        self.state = state
        self.phase = phase
        self.detail = detail
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard state != .idle else { return }
        let c = PanelPalette.stateColor(state, self)
        let dot = NSBezierPath(ovalIn: NSRect(x: 2, y: bounds.midY - 3, width: 6, height: 6))
        c.setFill(); dot.fill()
        let tail = NSMutableParagraphStyle()
        tail.lineBreakMode = .byTruncatingTail
        let a: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: c,
            .paragraphStyle: tail,
        ]
        let phaseW = min((phase as NSString).size(withAttributes: a).width + 2,
                         bounds.width * 0.55)
        (phase as NSString).draw(in: NSRect(x: 14, y: bounds.midY - 7,
                                            width: phaseW, height: 14), withAttributes: a)
        if !detail.isEmpty {
            let b: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: tail,
            ]
            // 阶段名再长也不能把 detail 挤到条带外面；剩余宽度不够就整句不画。
            let x = 18 + phaseW
            let w = bounds.width - x - 4
            if w > 24 {
                (detail as NSString).draw(in: NSRect(x: x, y: bounds.midY - 7,
                                                     width: w, height: 14), withAttributes: b)
            }
        }
    }
}

final class TargetPillView: PaletteRedrawView {
    var title = "" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        PanelPalette.hover(self).setFill(); path.fill()
        let t = title.isEmpty ? "当前目标" : "→ " + title
        let tail = NSMutableParagraphStyle()
        tail.lineBreakMode = .byTruncatingTail
        let a: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: tail,
        ]
        // 长目标名按胶囊宽度尾部省略，不再直接越界画到快捷键提示上
        (t as NSString).draw(in: NSRect(x: 8, y: bounds.midY - 7,
                                        width: bounds.width - 16, height: 14),
                             withAttributes: a)
    }
}

final class PanelButton: NSButton {
    init(title: String, symbol: String? = nil) {
        super.init(frame: .zero)
        self.title = title
        self.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        self.bezelStyle = .rounded
        self.isBordered = true
        self.imagePosition = symbol == nil ? .noImage : .imageLeading
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            image?.isTemplate = true
        }
        self.wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class FooterBarView: NSView {
    let openButton = PanelButton(title: "打开 Obsidian", symbol: "arrow.up.forward.app")
    let targetPill = TargetPillView()
    let shortcutLabel = NSTextField(labelWithString: "⌘F 搜索 · ESC 收起")
    var onOpen: (() -> Void)?
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // 只让「打开」按钮接事件，其余点按仍归 DropView（拖放无死区）
        let p = convert(point, from: superview)
        if openButton.frame.contains(p) { return openButton }
        return super.hitTest(point)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        shortcutLabel.font = .systemFont(ofSize: 10)
        shortcutLabel.textColor = .tertiaryLabelColor
        shortcutLabel.alignment = .right
        openButton.target = self
        openButton.action = #selector(openTapped)
        addSubview(openButton)
        addSubview(targetPill)
        addSubview(shortcutLabel)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func openTapped() { onOpen?() }

    func apply(_ f: PanelLayout.Frames) {
        openButton.frame = f.open
        targetPill.frame = f.targetPill
        shortcutLabel.frame = f.shortcut
        shortcutLabel.isHidden = f.compact
    }
}

final class PanelBorderView: NSView {
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18)
        PanelPalette.border(self).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
