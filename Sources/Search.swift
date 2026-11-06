import Foundation

// MARK: - 库内全文搜索（1.4.0）
//
// 选型结论（见 docs/检索性能实测.md）：
//   · `String.contains` 在 3000 篇 / 10MB 上单次要 180ms，不可用；
//   · UTF-8 `Data` + `memmem` 同样的数据 3.1ms；
//   · SQLite FTS5 与中文 bigram 倒排能再快 1~2ms，但要多带 60~100MB 内存
//     （或一个 C 依赖），对「一个菜单栏小工具」性价比不成立。
// 所以索引只做一件事：把每篇笔记的**小写 UTF-8 字节**留在内存里，匹配交给 memmem。

/// 一篇被索引的笔记。`bytes` 是小写化后的 UTF-8，专供匹配；
/// `text` 保留原文，用来取摘要片段（匹配命中后再取，不在热路径上）。
struct VaultDoc {
    let rel: String
    let mtime: Double
    let size: Int
    let bytes: Data
    let text: String
}

enum VaultIndexer {
    /// 索引时跳过的目录：Obsidian 自己的元数据、回收站、版本库、依赖目录
    static let skipDirs: Set<String> = [".obsidian", ".trash", ".git", "node_modules", ".DS_Store"]

    /// 单篇上限。超过这个大小的 .md 基本是导出物/日志，索引它只会拖慢刷新。
    static let maxBytes = 2 * 1024 * 1024

    static func isIndexable(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "md" else { return false }
        let parts = url.pathComponents
        for p in parts where skipDirs.contains(p) { return false }
        return true
    }

    /// 全量扫描（首次构建 / 强制重建）。返回按相对路径升序的文档。
    static func scan(vault: URL) -> [VaultDoc] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: vault,
                                     includingPropertiesForKeys: [.isRegularFileKey,
                                                                  .contentModificationDateKey,
                                                                  .fileSizeKey],
                                     options: [.skipsHiddenFiles],
                                     errorHandler: { _, _ in true }) else { return [] }
        var out: [VaultDoc] = []
        for case let url as URL in en {
            guard isIndexable(url) else { continue }
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey,
                                                            .contentModificationDateKey,
                                                            .fileSizeKey]),
                  v.isRegularFile == true else { continue }
            let size = v.fileSize ?? 0
            if size > maxBytes { continue }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)
            else { continue }
            out.append(VaultDoc(rel: relativePath(url, vault: vault),
                                mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0,
                                size: size,
                                bytes: Data(text.lowercased().utf8),
                                text: text))
        }
        return out.sorted { $0.rel < $1.rel }
    }

    static func relativePath(_ url: URL, vault: URL) -> String {
        let base = vault.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(base) else { return url.lastPathComponent }
        var rel = String(p.dropFirst(base.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }
}

enum VaultSearch {
    struct Hit {
        let rel: String
        let score: Int
        let line: Int
        let snippet: String
        let mtime: Double
    }

    /// memmem：在 haystack 里找 needle。比 `range(of:)` 快两个数量级，
    /// 而且不做 Unicode 归一化——我们要的就是「字节相同」。
    static func contains(_ hay: Data, _ needle: Data) -> Bool {
        if needle.isEmpty { return true }
        if needle.count > hay.count { return false }
        return hay.withUnsafeBytes { (h: UnsafeRawBufferPointer) -> Bool in
            guard let hp = h.baseAddress else { return false }
            return needle.withUnsafeBytes { (n: UnsafeRawBufferPointer) -> Bool in
                guard let np = n.baseAddress else { return false }
                return memmem(hp, h.count, np, n.count) != nil
            }
        }
    }

    /// 查询分词：空格分隔，全部命中才算命中（AND）。
    /// 每个词单独小写化——`lowercased()` 对中文是恒等，对英文/URL 才起作用。
    static func tokens(_ query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 命中位置在**原文**里的行号与上下文（1 基）。
    static func locate(in text: String, token: String) -> (line: Int, snippet: String) {
        let lines = text.components(separatedBy: .newlines)
        let low = token.lowercased()
        for (i, l) in lines.enumerated() {
            if l.lowercased().contains(low) {
                var s = l.trimmingCharacters(in: .whitespaces)
                if s.count > 90 { s = String(s.prefix(90)) + "…" }
                return (i + 1, s)
            }
        }
        // 跨行才命中的情况（罕见）：回退到开头一段，别让结果出现空摘要
        let head = text.prefix(90).replacingOccurrences(of: "\n", with: " ")
        return (1, head.trimmingCharacters(in: .whitespaces))
    }

    static func search(_ docs: [VaultDoc], query: String, limit: Int) -> [Hit] {
        let ts = tokens(query)
        guard !ts.isEmpty, limit > 0 else { return [] }
        let needles = ts.map { Data($0.utf8) }
        let nameNeedles = needles

        var hits: [Hit] = []
        for d in docs {
            // 先做最便宜的判断：所有词都得在正文里
            var all = true
            for n in needles where !contains(d.bytes, n) { all = false; break }
            guard all else { continue }

            let nameLow = Data(d.rel.lowercased().utf8)
            var score = 10
            var nameHit = true
            for n in nameNeedles where !contains(nameLow, n) { nameHit = false; break }
            if nameHit { score += 60 }
            // 词越多、越靠前、出现次数越多，排得越前
            var count = 0
            for n in needles {
                var rest = d.bytes
                var guardCount = 0
                while let r = firstRange(rest, n), guardCount < 12 {
                    count += 1
                    guardCount += 1
                    rest = rest.subdata(in: r.upperBound..<rest.count)
                    if rest.isEmpty { break }
                }
            }
            score += min(count, 10) * 3
            if d.text.hasPrefix("# ") || d.text.contains("\n# ") { score += 5 }
            if d.rel.hasSuffix("\(ts[0]).md") { score += 20 }

            let loc = locate(in: d.text, token: ts[0])
            hits.append(Hit(rel: d.rel, score: score, line: loc.line,
                            snippet: loc.snippet, mtime: d.mtime))
        }
        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
            return $0.rel < $1.rel
        }
        return Array(hits.prefix(limit))
    }

    private static func firstRange(_ hay: Data, _ needle: Data) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        let idx: Int? = hay.withUnsafeBytes { (h: UnsafeRawBufferPointer) -> Int? in
            guard let hp = h.baseAddress else { return nil }
            return needle.withUnsafeBytes { (n: UnsafeRawBufferPointer) -> Int? in
                guard let np = n.baseAddress, let p = memmem(hp, h.count, np, n.count) else { return nil }
                return hp.distance(to: UnsafeRawPointer(p))
            }
        }
        guard let i = idx else { return nil }
        return i..<(i + needle.count)
    }
}

/// 索引的持有者。做成 actor 是因为它同时被界面（主线程）和 CLI 调用，
/// 而内部状态是「整批字节」——并发读改写一定会撞。
actor VaultIndex {
    static let shared = VaultIndex()

    private var docs: [VaultDoc] = []
    private var stamp: [String: (Double, Int)] = [:]
    private var lastBuild: Date = .distantPast
    private var lastBuildMs: Double = 0
    private var lastVaultPath: String = ""

    struct Stats {
        let docs: Int
        let bytes: Int
        let buildMs: Double
        let incremental: Bool
        let at: Date
    }
    private(set) var lastStats = Stats(docs: 0, bytes: 0, buildMs: 0, incremental: false, at: .distantPast)

    /// 增量刷新：只重读 mtime/size 变过的文件。全量重建 3000 篇约 0.3s，
    /// 增量约 9ms——每次搜索前都刷一次的代价可以忽略，换来「刚存的笔记立刻搜得到」。
    @discardableResult
    func refreshIfNeeded(vault: URL, force: Bool = false,
                         maxAge: TimeInterval = 5, now: Date = Date()) -> Stats {
        let vaultPath = vault.standardizedFileURL.path
        let stale = force || lastVaultPath != vaultPath
            || docs.isEmpty || now.timeIntervalSince(lastBuild) > maxAge
        guard stale else { return lastStats }

        let t0 = Date()
        let full = force || lastVaultPath != vaultPath || docs.isEmpty
        lastVaultPath = vaultPath

        if full {
            let scanned = VaultIndexer.scan(vault: vault)
            docs = scanned
            stamp = Dictionary(uniqueKeysWithValues: scanned.map { ($0.rel, ($0.mtime, $0.size)) })
            lastBuildMs = Date().timeIntervalSince(t0) * 1000
            lastBuild = now
            lastStats = Stats(docs: docs.count, bytes: docs.reduce(0) { $0 + $1.size },
                              buildMs: lastBuildMs, incremental: false, at: now)
            return lastStats
        }

        let fm = FileManager.default
        guard let en = fm.enumerator(at: vault,
                                     includingPropertiesForKeys: [.isRegularFileKey,
                                                                  .contentModificationDateKey,
                                                                  .fileSizeKey],
                                     options: [.skipsHiddenFiles],
                                     errorHandler: { _, _ in true }) else { return lastStats }
        var seen: [String: (Double, Int)] = [:]
        var updates: [VaultDoc] = []
        var added = 0, changed = 0
        for case let url as URL in en {
            guard VaultIndexer.isIndexable(url) else { continue }
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey,
                                                            .contentModificationDateKey,
                                                            .fileSizeKey]),
                  v.isRegularFile == true else { continue }
            let size = v.fileSize ?? 0
            if size > VaultIndexer.maxBytes { continue }
            let rel = VaultIndexer.relativePath(url, vault: vault)
            let mtime = v.contentModificationDate?.timeIntervalSince1970 ?? 0
            if let old = stamp[rel], old.0 == mtime, old.1 == size {
                seen[rel] = old
                continue
            }
            // 读失败时**不**提交新 stamp：提交了就等于承认「这个文件已经是新内容」，
            // 而内存里还是旧正文，且以后 mtime 不变就再也不会重试。
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                if let old = stamp[rel] { seen[rel] = old }
                continue
            }
            seen[rel] = (mtime, size)
            if stamp[rel] == nil { added += 1 } else { changed += 1 }
            updates.append(VaultDoc(rel: rel, mtime: mtime, size: size,
                                    bytes: Data(text.lowercased().utf8), text: text))
        }

        // 合并：删掉消失的，替换变更的，其余原样保留（不重建整表）
        var byRel = Dictionary(uniqueKeysWithValues: docs.map { ($0.rel, $0) })
        let removed = byRel.keys.filter { seen[$0] == nil }.count
        for r in byRel.keys where seen[r] == nil { byRel.removeValue(forKey: r) }
        for u in updates { byRel[u.rel] = u }
        docs = byRel.values.sorted { $0.rel < $1.rel }
        stamp = seen
        lastBuildMs = Date().timeIntervalSince(t0) * 1000
        lastBuild = now
        lastStats = Stats(docs: docs.count, bytes: docs.reduce(0) { $0 + $1.size },
                          buildMs: lastBuildMs, incremental: true, at: now)
        if added + changed + removed > 0 {
            DiagLog.write("索引增量：+\(added) ~\(changed) -\(removed)，"
                          + "共 \(docs.count) 篇，\(String(format: "%.1f", lastBuildMs))ms")
        }
        return lastStats
    }

    func search(_ query: String, limit: Int = 20) -> [VaultSearch.Hit] {
        VaultSearch.search(docs, query: query, limit: limit)
    }

    func count() -> Int { docs.count }
}

// MARK: - Spotlight（1.5.1）

/// 库外的本地文件：名字命中的文档与常见文本类文件。
///
/// 为什么还要 Spotlight：库内索引只能回答「我记过什么」，
/// 回答不了「上周下载的那份 PDF 叫什么来着」。NSMetadataQuery 是系统现成的索引，
/// 代价是要等 run loop，所以必须带**硬超时**（1.2s），拿不到就返回空，
/// 绝不能让搜索框卡住。
enum SpotlightSearch {
    struct Hit {
        let path: String
        let name: String
        let kind: String
    }

    static func search(_ query: String, limit: Int = 10,
                       timeout: TimeInterval = 1.2, scopes: [Any]? = nil) -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        // NSMetadataQuery 需要**当前线程**有 run loop，并不要求是主线程。
        // 之前这里 `DispatchQueue.main.sync` 把查询搬到主线程，等于每次输入
        // 都把界面最多卡住 1.2 秒（输入框停住、面板无法收起）。
        // 现在就在调用线程上跑：后台搜索线程自带 run loop，主线程调用时同样成立。

        let mq = NSMetadataQuery()
        mq.predicate = NSPredicate(format: "kMDItemFSName == %@", "*\(q)*")
        mq.searchScopes = scopes ?? [NSMetadataQueryUserHomeScope]
        mq.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey,
                                               ascending: false)]

        // 完成标志由通知回调（可能在别的线程）写、这里读，必须是同步的
        let done = LockedFlag()
        let center = NotificationCenter.default
        let observer = center.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                          object: mq, queue: .main) { _ in done.set() }
        mq.start()
        let deadline = Date().addingTimeInterval(timeout)
        while !done.value && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        mq.disableUpdates()
        mq.stop()
        center.removeObserver(observer)

        var out: [Hit] = []
        for i in 0..<mq.resultCount {
            guard let item = mq.result(at: i) as? NSMetadataItem else { continue }
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            // 库内文件由 VaultIndex 负责，不在这里重复
            if path.hasPrefix(Cfg.vault.standardizedFileURL.path + "/") { continue }
            let name = (path as NSString).lastPathComponent
            let kind = (item.value(forAttribute: NSMetadataItemContentTypeKey) as? String) ?? ""
            out.append(Hit(path: path, name: name, kind: kind))
            if out.count >= limit { break }
        }
        return out
    }
}

// MARK: - 搜索命令行（--search）

enum SearchCLI {
    /// 退出码约定（脚本与自检都依赖它，不要改）：
    ///   0 = 有结果
    ///   1 = 词法正确但没有命中
    ///   2 = 用法错误 / 库不存在
    ///   3 = 索引过程中出错
    static func run(query: String, limit: Int, json: Bool, includeSpotlight: Bool) -> Int32 {
        let vault = Cfg.vault
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vault.path, isDirectory: &isDir),
              isDir.boolValue else {
            FileHandle.standardError.write("错误：库目录不存在 \(vault.path)\n".data(using: .utf8)!)
            return 2
        }
        guard !VaultSearch.tokens(query).isEmpty else {
            FileHandle.standardError.write("用法：--search <关键词> [--limit N] [--json]\n".data(using: .utf8)!)
            return 2
        }

        let t0 = Date()
        let sem = DispatchSemaphore(value: 0)
        var hits: [VaultSearch.Hit] = []
        var stats = VaultIndex.Stats(docs: 0, bytes: 0, buildMs: 0, incremental: false, at: Date())
        Task.detached {
            let idx = VaultIndex.shared
            stats = await idx.refreshIfNeeded(vault: vault)
            hits = await idx.search(query, limit: limit)
            sem.signal()
        }
        while sem.wait(timeout: .now() + 0.02) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let ms = Date().timeIntervalSince(t0) * 1000

        var local: [SpotlightSearch.Hit] = []
        if includeSpotlight {
            local = SpotlightSearch.search(query, limit: max(3, limit / 2))
        }

        if json {
            let items: [[String: Any]] = hits.map {
                ["path": $0.rel, "line": $0.line, "snippet": $0.snippet, "score": $0.score]
            }
            let loc: [[String: Any]] = local.map {
                ["path": $0.path, "name": $0.name, "kind": $0.kind]
            }
            let payload: [String: Any] = [
                "query": query,
                "count": items.count,
                "items": items,
                "local": loc,
                "index": ["docs": stats.docs, "bytes": stats.bytes,
                          "build_ms": Int(stats.buildMs), "incremental": stats.incremental],
                "elapsed_ms": Int(ms),
            ]
            if let d = try? JSONSerialization.data(withJSONObject: payload,
                                                   options: [.sortedKeys, .withoutEscapingSlashes]),
               let s = String(data: d, encoding: .utf8) {
                print(s)
            }
        } else {
            if hits.isEmpty {
                print("没有命中「\(query)」")
            }
            for h in hits {
                print("\(h.rel):\(h.line)  [\(h.score)]")
                if !h.snippet.isEmpty { print("    \(h.snippet)") }
            }
            if !local.isEmpty {
                print("—— 库外文件（Spotlight）——")
                for l in local { print("\(l.name)  \(l.path)") }
            }
            let foot = "· 索引 \(stats.docs) 篇 / \(stats.bytes / 1024) KB / "
                + "\(stats.incremental ? "增量" : "全量") "
                + "\(String(format: "%.1f", stats.buildMs))ms"
                + " · 查询 \(String(format: "%.1f", ms))ms\n"
            FileHandle.standardError.write(foot.data(using: .utf8)!)
        }

        MetricsStore.shared.record(MetricEvent(kind: "search", ok: !hits.isEmpty,
                                               target: "", noteRel: hits.first?.rel ?? "",
                                               source: includeSpotlight ? "search+spotlight" : "search",
                                               durationMs: Int(ms)))
        return hits.isEmpty ? 1 : 0
    }
}

extension VaultIndex {
    /// 同步包装：AppKit 回调与命令行里没有 `await` 上下文，
    /// 但又必须等索引刷完才能出结果。等待期间跑 run loop，
    /// 这样主线程调用时不会把界面冻住。
    static func blockingSearch(vault: URL, query: String, limit: Int)
        -> (hits: [VaultSearch.Hit], stats: VaultIndex.Stats) {
        let sem = DispatchSemaphore(value: 0)
        var hits: [VaultSearch.Hit] = []
        var st = VaultIndex.Stats(docs: 0, bytes: 0, buildMs: 0, incremental: false, at: Date())
        Task.detached(priority: .userInitiated) {
            let idx = VaultIndex.shared
            st = await idx.refreshIfNeeded(vault: vault)
            hits = await idx.search(query, limit: limit)
            sem.signal()
        }
        // 加硬超时：枚举异常时不能把调用线程永远挂在这里（App 里就是一条永不返回的搜索）
        let deadline = Date().addingTimeInterval(15)
        while sem.wait(timeout: .now() + 0.02) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if Date() > deadline {
                DiagLog.write("索引等待超时（15s），本次搜索返回已建好的部分")
                break
            }
        }
        return (hits, st)
    }
}

/// 一个带锁的布尔：Spotlight 的完成通知不保证与读取同线程。
final class LockedFlag {
    private let lock = NSLock()
    private var v = false

    func set() {
        lock.lock(); v = true; lock.unlock()
    }

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return v
    }
}
