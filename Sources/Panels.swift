import AppKit

// MARK: - 面板模式（1.3.16）
//
// 一个面板实例、两种形态：
//   · `.dropdown` 从菜单栏图标下拉，临时可见，ESC / 点外部收起；
//   · `.docked`   常驻桌面浮窗（老行为）。
// 为什么不建两个窗口：焦点、层级、Exposé 三处会各说各话，最后一定对不齐。

enum PanelMode: String {
    case dropdown
    case docked
}

enum PanelMetrics {
    static let docked = NSSize(width: 160, height: 176)
    /// 1.7.0：下拉面板 400×520（规格 B1），定位仍走 dropdownFrame 夹取
    static let dropdown = NSSize(width: 400, height: 520)
    /// 旧常量保留给 docked / 自检；下拉布局一律由 PanelLayout 计算
    static let dropZoneHeight: CGFloat = 120
    static let rowHeight: CGFloat = 44

    static func size(for mode: PanelMode) -> NSSize {
        mode == .dropdown ? dropdown : docked
    }
}

/// 下拉定位：**返回 frame 而不是 origin**。
///
/// 只算原点不够——窄屏时面板本身就放不下，尺寸必须一起裁。
/// 顶部固定贴 `visibleFrame.maxY`（菜单栏下方），水平以图标为中线再夹进屏幕，
/// 这样刘海、副屏负坐标、菜单栏自动隐藏都不会把面板送出屏幕。
func dropdownFrame(anchor: NSRect?, visible: NSRect, size: NSSize) -> NSRect {
    let w = min(size.width, max(visible.width - 16, 120))
    let h = min(size.height, max(visible.height - 16, 80))
    guard let a = anchor, a.width > 0 else {
        // 图标不可得（状态项被系统收起 / Bartender 之类）：主屏顶部居中
        return NSRect(x: visible.midX - w / 2, y: visible.maxY - h, width: w, height: h)
    }
    let x = min(max(a.midX - w / 2, visible.minX + 8), visible.maxX - w - 8)
    return NSRect(x: x.rounded(), y: (visible.maxY - h).rounded(), width: w, height: h)
}

// MARK: - 搜索结果行

struct SearchRow {
    enum Kind { case vault, local }
    let kind: Kind
    /// 库内相对路径 / 库外绝对路径
    let path: String
    let title: String
    let detail: String
}

/// 自绘结果列表。
///
/// 不用 NSTableView 的原因：它要 dataSource/delegate/复用队列三套协议，
/// 而我们只有「最多 7 行、一次全刷」的体量；自绘还能顺手把选中态做成
/// 与面板一致的圆角高亮，不用和系统表格样式打架。
final class SearchResultsView: NSView {
    // B6.2：Tab 焦点环要把结果区算进去，否则从搜索框 Tab 会直接跳到截屏按钮。
    override var acceptsFirstResponder: Bool { true }
    /// 结果区自己拿到焦点时，↑↓/Return 与「搜索框编辑时」行为一致。
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: moveSelection(1)                       // ↓
        case 126: moveSelection(-1)                      // ↑
        case 36, 76:                                     // Return / 数字键盘 Return
            if rows.indices.contains(selected) { onPick?(selected) }
        default: super.keyDown(with: event)
        }
    }
    private(set) var rows: [SearchRow] = []
    private(set) var selected = 0
    /// 没有结果时的提示语（空串则不显示）
    var emptyText = "" { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?
    /// ↑↓ 移动后回调，用于滚动到可见
    var onSelectionChanged: ((Int) -> Void)?

    // 1.7.0：默认右下原点（规格 B2）。第 0 行在顶部，鼠标命中与绘制共用 rowFrame。
    func rowFrame(_ i: Int) -> NSRect {
        NSRect(x: 4, y: bounds.height - CGFloat(i + 1) * PanelMetrics.rowHeight + 2,
               width: bounds.width - 8, height: PanelMetrics.rowHeight - 4)
    }

    func setRows(_ r: [SearchRow], empty: String) {
        rows = r
        selected = r.isEmpty ? -1 : 0
        emptyText = empty
        needsDisplay = true
    }

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selected = min(max(selected + delta, 0), rows.count - 1)
        needsDisplay = true
        onSelectionChanged?(selected)
    }

    func clearSelectionHighlight() {
        selected = -1
        needsDisplay = true
    }

    var selectedRow: SearchRow? {
        guard rows.indices.contains(selected) else { return nil }
        return rows[selected]
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        if rows.isEmpty {
            guard !emptyText.isEmpty else { return }
            let parts = emptyText.components(separatedBy: "\n")
            let title = parts.first ?? ""
            let sub = parts.dropFirst().joined(separator: " ")
            let ta: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centered(),
            ]
            let sa: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: centered(),
            ]
            let cy = bounds.midY
            (title as NSString).draw(in: NSRect(x: 12, y: cy - 6, width: bounds.width - 24, height: 20),
                                     withAttributes: ta)
            if !sub.isEmpty {
                (sub as NSString).draw(in: NSRect(x: 12, y: cy - 26,
                                                  width: bounds.width - 24, height: 18),
                                       withAttributes: sa)
            }
            return
        }

        for (i, row) in rows.enumerated() {
            let r = rowFrame(i)
            guard r.maxY <= bounds.height + 1 else { continue }
            if i == selected {
                PanelPalette.selected(self).setFill()
                NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            }
            // 行类型图标（16pt）
            let symbol = row.kind == .vault ? "tray.full" : "doc"
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                img.isTemplate = true
                NSColor.secondaryLabelColor.setFill()
                img.draw(in: NSRect(x: r.minX + 8, y: r.midY - 8, width: 16, height: 16))
            }
            // B2：单行尾部省略，交给排版引擎按实际宽度截，不按字数中间省略。
            let tail = NSMutableParagraphStyle()
            tail.lineBreakMode = .byTruncatingTail
            let title = row.title
            let tAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: tail,
            ]
            (title as NSString).draw(in: NSRect(x: r.minX + 32, y: r.minY + 19,
                                                width: r.width - 96, height: 16),
                                     withAttributes: tAttrs)

            let detail = row.detail
            let dAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: tail,
            ]
            (detail as NSString).draw(in: NSRect(x: r.minX + 32, y: r.minY + 4,
                                                 width: r.width - 96, height: 14),
                                      withAttributes: dAttrs)

            let badge = row.kind == .vault ? "库内" : "本机"
            let bAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: row.kind == .vault
                    ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor,
            ]
            let bs = (badge as NSString).size(withAttributes: bAttrs)
            (badge as NSString).draw(at: NSPoint(x: r.maxX - bs.width - 12, y: r.midY - 7),
                                     withAttributes: bAttrs)
        }
    }

    private func centered() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return p
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = rows.indices.first(where: { rowFrame($0).contains(p) }) else { return }
        let old = selected
        selected = i
        needsDisplay = true
        // 单击只选中；双击或 Return 才打开（规格 B6.1）
        if old == i && event.clickCount >= 2 { onPick?(i) }
    }
}

// MARK: - 使用看板（1.4.1）
//
// 独立 NSWindow（不是 panel）：看板是要停下来看的东西，不该跟着菜单栏图标收起，
// 也不该压在所有窗口之上。

final class DashboardView: NSView {
    private var summary = MetricsSummary()
    private var recent: [MetricEvent] = []
    private var noteMap: [String: String] = [:]
    private var hitAreas: [(NSRect, () -> Void)] = []
    var onOpen: ((String) -> Void)?
    var onRefresh: (() -> Void)?

    override var isFlipped: Bool { true }

    private var loading = false

    /// 读盘 + 解析都放后台：events.jsonl 攒到几 MB 时，主线程解析会让看板在
    /// 打开的一瞬间「卡住不动」——而看板恰恰是用户判断「程序是不是卡了」的地方。
    func reload() {
        if loading { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let events = MetricsStore.shared.all(days: 7)
            let s = MetricsQuery.summary(events: events, days: 7)
            let r = MetricsQuery.recent(events: events, limit: 6)
            let m = MetricNoteMap.all()
            DispatchQueue.main.async {
                guard let self else { return }
                self.summary = s
                self.recent = r
                self.noteMap = m
                self.loading = false
                self.needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        hitAreas.removeAll()

        let pad: CGFloat = 20
        var y: CGFloat = pad

        // 标题行
        ("使用看板" as NSString).draw(at: NSPoint(x: pad, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        let sub = "最近 7 天 · 数据只存在本机"
        (sub as NSString).draw(at: NSPoint(x: pad + 86, y: y + 5), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let refreshRect = NSRect(x: bounds.width - pad - 52, y: y - 2, width: 52, height: 20)
        drawPill("刷新", in: refreshRect, tint: .secondaryLabelColor)
        hitAreas.append((refreshRect, { [weak self] in self?.onRefresh?() }))
        y += 34

        // 四张指标卡
        let cardW = (bounds.width - pad * 2 - 36) / 4
        let cards: [(String, String, NSColor)] = [
            ("投递", "\(summary.ok + summary.failed)", .labelColor),
            ("成功率", summary.ok + summary.failed == 0 ? "—"
                : String(format: "%.0f%%", summary.successRate * 100), .systemGreen),
            ("平均耗时", summary.avgMs == 0 ? "—" : "\(summary.avgMs)ms", .labelColor),
            ("打开率", summary.ok == 0 ? "—"
                : String(format: "%.0f%%", summary.openRate * 100), .controlAccentColor),
        ]
        for (i, c) in cards.enumerated() {
            let r = NSRect(x: pad + CGFloat(i) * (cardW + 12), y: y, width: cardW, height: 66)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            NSColor.controlBackgroundColor.withAlphaComponent(0.9).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            (c.1 as NSString).draw(at: NSPoint(x: r.minX + 12, y: r.minY + 10), withAttributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: c.2,
            ])
            (c.0 as NSString).draw(at: NSPoint(x: r.minX + 12, y: r.minY + 42), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        y += 66 + 22

        // 近 7 日柱状
        drawSection("近 7 日投递", at: y)
        y += 24
        let chartH: CGFloat = 92
        let chart = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: chartH)
        drawChart(in: chart)
        y += chartH + 22

        // 最近记录（可点击跳转）
        drawSection("最近投递（点一条打开笔记）", at: y)
        y += 22
        if recent.isEmpty {
            ("还没有记录。拖一个文件进面板，这里就会出现第一条。" as NSString)
                .draw(at: NSPoint(x: pad, y: y), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11.5),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ])
        } else {
            for e in recent {
                let r = NSRect(x: pad, y: y, width: bounds.width - pad * 2, height: 26)
                if r.maxY > bounds.height { break }
                NSColor.controlBackgroundColor.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                let time = Self.timeFmt.string(from: e.at)
                let name = MetricsQuery.kindNames[e.kind] ?? e.kind
                let target = e.targetId.isEmpty ? "—" : e.targetId
                let line = "\(time)   \(name)   → \(target)"
                (line as NSString).draw(at: NSPoint(x: r.minX + 10, y: r.minY + 6),
                                        withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.labelColor,
                ])
                let okText = e.ok ? "成功" : "失败"
                let okColor: NSColor = e.ok ? .systemGreen : .systemRed
                (okText as NSString).draw(at: NSPoint(x: r.maxX - 92, y: r.minY + 6),
                                          withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                    .foregroundColor: okColor,
                ])
                if let rel = noteMap[e.noteId], !rel.isEmpty {
                    ("打开" as NSString).draw(at: NSPoint(x: r.maxX - 40, y: r.minY + 6),
                                              withAttributes: [
                        .font: NSFont.systemFont(ofSize: 10.5),
                        .foregroundColor: NSColor.controlAccentColor,
                    ])
                    hitAreas.append((r, { [weak self] in self?.onOpen?(rel) }))
                }
                y += 30
            }
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private func drawSection(_ s: String, at y: CGFloat) {
        (s as NSString).draw(at: NSPoint(x: 20, y: y), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    private func drawPill(_ s: String, in r: NSRect, tint: NSColor) {
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        path.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: tint,
        ]
        let size = (s as NSString).size(withAttributes: attrs)
        (s as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2),
                             withAttributes: attrs)
    }

    private func drawChart(in r: NSRect) {
        let days = summary.daily
        guard !days.isEmpty else { return }
        let maxV = max(days.map { $0.total }.max() ?? 0, 1)
        let slot = r.width / CGFloat(days.count)
        let barW = min(slot - 10, 34)
        // 基线
        NSColor.separatorColor.setStroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: r.minX, y: r.maxY - 16))
        base.line(to: NSPoint(x: r.maxX, y: r.maxY - 16))
        base.lineWidth = 1
        base.stroke()

        for (i, d) in days.enumerated() {
            let h = CGFloat(d.total) / CGFloat(maxV) * (r.height - 30)
            let x = r.minX + CGFloat(i) * slot + (slot - barW) / 2
            let barRect = NSRect(x: x, y: r.maxY - 16 - h, width: barW, height: max(h, d.total == 0 ? 2 : 3))
            let p = NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4)
            (d.failed > 0 ? NSColor.systemRed.withAlphaComponent(0.55)
                          : NSColor.controlAccentColor.withAlphaComponent(0.75)).setFill()
            p.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let label = d.label
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: NSPoint(x: r.minX + CGFloat(i) * slot + (slot - size.width) / 2,
                                                 y: r.maxY - 14),
                                     withAttributes: attrs)
            if d.total > 0 {
                let n = "\(d.total)"
                let ns = (n as NSString).size(withAttributes: attrs)
                (n as NSString).draw(at: NSPoint(x: r.minX + CGFloat(i) * slot + (slot - ns.width) / 2,
                                                 y: barRect.minY - 13),
                                     withAttributes: attrs)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (r, action) in hitAreas where r.contains(p) { action(); return }
    }
}

final class DashboardWindowController: NSWindowController {
    convenience init() {
        let size = NSSize(width: 680, height: 560)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "ObsidianDrop 使用看板"
        win.setContentSize(size)
        win.center()
        win.isReleasedWhenClosed = false
        self.init(window: win)
        let v = DashboardView(frame: NSRect(origin: .zero, size: size))
        v.autoresizingMask = [.width, .height]
        v.onRefresh = { [weak self] in self?.refresh() }
        v.onOpen = { [weak self] rel in
            self?.openNote(rel)
        }
        win.contentView = v
    }

    func refresh() { (window?.contentView as? DashboardView)?.reload() }

    func show() {
        refresh()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openNote(_ rel: String) {
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [
            URLQueryItem(name: "vault", value: Cfg.vault.lastPathComponent),
            URLQueryItem(name: "file", value: (rel as NSString).deletingPathExtension),
        ]
        if let u = comps.url { NSWorkspace.shared.open(u) } else {
            NSWorkspace.shared.open(Cfg.vault.appendingPathComponent(rel))
        }
        MetricsStore.shared.record(MetricEvent(kind: "open", target: "", noteRel: rel,
                                               source: "dashboard"))
    }
}

// MARK: - AI 模型设置（1.5.0）

final class AISettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let enableBox = NSButton(checkboxWithTitle: "启用入库前 AI 处理", target: nil, action: nil)
    private let baseField = NSTextField()
    private let modelBox = NSComboBox()
    private let visionBox = NSComboBox()
    private let keyField = NSSecureTextField()
    private let status = NSTextField(labelWithString: "")
    private var testing = false

    convenience init() {
        let size = NSSize(width: 520, height: 428)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "AI 模型配置"
        win.center()
        win.isReleasedWhenClosed = false
        self.init(window: win)
        build(in: win, size: size)
        load()
    }

    private func label(_ s: String, _ r: NSRect, note: String = "") -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.frame = r
        f.font = .systemFont(ofSize: 11.5, weight: .medium)
        f.textColor = .secondaryLabelColor
        window?.contentView?.addSubview(f)
        if !note.isEmpty {
            let n = NSTextField(labelWithString: note)
            n.frame = NSRect(x: r.minX, y: r.maxY + 2, width: r.width, height: 14)
            n.font = .systemFont(ofSize: 10)
            n.textColor = .tertiaryLabelColor
            window?.contentView?.addSubview(n)
        }
        return f
    }

    private func build(in win: NSWindow, size: NSSize) {
        guard let cv = win.contentView else { return }
        let pad: CGFloat = 22

        let title = NSTextField(labelWithString: "入库前 AI 处理")
        title.frame = NSRect(x: pad, y: size.height - 44, width: 300, height: 20)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        cv.addSubview(title)

        let desc = NSTextField(labelWithString: "文字先交给模型生成标题/摘要/标签，再写入 Obsidian。失败则原样入库，不会丢内容。")
        desc.frame = NSRect(x: pad, y: size.height - 64, width: size.width - pad * 2, height: 16)
        desc.font = .systemFont(ofSize: 10.5)
        desc.textColor = .secondaryLabelColor
        cv.addSubview(desc)

        enableBox.frame = NSRect(x: pad, y: size.height - 96, width: 260, height: 18)
        enableBox.target = self
        enableBox.action = #selector(toggleEnable)
        cv.addSubview(enableBox)

        _ = label("接口地址（OpenAI 兼容，例如 https://api.openai.com/v1）",
                  NSRect(x: pad, y: size.height - 132, width: 420, height: 15))
        baseField.frame = NSRect(x: pad, y: size.height - 158, width: size.width - pad * 2, height: 24)
        baseField.placeholderString = "https://api.openai.com/v1"
        baseField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        cv.addSubview(baseField)

        _ = label("模型", NSRect(x: pad, y: size.height - 194, width: 80, height: 15))
        _ = label("API Key（保存在系统钥匙串）", NSRect(x: 260, y: size.height - 194, width: 240, height: 15))
        modelBox.frame = NSRect(x: pad, y: size.height - 220, width: 220, height: 24)
        modelBox.usesDataSource = false
        modelBox.completes = true
        modelBox.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        cv.addSubview(modelBox)

        keyField.frame = NSRect(x: 260, y: size.height - 220, width: size.width - 260 - pad, height: 24)
        keyField.placeholderString = "sk-…"
        keyField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        cv.addSubview(keyField)

        let fetch = NSButton(title: "拉取模型列表", target: self, action: #selector(fetchModels))
        fetch.frame = NSRect(x: pad, y: size.height - 254, width: 110, height: 24)
        fetch.bezelStyle = .rounded
        fetch.controlSize = .small
        cv.addSubview(fetch)

        let test = NSButton(title: "测试连接", target: self, action: #selector(testConn))
        test.frame = NSRect(x: pad + 118, y: size.height - 254, width: 90, height: 24)
        test.bezelStyle = .rounded
        test.controlSize = .small
        cv.addSubview(test)

        // 1.7.0：视觉模型单独配置。留空 = 运行时回退到上方文字模型。
        _ = label("视觉模型（留空则使用上方文字模型）",
                  NSRect(x: pad, y: size.height - 288, width: 420, height: 15))
        visionBox.frame = NSRect(x: pad, y: size.height - 314, width: 260, height: 24)
        visionBox.usesDataSource = false
        visionBox.completes = true
        visionBox.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        visionBox.placeholderString = "gpt-4o-mini"
        cv.addSubview(visionBox)

        // 状态行放在按钮**下面**：原来 y 算成 height-282，跟按钮那行（height-254）
        // 叠了 6pt，两层文字压在一起看着像渲染坏了。
        status.frame = NSRect(x: pad, y: size.height - 348, width: size.width - pad * 2, height: 34)
        status.font = .systemFont(ofSize: 10.5)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2
        cv.addSubview(status)

        let note = NSTextField(labelWithString: "预算 \(Int(AIConfig.maxBudget))s 硬超时 · 只发送文字，不发音频/附件 · 关闭后不产生任何网络请求")
        note.frame = NSRect(x: pad, y: 54, width: size.width - pad * 2, height: 14)
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        cv.addSubview(note)

        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.frame = NSRect(x: size.width - pad - 80, y: 18, width: 80, height: 28)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        cv.addSubview(save)

        let cancel = NSButton(title: "关闭", target: self, action: #selector(closeWin))
        cancel.frame = NSRect(x: size.width - pad - 168, y: 18, width: 80, height: 28)
        cancel.bezelStyle = .rounded
        cv.addSubview(cancel)
    }

    private func load() {
        let c = AIConfigStore.config
        enableBox.state = c.enabled ? .on : .off
        baseField.stringValue = c.baseURL
        modelBox.removeAllItems()
        modelBox.addItems(withObjectValues: modelChoices())
        modelBox.stringValue = c.model
        visionBox.removeAllItems()
        visionBox.addItems(withObjectValues: ["gpt-4o-mini", "gpt-4o", "qwen-vl-max"]
                           + c.history.filter { !["gpt-4o-mini", "gpt-4o", "qwen-vl-max"].contains($0) })
        visionBox.stringValue = c.visionModel ?? ""
        keyField.stringValue = AIKeychain.load() ?? ""
        status.stringValue = AIConfigStore.hasKey ? "Key 已保存在钥匙串" : "还没有配置 Key"
    }

    private func modelChoices() -> [String] {
        var list = AIConfigStore.config.history
        for m in ["gpt-4o-mini", "gpt-4o", "qwen-plus", "deepseek-chat", "glm-4-flash"]
        where !list.contains(m) { list.append(m) }
        return list
    }

    private func currentConfig() -> AIConfig {
        var c = AIConfigStore.config
        c.enabled = enableBox.state == .on
        if let b = try? AIConfig.normalize(base: baseField.stringValue) { c.baseURL = b }
        let m = modelBox.stringValue.trimmingCharacters(in: .whitespaces)
        if !m.isEmpty { c.model = m }
        c.visionModel = visionBox.stringValue.trimmingCharacters(in: .whitespaces)
        return c
    }

    @objc private func toggleEnable() {
        var c = AIConfigStore.config
        c.enabled = enableBox.state == .on
        AIConfigStore.config = c
        if c.enabled && !AIConfigStore.hasKey {
            status.stringValue = "已启用，但还缺 API Key——现在投递会走「跳过 AI、原样入库」。"
        }
    }

    @objc private func fetchModels() {
        let c = currentConfig()
        let key = keyField.stringValue.isEmpty ? (AIKeychain.load() ?? "") : keyField.stringValue
        status.stringValue = "正在拉取模型列表…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = AIService.listModels(config: c, key: key)
            DispatchQueue.main.async {
                guard let self else { return }
                if list.isEmpty {
                    self.status.stringValue = "没有取到模型列表（有些兼容接口不实现 /models，手动填模型名即可）。"
                } else {
                    self.modelBox.removeAllItems()
                    self.modelBox.addItems(withObjectValues: list)
                    self.modelBox.stringValue = list.contains(c.model) ? c.model : (list.first ?? c.model)
                    self.status.stringValue = "取到 \(list.count) 个模型，选择后点保存。"
                }
            }
        }
    }

    @objc private func testConn() {
        guard !testing else { return }
        testing = true
        let c = currentConfig()
        let key = keyField.stringValue
        status.stringValue = "正在测试…（最长 \(Int(c.effectiveBudget))s）"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = AIService.test(config: c, key: key)
            DispatchQueue.main.async {
                guard let self else { return }
                self.testing = false
                self.status.stringValue = (r.ok ? "✓ " : "✗ ") + r.message
                self.status.textColor = r.ok ? .systemGreen : .systemRed
            }
        }
    }

    @objc private func save() {
        var c = currentConfig()
        do {
            c.baseURL = try AIConfig.normalize(base: baseField.stringValue)
        } catch {
            status.stringValue = "✗ " + error.localizedDescription
            status.textColor = .systemRed
            return
        }
        let key = keyField.stringValue
        if !key.isEmpty && !AIKeychain.save(key) {
            status.stringValue = "✗ 写入钥匙串失败（检查钥匙串是否被锁）"
            status.textColor = .systemRed
            return
        }
        if !c.history.contains(c.model) { c.history.insert(c.model, at: 0) }
        AIConfigStore.config = c
        // 记一笔「配置变更」即可；具体处理结果由归档链路逐条记录。
        // 这里**不能**用 kind="ai" + ai="off"：那会被看板当成「一次 AI 处理没启用」，
        // 每保存一次设置就多一条，AI 口径立刻失真。
        MetricsStore.shared.record(MetricEvent(kind: "ai-config", ok: true, source: "settings"))
        status.stringValue = "已保存：\(c.model) @ \(c.baseURL)（AI \(c.enabled ? "开" : "关")）"
        status.textColor = .secondaryLabelColor
    }

    @objc private func closeWin() { window?.orderOut(nil) }

    func show() {
        load()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
