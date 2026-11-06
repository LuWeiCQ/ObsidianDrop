import Foundation
import CryptoKit

// MARK: - 使用埋点（1.4.1）
//
// 三条铁律：
//   1. **只记「发生了什么」，不记「内容是什么」**。笔记正文、文件名、语音文字一律不落。
//      目录名与笔记路径在落盘前做加盐哈希，只保留前 8 位——能统计「投到哪个目标多」，
//      但把文件拷给别人也还原不出目录结构。
//   2. 本地 JSONL，不上传、不联网。用户能 `--metrics --raw` 直接看到全部原始记录。
//   3. 写失败绝不影响主流程：埋点是旁路，不是依赖。

struct MetricEvent: Codable {
    var v: Int = 1
    var at: Date = Date()
    /// drop / memo / screenshot / search / ai / open / fail
    var kind: String
    var ok: Bool = true
    /// 目标目录（已哈希）
    var targetId: String = ""
    /// 产出笔记（已哈希）
    var noteId: String = ""
    /// 触发来源：panel / menu / cli / watchdog / dashboard
    var source: String = ""
    var durationMs: Int = 0
    /// 这次操作的唯一编号（同一编号串起「投递 → AI → 归档 → 打开」）
    var captureId: String = ""
    var failReason: String = ""
    var count: Int = 1
    /// AI 环节状态：off / pending / done / skipped
    var ai: String = ""

    init(kind: String, ok: Bool = true, target: String = "", noteRel: String = "",
         source: String = "", durationMs: Int = 0, captureId: String = "",
         failReason: String = "", count: Int = 1, ai: String = "", at: Date = Date()) {
        self.at = at
        self.kind = kind
        self.ok = ok
        self.targetId = MetricID.hash(target)
        self.noteId = MetricID.hash(noteRel)
        self.source = source
        self.durationMs = durationMs
        self.captureId = captureId.isEmpty ? MetricID.random() : captureId
        self.failReason = failReason
        self.count = count
        self.ai = ai
    }
}

enum MetricID {
    /// 固定盐 + SHA256 前 8 位。盐是常量，所以同一目录恒得同一 id（可做聚合），
    /// 但无法从 id 反推目录名。
    private static let salt = "obsidiandrop-metric-v1"

    static func hash(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        let d = SHA256.hash(data: Data((salt + "|" + s).utf8))
        return d.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    static func random() -> String {
        // 不引入 UUID 的 36 字符：8 位十六进制足够区分同一天的几十次操作
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
    }
}

final class MetricsStore: @unchecked Sendable {
    static let shared = MetricsStore()

    private let lock = NSLock()
    private var overrideDir: URL?
    private let limit = 5 * 1024 * 1024

    var directory: URL {
        lock.lock(); defer { lock.unlock() }
        if let d = overrideDir { return d }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ObsidianDrop/metrics", isDirectory: true)
    }

    func setDirectory(_ u: URL?) {
        lock.lock(); overrideDir = u; lock.unlock()
    }

    var fileURL: URL { directory.appendingPathComponent("events.jsonl") }

    func record(_ e: MetricEvent) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? enc.encode(e) else { return }
        data.append(0x0A)
        // 先把目录取出来再上锁：`directory` 自己也要拿同一把锁，
        // 持锁时再调它就是死锁（NSLock 不递归，且不会有任何报错——只会安静挂住）。
        let dir = directory
        let file = dir.appendingPathComponent("events.jsonl")
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if let attrs = try? fm.attributesOfItem(atPath: file.path),
           let size = attrs[.size] as? Int, size > limit {
            // 超限不删历史，改名归档一份，保留可追溯性
            let old = dir.appendingPathComponent("events-\(Int(Date().timeIntervalSince1970)).jsonl")
            try? fm.moveItem(at: file, to: old)
        }
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: file)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    func all(now: Date = Date(), days: Int = 30) -> [MetricEvent] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return rawAll().filter { $0.at >= cutoff }
    }

    func rawAll() -> [MetricEvent] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])
        else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var out: [MetricEvent] = []
        var bad = 0
        for u in items where u.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: u),
                  let s = String(data: data, encoding: .utf8) else {
                // 整个文件读不出来（权限/被占用/编码坏了）也是问题，别静默当空文件
                bad += 1
                DiagLog.write("埋点文件读取失败或不是 UTF-8：\(u.lastPathComponent)")
                continue
            }
            for line in s.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let e = try? dec.decode(MetricEvent.self, from: d) else {
                    // 进程被强杀时最后一行可能只写了一半。丢这一行、继续读后面的，
                    // 但要留个数——真出问题（比如编码改坏了）能从日志看出来。
                    bad += 1
                    continue
                }
                out.append(e)
            }
        }
        if bad > 0 { DiagLog.write("埋点有 \(bad) 行无法解析，已跳过（多为进程强杀留下的半行）") }
        return out
    }
}

// MARK: - 看板口径（纯函数，可单测）

struct MetricsDay {
    let label: String     // MM-dd
    let total: Int
    let ok: Int
    let failed: Int
}

struct MetricsSummary {
    var total = 0
    var ok = 0
    var failed = 0
    var successRate: Double = 0
    var avgMs: Int = 0
    /// n ≥ 30 才给 p95：样本太少时 p95 等于最大值，会把人吓一跳且不具代表性
    var p95Ms: Int?
    var byKind: [(kind: String, count: Int)] = []
    var byTarget: [(id: String, count: Int)] = []
    var daily: [MetricsDay] = []
    var opened = 0
    var openRate: Double = 0
    var aiDone = 0
    var aiSkipped = 0
    var aiOff = 0
    var failReasons: [(reason: String, count: Int)] = []
}

enum MetricsQuery {
    static let kindNames: [String: String] = [
        "drop": "拖拽投递", "memo": "语音灵感", "screenshot": "截屏",
        "search": "搜索", "ai": "AI 处理", "ai-config": "AI 配置",
        "open": "打开笔记", "fail": "失败",
    ]

    static func dayKey(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func shortDay(_ d: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        // 标签必须和分桶用同一个时区，否则传入别的日历（自检、跨时区诊断）时
        // 会出现「桶是 03-08、标签写 03-09」这种自相矛盾的输出
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        return f.string(from: d)
    }

    /// 「投递类」事件：真正把东西送进库的动作，成功率只按这些算。
    /// 搜索/打开不算投递，混进去会把成功率稀释得没有意义。
    static func isDelivery(_ k: String) -> Bool {
        k == "drop" || k == "memo" || k == "screenshot"
    }

    static func summary(events: [MetricEvent], now: Date = Date(), days: Int = 7,
                        calendar: Calendar = .current) -> MetricsSummary {
        var s = MetricsSummary()
        // 日期一律用 Calendar 递推，不用「减 86400 秒」：跨夏令时那天差一小时，
        // startOfDay 会把两个日期算成同一天，柱状图于是少一根、旁边那根翻倍。
        func dayStart(_ back: Int) -> Date {
            let d = calendar.date(byAdding: .day, value: -back, to: now)
                ?? now.addingTimeInterval(-Double(back) * 86400)
            return calendar.startOfDay(for: d)
        }
        let cutoff = dayStart(days - 1)
        let scoped = events.filter { $0.at >= cutoff }

        var durations: [Int] = []
        var kindCount: [String: Int] = [:]
        var targetCount: [String: Int] = [:]
        var failCount: [String: Int] = [:]
        /// 一次投递会同时产生「ai」事件和带 ai 字段的投递事件，两条都算就会翻倍。
        /// 按 captureId 归并，且 `ai` 事件优先——它记的是这次 AI 的最终结论。
        var aiByCapture: [String: (state: String, isAI: Bool)] = [:]
        var openedNotes = Set<String>()

        for (idx, e) in scoped.enumerated() {
            s.total += e.count
            if isDelivery(e.kind) {
                if e.ok { s.ok += 1 } else { s.failed += 1 }
                if e.ok, e.durationMs > 0 { durations.append(e.durationMs) }
                if !e.ok, !e.failReason.isEmpty {
                    failCount[e.failReason, default: 0] += 1
                }
                if !e.targetId.isEmpty { targetCount[e.targetId, default: 0] += 1 }
            }
            if e.kind == "open" {
                // 同一篇笔记点开十次只算一次：打开率问的是「有多少产出被看过」，
                // 不是「点了多少下」。缺少 noteId 的老记录退回到 captureId 去重。
                let key = e.noteId.isEmpty ? e.captureId : e.noteId
                if !key.isEmpty { openedNotes.insert(key) }
            }
            if !e.ai.isEmpty {
                // 两个标识都为空的老记录不能共用空键——共用就会被合并成一条，
                // 把 N 次处理压成 1 次。给每条一个进程内唯一的替身键。
                let cap = !e.captureId.isEmpty ? e.captureId
                    : (!e.noteId.isEmpty ? e.noteId : "#\(idx)")
                let isAI = e.kind == "ai"
                // 已有 ai 事件时不允许被投递事件覆盖（反过来可以：老数据只有投递事件）
                let keepOld = (aiByCapture[cap]?.isAI ?? false) && !isAI
                if !keepOld { aiByCapture[cap] = (e.ai, isAI) }
            }
            kindCount[e.kind, default: 0] += e.count
        }
        s.opened = openedNotes.count
        for (_, v) in aiByCapture {
            switch v.state {
            case "done": s.aiDone += 1
            case "skipped": s.aiSkipped += 1
            case "off": s.aiOff += 1
            default: break
            }
        }

        let deliveryTotal = s.ok + s.failed
        s.successRate = deliveryTotal == 0 ? 0 : Double(s.ok) / Double(deliveryTotal)
        s.avgMs = durations.isEmpty ? 0 : durations.reduce(0, +) / durations.count
        s.p95Ms = durations.count >= 30 ? percentile(durations, 0.95) : nil
        s.openRate = s.ok == 0 ? 0 : min(1, Double(s.opened) / Double(s.ok))
        s.byKind = kindCount.map { (kind: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
        s.byTarget = targetCount.map { (id: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
        s.failReasons = failCount.map { (reason: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }

        // 补齐空白日：柱状图不能跳日，否则「周三没干活」看起来像「周三不存在」
        var daysOut: [MetricsDay] = []
        for i in 0..<days {
            let d = dayStart(days - 1 - i)
            let key = dayKey(d)
            let items = scoped.filter { dayKey($0.at, calendar: calendar) == key && isDelivery($0.kind) }
            daysOut.append(MetricsDay(label: shortDay(d, calendar: calendar),
                                      total: items.count,
                                      ok: items.filter { $0.ok }.count,
                                      failed: items.filter { !$0.ok }.count))
        }
        s.daily = daysOut
        return s
    }

    /// 最近 N 条投递记录（看板列表用，最新的在前）
    static func recent(events: [MetricEvent], limit: Int = 12) -> [MetricEvent] {
        events.filter { isDelivery($0.kind) }
            .sorted { $0.at > $1.at }
            .prefix(limit)
            .map { $0 }
    }

    static func percentile(_ xs: [Int], _ p: Double) -> Int {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }
}

// MARK: - 看板命令行（--metrics）

enum MetricsCLI {
    static func run(json: Bool, days: Int, raw: Bool) -> Int32 {
        let store = MetricsStore.shared
        if raw {
            let all = store.rawAll().sorted { $0.at < $1.at }
            if json {
                let enc = JSONEncoder()
                enc.dateEncodingStrategy = .iso8601
                enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                if let d = try? enc.encode(all), let s = String(data: d, encoding: .utf8) {
                    print(s)
                }
            } else {
                for e in all {
                    print("[\(iso(e.at))] \(e.kind) ok=\(e.ok) src=\(e.source) "
                          + "target=\(e.targetId) ms=\(e.durationMs) ai=\(e.ai) cap=\(e.captureId)")
                }
                print("共 \(all.count) 条")
            }
            return 0
        }

        let events = store.all(days: max(days, 1))
        let s = MetricsQuery.summary(events: events, days: days)
        if json {
            let payload: [String: Any] = [
                "days": days,
                "total": s.total, "ok": s.ok, "failed": s.failed,
                "success_rate": (s.successRate * 1000).rounded() / 1000,
                "avg_ms": s.avgMs,
                "p95_ms": s.p95Ms ?? -1,
                "opened": s.opened,
                "open_rate": (s.openRate * 1000).rounded() / 1000,
                "ai": ["done": s.aiDone, "skipped": s.aiSkipped, "off": s.aiOff],
                "by_kind": s.byKind.map { ["kind": $0.kind, "count": $0.count] },
                "by_target": s.byTarget.map { ["id": $0.id, "count": $0.count] },
                "daily": s.daily.map { ["day": $0.label, "total": $0.total,
                                        "ok": $0.ok, "failed": $0.failed] },
                "fail_reasons": s.failReasons.map { ["reason": $0.reason, "count": $0.count] },
            ]
            if let d = try? JSONSerialization.data(withJSONObject: payload,
                                                   options: [.sortedKeys, .withoutEscapingSlashes]),
               let str = String(data: d, encoding: .utf8) {
                print(str)
            }
        } else {
            print("近 \(days) 天（投递 \(s.ok + s.failed) 次 / 成功 \(s.ok) / 失败 \(s.failed)）")
            print("成功率 \(String(format: "%.1f", s.successRate * 100))%"
                  + " · 平均 \(s.avgMs)ms"
                  + (s.p95Ms.map { " · p95 \($0)ms" } ?? " · p95 样本不足")
                  + " · 打开率 \(String(format: "%.1f", s.openRate * 100))%")
            print("AI：完成 \(s.aiDone) · 跳过 \(s.aiSkipped) · 未启用 \(s.aiOff)")
            for d in s.daily {
                let bar = String(repeating: "█", count: min(d.total, 40))
                print("  \(d.label)  \(String(format: "%2d", d.total))  \(bar)")
            }
            for k in s.byKind.prefix(6) {
                print("  \(MetricsQuery.kindNames[k.kind] ?? k.kind)：\(k.count)")
            }
        }
        return 0
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: d)
    }
}

// MARK: - 跳转表

/// 看板「打开」需要知道 id 对应哪篇笔记，但埋点流里只有哈希。
///
/// 折中：单独维护一张**只在本机、只给跳转用**的表（`jump.json`），
/// `--metrics --raw` 与导出的统计都不包含它。这样「埋点不含路径」的承诺仍然成立，
/// 同时看板还能真的点开那篇笔记。
enum MetricNoteMap {
    private static let lock = NSLock()

    private static var url: URL {
        MetricsStore.shared.directory.appendingPathComponent("jump.json")
    }

    static func remember(noteId: String, rel: String) {
        guard !noteId.isEmpty, !rel.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var m = readRaw()
        m[noteId] = rel
        if m.count > 1000 {
            // 只保留最近 1000 条；再多也没人翻
            let keep = m.suffix(1000)
            m = Dictionary(uniqueKeysWithValues: Array(keep))
        }
        if let d = try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]) {
            // 原子写：看板随时可能在读这张表，写一半时读到半截 JSON 会整表丢失
            try? d.write(to: url, options: .atomic)
        }
    }

    static func resolve(_ id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return readRaw()[id]
    }

    static func all() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return readRaw()
    }

    private static func readRaw() -> [String: String] {
        guard let d = try? Data(contentsOf: url),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
        return m
    }
}
