import AppKit
import UniformTypeIdentifiers
import ServiceManagement
import AVFoundation
import CoreAudio
import Speech
import os

/// 截图临时源图的清理闸门（1.7.0 复核修补）。
///
/// 以前 GUI / CLI 都是 `Filer.file` 一返回就删临时 PNG，之后才检查失败报告；
/// 归档失败时库里没有笔记、已复制的附件也会被回滚，临时 PNG 是唯一副本。
/// 现在只有「零失败 + 确实产出了笔记」才允许删，失败时保留源图并告知路径。
enum ScreenshotCleanup {
    static func canDiscard(failures: Int, noteRel: String) -> Bool {
        failures == 0 && !noteRel.isEmpty
    }
}

// MARK: - 常量

enum Cfg {
    static let vaultKey = "vaultPath"
    static let targetKey = "targetRel"
    static let posXKey = "panelX"
    static let posYKey = "panelY"
    static let visibleKey = "panelVisible"
    /// 窗口是否置于底层（不挡其他窗口）
    static let bottomKey = "panelBottom"
    /// 面板形态：dropdown（菜单栏下拉）/ docked（常驻浮窗）
    static let modeKey = "panelMode"
    /// 老版本用过的键。任一存在 → 说明是老用户，升级后迁移成 docked，
    /// 别把人家常驻了好几版的窗口没收走。
    static let legacyKeys = [posXKey, posYKey, visibleKey, bottomKey, targetKey, vaultKey]

    static var defaultVault: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Obsidian/Main")
    }

    /// 命令行 `--vault` 覆盖：只影响本次进程，不写入偏好，便于用隔离测试库验收
    static var overrideVault: URL?

    static var vault: URL {
        if let o = overrideVault { return o }
        if let s = UserDefaults.standard.string(forKey: vaultKey), !s.isEmpty {
            return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        }
        return defaultVault
    }

    static var storedTarget: String {
        UserDefaults.standard.string(forKey: targetKey) ?? "00-收件箱"
    }

    static func saveTarget(_ rel: String) {
        UserDefaults.standard.set(rel, forKey: targetKey)
    }
}

// MARK: - 目标

struct ArchiveTarget {
    enum Kind { case inbox, project, plain }
    let rel: String
    let name: String
    var kind: Kind {
        if rel == "00-收件箱" { return .inbox }
        if rel.hasPrefix("10-项目/") { return .project }
        return .plain
    }

    /// 与实际投递目标一致的标签（QA-003）。
    /// 以前无论投到哪个目标都写「收件箱」，导致项目/领域/资源笔记被误分类。
    var tag: String {
        switch kind {
        case .inbox:   return "收件箱"
        case .project: return "项目"
        case .plain:   return Targets.stripNumericPrefix((rel as NSString).lastPathComponent)
        }
    }
}

enum Targets {
    /// "20-领域" → "领域"，"10-项目" → "项目"；没有数字编号前缀时原样返回
    static func stripNumericPrefix(_ s: String) -> String {
        let parts = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy({ $0.isNumber }) {
            let rest = String(parts[1]).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? s : rest
        }
        return s
    }

    /// 固定项 + 扫描 10-项目 下的所有项目
    ///
    /// P2：按「项目目录 mtime」缓存。菜单每次弹出都会调这里，
    /// 原来每次都同步 `contentsOfDirectory` + 逐项 `fileExists`，
    /// 项目一多，右键菜单就有可感知的延迟；而项目目录没变时这个结果不会变。
    static func all(vault: URL) -> [ArchiveTarget] {
        let fm = FileManager.default
        let projectsDir = vault.appendingPathComponent("10-项目")
        let attrs = try? fm.attributesOfItem(atPath: projectsDir.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = vault.standardizedFileURL.path + "#" + String(mtime)

        cacheLock.lock()
        if let c = cache, c.key == key {
            cacheLock.unlock()
            return c.list
        }
        cacheLock.unlock()

        var list: [ArchiveTarget] = [ArchiveTarget(rel: "00-收件箱", name: "00-收件箱")]
        if let names = try? fm.contentsOfDirectory(atPath: projectsDir.path) {
            for n in names.sorted() where !n.hasPrefix(".") {
                var isDir: ObjCBool = false
                let p = projectsDir.appendingPathComponent(n).path
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                    list.append(ArchiveTarget(rel: "10-项目/\(n)", name: n))
                }
            }
        }
        list.append(ArchiveTarget(rel: "20-领域", name: "20-领域"))
        list.append(ArchiveTarget(rel: "30-资源", name: "30-资源"))

        cacheLock.lock()
        cache = (key: key, list: list)
        cacheLock.unlock()
        return list
    }

    private static let cacheLock = NSLock()
    private static var cache: (key: String, list: [ArchiveTarget])?

    /// 自检用：清缓存，避免跨用例串味
    static func invalidateCache() {
        cacheLock.lock(); cache = nil; cacheLock.unlock()
    }
}

// MARK: - 路径守卫

/// 投递目标的安全解析（QA-002）。
///
/// 规则：只接受库内相对路径；拒绝绝对路径、`~` 开头、任何 `..` 路径段，
/// 并在词法规范化 + 符号链接解析之后再次确认结果仍在库内。
/// 这样 `--target ../x`、`--target /tmp/x`、以及「库内软链指向库外」都会被整体拒绝，
/// 不会出现「笔记被写到库外、附件留在库内」的分裂状态。
enum VaultGuard {
    enum Failure: LocalizedError {
        case invalidTarget(String)
        case outsideVault(String)

        var errorDescription: String? {
            switch self {
            case .invalidTarget(let m): return m
            case .outsideVault(let m): return m
            }
        }
    }

    /// 规范化用户输入的目标：去首尾空白、去空段、去 `.` 段。
    ///
    /// 必须和 `resolve` 用同一份规范化结果去判断「这是不是项目目标」——
    /// 否则 `./10-项目/P1` 或 ` 10-项目/P1 ` 会落到正确目录，
    /// 却被当成普通目标（附件进全局 `附件/`、标签变成项目名），与产品语义不符。
    /// 不处理 `..`：那属于应当拒绝的写法，由 `resolve` 抛错。
    static func normalize(_ rel: String) -> String {
        rel.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
            .joined(separator: "/")
    }

    /// 返回已规范化的库内目录 URL；越界或非法写法直接抛错
    static func resolve(target rel: String, vault: URL) throws -> URL {
        // 绝对路径/`~` 必须在规范化之前判断：normalize 会吃掉前导空段，"/tmp/x" 会变成 "tmp/x"
        let trimmed = rel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw Failure.invalidTarget("投递目标不能为空") }
        if trimmed.hasPrefix("/") {
            throw Failure.invalidTarget("投递目标必须是库内相对路径，拒绝绝对路径：\(rel)")
        }
        if trimmed.hasPrefix("~") {
            throw Failure.invalidTarget("投递目标不能使用 ~ 开头的路径：\(rel)")
        }

        let raw = normalize(rel)
        if raw.isEmpty {
            throw Failure.invalidTarget("投递目标不能是库根目录本身：\(rel)")
        }
        let comps = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if comps.contains("..") {
            throw Failure.invalidTarget("投递目标不能包含 .. 路径段：\(rel)")
        }

        let vaultReal = realPath(vault)
        let candidate = vault.appendingPathComponent(comps.joined(separator: "/"))
        let resolved = realPath(candidate)

        guard contains(resolved.path, in: vaultReal.path) else {
            throw Failure.outsideVault(
                "投递目标解析后不在库内（可能是符号链接指向库外）：\(rel) → \(resolved.path)"
            )
        }
        if resolved.path == vaultReal.path {
            throw Failure.invalidTarget("投递目标不能是库根目录本身：\(rel)")
        }
        return resolved
    }

    /// 校验一个「已经构造好的库内目录」在解析符号链接后仍在库内。
    ///
    /// 附件目录 `附件/YYYY-MM` 和项目文档目录 `<项目>/文档` 不是用户直接输入的，
    /// 但它们完全可能是库里预先存在的软链（有人把附件目录链到外置盘/同步盘的子目录），
    /// 所以同样要过这一关，否则会出现「笔记在库内、附件被写到库外」的分裂状态。
    static func ensureInside(_ url: URL, vault: URL, label: String) throws -> URL {
        let vaultReal = realPath(vault)
        let resolved = realPath(url)
        guard resolved.path != vaultReal.path, contains(resolved.path, in: vaultReal.path) else {
            throw Failure.outsideVault(
                "\(label)解析后不在库内（可能是符号链接指向库外）：\(resolved.path)"
            )
        }
        return resolved
    }

    /// 词法规范化（消掉 . 与重复分隔符）后再解析符号链接。
    ///
    /// 注意：不能直接用 `resolvingSymlinksInPath()` —— 对不存在的路径它会整体放弃解析，
    /// 于是 `库/附件/2026-11`（2026-11 还没创建）里的 `附件` 软链不会被解析，
    /// 校验会误判为「在库内」并通过，接着 createDirectory 就把目录建到库外去了。
    /// 这里先向下找到最深的存在路径，解析它，再把不存在的尾段拼回去。
    static func realPath(_ url: URL) -> URL {
        let full = url.standardizedFileURL
        var existing = full
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            let last = existing.lastPathComponent
            if last.isEmpty { break }
            tail.insert(last, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        let resolvedBase = existing.resolvingSymlinksInPath().standardizedFileURL
        return tail.reduce(resolvedBase) { $0.appendingPathComponent($1) }
    }

    static func contains(_ child: String, in parent: String) -> Bool {
        if child == parent { return true }
        let base = parent.hasSuffix("/") ? parent : parent + "/"
        return child.hasPrefix(base)
    }
}

// MARK: - 归档引擎

struct DropOutcome {
    let source: String
    let noteRel: String
    let fileRel: String
    /// 1.7.0：一次投递的主键，AI 事件与投递事件必须用同一个 id
    var captureId: String = ""
    var scene: AIScene = .legacy
    var aiState: AIState = .off
    var aiReason: String = ""

    init(source: String = "", noteRel: String, fileRel: String,
         captureId: String = "", scene: AIScene = .legacy,
         aiState: AIState = .off, aiReason: String = "") {
        self.source = source
        self.noteRel = noteRel
        self.fileRel = fileRel
        self.captureId = captureId
        self.scene = scene
        self.aiState = aiState
        self.aiReason = aiReason
    }
}

/// 单个源文件的失败原因（QA-001）：不再用抛出中断整批
struct BatchFailure {
    let source: String
    let reason: String
}

/// 一批投递的完整结果：既保留成功项，也保留失败项
struct BatchReport {
    var outcomes: [DropOutcome] = []
    var failures: [BatchFailure] = []

    var total: Int { outcomes.count + failures.count }
    var partial: Bool { !outcomes.isEmpty && !failures.isEmpty }
    var allSucceeded: Bool { failures.isEmpty }
    var allFailed: Bool { outcomes.isEmpty && !failures.isEmpty }
}

enum FilerError: LocalizedError {
    case vaultMissing(String)
    case sourceMissing(String)
    case copyFailed(String, String)
    case noteFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .vaultMissing(let p): return "库目录不存在：\(p)"
        case .sourceMissing(let p): return "源文件不存在：\(p)"
        case .copyFailed(let n, let m): return "复制失败 \(n)：\(m)"
        case .noteFailed(let n, let m): return "笔记写入失败 \(n)：\(m)（已回收已复制的附件，库内不留残留）"
        }
    }
}

final class Filer {
    private let vault: URL
    private let fm = FileManager.default

    init(vault: URL) { self.vault = vault }

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let secondFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH-mm-ss"
        return f
    }()

    /// 清掉会破坏 wikilink 的字符
    static func sanitize(_ s: String) -> String {
        var bad = CharacterSet(charactersIn: "[]|#^\\/:*?\"<>")
        bad.insert(charactersIn: "\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名" : String(trimmed.prefix(80))
    }

    private func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        var i = 2
        while fm.fileExists(atPath: candidate.path) {
            let n = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
            candidate = dir.appendingPathComponent(n)
            i += 1
        }
        return candidate
    }

    private func relPath(_ url: URL) -> String {
        let base = VaultGuard.realPath(vault).path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let p = VaultGuard.realPath(url).path
        return p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : p
    }

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "svg", "avif"
    ]

    /// YAML 标量：标签一律加双引号，避免目录名里的空格/冒号破坏 frontmatter
    static func yamlScalar(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func yamlTags(_ tags: [String]) -> String {
        var seen = Set<String>()
        return tags
            .filter { seen.insert($0).inserted }
            .map { "  - \(yamlScalar($0))" }
            .joined(separator: "\n")
    }

    func file(_ urls: [URL], target rel: String,
              contexts: [ArchiveContext]? = nil) throws -> BatchReport {
        guard fm.fileExists(atPath: vault.path) else { throw FilerError.vaultMissing(vault.path) }

        // 目标先规范化并校验仍在本库内；越界写法整体拒绝，什么都不写（QA-002）
        let noteDirRaw = try VaultGuard.resolve(target: rel, vault: vault)
        // 类别、标签、笔记里的「目标」字段都必须用同一份规范化结果，
        // 否则 `./10-项目/P1` 这类写法会落对目录却算成普通目标
        let normalizedRel = VaultGuard.normalize(rel)
        let target = ArchiveTarget(rel: normalizedRel,
                                   name: (normalizedRel as NSString).lastPathComponent)
        // 建目录前后各校验一次：库内软链指向库外时，createDirectory 不会报错（目录已存在），
        // 所以不能只依赖创建本身成功与否。
        _ = try VaultGuard.ensureInside(noteDirRaw, vault: vault, label: "笔记目录")
        try fm.createDirectory(at: noteDirRaw, withIntermediateDirectories: true)
        let noteDir = try VaultGuard.ensureInside(noteDirRaw, vault: vault, label: "笔记目录")

        // 项目类目标：文件进「文档/」（会同步到手机）
        // 其它目标：文件进全局「附件/年-月/」（会同步到 iCloud 镜像，手机可见）
        let fileDirRaw: URL
        switch target.kind {
        case .project:
            fileDirRaw = noteDir.appendingPathComponent("文档")
        default:
            fileDirRaw = vault.appendingPathComponent("附件")
                .appendingPathComponent(Filer.monthFmt.string(from: Date()))
        }
        // 附件目录同样必须落在库内：它是本应用自己拼的，但库里可能已经存在同名软链
        _ = try VaultGuard.ensureInside(fileDirRaw, vault: vault, label: "附件目录")
        try fm.createDirectory(at: fileDirRaw, withIntermediateDirectories: true)
        let fileDir = try VaultGuard.ensureInside(fileDirRaw, vault: vault, label: "附件目录")

        // 1.7.0：整批共用一个 12 秒 AI 预算。先做一次不读内容的快速分类，
        // 算出「还需要请求的项目数」，逐项按剩余预算公平分摊（规格 A4.2）。
        let cfg = AIConfigStore.config
        let batch = contexts?.first?.batchBudget
            ?? AIBatchBudget(cap: cfg.effectiveBudget)
        let origin = contexts?.first?.source == "screenshot" ? "screenshot" : "drop"
        // A1：调用方已给出场景时直接用，不在后台再分类一次（也保证 CLI --scene 生效）。
        let quick: [AIScene] = {
            if let contexts, contexts.count == urls.count { return contexts.map(\.scene) }
            return urls.map { SceneRouter.classify(file: $0, origin: origin) }
        }()
        var aiLeft = cfg.enabled ? quick.filter { $0.usesModel }.count : 0

        // 逐个处理：单个文件失败不再中断整批，成功项与失败项都要留痕（QA-001）
        var report = BatchReport()
        for (i, src) in urls.enumerated() {
            do {
                let ctx: ArchiveContext
                if let contexts, i < contexts.count {
                    ctx = contexts[i]
                } else {
                    ctx = ArchiveContext(source: origin, scene: quick[i], target: normalizedRel,
                                         sourceURL: src, batchBudget: batch)
                }
                report.outcomes.append(try archive(src, target: target, noteDir: noteDir,
                                                   fileDir: fileDir, context: ctx,
                                                   aiPending: max(1, aiLeft), config: cfg))
                if quick[i].usesModel { aiLeft = max(0, aiLeft - 1) }
            } catch {
                if quick[i].usesModel { aiLeft = max(0, aiLeft - 1) }
                report.failures.append(BatchFailure(source: src.path, reason: error.localizedDescription))
            }
        }
        return report
    }

    /// 归档单个源文件；失败只抛出这一项的错误
    private func archive(_ src: URL, target: ArchiveTarget, noteDir: URL, fileDir: URL,
                         context: ArchiveContext, aiPending: Int,
                         config: AIConfig) throws -> DropOutcome {
        // 源可能是符号链接：解析到真实对象再复制。
        // 否则库内会留下一个指向库外的链接——既不是独立副本，笔记里的「文件」字段
        // 也会变成库外绝对路径，越界检查形同虚设。
        let realSrc = src.resolvingSymlinksInPath().standardizedFileURL
        guard fm.fileExists(atPath: realSrc.path) else { throw FilerError.sourceMissing(src.path) }

        var isDir: ObjCBool = false
        fm.fileExists(atPath: realSrc.path, isDirectory: &isDir)
        let isFolder = isDir.boolValue

        let rawBase = (src.lastPathComponent as NSString).deletingPathExtension
        let ext = isFolder ? "" : realSrc.pathExtension
        let base = Filer.sanitize(rawBase)
        let day = Filer.dayFmt.string(from: Date())
        let dest = uniqueURL(in: fileDir, base: "\(day) \(base)", ext: ext)

        do {
            try fm.copyItem(at: realSrc, to: dest)
        } catch {
            throw FilerError.copyFailed(src.lastPathComponent, error.localizedDescription)
        }

        // 1.7.0：分类 → 提取/压缩 → 请求模型，全部在这个后台调用里完成。
        // 任何一步失败都只是「这一项没有 AI」，笔记照样按 1.6.0 模板落盘。
        let material = SceneMaterial.prepare(url: src, origin: context.source,
                                             target: target.rel,
                                             forcedScene: context.scene)
        let scene = material.scene
        var outcome = AISceneOutcome.off
        if config.enabled {
            if let input = material.input, scene.usesModel {
                let budget = context.batchBudget.attemptBudget(pending: aiPending)
                outcome = AISceneService.process(input, config: config, budget: budget)
            } else if !material.reason.isEmpty, scene == .legacy {
                // 原本可摘要但取文失败：仍算一次 skipped（不重发请求）
                outcome = .skipped(material.reason)
            }
            // 天生 legacy 的类型：状态保持 off，不写 ai 事件，由投递事件表达
        }
        // AI 事件：一次投递最多一条，且与投递事件共用 captureId
        if config.enabled, outcome.state != .off,
           scene.usesModel || outcome.requested || !material.reason.isEmpty {
            MetricsStore.shared.record(MetricEvent(
                kind: "ai", ok: outcome.state == .done, target: target.rel,
                source: context.source, durationMs: outcome.result?.ms ?? 0,
                captureId: context.captureId, failReason: outcome.reason,
                ai: outcome.state.rawValue))
        }

        // 生成笔记
        let noteBaseName = "\(day) \(base)"
        let destRel = relPath(dest)
        let linkName = destRel
        let isImage = Filer.imageExts.contains(ext.lowercased())
        let linkLine: String
        if isFolder {
            let count = (try? fm.subpathsOfDirectory(atPath: dest.path).count) ?? 0
            linkLine = "文件夹已归档（\(count) 个文件）：`\(destRel)`"
        } else if isImage {
            linkLine = "![[\(linkName)]]"
        } else if ext.lowercased() == "pdf" {
            linkLine = "![[\(linkName)]]"
        } else {
            linkLine = "[[\(linkName)|打开 \(base).\(ext)]]"
        }

        let sizeText = isFolder ? "文件夹" : Filer.humanSize(dest)
        // 来源文案由投递上下文决定，不再「文件在临时目录就当截图」——
        // 临时目录里的普通图片会被误标，而移到别处的截图又会漏标。
        let srcDir = context.source == "screenshot"
            ? "本机屏幕截图"
            : (src.path as NSString).deletingLastPathComponent
        let stamp = Filer.stampFmt.string(from: Date())
        // 提示里的目录直接取自实际落盘位置，避免和真实路径脱节（QA-005）
        let destDirRel = (destRel as NSString).deletingLastPathComponent
        let placeHint = target.kind == .project
            ? "`\(destDirRel)/`，会同步到 iPhone"
            : "`\(destDirRel)/`，会随库同步到手机"

        // A6.6：关闭 / 失败 / legacy 必须与 1.6.0 逐字一致，一个字段都不能多。
        let legacyFront = """
        ---
        类型: 文件归档
        文件: \(destRel)
        归档时间: \(stamp)
        来源目录: \(srcDir)
        目标: \(target.rel)
        tags:
        \(Filer.yamlTags([target.tag]))
        ---

        # \(base)

        \(linkLine)

        > [!note] 投递记录
        > - 原始位置：`\(src.path)`
        > - 大小：\(sizeText)
        > - 存放位置：\(placeHint)
        > - 由 ObsidianDrop 于 \(stamp) 投递到「\(target.rel)」

        ## 说明

        """

        let front: String
        if outcome.state == .done, let r = outcome.result, scene.usesModel {
            // A6.2：画面文字为空时整段 callout 不出现
            let visible: String
            if scene == .image, !r.visibleText.isEmpty {
                let lines = r.visibleText.components(separatedBy: "\n")
                    .map { "> \($0)" }.joined(separator: "\n")
                visible = "\n> [!quote]- 画面文字\n" + lines + "\n"
            } else {
                visible = ""
            }
            let action = scene == .image ? "识别图片并生成概述" : "生成标题/摘要/标签"
            front = """
            ---
            类型: 文件归档
            文件: \(destRel)
            归档时间: \(stamp)
            来源目录: \(srcDir)
            目标: \(target.rel)
            摘要: \(Filer.yamlQuoted(r.summary))
            AI: \(Filer.yamlQuoted("\(r.model)（\(r.ms)ms）"))
            AI场景: "\(scene.rawValue)"
            tags:
            \(Filer.yamlTags([target.tag] + r.tags))
            ---

            # \(r.title.isEmpty ? base : r.title)

            > [!abstract] 摘要
            > \(r.summary)

            \(linkLine)
            \(visible)
            > [!note] 投递记录
            > - 原始位置：`\(src.path)`
            > - 大小：\(sizeText)
            > - 存放位置：\(placeHint)
            > - 由 ObsidianDrop 于 \(stamp) 投递到「\(target.rel)」
            > - 整理：\(r.model) \(action)（\(r.ms)ms）

            ## 说明

            """
        } else {
            front = legacyFront
        }

        // 先复制附件、再独占发布笔记：笔记写失败必须把刚复制的附件也删掉。
        // link(2) 保证「只新建不覆盖」；同名冲突自动换 -2/-3。
        do {
            let published = try ExclusiveNoteWriter.publish(text: front, dir: noteDir,
                                                            base: noteBaseName)
            return DropOutcome(source: src.path, noteRel: relPath(published),
                               fileRel: destRel, captureId: context.captureId,
                               scene: scene, aiState: outcome.state,
                               aiReason: outcome.reason)
        } catch {
            try? fm.removeItem(at: dest)
            throw FilerError.noteFailed(noteBaseName, error.localizedDescription)
        }
    }

    /// 把一段语音转写文稿写成笔记（不产生附件）
    ///
    /// `ai` 是入库前 AI 处理的结果（1.5.0）。为空时行为与旧版完全一致——
    /// 这是刻意的：AI 关着/失败/超时，笔记必须和以前长得一模一样，
    /// 不能出现「这次没摘要、上次有」的随机差异。
    func memo(text: String, target rel: String, duration: TimeInterval, engine: String,
              ai: AIResult? = nil, aiState: AIState = .off,
              sceneResult: AISceneResult? = nil) throws -> DropOutcome {
        guard fm.fileExists(atPath: vault.path) else { throw FilerError.vaultMissing(vault.path) }

        let noteDirRaw = try VaultGuard.resolve(target: rel, vault: vault)
        try fm.createDirectory(at: noteDirRaw, withIntermediateDirectories: true)
        let noteDir = try VaultGuard.ensureInside(noteDirRaw, vault: vault, label: "笔记目录")
        let normalizedRel = VaultGuard.normalize(rel)
        let target = ArchiveTarget(rel: normalizedRel,
                                   name: (normalizedRel as NSString).lastPathComponent)

        let now = Date()
        let day = Filer.dayFmt.string(from: now)
        let stamp = Filer.stampFmt.string(from: now)
        let hms = Filer.secondFmt.string(from: now)
        let noteBaseName = "\(day) 灵感 \(hms)"
        let dur = Memo.clock(duration)

        // 正文按空行分段，读起来像随手记而不是一整坨（1.6.0 行为，关闭/失败必须逐字保持）
        let paragraphs = text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        // 1.7.0 A6.3：只有拿到润色稿才替换正文；旧 pending 的 done 结果没有润色稿，
        // 仍旧用原转写，不升级、不重新计费。
        let polished = sceneResult?.polishedText ?? ""
        let hasPolish = aiState == .done && !polished.isEmpty
        let bodyText = hasPolish ? Filer.squeezeBlankLines(polished) : paragraphs
        let originalQuote: String
        if hasPolish {
            let quoted = text.components(separatedBy: CharacterSet.newlines)
                .map { $0.trimmed.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
            originalQuote = "> [!quote]- 原始转写\n" + quoted + "\n\n"
        } else {
            originalQuote = ""
        }

        let body = """
        ---
        类型: 灵感速记
        创建时间: \(stamp)
        时长: \(dur)
        目标: \(rel)
        转写: 端上本机（\(engine)）
        \(aiFrontMatter(ai, state: aiState, hasPolish: hasPolish))tags:
        \(Filer.yamlTags(["灵感", target.tag] + (ai?.tags ?? [])))
        ---

        # \(ai?.title.isEmpty == false ? ai!.title : "灵感 \(stamp)")

        \(ai?.summary.isEmpty == false ? "> [!abstract] 摘要\n> \(ai!.summary)\n\n" : "")\(bodyText)

        \(originalQuote)> [!note] 录制信息
        > - 时长：\(dur)
        > - 转写：Mac 本机完成，未上传云端
        \(aiLine(ai, state: aiState, hasPolish: hasPolish))> - 由 ObsidianDrop 于 \(stamp) 录在「\(rel)」

        """
        let published = try ExclusiveNoteWriter.publish(text: body, dir: noteDir,
                                                        base: noteBaseName)
        return DropOutcome(noteRel: relPath(published), fileRel: "")
    }

    /// 段落之间恰好一个空行；行内首尾空白清掉。不改文字内容。
    static func squeezeBlankLines(_ s: String) -> String {
        var out: [String] = []
        var blank = false
        for raw in s.components(separatedBy: CharacterSet.newlines) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty {
                if blank || out.isEmpty { continue }
                blank = true
            } else {
                blank = false
            }
            out.append(l)
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    /// 只有**真的处理过**才写这两行。跳过/未启用时写「AI: 跳过」会让笔记里
    /// 多出一条与内容无关的状态噪音；而完全不写又分不清「没配」和「配了没生效」——
    /// 折中是：done 写模型名，skipped 写一行原因，off 什么都不写。
    private func aiFrontMatter(_ ai: AIResult?, state: AIState,
                               hasPolish: Bool = false) -> String {
        switch state {
        case .off, .pending:
            return ""
        case .done:
            guard let ai else { return "" }
            var s = "摘要: \(Filer.yamlQuoted(ai.summary))\n"
            if hasPolish {
                // 1.7.0 A6.3：整个「模型（耗时）」是一个 YAML 标量
                s += "AI: \(Filer.yamlQuoted("\(ai.model)（\(ai.ms)ms）"))\n"
                s += "AI场景: \"transcript\"\n"
            } else {
                // 1.6.0 的 done pending 没有润色稿：逐字保持旧模板，不升级、不重新计费
                s += "AI: \(Filer.yamlQuoted(ai.model))（\(ai.ms)ms）\n"
            }
            return s
        case .skipped:
            return "AI: 跳过（本次未处理，正文为原始转写）\n"
        }
    }

    private func aiLine(_ ai: AIResult?, state: AIState,
                        hasPolish: Bool = false) -> String {
        switch state {
        case .done:
            guard let ai else { return "" }
            let what = hasPolish ? "润色、分段并生成标题/摘要/标签" : "生成标题/摘要/标签"
            return "> - 整理：\(ai.model) \(what)（\(ai.ms)ms）\n"
        case .skipped:
            return "> - 整理：AI 未生效，正文为原始转写\n"
        case .off, .pending:
            return ""
        }
    }

    /// YAML 双引号标量：引号与反斜杠转义，换行已在上游清掉
    static func yamlQuoted(_ s: String) -> String {
        let e = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(e)\""
    }

    static func humanSize(_ url: URL) -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return "未知" }
        let bytes = v.fileSize ?? v.totalFileAllocatedSize ?? 0
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - 截图

enum Screenshot {
    enum Mode: String {
        case area       // 拖选区域
        case window     // 点选窗口
        case full       // 整屏（主显示器）
        case clipboard  // 拖选后直接进剪贴板
    }

    /// 同步执行一次截图。返回 (是否成功, 临时文件, 提示语)
    static func capture(_ mode: Mode) -> (ok: Bool, file: URL?, message: String) {
        let fm = FileManager.default
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH-mm-ss"
        let base = "屏幕截图 \(fmt.string(from: Date()))"
        let out = fm.temporaryDirectory.appendingPathComponent(base + ".png")
        try? fm.removeItem(at: out)

        var args: [String]
        switch mode {
        case .area:      args = ["-i", "-x", "-t", "png", out.path]
        case .window:    args = ["-i", "-W", "-o", "-x", "-t", "png", out.path]
        case .full:      args = ["-m", "-x", "-t", "png", out.path]
        case .clipboard: args = ["-i", "-x", "-c"]
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        do {
            try p.run()
        } catch {
            return (false, nil, "无法启动截图工具：\(error.localizedDescription)")
        }
        p.waitUntilExit()

        if mode == .clipboard {
            return p.terminationStatus == 0
                ? (true, nil, "已复制到剪贴板")
                : (false, nil, "已取消")
        }
        if p.terminationStatus != 0 {
            return (false, nil, "截图失败（退出码 \(p.terminationStatus)），通常是还没授予「屏幕录制」权限")
        }
        let attrs = try? fm.attributesOfItem(atPath: out.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard fm.fileExists(atPath: out.path), size > 0 else {
            return (false, nil, "已取消")
        }
        return (true, out, base)
    }
}

// MARK: - 灵感速记（录音 → 端上转写）

/// 录音/转写阶段
enum MemoPhase {
    case preparing
    case recording
    case transcribing
}

/// 一次录音/转写的结果画像。
///
/// 为什么需要它：转写出来是空的时候，原来的界面只有一句「没听清」，
/// 用户和开发者都不知道是「没录到音频」「录到了但没声音」「有声音但语言不匹配」
/// 还是「格式转换一直失败」。这四种情况的处置完全不同，必须分开说。
struct MemoOutcome {
    /// 墙钟录音时长
    var recorded: Double = 0
    /// 真正送进识别引擎的音频秒数
    var fed: Double = 0
    /// 识别出的字数
    var chars: Int = 0
    /// 音量峰值 0…1
    var peak: Float = 0
    /// 是否出现过音频格式转换失败
    var broken: Bool = false
    /// 写录音文件失败的次数（磁盘满、权限、格式突变都可能）
    var writeErrors: Int = 0
    /// 录音没完整落盘：转写内容可能缺一截，界面必须说清楚（build 25）
    var incompleteRecording: Bool { writeErrors > 0 }
    /// 是否来自音频文件（而不是现场录音）
    var fromFile: Bool = false
    /// 录音原始文件（1.3.11 起：录音先落盘再按文件转写，失败时这个文件还在）
    var recordingPath: String = ""
    /// 这一轮结果在「待归档队列」里的编号。
    /// 空 = 没有落盘（0 字、失败，或落盘本身出错）。
    /// 有了它，界面没接住也不影响归档——下次启动或看门狗会照着这个编号补上。
    var pendingID: String = ""

    /// 0 字时的原因判断，按「最可能且最容易查」的顺序排
    var diagnosis: String {
        var base: String
        if fed < 0.5 {
            base = "识别引擎几乎没收到音频（只收到 \(String(format: "%.2f", fed)) 秒）。"
                + "多半是麦克风没被系统真正打开：看「系统设置 → 声音 → 输入」里有没有电平跳动，"
                + "确认输入设备不是「无」，再重开一次程序。"
        } else if peak < 0.02 {
            base = "收到了 \(Memo.clock(fed)) 音频，但全程几乎没有声音（峰值 \(Int(peak * 100))%）。"
                + "检查输入音量是否被拉到最小、机身/键盘上的静音键是否生效、外接麦克风是否插在正确的口上。"
        } else if broken {
            base = "音频格式转换一路有失败，识别引擎没吃到有效数据（已收到 \(Memo.clock(fed)) 音频）。"
                + "这类是程序问题，把这条信息发给我即可，不用你改设置。"
        } else {
            base = "收到了 \(Memo.clock(fed)) 音频、音量峰值 \(Int(peak * 100))%，但一个字都没识别出来。"
                + "常见原因是语言不匹配（当前语言包：\(Memo.localeName)）：说方言或外语时，"
                + "可用 defaults write com.lw.obsidiandrop memoLocale <语言代码> 换语言包后重开程序。"
        }
        if !recordingPath.isEmpty {
            base += "\n\n这次的录音已经原样留在：\n\(recordingPath)\n"
                + "可以直接双击播放确认里面有没有声音；也可以右键菜单「转写音频文件…」选它再试一次。"
        }
        return base
    }
}

/// 面板的显示状态
enum MemoUI {
    case idle
    case preparing(String)
    case recording(TimeInterval, Float)
    /// 转写中：带上完整进度（标题里有百分比，副标题里是"还剩多少"）
    case transcribing(TranscribeProgress)
}

/// 跨版本安全的回调口：只用基础类型，不把 @available 传染给调用方。
///
/// 每个回调都带 `run`：**这一轮「灵感」的编号**。1.3.11 及以前没有这个字段，
/// 收尾阶段的进度是后台每 0.3 秒推一次的，队列里最后一条常常晚于
/// `memoDone` 执行——界面被重新画成「收尾中」，而之后再也不会有事件更新，
/// 用户看到的就是「一直卡在转写收尾中」。带上编号，迟到的一律丢弃。
protocol MemoSink: AnyObject {
    func memoPhase(_ phase: MemoPhase, note: String, run: Int)
    func memoProgress(_ progress: TranscribeProgress, run: Int)
    func memoLevel(_ level: Float, run: Int)
    func memoPartial(_ text: String, run: Int)
    func memoDone(text: String, duration: TimeInterval, outcome: MemoOutcome, error: Error?, run: Int)
}

enum MemoError: LocalizedError {
    case needNewerOS
    case micDenied
    case speechDenied
    case micUnavailable(String)
    case localeUnavailable(String)
    case noAudioFormat
    case engineFailed(String)
    case modelCheckTimeout
    case modelDownloadTimeout
    case speechEngineTimeout
    case audioUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .needNewerOS:
            return "「灵光一现」用的是 macOS 26 起的本机语音转写，当前系统版本不支持。"
        case .micDenied:
            return "没有麦克风权限。请到「系统设置 → 隐私与安全性 → 麦克风」勾上 ObsidianDrop，然后退出重开程序。若列表里根本没有 ObsidianDrop，说明系统还没登记它——把 app 拖进「应用程序」目录后重开一次，再点录音、在弹窗里允许即可。"
        case .speechDenied:
            return "没有语音识别权限。请到「系统设置 → 隐私与安全性 → 语音识别」勾上 ObsidianDrop，然后退出重开程序。"
        case .micUnavailable(let s):
            return "麦克风不可用：\(s)"
        case .localeUnavailable(let l):
            return "系统里找不到「\(l)」的语音模型。可在「系统设置 → 通用 → 语言与地区 → 听写语言」里加上中文。"
        case .noAudioFormat:
            return "无法建立音频转换格式（采样率不匹配）。"
        case .engineFailed(let s):
            return "转写引擎启动失败：\(s)"
        case .modelCheckTimeout:
            return "检查语音模型超时（30 秒）。多半是连不上 Apple 的模型服务，检查网络/代理后重试。"
        case .modelDownloadTimeout:
            return "语音模型下载超时（10 分钟）。首次使用要下几百 MB，请检查网络/代理后重试。"
        case .speechEngineTimeout:
            return "语音转写服务没有响应（30 秒）。多半是「语音识别」权限没给或系统语音服务没就绪；请到「系统设置 → 隐私与安全性 → 语音识别」勾上 ObsidianDrop，然后退出重开程序。"
        case .audioUnreadable(let name):
            return "读不出「\(name)」里的音频数据。文件可能录制时没写成功（头部长度是 0 且已无法推断），或者不是真正的音频。先用「音乐」或 QuickTime 打开确认能播放，再另存为 m4a 试一次。"
        }
    }
}

enum Memo {
    /// 单次录音上限（秒）。`nil` = 不限时长（1.7.0 build 23 起）。
    ///
    /// 保留这个开关而不是删掉判断：将来若要恢复上限只改这里一处，
    /// 自检也能直接断言 `== nil`，不用去读计时器实现。
    static let maxSeconds: Double? = nil

    /// 没有可用输入设备时的建议文案。
    ///
    /// 必须**带着实测结果**回去，而且**不能写死机型**：原来这里写的是
    /// 「Mac mini 没有内置麦克风」，结果在 MacBook Air 上一旦探测出错，
    /// 弹出来的还是这句话，用户会以为自己装错了包。
    static func noMicAdvice(_ p: AudioInputProbe) -> String {
        """
        这台电脑没有可用的音频输入设备，所以无法录音。
        实测：\(p.detail)
        可以按顺序排查：
        1) 「系统设置 → 声音 → 输入」里是否选中了一个设备，输入电平条有没有跳动；
        2) 外接麦克风 / 耳机是否插好；机身或键盘上的静音键是否把输入关了；
        3) 如果只有「连续互通麦克风」，先在「音频 MIDI 设置」里确认它在线（iPhone 要同一网络、同一 Apple 账户）；
        4) 在终端跑一次 ObsidianDrop --audio-check，把输出发回来能定位到具体哪一环。
        如果只是想把已有录音转成文字，用右键菜单「转写音频文件…」，\
        或在终端跑 ObsidianDrop --transcribe <音频文件>。
        """
    }

    /// 0:07 / 1:23 这种计时显示
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        // 录音不限时长后必须支持小时位：否则 2 小时会显示成 120:00，
        // 看起来像分钟数溢出。
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 人话时长：42 秒 / 3 分 12 秒 / 1 小时 02 分
    static func humanDuration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分 \(s % 60) 秒" }
        return "\(s / 3600) 小时 \(String(format: "%02d", (s % 3600) / 60)) 分"
    }

    static var localeID: String {
        let v = UserDefaults.standard.string(forKey: "memoLocale") ?? ""
        return v.isEmpty ? "zh-CN" : v
    }

    static var localeName: String {
        localeID.hasPrefix("zh") ? "中文" : localeID
    }
}

// MARK: - 转写进度

/// 转写进度：界面和命令行共用同一份。
///
/// 为什么要有结构、而不是一句「正在转成文字…」：
/// 转写分好几段（查语言包 → 查/下模型 → 识别 → 收尾），每段耗时量级差很多，
/// 一句静态文案在长音频上会让人以为卡死。这里把「在做什么 / 已到哪 / 还剩多少」
/// 拆开，界面拼成标题 + 副标题，CLI 拼成一行。
struct TranscribeProgress {
    enum Stage: Equatable {
        case preparing   // 查语言包、查模型、下载模型、启动引擎
        case analyzing   // 正在识别
        case finishing   // 收尾：系统还在消化已送入的音频
    }

    var stage: Stage = .preparing
    /// 界面标题，只写「在做什么」，**不带百分比**。
    ///
    /// 百分比要单独显示在图标上那个进度环里（大字），标题再塞一遍反而两个地方
    /// 各说一个数。CLI 仍然用 headline（带百分比），因为终端里没有图形环。
    var stageTitle: String = ""
    /// 主行，例如「识别中 3:12 / 12:00（27%）」
    var headline: String = ""
    /// 副行，例如「已出 128 字 · 剩余约 8 分钟」
    var detail: String = ""
    /// 0…1，未知时 nil。nil 表示「不知道还剩多少」，界面用不确定态的转圈环
    var percent: Double? = nil
    /// 已处理音频秒数
    var processed: Double = 0
    /// 音频总秒数（文件路径有，实时录音没有）
    var total: Double? = nil
    var chars: Int = 0

    static func preparing(_ note: String) -> TranscribeProgress {
        TranscribeProgress(stage: .preparing, stageTitle: "准备中", headline: note, detail: "")
    }

    /// 文字已经出来，正在把笔记和附件写进库。
    ///
    /// 这一段原来没有独立状态：写库发生在 `memoDone` 里、界面重绘之前，
    /// 库在 iCloud 上的时候可能要卡几秒——用户看到的就是「一直收尾中」。
    static func saving(_ chars: Int) -> TranscribeProgress {
        var p = TranscribeProgress()
        p.stage = .finishing
        p.stageTitle = "归档中"
        p.headline = "把笔记和附件写进库…"
        p.detail = chars > 0 ? "已识别 \(chars) 字" : ""
        p.chars = chars
        return p
    }

    /// 识别阶段的进度行。processed 是"已处理到音频的哪一秒"。
    static func analyzing(processed: Double, total: Double?, chars: Int) -> TranscribeProgress {
        var p = TranscribeProgress()
        p.stage = .analyzing
        p.stageTitle = "转写中"
        p.processed = processed
        p.total = total
        p.chars = chars

        if let total, total > 0 {
            let raw = max(0, min(1, processed / total))
            p.percent = raw
            p.headline = "识别中 \(Memo.clock(processed)) / \(Memo.clock(total))（\(Int(raw * 100))%）"
            let remain = max(0, total - processed)
            // 副标题只有 144pt 宽，写「已出 63 字 · 剩余音频 1 分 20 秒」会被截成
            // 「已出 63 字 ·...频 1 分 20 秒」。百分比已经在进度环里，这里只留
            // 最短的两个信息：多少字、还剩多少音频。
            p.detail = remain > 1
                ? "已出 \(chars) 字 · 剩 \(Memo.clock(remain))"
                : "已出 \(chars) 字 · 音频已送完"
        } else {
            p.headline = "识别中 \(Memo.clock(processed))"
            p.detail = chars > 0 ? "已出 \(chars) 字" : "还没有识别结果，继续说"
        }
        return p
    }

    /// 收尾阶段的进度行。留给用户的是「为什么要等」而不是「卡了」。
    ///
    /// 这里 **故意不给 percent**：音频其实已经全部送完了，显示 100% 会让人以为
    /// 「已经完成为什么还不动」。改成不确定态的转圈 + 已等时长，语义才对。
    static func finishing(processed: Double, total: Double?, chars: Int, waited: Double) -> TranscribeProgress {
        var p = analyzing(processed: processed, total: total, chars: chars)
        p.stage = .finishing
        p.stageTitle = "收尾中"
        p.percent = nil
        p.headline = "收尾中 \(Memo.clock(waited))"
        p.detail = "已出 \(chars) 字 · 已等 \(Memo.clock(waited))"
        return p
    }
}

// MARK: - 命令行进度输出

/// CLI 的进度打印：阶段变化立刻打一行，其余每 2 秒最多一行。
/// 不节流的话，百分比每 0.4 秒变一次会把终端刷满，反而看不出进度。
final class CLIProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var lastLine = ""
    private var lastStage: TranscribeProgress.Stage? = nil
    private var lastAt = Date.distantPast

    func emit(_ p: TranscribeProgress) {
        let line = p.detail.isEmpty ? p.headline : "\(p.headline) · \(p.detail)"
        lock.lock()
        let stageChanged = p.stage != lastStage
        let due = Date().timeIntervalSince(lastAt) >= 2
        if !stageChanged && !due { lock.unlock(); return }
        lastStage = p.stage
        lastLine = line
        lastAt = Date()
        lock.unlock()
        FileHandle.standardError.write("· \(line)\n".data(using: .utf8)!)
    }
}

// MARK: - 音频输入设备探测

/// 麦克风探测结果。
///
/// 为什么要有这么一层：判断「有没有麦克风」原来只用了
/// `AVCaptureDevice.DiscoverySession(deviceTypes: [], mediaType: .audio, ...)`
/// 一条路。`deviceTypes` 传空数组**并不是**「不限类型」的可靠写法——
/// 它按「不匹配任何类型」解释时就会返回空列表。于是在有内置麦克风的
/// MacBook Air 上也会被判成「没有音频输入设备」，弹出来的还是写着
/// 「Mac mini 没有内置麦克风」的文案，看起来像是装错了机器。
///
/// 现在同时走四路，任意一路有结果就算有设备；只有四路全空才认定没有：
///   1. DiscoverySession（明确的 deviceTypes）
///   2. AVCaptureDevice.default(for: .audio)
///   3. 旧接口 devices(for:)（DiscoverySession 在个别系统版本上有返回空的 bug）
///   4. AVAudioEngine 的真实输入格式（硬件真相：没设备是 0 Hz / 0 ch）
struct AudioInputProbe {
    /// AVCapture 报出来的输入设备名（多路合并去重）
    var captured: [String] = []
    /// CoreAudio 报出来的输入设备（最底层，AVFoundation 出错时它通常还是准的）
    var coreAudio: [String] = []
    /// 系统默认输入设备名
    var defaultName: String? = nil
    /// AVAudioEngine 的真实输入采样率。注意不能用 outputFormat——
    /// 没有输入设备时它会回退成 44100/2ch 的假格式。
    var sampleRate: Double = 0
    var channels: UInt32 = 0

    var auth: String = "unknown"
    var authRaw: AVAuthorizationStatus = .notDetermined

    /// 任一路有结果就算有
    var usable: Bool { !captured.isEmpty || !coreAudio.isEmpty || sampleRate > 0 }

    /// 给人看的一行实测结果，会原样进错误弹窗和 --audio-check
    var detail: String {
        let dev = captured.isEmpty ? "无" : captured.joined(separator: "、")
        let ca = coreAudio.isEmpty ? "无" : coreAudio.joined(separator: "、")
        return String(
            format: "AVFoundation 设备：%@；CoreAudio 设备：%@；默认输入：%@；输入格式：%.0f Hz / %u ch；麦克风授权：%@",
            dev, ca, defaultName ?? "无", sampleRate, channels, auth)
    }
}

enum AudioProbe {
    /// 读一遍系统状态。只做查询，不请求权限、不启动采集，随时调用都安全。
    static func run(withEngine: Bool = true) -> AudioInputProbe {
        var p = AudioInputProbe()

        // ① 明确类型。macOS 14 起有 .microphone 这个聚合类型，
        //    更早的系统只能逐个列出内置/外接。
        if #available(macOS 14.0, *) {
            let s = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            p.captured = s.devices.map(\.localizedName)
        } else {
            let s = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInMicrophone, .externalUnknown],
                mediaType: .audio, position: .unspecified)
            p.captured = s.devices.map(\.localizedName)
        }

        // ② 系统默认输入。纯属性查询，不需要授权
        if let d = AVCaptureDevice.default(for: .audio) {
            p.defaultName = d.localizedName
            if !p.captured.contains(d.localizedName) { p.captured.append(d.localizedName) }
        }

        // ③ 旧接口兜底。这条在 macOS 14+ 被标为 deprecated，但它是
        //    DiscoverySession 返回空时唯一还能看到设备的路子，保留并忽略警告。
        for d in AVCaptureDevice.devices(for: .audio) where !p.captured.contains(d.localizedName) {
            p.captured.append(d.localizedName)
        }

        // ④ CoreAudio 层。AVFoundation 的授权/发现逻辑出问题时这一层仍然准确，
        //    两边一对照就知道是「真的没设备」还是「上层没看到设备」。
        p.coreAudio = coreAudioInputs()

        // ⑤ 引擎看到的真实输入格式
        if withEngine {
            let e = AVAudioEngine()
            let f = e.inputNode.inputFormat(forBus: 0)
            p.sampleRate = f.sampleRate
            p.channels = f.channelCount
        }

        p.authRaw = AVCaptureDevice.authorizationStatus(for: .audio)
        switch p.authRaw {
        case .authorized:    p.auth = "已允许"
        case .denied:        p.auth = "已拒绝"
        case .restricted:    p.auth = "受限制"
        case .notDetermined: p.auth = "未决定"
        @unknown default:    p.auth = "未知"
        }
        return p
    }

    /// 直接从 CoreAudio 列输入设备（不经过 AVFoundation）。
    /// 返回值形如 ["MacBook Air 麦克风 (1ch)"]。
    static func coreAudioInputs() -> [String] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        var out: [String] = []
        for id in ids {
            // 只保留「有输入通道」的设备：扬声器、虚拟输出都不算
            var cfgAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var cfgSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &cfgAddr, 0, nil, &cfgSize) == noErr,
                  cfgSize > 0 else { continue }
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(cfgSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &cfgAddr, 0, nil, &cfgSize, raw) == noErr else { continue }
            let list = UnsafeMutableAudioBufferListPointer(
                raw.assumingMemoryBound(to: AudioBufferList.self))
            let chans = list.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard chans > 0 else { continue }

            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            // 用 Unmanaged 接：这个属性返回的是 +1 的 CFString，
            // 直接给 CFString 变量取地址会触发「可能含对象引用」的警告，
            // 语义也不对（会多一次 ARC 持有）。
            var cfName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &cfName) == noErr,
               let n = cfName?.takeRetainedValue() {
                out.append("\(n) (\(chans)ch)")
            }
        }
        return out
    }

    /// 设备型号，形如 MacBookAir10,1。远程排查时一眼能分清是哪台机器。
    static func machineModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "未知" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "未知" }
        return String(cString: buf)
    }

    /// 多行诊断报告：错误弹窗的「复制诊断信息」和 `--audio-check` 共用同一份内容，
    /// 保证用户看到什么、发回来的就是什么。
    static func report() -> String {
        // 未授权时不去碰 AVAudioEngine（避免多余的 TCC 交互），
        // 其余四路照常探测——设备名不需要授权就能读到。
        var p = run(withEngine: false)
        let probedEngine = (p.authRaw == .authorized)
        if probedEngine { p = run(withEngine: true) }

        let time = ISO8601DateFormatter().string(from: Date())
        var lines: [String] = [
            "ObsidianDrop 音频诊断",
            "时间：\(time)",
            "机型：\(machineModel())",
            "系统：\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "AVFoundation 设备：\(p.captured.isEmpty ? "无" : p.captured.joined(separator: "、"))",
            "CoreAudio 设备：\(p.coreAudio.isEmpty ? "无" : p.coreAudio.joined(separator: "、"))",
            "默认输入：\(p.defaultName ?? "无")",
            probedEngine
                ? String(format: "引擎输入格式：%.0f Hz / %u ch", p.sampleRate, p.channels)
                : "引擎输入格式：未探测（麦克风未授权）",
            "麦克风授权：\(p.auth)",
            "结论：\(p.usable ? "有可用输入设备" : "没有可用输入设备")",
        ]
        if !p.usable {
            lines.append("提示：若「CoreAudio 设备」有值而「AVFoundation 设备」为空，属于上层发现失败；"
                         + "若两边都为空，则是系统层面就没有输入设备。")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 音频投喂器（把任意格式转成分析器能吃的 AnalyzerInput）

/// 把任意来源的 buffer（麦克风硬件格式 / 文件格式）转成可投喂的 `AnalyzerInput`。
///
/// 存在的理由：`AnalyzerInput(buffer:)` 内部是 **Swift 运行时断言**——
/// 格式不合规会直接 SIGTRAP 闪退，连 catch 都接不住。所以必须由我们自己
/// 保证格式，或者交给官方的 `AnalyzerInputConverter`（它抛的是可捕获错误）。
@available(macOS 26.0, *)
protocol AudioFeeder: AnyObject {
    /// 转不成就返回 nil（跳过这一块），不要抛
    func makeInputs(from buf: AVAudioPCMBuffer) -> [AnalyzerInput]?
    /// 收尾时把转换器里没吐完的尾巴交出来
    func flush() -> [AnalyzerInput]
}

/// macOS 27+：官方转换器。格式不合规时抛可捕获错误，由我们决定跳过还是放弃。
@available(macOS 27.0, *)
final class OfficialFeeder: AudioFeeder {
    private let conv: AnalyzerInputConverter
    init(_ conv: AnalyzerInputConverter) { self.conv = conv }

    func makeInputs(from buf: AVAudioPCMBuffer) -> [AnalyzerInput]? {
        try? conv.convert(buf, at: nil)
    }

    func flush() -> [AnalyzerInput] { (try? conv.flush()) ?? [] }
}

/// macOS 26：自己转码。必须严格核对格式——这里任何一处漏判都会变成 SIGTRAP。
@available(macOS 26.0, *)
final class ManualFeeder: AudioFeeder {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) { self.target = target }

    func makeInputs(from buf: AVAudioPCMBuffer) -> [AnalyzerInput]? {
        let srcFmt = buf.format
        guard srcFmt.sampleRate > 0, srcFmt.channelCount > 0, buf.frameLength > 0 else { return nil }

        var out = buf
        if srcFmt != target {
            if converter == nil { converter = AVAudioConverter(from: srcFmt, to: target) }
            guard let c = converter else { return nil }
            let ratio = target.sampleRate / srcFmt.sampleRate
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 2048
            guard let dst = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
            var err: NSError?
            var supplied = false
            let st = c.convert(to: dst, error: &err) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buf
            }
            guard err == nil, st != .error, dst.frameLength > 0 else { return nil }
            out = dst
        }

        // 最后一道闸：格式必须与分析器要求逐项一致，否则宁可丢这块也不能交给 AnalyzerInput
        let f = out.format
        guard f == target,
              f.sampleRate == target.sampleRate,
              f.channelCount == target.channelCount,
              f.commonFormat == target.commonFormat,
              f.isInterleaved == target.isInterleaved else { return nil }
        return [AnalyzerInput(buffer: out)]
    }

    func flush() -> [AnalyzerInput] { [] }
}

// MARK: - 转写引擎（macOS 26+，SpeechAnalyzer / DictationTranscriber）

/// 落盘日志：`~/Library/Logs/ObsidianDrop.log`，超过 200 KB 自动重来。
///
/// `NSLog` 进的是系统统一日志，用户的 Mac 上不好取——一句「卡住了」发过来，
/// 这边只能猜。1.3.12 起把关键节点（录音时长、识别耗时、收尾耗时、产出字数）
/// 直接写成文本，出问题让用户把这一个文件发过来即可。
enum DiagLog {
    private static let queue = DispatchQueue(label: "com.lw.obsidiandrop.diaglog")
    private static let limit = 512 * 1024
    /// 计时起点。在 `header()` 里重置——直接用 `static let = Date()` 会变成
    /// 首次访问时才初始化（懒加载），于是日志里「进程已运行」永远是 0.0s。
    private static var startRef = Date()

    /// 缓存的格式化器与句柄：只在 `queue` 上用，见 `append`
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()
    private static var handle: FileHandle?
    private static var written = 0

    /// 版本号，取自 Info.plist。
    ///
    /// 1.3.12 的现场日志里**没有版本号**，拿到一份日志也说不清是哪个构建打出来的，
    /// 「这个 bug 修没修」全靠猜。以后每条启动头都必须带版本。
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "源码直跑"
        let b = info?["CFBundleVersion"] as? String ?? "-"
        return "\(v)(\(b))"
    }

    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ObsidianDrop.log")
    }()

    static var path: String { url.path }

    /// 启动头：把「同一次运行」与上一次分开，并写清版本/机型/系统/库位置。
    /// 排查时第一眼看这几行，就能排除「版本不对」「库路径不对」这两大类误判。
    static func header(_ tag: String, extra: String = "") {
        startRef = Date()
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let pid = ProcessInfo.processInfo.processIdentifier
        write("===== \(tag) ｜ 版本 \(versionText) ｜ \(AudioProbe.machineModel()) ｜ \(os)"
              + " ｜ PID \(pid) ｜ 库 \(Cfg.vault.path) ｜ 日志 \(path)"
              + (extra.isEmpty ? "" : " ｜ \(extra)") + " =====")
    }

    /// 带轮次前缀的一行。轮次是唯一能把「上一轮的迟到回调」与「本轮」分开的东西，
    /// 所以凡是灵感链路上打的日志都带上它。
    static func round(_ run: Int, _ message: String) {
        write("run \(run) ｜ \(message)")
    }

    /// 进程已运行多久，形如 12.3s
    static func uptime() -> String {
        String(format: "%.1fs", Date().timeIntervalSince(startRef))
    }

    static func write(_ message: String) {
        // P1：DateFormatter 与文件句柄都缓存。
        // 原实现每条日志 new 一个 DateFormatter + open/seek/close 一次文件，
        // 转写进度密集时每 0.3s 就有好几条，全花在格式化与 open(2) 上。
        let now = Date()
        queue.async { append(message, at: now) }
    }

    /// 等日志队列排空。
    /// CLI 路径（`--metrics` / `--search` / `--ai-*`）写完日志就 `exit`，
    /// 异步队列里的最后几条会被直接丢掉——偏偏那些正是「为什么失败」的解释。
    static func flush() {
        queue.sync {}
    }

    /// 只在日志队列上执行，所有可变状态（handle / written / fmt）因此天然串行
    private static func append(_ message: String, at date: Date) {
        let line = "[\(fmt.string(from: date))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if handle == nil {
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            written = (attrs?[.size] as? Int) ?? 0
        }
        if written > limit {
            try? handle?.close()
            handle = nil
            written = 0
            try? fm.removeItem(at: url)
            return append(message, at: date)
        }
        handle?.write(data)
        written += data.count
    }
}

/// 迟到回调的判据（纯逻辑，自检里直接测）。
///
/// 两条都要满足才接受：编号等于当前轮，且本轮尚未收尾。
/// 少了任何一条，收尾阶段最后一条进度就会把界面画回「收尾中」并且再无人更新。
enum MemoGate {
    /// 进度 / 音量：轮次要一致，而且本轮已经收尾就不再画。
    ///
    /// 少了「未收尾」这一条，收尾阶段最后一条进度会把界面画回「收尾中」并且再无人更新。
    static func acceptsProgress(run: Int, current: Int, stateIsIdle: Bool) -> Bool {
        run == current && !stateIsIdle
    }

    /// 结果（done）：**只比轮次，不要求「未收尾」**。
    ///
    /// 1.3.13 起有看门狗：长时间没有任何事件会把界面强制恢复成 idle，让人能继续操作。
    /// 这时后台那一轮可能还活着，它最后交上来的文本不该被丢掉——丢掉的正是用户刚说完的那段话。
    /// 轮次编号已经能挡住上一轮的迟到回调，所以这里只比编号。
    static func acceptsDone(run: Int, current: Int) -> Bool {
        run == current
    }
}

/// 把回调投到主线程，并且**不依赖产生回调的那个对象还活着**。
///
/// 1.3.13 把「会话是否还活着」和「结果能否送达」绑在一起：投递闭包写的是
/// `[weak self]`，self 是 `MemoSession`。会话在 `endMemo()` 里被置空、转写任务
/// 一结束就被释放，于是排在主队列的结果块取到 nil，被当作「会话已释放」丢掉。
/// 现场日志里「交付结果到主线程」与「丢弃 done：录音会话已释放」在同一毫秒，
/// 就是这一跳断的。
///
/// 这正是「界面对象不在就忽略显示」与「数据必须落袋」被混为一谈。
/// 现在 sink 在入队时取出并强持有：界面还在就画，界面没了也照样把结果交给它
/// （AppDelegate 本身是常驻的，强引用只是维持到这次投递执行完）。
enum MemoDelivery {
    static func post(run: Int, what: String, to sink: MemoSink, logLag: Bool = true,
                     _ block: @escaping (MemoSink, Int) -> Void) {
        let queuedAt = Date()
        DispatchQueue.main.async {
            let lag = Date().timeIntervalSince(queuedAt)
            if logLag, lag > 0.4 {
                DiagLog.round(run, "主线程排了 \(String(format: "%.1f", lag))s 才处理 \(what)"
                              + "（主线程可能被堵住）")
            }
            block(sink, run)
        }
    }
}

/// 带超时的「执行并等待」：work 在时限内完成返回 true，超时返回 false 并取消内部任务。
/// 轮询 done 标志，work 一完成就立即返回；只有真正卡死才会耗满 seconds。
///
/// 不用 `withTaskGroup` + `cancelAllTasks()`，因为后者要 macOS 14+，而本项目部署目标是 13.0。
func runWithTimeout(seconds: Double, _ work: @escaping () async -> Void) async -> Bool {
    let done = OSAllocatedUnfairLock(initialState: false)
    let workTask = Task.detached(priority: .userInitiated) {
        await work()
        done.withLock { $0 = true }
    }
    let start = Date()
    while true {
        if done.withLock({ $0 }) { return true }
        if Date().timeIntervalSince(start) >= seconds { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    let finished = done.withLock({ $0 })
    if !finished { workTask.cancel() }
    return finished
}

/// 一次性把音频喂给系统端上模型，边喂边出字。
/// 麦克风与文件两条路径共用它，保证识别口径一致。
@available(macOS 26.0, *)
final class SpeechRunner {
    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    /// 音频投喂器：macOS 27+ 用官方 `AnalyzerInputConverter`（格式不合规抛可捕获错误），
    /// macOS 26 用自研转码 + 严格格式闸。两者都保证不会把格式不合规的 buffer
    /// 交给 `AnalyzerInput`——那会直接 SIGTRAP 闪退。
    private let feeder: AudioFeeder
    private var collectTask: Task<Void, Never>?

    private var finalText = ""
    private var partialText = ""

    /// 实时文本（整段累计）
    var onUpdate: ((String) -> Void)?

    // MARK: 运行期计数
    //
    // 只用来诊断「为什么没出字」和判断能不能安全收尾：
    // fed   —— 成功喂给分析器的音频块数
    // frames—— 累计帧数
    // events—— 结果流产出的事件数
    // done  —— 结果流是否已经自然结束（收尾就等这一个标志）
    // broken—— 音频格式转换失败过（格式不对会让分析器永远不出结果）
    fileprivate struct Diag: Sendable {
        var fed = 0
        /// 累计帧数，已折算成**分析器格式**（不是源 buffer 的帧数）。
        /// 直接累加源帧会把 48kHz 的录音算成 3 倍时长，
        /// 进而把收尾超时上限也算成 3 倍，长音频会白等很久。
        var frames: AVAudioFramePosition = 0
        var events = 0
        var chars = 0
        var done = false
        var broken = false
    }

    private var diag = Diag()
    private let diagLock = NSLock()

    private func mutateDiag(_ block: (inout Diag) -> Void) {
        diagLock.lock()
        block(&diag)
        diagLock.unlock()
    }

    private func readDiag() -> Diag {
        diagLock.lock()
        defer { diagLock.unlock() }
        return diag
    }

    /// 一行摘要，写进 logs/memo.log
    var stats: String {
        let d = readDiag()
        return "喂入 \(d.fed) 块/\(d.frames) 帧、出字 \(d.events) 次"
            + (d.broken ? "、格式转换有失败" : "")
    }

    private init(transcriber: DictationTranscriber,
                 analyzer: SpeechAnalyzer,
                 format: AVAudioFormat,
                 feeder: AudioFeeder,
                 continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.format = format
        self.feeder = feeder
        self.continuation = continuation
    }

    /// 建引擎的公共前半段：查语言包 → 查模型 →（必要时）下载模型 → 建分析器。
    ///
    /// 实时录音和文件转写共用这一段，保证两条路的识别口径一致。
    /// 每一步都给 progress：这几步最容易被误认成「卡死」——尤其是首次下载模型。
    private static func prepare(localeID: String,
                                progress: ((TranscribeProgress) -> Void)? = nil) async throws
        -> (transcriber: DictationTranscriber, analyzer: SpeechAnalyzer) {
        let prepStart = Date()
        progress?(.preparing("准备语音转写…"))

        // ① 查 locale。这一步会碰系统的语音服务，权限没给/服务没就绪时会一直吊着，
        //    所以限时 20s，别让界面永远停在「准备中」。
        var locale: Locale?
        let localeOK = await runWithTimeout(seconds: 20) {
            locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID))
            if locale == nil {
                locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current)
            }
        }
        guard localeOK else { throw MemoError.speechEngineTimeout }
        guard let locale else { throw MemoError.localeUnavailable(localeID) }
        DiagLog.write("准备：语言 \(localeID) → \(localizedName(locale))，"
                      + "耗时 \(String(format: "%.1f", Date().timeIntervalSince(prepStart)))s")

        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)

        // ② 查模型要不要装。这一步要访问 Apple 资产服务，网络不通时会一直吊着，
        //    所以先给界面一句提示，再限时 60s 兜底。
        progress?(.preparing("检查「\(localizedName(locale))」语音模型是否已安装…"))
        var installReq: AssetInstallationRequest?
        var reqError: Error?
        let reqOK = await runWithTimeout(seconds: 60) {
            do { installReq = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) }
            catch { reqError = error }
        }
        guard reqOK else { throw MemoError.modelCheckTimeout }
        if let reqError { throw reqError }
        DiagLog.write("准备：语音模型 \(installReq == nil ? "已安装" : "需要下载")，"
                      + "累计 \(String(format: "%.1f", Date().timeIntervalSince(prepStart)))s")

        // ③ 首次使用要下几百 MB 的模型，慢是正常的，但必须有提示、有上限。
        if let req = installReq {
            progress?(.preparing("下载「\(localizedName(locale))」语音模型…（首次使用，几百 MB，最长等 10 分钟）"))
            // 下载期间**每 0.3 秒报一次「已等多久」**：
            // 一是让用户知道没卡死，二是让看门狗知道这一轮还活着——
            // 否则一次几百 MB 的下载会被自己的看门狗当成卡死。
            let dlStart = Date()
            let ticker = Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if Task.isCancelled { break }
                    let waited = Memo.clock(Date().timeIntervalSince(dlStart))
                    progress?(.preparing("正在下载「\(localizedName(locale))」语音模型…已等 \(waited)"))
                }
            }
            var dlError: Error?
            let dlOK = await runWithTimeout(seconds: 600) {
                do { try await req.downloadAndInstall() }
                catch { dlError = error }
            }
            ticker.cancel()
            DiagLog.write("准备：模型下载 \(dlOK ? "完成" : "超时")，"
                          + "耗时 \(String(format: "%.1f", Date().timeIntervalSince(dlStart)))s，"
                          + "累计 \(String(format: "%.1f", Date().timeIntervalSince(prepStart)))s")
            guard dlOK else { throw MemoError.modelDownloadTimeout }
            if let dlError { throw dlError }
            progress?(.preparing("语音模型下载完成，正在装载…"))
        }

        return (transcriber, SpeechAnalyzer(modules: [transcriber]))
    }

    /// 建立「实时录音」用的引擎：需要输入流与投喂器。
    static func make(localeID: String,
                     progress: ((TranscribeProgress) -> Void)? = nil) async throws -> SpeechRunner {
        let (transcriber, analyzer) = try await prepare(localeID: localeID, progress: progress)

        // ④ 建分析器并启动。限时 30s——语音服务起不来时要有明确报错，
        //    而不是永远转圈。
        progress?(.preparing("启动转写引擎…"))
        var runner: SpeechRunner?
        var buildError: Error?
        let buildOK = await runWithTimeout(seconds: 30) {
            do {
                guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    buildError = MemoError.noAudioFormat
                    return
                }
                let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
                try await analyzer.start(inputSequence: stream)
                // 投喂器：macOS 27+ 用官方转换器（最稳），26 用自研转码。
                // OBSIDIANDROP_FEEDER=manual 可强制走自研转码，用于排查
                // 「某种采样率下不出字」这类格式问题。
                let forceManual = ProcessInfo.processInfo.environment["OBSIDIANDROP_FEEDER"] == "manual"
                let feeder: AudioFeeder
                if #available(macOS 27.0, *), !forceManual {
                    let c = try await AnalyzerInputConverter.converter(compatibleWith: [transcriber])
                    feeder = OfficialFeeder(c)
                } else {
                    feeder = ManualFeeder(target: fmt)
                }
                let r = SpeechRunner(transcriber: transcriber,
                                     analyzer: analyzer,
                                     format: fmt,
                                     feeder: feeder,
                                     continuation: cont)
                r.startCollecting()
                runner = r
            } catch {
                buildError = error
            }
        }
        guard buildOK else { throw MemoError.speechEngineTimeout }
        if let buildError { throw buildError }
        guard let runner else { throw MemoError.noAudioFormat }
        return runner
    }

    private static func localizedName(_ l: Locale) -> String {
        Locale(identifier: "zh_CN").localizedString(forIdentifier: l.identifier) ?? l.identifier
    }

    /// 有些录音笔 / 手机 / 边录边写的程序会把 wav 的 `data` chunk 长度写成 0
    /// （录到一半断电、程序崩溃、或导出前没回填头部）。`AVAudioFile` 会严格按声明长度读，
    /// 于是一帧都读不到 —— 用户看到的就是「这个 wav 识别不出来」。
    /// 这里按文件实际大小把 RIFF / data 两处长度改回来，落一份临时副本再读。
    private static func repairedWAV(_ url: URL) -> URL? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        guard let head = try? fh.read(upToCount: 12), head.count == 12 else { return nil }
        let h = [UInt8](head)
        guard Array(h[0..<4]) == Array("RIFF".utf8),
              Array(h[8..<12]) == Array("WAVE".utf8) else { return nil }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sizeNum = attrs[.size] as? NSNumber else { return nil }
        let fileSize = sizeNum.intValue
        guard fileSize > 12 else { return nil }

        var pos = 12
        var dataOff: Int? = nil
        var declared: UInt32 = 0
        var blockAlign = 1

        // 逐个 chunk 走，只为了找到 data 的位置和它声明的长度
        while pos + 8 <= fileSize {
            _ = try? fh.seek(toOffset: UInt64(pos))
            guard let ch = try? fh.read(upToCount: 8), ch.count == 8 else { break }
            let c = [UInt8](ch)
            let id = String(bytes: c[0..<4], encoding: .ascii) ?? ""
            let size = UInt32(c[4]) | (UInt32(c[5]) << 8) | (UInt32(c[6]) << 16) | (UInt32(c[7]) << 24)

            if id == "fmt " {
                // blockAlign 在 fmt 体的第 12 字节
                if let body = try? fh.read(upToCount: min(Int(size), 32)), body.count >= 14 {
                    let f = [UInt8](body)
                    blockAlign = max(1, Int(UInt16(f[12]) | (UInt16(f[13]) << 8)))
                }
            }
            if id == "data" {
                dataOff = pos + 8
                declared = size
                break
            }
            let adv = Int(size) + Int(size & 1)   // chunk 按偶数字节对齐
            if adv <= 0 { break }
            pos += 8 + adv
        }

        guard let off = dataOff else { return nil }
        var actual = fileSize - off
        guard actual > 0 else { return nil }
        // 声明长度正常（≤ 实际剩余）就不动，避免误伤好文件
        guard declared == 0 || Int(declared) > actual else { return nil }
        if blockAlign > 1 { actual -= actual % blockAlign }   // 丢掉尾部不完整的采样帧
        guard actual > 0 else { return nil }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsidianDrop-fixed-\(UUID().uuidString).wav")
        try? FileManager.default.removeItem(at: tmp)
        guard (try? FileManager.default.copyItem(at: url, to: tmp)) != nil else { return nil }
        guard let w = try? FileHandle(forWritingTo: tmp) else { return nil }
        defer { try? w.close() }

        func put32(_ v: UInt32, at o: Int) {
            var le = v.littleEndian
            let d = withUnsafeBytes(of: &le) { Data($0) }
            _ = try? w.seek(toOffset: UInt64(o))
            try? w.write(contentsOf: d)
        }
        put32(UInt32(truncatingIfNeeded: fileSize - 8), at: 4)
        put32(UInt32(truncatingIfNeeded: actual), at: off - 4)

        NSLog("ObsidianDrop: 修正 wav 头：data 声明 \(declared) → \(actual) 字节（原长度不可信）")
        return tmp
    }

    /// 线程安全的结果累计器。
    /// 文件路径下 `analyzeSequence` 在等整套音频处理完，结果由另一个 Task 收集，
    /// 两边都需要读它，所以必须自己加锁。
    final class TextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var final = ""
        private var partial = ""
        /// 已定稿结果的音频区间（秒）。
        ///
        /// 1.3.13 只记总字数，于是「94 秒音频出 51 字」这种日志根本判不出是
        /// 「用户本来就没说几句」还是「丢了一大半」——两者在字数上长得一样。
        /// 有了区间就能算：文字覆盖了音频的多少秒、最长的一段空白有多长。
        private var finalRanges: [(Double, Double)] = []
        private var finalCount = 0
        private var partialCount = 0

        func push(_ s: String, isFinal: Bool, range: CMTimeRange? = nil) {
            lock.lock(); defer { lock.unlock() }
            if isFinal {
                final += s
                partial = ""
                finalCount += 1
                if let range {
                    let a = CMTimeGetSeconds(range.start)
                    let b = CMTimeGetSeconds(range.end)
                    if a.isFinite, b.isFinite, b > a { finalRanges.append((a, b)) }
                }
            } else {
                partial = s
                partialCount += 1
            }
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return SpeechRunner.merge(final, partial).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return final.count + partial.count
        }

        var parts: (final: Int, partial: Int) {
            lock.lock(); defer { lock.unlock() }
            return (finalCount, partialCount)
        }

        /// 文字对音频的覆盖：覆盖了多少秒、最长一段「没有文字」的空白有多长。
        /// 只统计定稿结果——未定稿的结果会被后续覆盖，算进来会虚高。
        func coverage(total: Double) -> (covered: Double, maxGap: Double, segments: Int) {
            lock.lock(); defer { lock.unlock() }
            let segs = finalRanges
                .map { (max(0, $0.0), min($0.1, total > 0 ? total : $0.1)) }
                .filter { $0.1 > $0.0 }
                .sorted { $0.0 < $1.0 }
            var covered = 0.0
            var maxGap = 0.0
            var cursor = 0.0
            for (a, b) in segs {
                if a > cursor { maxGap = max(maxGap, a - cursor) }
                if b > cursor {
                    covered += b - max(cursor, a)
                    cursor = b
                }
            }
            if total > cursor { maxGap = max(maxGap, total - cursor) }
            return (covered, maxGap, segs.count)
        }
    }

    /// 打开音频文件；wav 头里长度字段不可信时，用修正过的副本再开。
    private static func openAudio(_ url: URL) throws -> (file: AVAudioFile, cleanup: URL?) {
        do {
            let a = try AVAudioFile(forReading: url)
            if a.length > 0 { return (a, nil) }
        } catch {
            guard let fixed = repairedWAV(url) else { throw error }
            return (try AVAudioFile(forReading: fixed), fixed)
        }
        guard let fixed = repairedWAV(url) else {
            return (try AVAudioFile(forReading: url), nil)
        }
        return (try AVAudioFile(forReading: fixed), fixed)
    }

    /// 转写一个音频文件。与麦克风路径共用同一套引擎与识别口径。
    ///
    /// 1.3.10 起改用 `analyzeSequence(from:)`，不再自己「读一块 → yield 一块」。
    ///
    /// 原来那条路有一个致命的节奏问题：读文件几乎是瞬间的（1 小时音频十几秒就灌完），
    /// 而识别要几十秒。灌进来的 buffer 全堆在 `AsyncStream` 里，`finish()` 一关流，
    /// 没被消费的部分**直接丢掉**——表现就是「60 秒音频只出 10 个字」。
    /// `analyzeSequence` 是「处理完整个序列才返回」，本身带背压，从根上避免这个问题。
    static func transcribeFile(at url: URL,
                               localeID: String,
                               progress: @escaping (TranscribeProgress) -> Void = { _ in }) async throws -> (text: String, seconds: Double) {
        let (transcriber, analyzer) = try await prepare(localeID: localeID, progress: progress)

        let opened = try openAudio(url)
        defer { if let c = opened.cleanup { try? FileManager.default.removeItem(at: c) } }
        let audio = opened.file
        guard audio.length > 0 else { throw MemoError.audioUnreadable(url.lastPathComponent) }

        let rate = audio.processingFormat.sampleRate
        let seconds = rate > 0 ? Double(audio.length) / rate : 0
        DiagLog.write("转写文件：\(url.lastPathComponent)，\(Int(rate))Hz/"
                      + "\(audio.processingFormat.channelCount)ch，"
                      + "\(String(format: "%.1f", seconds))s（\(audio.length) 帧）")
        progress(TranscribeProgress(
            stage: .analyzing,
            headline: "准备识别 \(Memo.humanDuration(seconds)) 的音频…",
            detail: "",
            percent: 0, processed: 0, total: seconds, chars: 0))

        let box = TextBox()
        let collector = Task.detached {
            do {
                for try await r in transcriber.results {
                    box.push(String(r.text.characters), isFinal: r.isFinal, range: r.range)
                }
            } catch {
                NSLog("ObsidianDrop: 文件转写结果流结束 \(error)")
            }
        }

        // 进度轮询：analyzeSequence 是一个长调用，内部不会回调进度，
        // 所以每隔 0.4 秒读一次分析器的 volatileRange（已处理到的时间点）。
        let reporter = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { break }
                let processed = await SpeechRunner.processedSeconds(analyzer, fallback: 0)
                progress(.analyzing(processed: processed, total: seconds, chars: box.count))
            }
        }

        var analyzeError: Error?
        let analyzeStart = Date()
        // `analyzeSequence` 自己不带超时：真机上语音服务异常时它可能一直不返回，
        // 界面就永远停在「识别中」。按实测吞吐（约 80 倍实时）给一个宽松上限——
        // 宁可慢，不能卡死；超时就带着已经出来的文字收工。
        let analyzeLimit = min(max(90.0, seconds / 8.0), 1200.0)
        let analyzeOK = await runWithTimeout(seconds: analyzeLimit) {
            do {
                _ = try await analyzer.analyzeSequence(from: audio)
            } catch {
                analyzeError = error
            }
        }
        reporter.cancel()
        if !analyzeOK {
            DiagLog.write("识别超时：音频 \(Int(seconds))s，限 \(Int(analyzeLimit))s，已出 \(box.count) 字")
            NSLog("ObsidianDrop: analyzeSequence 超时（限 \(Int(analyzeLimit))s），按已识别内容收尾")
        } else {
            DiagLog.write("识别完成：用时 \(String(format: "%.1f", Date().timeIntervalSince(analyzeStart)))s，已出 \(box.count) 字")
            // 音频不短却一个字都没出，说明结果还在管道里没被消费——
            // 这正是现场日志里「识别 0.1s 出 0 字」那种形状，后面的收尾会补齐，
            // 但要留一条，免得下次又以为是转写失败。
            if box.count == 0, seconds > 3 {
                DiagLog.write("注意：analyzeSequence 已返回但仍是 0 字，改由收尾阶段补齐")
            }
        }
        if let analyzeError { collector.cancel(); throw analyzeError }

        // 收尾：analyzeSequence 返回时音频已处理完，但结果流里还有一批结果没被
        // collector 消费掉（刚才那条进度显示「已出 0 字」就是这个原因）。
        // 所以收尾阶段用一个短轮询更新字数，而不是一次性报个 0。
        let finStart = Date()
        let finTicker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { break }
                progress(.finishing(processed: seconds, total: seconds,
                                    chars: box.count,
                                    waited: Date().timeIntervalSince(finStart)))
            }
        }
        // 收尾要多久取决于「系统里还积压多少音频」，跟录音长度成正比：
        // 实测 3 分钟音频 5.5 秒、48 分钟音频 90 秒上下。给 20 分之一并留 15 秒底线。
        // 录音不限时长后上限放到 900s：旧 180s 只够约 1 小时音频，半天会议会截尾。
        let finalizeLimit = min(max(15.0, seconds / 20.0), 900.0)
        let finalizeOK = await runWithTimeout(seconds: finalizeLimit) {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        DiagLog.write("收尾：用时 \(String(format: "%.1f", Date().timeIntervalSince(finStart)))s"
                      + "（限 \(Int(finalizeLimit))s），" + (finalizeOK ? "正常" : "超时") + "，字数 \(box.count)")
        if !finalizeOK { NSLog("ObsidianDrop: 文件转写收尾超时（\(Int(finalizeLimit))s），返回已识别内容") }
        // 结果流收尾同样跟着音频长度放宽，长录音最后一批结果才不会被丢掉
        let drainLimit = min(max(5.0, seconds / 120.0), 120.0)
        let drainOK = await runWithTimeout(seconds: drainLimit) { _ = await collector.value }
        if !drainOK {
            // 收尾都结束了结果流还没走完：后面这批结果就是「已经识别出来但没读走」，
            // 不说出来，下次还会被当成丢字去查引擎。
            DiagLog.write("注意：结果流 \(Int(drainLimit)) 秒内没有收完（collector 超时），可能有结果没被读走")
        }
        finTicker.cancel()

        let text = box.text
        DiagLog.write("转写完成：音频 \(Int(seconds))s，产出 \(text.count) 字")
        // 覆盖度：文字覆盖了多少秒音频、最长的一段空白有多长、结果条数。
        // 这是 1.3.13 缺的那块证据——「94 秒只出 51 字」到底是不是丢字，
        // 看这一行就能判断，不用再靠猜。
        let cov = box.coverage(total: seconds)
        let parts = box.parts
        let pct = seconds > 0 ? Int(cov.covered / seconds * 100) : 0
        DiagLog.write("结果覆盖：\(cov.segments) 段定稿（partial \(parts.partial) 条），"
                      + "覆盖 \(String(format: "%.1f", cov.covered))s / \(String(format: "%.1f", seconds))s（\(pct)%），"
                      + "最长空白 \(String(format: "%.1f", cov.maxGap))s")
        if seconds > 10, cov.covered / max(seconds, 0.1) < 0.5 {
            DiagLog.write("注意：文字只覆盖了不到一半的音频。可能是长时间安静，也可能真丢了字——"
                          + "拿一段有人工逐字稿的音频跑 --transcribe 对照即可确认")
        }
        NSLog("ObsidianDrop: 文件转写完成，音频 \(Int(seconds))s，产出 \(text.count) 字，覆盖 \(pct)%")
        return (text, seconds)
    }

    /// 已处理到音频的哪一秒。优先读分析器的 volatileRange（精确），
    /// 读不到（nil）时退回传进来的兜底值。
    private static func processedSeconds(_ analyzer: SpeechAnalyzer, fallback: Double) async -> Double {
        if let r = await analyzer.volatileRange {
            let s = CMTimeGetSeconds(r.end)
            if s.isFinite, s >= 0 { return s }
        }
        return fallback
    }

    var audioFormat: AVAudioFormat { format }

    /// 把一块音频喂给分析器。
    ///
    /// 交给 `AudioFeeder` 处理格式：转不了就跳过这一块，不中断整段转写，
    /// 更不会把格式不合规的 buffer 送进 `AnalyzerInput`（那会 SIGTRAP 闪退）。
    func feed(_ buf: AVAudioPCMBuffer) {
        guard buf.frameLength > 0 else { return }
        guard let inputs = feeder.makeInputs(from: buf) else {
            mutateDiag { $0.broken = true }
            NSLog("ObsidianDrop: 音频转换失败，已跳过该块（\(buf.format.sampleRate)Hz/\(buf.format.channelCount)ch）")
            return
        }
        for input in inputs {
            continuation.yield(input)
        }
        // 折算到分析器格式：录音走的是 48kHz 硬件格式，直接累加会把时长算成三倍
        let srcRate = buf.format.sampleRate
        let equivalent = srcRate > 0
            ? AVAudioFramePosition(Double(buf.frameLength) * format.sampleRate / srcRate)
            : AVAudioFramePosition(buf.frameLength)
        mutateDiag { $0.fed += 1; $0.frames += equivalent }
    }

    /// 已送入分析器的音频秒数（按分析器格式折算）
    var fedSeconds: Double {
        format.sampleRate > 0 ? Double(readDiag().frames) / format.sampleRate : 0
    }

    /// 当前已识别字数（定稿 + 未定稿）
    var recognizedChars: Int { readDiag().chars }

    /// 是否出现过音频格式转换失败（格式问题会让分析器永远不出结果）
    var converterBroken: Bool { readDiag().broken }

    private func startCollecting() {
        collectTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    let s = String(result.text.characters)
                    self.mutateDiag { $0.events += 1 }
                    if result.isFinal {
                        self.finalText += s
                        self.partialText = ""
                    } else {
                        self.partialText = s
                    }
                    let merged = SpeechRunner.merge(self.finalText, self.partialText)
                    self.mutateDiag { $0.chars = merged.count }
                    self.onUpdate?(merged)
                }
            } catch {
                NSLog("ObsidianDrop: 转写流结束 \(error)")
            }
        }
    }

    /// 结束输入 → 等系统把尾巴转完 → 返回全文
    ///
    /// 关键修复：原先 `finalizeAndFinishThroughEndOfInput()` 在某些内核状态下会永久挂起，
    /// 导致面板一直卡在「正在转成文字…」。`finish()` 现在为两步都加上超时兜底，
    /// 即便系统转写内核卡死，也会在限时后强制收尾并返回已累计的文本。
    ///
    /// 超时上限**跟着音频长度走**：短录音积压很少，10 秒够了；
    /// 但「转写音频文件」是把整个文件按最大速度灌进分析器，喂完时分析器里还积压着
    /// 大段未消化的音频（实测 1 小时音频灌入只要十几秒，分析却要几十秒），
    /// 固定 10 秒会把尾巴整段丢掉。
    func finish(progress: @escaping (TranscribeProgress) -> Void = { _ in }) async -> String {
        // 0) 先把转换器里没吐完的尾巴 flush 出来，否则最后一点音频会丢
        for input in feeder.flush() { continuation.yield(input) }

        // 1) 通知分析器：没有更多音频了
        continuation.finish()

        let audioSeconds = fedSeconds
        // 约 30 倍实时（下限 10s）——实测分析吞吐在 90 倍实时左右，留足余量。
        // 录音不限时长后，上限必须跟着放大：旧版 180s 只够撑到约 4 小时音频，
        // 现在放到 15 分钟，半天会议也收得回来。
        let finalizeLimit = min(max(10.0, audioSeconds / 30.0), 900.0)
        // 结果流收尾只需等分析器把最后一批结果吐完，比 finalize 短
        let drainLimit = min(max(5.0, audioSeconds / 120.0), 120.0)

        // 收尾期间每 0.5 秒报一次「已经等了多久」。
        // 这段最容易被误判成卡死：实时录音时它通常 1~3 秒，长音频可以到十几秒。
        let started = Date()
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { break }
                guard let self else { break }
                progress(.finishing(processed: self.fedSeconds, total: nil,
                                    chars: self.recognizedChars,
                                    waited: Date().timeIntervalSince(started)))
            }
        }
        defer { ticker.cancel() }

        // 2) 强制产出最终稿（这一步可能挂起，必须限时）
        let finalized = await runWithTimeout(seconds: finalizeLimit) {
            do {
                try await self.analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                NSLog("ObsidianDrop: finalize \(error)")
            }
        }
        if !finalized {
            NSLog("ObsidianDrop: finalize 超时（限 \(Int(finalizeLimit))s，音频 \(Int(audioSeconds))s），强制收尾（可能丢失尾部片段）")
        }

        // 3) 等结果流自然结束
        _ = await runWithTimeout(seconds: drainLimit) {
            _ = await self.collectTask?.value
        }

        let out = SpeechRunner.merge(finalText, partialText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("ObsidianDrop: 转写收尾完成，\(stats)，产出 \(out.count) 字")
        return out
    }

    /// 拼「已定稿 + 当前未完句」，并避免重复
    static func merge(_ done: String, _ pending: String) -> String {
        let p = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return done }
        if done.hasSuffix(p) || done.contains(p) { return done }
        return done + p
    }

    /// 峰值电平（0…1），只用于面板上的呼吸效果与「有没有声音」的判断
    static func level(_ buf: AVAudioPCMBuffer) -> Float {
        let n = Int(buf.frameLength)
        guard n > 0 else { return 0 }
        // 硬件格式不一定是 float32：老声卡/VoIP 设备可能是 int16。
        // 只认 floatChannelData 的话，这类设备的电平永远是 0，
        // 于是「3 秒没听到声音」会误报、0 字诊断也会误判成「你没说话」。
        var sum: Float = 0
        if let ch = buf.floatChannelData {
            let p = ch[0]
            for i in 0..<n { let v = p[i]; sum += v * v }
        } else if let ch = buf.int16ChannelData {
            let p = ch[0]
            for i in 0..<n { let v = Float(p[i]) / 32768; sum += v * v }
        } else if let ch = buf.int32ChannelData {
            let p = ch[0]
            for i in 0..<n { let v = Float(p[i]) / 2147483648; sum += v * v }
        } else {
            return 0
        }
        let rms = (sum / Float(n)).squareRoot()
        // 经验映射：把 -50dB…-10dB 拉成 0…1
        let db = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (db + 50) / 40))
    }
}

// MARK: - 录音落盘（先存音频，再按文件转写）

/// 把麦克风采到的音频原样写成文件。
///
/// 为什么改成「先落盘、再转写」：
/// 原来录音时边收边喂给识别引擎，成败取决于「喂入速度与分析速度的竞争」；
/// 更糟的是引擎要等语音模型装好才能建立，首次使用时用户点「结束」可能**根本没有引擎**，
/// 于是表现为「录音之后转写不成功」，而音频已经不在任何地方了。
///
/// 现在录音只做一件事：把音频写进文件。转写走已经验证过的文件路径
/// （`analyzeSequence`，自带背压）。两条路彻底解耦：
///   · 录音永不因为识别引擎没就绪而失败；
///   · 转写复用「转写音频文件…」完全同一套逻辑，出问题只在一处；
///   · 万一没转出字，原始音频还在，可以播放确认或重新转写。
final class RecordingStore: @unchecked Sendable {
    let url: URL
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    /// 打开文件时记下的格式摘要。
    ///
    /// `close()` 会把 `format` 清掉（句柄都放了，留着没意义），但日志偏偏是
    /// **关文件之后**才打印的——1.3.13 的现场日志因此永远写着「格式 未建立
    /// （没有任何音频块进来）」，而同一行又明明有 452 万帧、18 MB 文件，
    /// 等于在告诉排查的人「音频根本没进来」，方向直接被带偏。
    /// 摘要必须在打开时固化，不随句柄释放而消失。
    private var formatSummary: String?
    /// 建文件时定下的采样率。**不能跟着 `format` 一起在 close() 里清掉**：
    /// 关闭后还要用它把帧数换算成时长，清掉就会把「有 12 秒音频」算成 0 秒，
    /// 然后误判成「没有录到音频」。
    private var sampleRate: Double = 0
    private var closed = false
    private let lock = NSLock()
    /// 已写入的帧数（只统计写成功的），用来算真实录音时长
    private(set) var frames: AVAudioFramePosition = 0
    /// 写入失败次数。非 0 时"没转出字"的解释会是「文件写入有问题」而不是「你没说话」
    private(set) var writeErrors = 0

    /// 文件格式摘要（诊断用）。真机排查看的就是这一行——
    /// 到底是 48kHz 立体声还是 16kHz 单声道，直接决定后面转码有没有走错路。
    var formatText: String {
        lock.lock(); defer { lock.unlock() }
        if let s = formatSummary { return s }
        // 摘要没记下来（异常路径）时，至少别撒谎：有帧就是有音频块进来过
        if frames > 0 { return "未记录（已写入 \(frames) 帧）" }
        return "未建立（没有任何音频块进来）"
    }

    /// 格式摘要的唯一生成处：日志、诊断、自检都读它，避免三处各写一份格式描述
    static func describe(_ f: AVAudioFormat) -> String {
        let kind: String
        switch f.commonFormat {
        case .pcmFormatFloat32: kind = "float32"
        case .pcmFormatInt16: kind = "int16"
        case .pcmFormatInt32: kind = "int32"
        default: kind = "\(f.commonFormat.rawValue)"
        }
        return "\(Int(f.sampleRate))Hz/\(f.channelCount)ch/\(kind)\(f.isInterleaved ? "/交错" : "")"
    }

    /// 录音文件目录：转写成功就删，失败时留着给用户排查
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ObsidianDrop/recordings", isDirectory: true)
    }

    init(directory: URL = RecordingStore.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        url = directory.appendingPathComponent("录音-\(df.string(from: Date())).caf")
    }

    /// 写一块音频。
    ///
    /// 必须用**第一块 buffer 自己的格式**建文件：`AVAudioFile.write(from:)` 要求
    /// buffer 格式与文件 `processingFormat` 完全一致，不一致会抛 ObjC 异常——
    /// Swift 接不住，直接 SIGABRT 闪退。所以格式一律从数据来，不从设备查询来。
    func append(_ buf: AVAudioPCMBuffer) {
        guard buf.frameLength > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        // 关掉之后还可能有最后一块在途（tap 回调执行中），必须无视，
        // 否则会在同一路径上把文件重建/截断，把已经录好的内容毁掉。
        guard !closed else { return }

        if file == nil {
            do {
                file = try AVAudioFile(forWriting: url,
                                       settings: buf.format.settings,
                                       commonFormat: buf.format.commonFormat,
                                       interleaved: buf.format.isInterleaved)
                format = buf.format
                formatSummary = RecordingStore.describe(buf.format)
                sampleRate = buf.format.sampleRate
                NSLog("ObsidianDrop: 开始录音 \(url.lastPathComponent)（\(Int(buf.format.sampleRate))Hz/\(buf.format.channelCount)ch）")
            } catch {
                writeErrors += 1
                NSLog("ObsidianDrop: 录音文件打不开 \(error)")
                return
            }
        }

        guard let f = file, let ff = format, ff == buf.format else {
            writeErrors += 1
            NSLog("ObsidianDrop: 录音格式中途变了，跳过一块（\(Int(buf.format.sampleRate))Hz/\(buf.format.channelCount)ch）")
            return
        }
        do {
            try f.write(from: buf)
            frames += AVAudioFramePosition(buf.frameLength)
        } catch {
            writeErrors += 1
            NSLog("ObsidianDrop: 写录音文件失败 \(error)")
        }
    }

    /// 关文件。不关的话最后一段还在缓冲区里，文件时长会偏短。
    func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        file = nil
        format = nil
    }

    /// 文件里实际有多少秒（按写入帧数算，比墙钟更准）。关文件后依然可用。
    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        guard sampleRate > 0 else { return 0 }
        return Double(frames) / sampleRate
    }

    var sizeBytes: Int64 {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (a?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func discard() {
        try? FileManager.default.removeItem(at: url)
    }

    /// 启动时清掉多天前留下的失败录音，避免无声堆积
    static func prune(olderThan days: Int = 7) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for u in items {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let d, d < cutoff { try? fm.removeItem(at: u) }
        }
    }
}

// MARK: - 待归档队列（1.3.14）

/// 一轮转写的**不可变结果**。
///
/// 这里刻意把 vault / target 一起冻结：归档可能发生在几分钟后（看门狗恢复、
/// 用户已经开始了新一轮、甚至下次启动），那时 `Cfg.vault` 或 `memoTarget`
/// 都可能已经不是当时那个——拿新的目标去写旧的内容，就是串档。
struct PendingMemo: Codable {
    var id: String
    var text: String
    var duration: Double
    var target: String
    var vaultPath: String
    var engine: String
    var audioPath: String
    var source: String          // "record" / "file"
    var createdAt: Date
    var attempts: Int

    // 1.5.0：AI 前置处理的结果跟着 pending 一起落盘。
    // 用可选而不是给默认值，是为了让**旧版写下的 pending 文件**照常解码——
    // 合成解码器对「非可选 + 默认值」同样要求键存在，缺键就整条读不出来。
    var aiState: AIState?
    var aiTitle: String?
    var aiSummary: String?
    var aiTags: [String]?
    /// 模型名与耗时也要落盘：否则崩溃恢复后重写的笔记里会变成「空模型 / 0ms」
    var aiModel: String?
    var aiMs: Int?

    // 1.7.0：全部可选 —— 旧版 pending 缺这些键也能照常解码。
    // aiScene 缺失一律解释为 .transcript：1.6.0 的队列只有转写这一条来源。
    var aiScene: AIScene?
    var aiPolishedText: String?
    var aiVisibleText: String?
    var aiReason: String?
    var aiEdits: [AIEdit]?

    var ai: AIState { aiState ?? .off }
    var scene: AIScene { aiScene ?? .transcript }

    var vault: URL { URL(fileURLWithPath: vaultPath) }
}

/// 转写结果的落盘队列。
///
/// 1.3.13 的顺序是「拿到文字 → 删录音 → 投给界面」。投递只要失败一次
/// （会话被释放、轮次被顶掉、进程退出），文字和录音就同时消失，
/// 用户看到的只有「一直在收尾中」加一句「卡住了」。
/// 现在反过来：文字先原子落盘，界面只是**消费者之一**，不是唯一保管人。
enum PendingStore {
    /// 自检用：把队列目录指到临时目录，别往真实的 Application Support 里写
    static var overrideDirectory: URL?

    static var directory: URL {
        if let d = overrideDirectory { return d }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ObsidianDrop/pending", isDirectory: true)
    }

    /// 原子写入：先写 `.tmp` 再 rename。
    /// 直接写正式文件的话，进程在写一半时被结束，下次启动会读到半截 JSON——
    /// 那条结果就等于没保存，而且看不出来。
    @discardableResult
    static func enqueue(_ m: PendingMemo) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let final = directory.appendingPathComponent("\(m.id).json")
        let tmp = directory.appendingPathComponent(".\(m.id).tmp")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try enc.encode(m).write(to: tmp, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        // 原子替换：`remove` + `move` 之间有一个窗口，两边都不存在——
        // 进程正好在这时被杀，那条结果就彻底没了（而它可能是唯一一份文字）。
        // rename(2) 在同一卷上是原子的，并且保留 tmp 的 0600 权限。
        if rename(tmp.path, final.path) != 0 {
            // 极少数情况（跨卷 / 权限）：退回 remove + move，并把错误抛出去
            _ = try? fm.removeItem(at: final)
            try fm.moveItem(at: tmp, to: final)
        }
        return final
    }

    static func all() -> [PendingMemo] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return items
            .filter { $0.pathExtension == "json" }
            .compactMap { u -> PendingMemo? in
                guard let d = try? Data(contentsOf: u),
                      let m = try? dec.decode(PendingMemo.self, from: d) else {
                    // 坏文件不能静默忽略：它可能是唯一一份文字，要留痕。
                    // 带上完整路径——否则日志里只出现一个文件名，分不清是真实的待归档
                    // 目录还是自检用的临时目录，排查时又要多猜一轮。
                    DiagLog.write("待归档文件无法解析，已跳过：\(u.path)")
                    return nil
                }
                return m
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// P6：按 id 直接读那一个文件。
    /// 原实现是 `all().first { … }`——每次调用都要把队列里所有 JSON 读一遍并解码，
    /// 而归档收尾时连着调两次，队列长时就是 O(N) × 2 的纯浪费。
    static func load(id: String) -> PendingMemo? {
        let u = directory.appendingPathComponent("\(id).json")
        guard let d = try? Data(contentsOf: u) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(PendingMemo.self, from: d)
    }

    @discardableResult
    static func remove(id: String) -> Bool {
        ((try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))) != nil)
    }

    static var count: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".json") }.count ?? 0
    }
}

/// 「这篇笔记已经落盘了」的凭据。
///
/// 归档的顺序是「写笔记 → 删 pending」，中间那段是崩溃窗口：进程正好在这里被杀，
/// 重启后补归档看到 pending 还在，就会再写一篇内容相同、只差几秒时间戳的笔记。
/// 用户视角是「明明只录了一次，知识库里出现两条」——而且删了 pending 才算完的话，
/// 这段窗口非常短但并非不可能（掉电、强杀、内核 panic 都算）。
///
/// 所以在删 pending 之前先原子写一个 `<id>.done`，里面记着笔记路径。
/// 补归档看到它就直接清理，不再写第二篇。
enum ArchiveMarker {
    private static func url(_ id: String) -> URL {
        PendingStore.directory.appendingPathComponent("\(id).done")
    }

    @discardableResult
    static func mark(id: String, rel: String) -> Bool {
        let u = url(id)
        try? FileManager.default.createDirectory(at: PendingStore.directory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard (try? Data(rel.utf8).write(to: u, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: u.path)
        return true
    }

    static func doneRel(id: String) -> String? {
        guard let d = try? Data(contentsOf: url(id)),
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func clear(id: String) {
        try? FileManager.default.removeItem(at: url(id))
    }

    /// 孤儿标记清扫：标记写完、`clear` 之前又崩了，就会留下一堆没用的 .done。
    /// 每个目录每进程扫一次（用目录路径做键，自检/CLI 切临时目录时不会互相占位），
    /// 超过 3 天的删掉——正常路径下它们活不过一次归档。
    private static var sweptDirs = Set<String>()
    static func sweepIfNeeded(now: Date = Date()) {
        let key = PendingStore.directory.path
        if sweptDirs.contains(key) { return }
        sweptDirs.insert(key)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: PendingStore.directory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return }
        for u in items where u.pathExtension == "done" {
            guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey]),
                  let at = v.contentModificationDate,
                  now.timeIntervalSince(at) > 3 * 86400 else { continue }
            try? fm.removeItem(at: u)
        }
    }
}

/// 崩溃恢复期的「这段文字是不是已经写成过笔记」判断。
///
/// `ArchiveMarker` 只能覆盖「笔记写完 → 标记落盘」之后的那段窗口。真正剩下的
/// 最后一段是「Filer 写完笔记 → 标记还没落盘」，这段没法用文件标记消掉（要先知道
/// 笔记路径，而路径是 Filer 里生成的）。
///
/// 所以恢复路径上再加一道内容查重：只在补归档时、只对**已经躺了 90 秒以上**的
/// pending 做。1.7.0 复核修补：以前只比「正文前 60 字」，两段开头相同但内容不同的
/// 录音会被当成同一条，未归档那条连同音频一起被删。现在要求**整段原文**都出现在
/// 某篇笔记里才算命中，且命中后绝不删音频（查重只证明写过相似笔记，不证明安全入库）。
enum RecoveryDedupe {
    /// 与 `Filer.memo` 完全一致的正文规范化：逐行 trim、去空行、段落间空一行。
    static func normalize(_ text: String) -> String {
        text.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func existingNote(vault: URL, text: String, createdAt: Date,
                             now: Date = Date()) -> String? {
        guard now.timeIntervalSince(createdAt) > 90 else { return nil }
        let norm = normalize(text)
        // 太短的文字（「好」「收到」）查重必然误判，宁可重复写一次也不误删
        guard norm.count >= 12 else { return nil }
        let lo = createdAt.timeIntervalSince1970 - 5
        let hi = createdAt.timeIntervalSince1970 + 600
        let docs = VaultIndexer.scan(vault: vault).filter { $0.mtime >= lo && $0.mtime <= hi }
        return docs.first { normalize($0.text).contains(norm) }?.rel
    }
}

/// 归档执行者：全进程只有它会把「文字」写成笔记。
///
/// 归档有两个入口——界面拿到结果、以及看门狗/启动时的补归档。两条路可能同时
/// 遇到同一条 pending，必须保证**只写一次笔记**：`Filer.memo` 生成的文件名带
/// 秒级时间戳，重复写会变成两篇重复笔记。
///
/// 做法是「串行队列 + 入队后重新确认 pending 还在」：谁先把 pending 文件删掉，
/// 谁就是归档成功的那一个；后到的看到文件已不在，直接返回 nil。
enum MemoArchiveQueue {
    private static let queue = DispatchQueue(label: "com.lw.obsidiandrop.archive")

    private static func path(_ id: String) -> String {
        PendingStore.directory.appendingPathComponent("\(id).json").path
    }

    /// 把一条 pending 写进笔记。成功后删 pending 与录音，失败保留两者。
    /// 返回 nil 表示「这条已经被别的路径归档完了」，不是错误。
    /// 必须在后台线程调用（Filer 会做文件 IO）。
    /// `batch`/`aiPending` 只由 `drain(_:)` 传入：一次补归档共享同一个 12 秒预算
    /// （规格 A7.1）。单条归档（正常流程 / CLI）不传，仍拿满额预算。
    static func archive(_ m: PendingMemo, batch: AIBatchBudget? = nil,
                        aiPending: Int = 1) throws -> DropOutcome? {
        try queue.sync {
            // 已经在别处归档过：pending 被删掉就是唯一事实，别信内存里的状态
            guard FileManager.default.fileExists(atPath: path(m.id)) else { return nil }

            // 上次「笔记写完、pending 还没删」时中断了：这篇已经在库里，只做清理。
            if let rel = ArchiveMarker.doneRel(id: m.id) {
                PendingStore.remove(id: m.id)
                ArchiveMarker.clear(id: m.id)
                if !m.audioPath.isEmpty { try? FileManager.default.removeItem(atPath: m.audioPath) }
                DiagLog.write("跳过重复归档：\(m.id) 已写入 \(rel)（上次在删 pending 前中断）")
                return nil
            }
            ArchiveMarker.sweepIfNeeded()

            // AI 前置处理只挂在这里。
            //
            // 为什么不能挂界面的「转写完成」回调：那条路会被看门狗恢复、启动补归档、
            // 轮次被顶掉三条路径绕过，于是同一段文字有时过了 AI、有时没过，而且看不出来。
            // 这里是全进程唯一的写笔记入口，挂这儿才有「每条都一致」。
            var memo = m
            var aiState = m.ai
            var aiResult = AIResult(title: m.aiTitle ?? "", summary: m.aiSummary ?? "",
                                    tags: m.aiTags ?? [], model: m.aiModel ?? "",
                                    ms: m.aiMs ?? 0)
            var hasAIResult = !aiResult.title.isEmpty || !aiResult.summary.isEmpty
                || !aiResult.tags.isEmpty

            // 1.7.0：旧 done pending 没有润色稿，恢复成一个「只有标题/摘要」的场景结果，
            // Filer 会按 1.6.0 的原转写正文落盘，不升级、不重新计费。
            var sceneResult: AISceneResult?
            if aiState == .done, hasAIResult {
                sceneResult = AISceneResult(
                    scene: .transcript, title: aiResult.title, summary: aiResult.summary,
                    tags: aiResult.tags, polishedText: m.aiPolishedText ?? "",
                    visibleText: m.aiVisibleText ?? "", edits: m.aiEdits ?? [],
                    model: aiResult.model, ms: aiResult.ms, truncated: false)
            }

            if aiState == .off || aiState == .pending {
                let cfg = AIConfigStore.config
                if cfg.enabled {
                    let input = AISceneInput.transcript(text: m.text, target: m.target,
                                                        engine: m.engine,
                                                        duration: m.duration)
                    // 单条 pending 用完整预算；drain 补归档时整批共用一个 deadline。
                    let outcome: AISceneOutcome
                    if let batch {
                        if let allowed = batch.attemptBudget(pending: aiPending) {
                            outcome = AISceneService.process(input, config: cfg, budget: allowed)
                        } else {
                            outcome = .skipped("批量 AI 预算已耗尽")
                        }
                    } else {
                        outcome = AISceneService.process(input, config: cfg,
                                                         budget: cfg.effectiveBudget)
                    }
                    aiState = outcome.state
                    if let r = outcome.result {
                        aiResult = r.legacy
                        hasAIResult = true
                        sceneResult = r
                        memo.aiTitle = r.title
                        memo.aiSummary = r.summary
                        memo.aiTags = r.tags
                        memo.aiModel = r.model
                        memo.aiMs = r.ms
                        memo.aiScene = .transcript
                        memo.aiPolishedText = r.polishedText
                        memo.aiVisibleText = r.visibleText
                        memo.aiEdits = r.edits
                        memo.aiReason = outcome.reason
                    }
                    memo.aiState = outcome.state
                    // 结果写回 pending：进程若在下一步崩掉，重试看到 .done 就不会重复计费
                    do {
                        try PendingStore.enqueue(memo)
                    } catch {
                        DiagLog.write("AI 结果写回 pending 失败：\(error.localizedDescription)"
                                      + "（若随后崩溃，这条会重新请求一次）")
                    }
                    if outcome.state != .off {
                        MetricsStore.shared.record(MetricEvent(
                            kind: "ai", ok: outcome.state == .done, target: m.target,
                            source: "archive", durationMs: outcome.result?.ms ?? 0,
                            captureId: m.id, failReason: outcome.reason,
                            ai: outcome.state.rawValue))
                    }
                    if outcome.state == .skipped {
                        DiagLog.write("AI 处理跳过：\(outcome.reason)（原文照常入库）")
                    }
                } else {
                    aiState = .off
                }
            }

            let out = try Filer(vault: m.vault).memo(text: m.text, target: m.target,
                                                     duration: m.duration, engine: m.engine,
                                                     ai: hasAIResult ? aiResult : nil,
                                                     aiState: aiState,
                                                     sceneResult: sceneResult)
            // **先确认笔记写成功，再删 pending 和录音**。
            // 顺序反了就等于「删完才发现没写成」——1.3.13 的丢数据正是这么来的。
            // 中间再加一道 done 标记：删 pending 之前崩溃时，补归档不会重复写第二篇。
            let marked = ArchiveMarker.mark(id: m.id, rel: out.noteRel)
            let removed = PendingStore.remove(id: m.id)
            // 只有 pending 真没了才清标记：删失败还留着标记，下次补归档才能认出来
            if removed {
                ArchiveMarker.clear(id: m.id)
            } else {
                DiagLog.write("pending 删除失败：\(m.id)（标记保留，下次补归档会重试清理）")
            }
            if !marked {
                DiagLog.write("完成标记写入失败：\(m.id)——此刻崩溃会重复写一篇")
            }
            if !m.audioPath.isEmpty { try? FileManager.default.removeItem(atPath: m.audioPath) }

            // 埋点也放在这个唯一出口：界面、看门狗、启动补归档都从这里走，
            // 因此每条只会计一次，且不依赖界面是否还活着。
            let kind = m.source == "file" ? "memo" : (m.source == "record" ? "memo" : "drop")
            let ev = MetricEvent(kind: kind, ok: true, target: m.target, noteRel: out.noteRel,
                                 source: "archive", durationMs: Int(m.duration * 1000),
                                 captureId: m.id, ai: aiState.rawValue)
            MetricsStore.shared.record(ev)
            MetricNoteMap.remember(noteId: ev.noteId, rel: out.noteRel)
            return out
        }
    }

    /// 补归档：把还没写进笔记的结果补上（启动时 / 看门狗恢复时 / 轮次被顶掉时）。
    @discardableResult
    static func drain(limit: Int = 5) -> (ok: Int, failed: Int) {
        var ok = 0, failed = 0
        let list = Array(PendingStore.all().prefix(limit))
        // A7.1：一次补归档共用同一个 12 秒 AI 预算，按剩余项数公平分摊。
        // 不这样做的话 5 条 pending 各拿满 12 秒，看门狗恢复一次最长能卡 60 秒。
        let cfg = AIConfigStore.config
        let batch = AIBatchBudget(cap: cfg.effectiveBudget)
        var aiLeft = cfg.enabled
            ? list.filter { $0.ai == .off || $0.ai == .pending }.count : 0
        for m in list {
            let needsAI = m.ai == .off || m.ai == .pending
            defer { if needsAI { aiLeft = max(0, aiLeft - 1) } }
            // 恢复路径的内容查重：覆盖「笔记写完、完成标记还没落盘」这一段窗口。
            // 只在补归档时做，且要求 pending 已躺 90 秒以上，正常流程零开销。
            let vaultURL = URL(fileURLWithPath: m.vaultPath)
            if let rel = RecoveryDedupe.existingNote(vault: vaultURL, text: m.text,
                                                     createdAt: m.createdAt) {
                PendingStore.remove(id: m.id)
                ArchiveMarker.clear(id: m.id)
                // 音频绝不在这里删：内容查重只能证明「库里有一篇含同样全文的笔记」，
                // 不能证明这段录音已安全入库。误判时源音仍在，可人工恢复。
                let kept = m.audioPath.isEmpty ? "（无音频）" : "：\(m.audioPath)"
                DiagLog.write("补归档跳过：\(m.id) 的整段文字已出现在 \(rel)"
                              + "（上次写完笔记后中断）；已清理 pending，音频保留\(kept)")
                ok += 1
                continue
            }
            do {
                if let out = try archive(m, batch: batch, aiPending: max(1, aiLeft)) {
                    ok += 1
                    DiagLog.write("补归档完成：\(m.id) → \(out.noteRel)（\(m.text.count) 字）")
                }
            } catch {
                failed += 1
                DiagLog.write("补归档失败：\(m.id) ｜ \(error.localizedDescription)"
                              + "（pending 与录音都保留）")
                // 失败也要进看板，否则「成功率」只统计成功路径，永远是 100%
                MetricsStore.shared.record(MetricEvent(
                    kind: "memo", ok: false, target: m.target, source: "drain",
                    failReason: error.localizedDescription, ai: m.ai.rawValue))
            }
        }
        return (ok, failed)
    }
}

// MARK: - 麦克风录音会话（macOS 26+）

@available(macOS 26.0, *)
final class MemoSession {
    private let localeID: String
    /// 这一轮「灵感」的编号，随回调一起传给界面，用来丢弃迟到的进度
    private let run: Int
    /// 归档目标与库路径，**开始时冻结**。结果可能几分钟后才归档，
    /// 那时用户可能已经换了目标、甚至换了库——不能到时候再读全局状态。
    private let target: String
    private let vault: URL
    private weak var sink: MemoSink?

    private let engine = AVAudioEngine()
    /// 录音落盘器（1.3.11 起录音不再实时喂识别引擎）
    private var store: RecordingStore?
    private var tapInstalled = false
    private var startedAt: Date?
    /// 结束/取消标志。start 在后台线程、stop 在主线程，必须加锁。
    private let stateLock = NSLock()
    private var stopped = false

    /// 本次录音的音量峰值。tap 在实时线程写、主线程读，只用来判断「到底有没有声音」。
    private let levelLock = NSLock()
    private var peak: Float = 0

    init(localeID: String, run: Int, target: String, vault: URL) {
        self.localeID = localeID
        self.run = run
        self.target = target
        self.vault = vault
    }

    private var isStopped: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopped
    }

    private func markStopped() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if stopped { return false }
        stopped = true
        return true
    }

    private func readPeak() -> Float {
        levelLock.lock(); defer { levelLock.unlock() }
        return peak
    }

    private func bumpPeak(_ v: Float) {
        levelLock.lock()
        if v > peak { peak = v }
        levelLock.unlock()
    }

    func start(sink: MemoSink) {
        self.sink = sink
        DiagLog.round(run, "录音会话开始：探测设备与权限")
        emit("phase.preparing") { s, r in s.memoPhase(.preparing, note: "检查麦克风…", run: r) }

        Task.detached(priority: .userInitiated) { [self] in
            do {
                // ① 先确认设备在不在。这一步是瞬时的——没有麦克风就别让用户
                //    白等几十分钟的模型下载才告诉他「你这儿没麦克风」。
                //
                //    这里有个必须先分辨的情形：**首次运行时 TCC 还没授权，
                //    个别系统版本会因此不返回设备列表**。原来直接拿空列表
                //    判死，用户在 MacBook Air 上第一次点录音就被告知
                //    「没有音频输入设备」。所以「探不到设备 + 权限未决定」
                //    要先把权限要下来，再复探一次。
                var probe = AudioProbe.run(withEngine: false)
                if !probe.usable, probe.authRaw == .notDetermined {
                    _ = await MemoSession.requestMic()
                    probe = AudioProbe.run(withEngine: false)
                }
                // 上层（AVFoundation）看不到设备、但权限已经给过时，再看一眼
                // 引擎的真实输入格式。没授权就不碰引擎——避免在 TCC 未定时
                // 访问 inputNode 触发额外的系统交互。
                if !probe.usable, probe.authRaw == .authorized {
                    probe = AudioProbe.run(withEngine: true)
                }
                DiagLog.round(run, "设备探测：AVCapture \(probe.captured.count) 个"
                              + " / CoreAudio \(probe.coreAudio.count) 个"
                              + " / 默认输入 \(probe.defaultName ?? "无")"
                              + " / 权限 \(probe.auth) / 可用 \(probe.usable ? "是" : "否")")
                guard probe.usable else {
                    // 设备探不到时先看权限：确实是权限问题就报权限，
                    // 不要让用户去查一个本来就没坏的东西
                    if probe.authRaw == .denied || probe.authRaw == .restricted {
                        throw MemoError.micDenied
                    }
                    throw MemoError.micUnavailable(Memo.noMicAdvice(probe))
                }
                // ② 再问权限（已授权时这里直接返回 true，不会二次弹窗）
                guard await MemoSession.requestMic() else { throw MemoError.micDenied }

                // ③ 语音识别授权顺手要下来（失败不阻塞录音：说完再授权也来得及）
                if await MemoSession.requestSpeech() == false {
                    NSLog("ObsidianDrop: 语音识别权限未授予，本次录音仍会保存，转写时再提示")
                }

                // ④ 打开录音文件并开始收。**这里不建语音引擎**：
                //    模型没下载完、语音服务没就绪、甚至识别权限没给，
                //    都不该影响「把你说的话存下来」这件事。
                //
                //    这里的两次 isStopped 检查不是多余的：用户可能在
                //    「要权限」的弹窗上就点了取消/结束。若此时还去建文件、
                //    起引擎，就会留下一个没人管的录音会话——文件一直长，
                //    而自动结束计时器已经停了，不会有人来收尾。
                guard !self.isStopped else { return }
                self.store = try RecordingStore()
                guard !self.isStopped else {
                    self.store?.discard()
                    self.store = nil
                    return
                }

                try self.startAudio()
                self.startedAt = Date()
                if self.isStopped {
                    // 极端情形：准备期间用户已经点了结束
                    self.teardown()
                    self.store?.close()
                    self.store?.discard()
                    self.store = nil
                    return
                }
                self.emit("phase.recording") { s, r in s.memoPhase(.recording, note: "", run: r) }
                DiagLog.round(self.run, "录音启动成功：\(self.store?.url.lastPathComponent ?? "-")，开始收音频")
            } catch {
                NSLog("ObsidianDrop: 录音启动失败 \(error)")
                self.store?.discard()
                self.store = nil
                self.emit("done.启动失败") { s, r in s.memoDone(text: "", duration: 0, outcome: MemoOutcome(), error: error, run: r) }
            }
        }
    }

    /// 结束录音 → 关文件 → 用「转写音频文件」那条路转。
    ///
    /// 这是 1.3.11 的核心改动：录音与转写彻底解耦，转写走已验证的文件路径。
    func stop() {
        guard markStopped() else { return }
        teardown()

        let wall = startedAt.map { Date().timeIntervalSince($0) } ?? 0

        guard let store else {
            // 引擎/文件还没准备好就点了结束：明确告知，不要静默停住
            DiagLog.round(run, "结束录音时没有录音文件（store 为空），走「点太早」提示")
            emit("done.无录音文件") { s, r in
                s.memoDone(text: "", duration: 0, outcome: MemoOutcome(),
                           error: MemoError.engineFailed(
                               "这次没有拿到录音文件（点结束太早了，或麦克风没能打开）。等面板显示「录音中 0:00」再说话，说完再点结束。"),
                           run: r)
            }
            return
        }
        self.store = nil
        store.close()

        let recorded = store.seconds
        let peak = readPeak()
        let errors = store.writeErrors
        let audio = store.url
        DiagLog.round(run, "录音结束：墙钟 \(String(format: "%.1f", wall))s，文件 \(String(format: "%.1f", recorded))s，"
                      + "\(store.sizeBytes) 字节，格式 \(store.formatText)，帧 \(store.frames)，"
                      + "写失败 \(errors) 次，峰值 \(Int(peak * 100))%")

        // 文件里没内容：不用去转写，直接说清楚是哪一环出的问题
        guard recorded >= 0.2, store.sizeBytes > 2000 else {
            store.discard()
            var o = MemoOutcome()
            o.recorded = wall
            o.fed = recorded
            o.peak = peak
            o.broken = errors > 0
            o.writeErrors = errors
            DiagLog.round(run, "录音文件里没有音频，不进入转写")
            emit("done.无音频") { s, r in
                s.memoDone(text: "", duration: wall, outcome: o,
                           error: MemoError.engineFailed(
                               "录音文件里没有音频（持续 \(Memo.clock(wall))，写入 \(String(format: "%.2f", recorded)) 秒"
                                   + (errors > 0 ? "，写文件失败 \(errors) 次" : "")
                                   + "）。多半是麦克风没有真正打开：看「系统设置 → 声音 → 输入」有没有电平跳动。"),
                           run: r)
            }
            return
        }

        emit("progress.preparing") { s, r in
            s.memoProgress(.preparing("录音已存好（\(Memo.humanDuration(recorded))），开始转写…"), run: r)
        }

        Task.detached(priority: .userInitiated) { [self] in
            do {
                guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                    throw MemoError.speechDenied
                }
                DiagLog.round(run, "开始转写录音文件 \(audio.lastPathComponent)")
                let t0 = Date()
                let r = try await SpeechRunner.transcribeFile(at: audio, localeID: localeID) { p in
                    self.emit("progress") { s, r in s.memoProgress(p, run: r) }
                }
                DiagLog.round(run, "转写返回：\(String(format: "%.1f", Date().timeIntervalSince(t0)))s，"
                              + "音频 \(String(format: "%.1f", r.seconds))s → \(r.text.count) 字")

                var o = MemoOutcome()
                o.recorded = recorded
                o.fed = r.seconds
                o.chars = r.text.count
                o.peak = peak
                o.broken = errors > 0
                o.writeErrors = errors
                // 录音**一律留着**，等笔记真正写成功再由归档环节删。
                // 1.3.13 在这里就 `store.discard()`，紧接着才投递结果——
                // 投递一失败，文字和录音就同时没了。先落盘、先保命。
                o.recordingPath = audio.path

                if !r.text.isEmpty {
                    // ① 先把文字原子落盘，再谈交付。
                    //    界面只是消费者之一：即使这次没人接住，下次启动也会补归档。
                    let m = PendingMemo(id: UUID().uuidString,
                                        text: r.text,
                                        duration: recorded,
                                        target: target,
                                        vaultPath: vault.path,
                                        engine: "DictationTranscriber / \(Memo.localeName)",
                                        audioPath: audio.path,
                                        source: "record",
                                        createdAt: Date(),
                                        attempts: 0,
                                        aiState: AIConfigStore.config.enabled ? .pending : nil)
                    do {
                        try PendingStore.enqueue(m)
                        o.pendingID = m.id
                        DiagLog.round(run, "结果已落盘：\(m.id)（\(m.text.count) 字）→ 待归档队列")
                    } catch {
                        // 落盘失败不能让整轮失败：至少还有录音，交付照常走
                        DiagLog.round(run, "结果落盘失败：\(error.localizedDescription)"
                                      + "（继续交付，录音保留 \(audio.lastPathComponent)）")
                    }
                }
                DiagLog.round(run, "交付结果到主线程（done）")
                self.emit("done") { s, rid in s.memoDone(text: r.text, duration: recorded, outcome: o, error: nil, run: rid) }
            } catch {
                var o = MemoOutcome()
                o.recorded = recorded
                o.fed = 0
                o.peak = peak
                o.broken = errors > 0
                o.writeErrors = errors
                o.recordingPath = audio.path
                DiagLog.round(run, "转写抛错：\(error.localizedDescription)，交付 done.异常")
                self.emit("done.异常") { s, r in s.memoDone(text: "", duration: recorded, outcome: o, error: error, run: r) }
            }
        }
    }

    /// 取消：丢掉这次录音，立刻收摊
    func cancel() {
        guard markStopped() else { return }
        teardown()
        let s = store
        store = nil
        s?.close()
        Task.detached(priority: .utility) { s?.discard() }
    }

    /// 把回调送到主线程。
    ///
    /// **只弱引用到「取 sinks 的那一刻」为止，之后强持有 sink。**
    ///
    /// 1.3.13 的写法是 `DispatchQueue.main.async { [weak self] in ... self.sink ... }`：
    /// 会话本身靠 `Task.detached { [self] }` 吊着命，结果一投递完，任务闭包返回、
    /// `[self]` 这份强引用消失；`AppDelegate` 早在 `endMemo()` 里把 `memoSession`
    /// 置空了，于是**排在主队列里的那块闭包拿到的 self 已经是 nil**，
    /// 结果被丢、界面永远停在收尾中——现场日志里「交付结果」和「会话已释放」
    /// 落在同一毫秒（21:27:42.030）就是这个时序。
    ///
    /// 结论：会话活多久，只该决定「进度画不画得出来」；**结果能不能送到，
    /// 不能挂在一个随时会死的对象上**。所以这里把 sink 强捕获进闭包，
    /// 与自身上下文彻底解耦。
    private func emit(_ what: String, logLag: Bool = true,
                      _ block: @escaping (MemoSink, Int) -> Void) {
        let runID = run
        guard let target = sink else {
            DiagLog.round(runID, "丢弃 \(what)：界面回调对象已释放")
            return
        }
        MemoDelivery.post(run: runID, what: what, to: target, logLag: logLag, block)
    }

    private func startAudio() throws {
        // ① 先确认设备在不在（纯属性查询，不会抛异常）。
        //    这是「点灵感就闪退」的第一道防线：没有麦克风时
        //    `inputNode.outputFormat(forBus:0)` 会回退出一个 44100/2ch 的**假格式**，
        //    拿它去 installTap，底层 AVAudioEngineGraph 会抛 NSException——
        //    Swift 捕不住 ObjC 异常，结果就是 SIGABRT 直接闪退。
        //    withEngine: false —— 不在这里另建引擎，避免与 self.engine 抢设备；
        //    下面用 self.engine 自己的 inputFormat 做同样判断。
        let probe = AudioProbe.run(withEngine: false)
        if probe.captured.isEmpty {
            // 设备列表空时再看引擎这边的真实格式，两路都空才判死
            let f = engine.inputNode.inputFormat(forBus: 0)
            guard f.sampleRate > 0, f.channelCount > 0 else {
                throw MemoError.micUnavailable(Memo.noMicAdvice(probe))
            }
        }

        let input = engine.inputNode
        engine.prepare()

        // ② 硬件真实输入格式。必须用 inputFormat，不能用 outputFormat——
        //    没有输入设备时 outputFormat 会回退成输出侧的假格式（44100/2ch），
        //    守卫会被假格式骗过，然后死在 installTap。
        let hwFmt = input.inputFormat(forBus: 0)
        guard hwFmt.sampleRate > 0, hwFmt.channelCount > 0 else {
            throw MemoError.micUnavailable(
                "系统里没有给出可用的输入格式，请检查「系统设置 → 声音 → 输入」里是否选中了设备")
        }

        // ③ 装 tap 用 format: nil —— 让 AVAudioEngine 走硬件原生格式，
        //    从根上避免「传入格式与硬件不匹配」这一类 NSException。
        //    回调里只做两件事：算音量（驱动界面呼吸）、把 buffer 写进文件。
        //    识别一律等录完之后按文件做，不在实时线程里抢资源。
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
            guard let self else { return }
            let lv = SpeechRunner.level(buf)
            if lv > self.readPeak() { self.bumpPeak(lv) }
            self.emit("level", logLag: false) { s, r in s.memoLevel(lv, run: r) }
            self.store?.append(buf)
        }
        tapInstalled = true
        do {
            try engine.start()
        } catch {
            throw MemoError.engineFailed(error.localizedDescription)
        }
    }

    private func teardown() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
    }

    private static func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    private static func requestSpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }
}

// MARK: - 投放视图

/// 独立的边框层：最后加入子视图，保证绘制在视觉层之上
final class BorderView: NSView {
    var dragging = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    /// 纯装饰层，不参与点击命中，否则会挡住按钮
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.0, dy: 1.0)
        let path = NSBezierPath(roundedRect: r, xRadius: 19, yRadius: 19)
        path.lineWidth = dragging ? 2.0 : 1.5
        if dragging {
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(0.28).setStroke()
            path.setLineDash([5, 4], count: 2, phase: 0)
            path.stroke()
        }
    }
}

/// 面板里的小药丸按钮（无边框 + 自绘底色）
/// 注意：它**不接收鼠标事件**（hitTest 返回 nil）。点击与悬停由 DropView 统一处理，
/// 否则按钮会把自己那一块从拖放命中区里挖走，成为投放死区。
final class PillButton: NSButton {
    private var hovered = false { didSet { refresh() } }
    private var baseTint: NSColor = .secondaryLabelColor
    private var symbolName = ""

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        font = .systemFont(ofSize: 10.5, weight: .medium)
        if #available(macOS 11.0, *) { imageHugsTitle = true }
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 完全不参与命中测试（鼠标由 DropView 统一分发）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// B6.2 复核修补：以前 Tab 链里有这两个按钮，但 NSButton 自绘子类没有
    /// acceptsFirstResponder，makeFirstResponder 会失败，焦点根本到不了。
    override var acceptsFirstResponder: Bool { true }
    private var focused = false { didSet { refresh() } }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { focused = true }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { focused = false }
        return ok
    }

    func setHovered(_ v: Bool) { hovered = v }

    /// 录音时会换成「结束」+ 红色
    ///
    /// P9：只在**真的变了**的时候改标题与图标。录音期界面每 0.1s 重画一次状态，
    /// 原来每次都重建一个 NSImage 并让按钮重排文本，55ms 的定时器叠上这个开销，
    /// 风扇是能听见的。
    func setStyle(title: String, symbol: String, tint: NSColor, tip: String? = nil) {
        if self.title != title { self.title = title }
        if symbolName != symbol {
            symbolName = symbol
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        if let tip, toolTip != tip { toolTip = tip }
        if baseTint != tint {
            baseTint = tint
            refresh()
        }
    }

    private func refresh() {
        contentTintColor = (hovered || focused) ? .controlAccentColor : baseTint
        layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(focused ? 0.20 : (hovered ? 0.14 : 0.07)).cgColor
        layer?.borderColor = focused
            ? NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor : nil
        layer?.borderWidth = focused ? 1.5 : 0
    }
}

/// 图标位置上的进度环：环 + 中间一个大号百分比。
///
/// 为什么把百分比挪到这里：小面板只有 160 宽，标题里写
/// 「识别中 3:12 / 12:00（27%）」会被截断；而进度本来就是「一眼看」的东西。
/// 环画在图标的位置上，标题只留「转写中」，副标题留「已出 N 字 · 剩余…」，
/// 三个字的信息各归各位，不再互相挤。
final class RingView: NSView {
    enum Mode: Equatable {
        case hidden
        /// 不知道进度（收尾阶段）：转圈
        case spinning
        /// 0…1
        case value(Double)
    }

    private(set) var mode: Mode = .hidden
    private var phase: CGFloat = 0
    private var spinTimer: Timer?
    var tint: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    /// 纯装饰，不参与点击（否则会挡住面板的拖拽与投放命中）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ m: Mode) {
        guard mode != m else { return }
        mode = m
        if case .spinning = m { startSpin() } else { stopSpin() }
        needsDisplay = true
    }

    private func startSpin() {
        guard spinTimer == nil else { return }
        // P8：转圈只重绘环自己那一小块（原来每帧重绘整个 52×52 视图并连带
        // 触发父视图合成），频率同时从 18Hz 降到 24Hz——肉眼更顺，开销更低。
        let t = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase = (self.phase + 1.0 / 24.0).truncatingRemainder(dividingBy: 1)
            self.setNeedsDisplay(self.bounds.insetBy(dx: -2, dy: -2))
        }
        RunLoop.main.add(t, forMode: .common)
        spinTimer = t
    }

    private func stopSpin() {
        spinTimer?.invalidate()
        spinTimer = nil
    }

    deinit { spinTimer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        guard mode != .hidden else { return }

        let d = min(bounds.width, bounds.height)
        let circle = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let lw: CGFloat = 3.5
        let radius = d / 2 - lw / 2 - 1
        let center = NSPoint(x: circle.midX, y: circle.midY)

        // 轨道：整圈浅色，保证「已知最大是多少」
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lw
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        track.stroke()

        let arc = NSBezierPath()
        switch mode {
        case .hidden:
            return
        case .spinning:
            let start = -90 + phase * 360
            arc.appendArc(withCenter: center, radius: radius,
                          startAngle: start, endAngle: start + 84)
        case .value(let v):
            let p = CGFloat(max(0, min(1, v)))
            if p > 0.002 {
                // 顺时针从 12 点开始画
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: 90, endAngle: 90 - 360 * p, clockwise: true)
            }
        }
        arc.lineWidth = lw
        arc.lineCapStyle = .round
        tint.setStroke()
        arc.stroke()

        let text: String
        switch mode {
        case .value(let v): text = "\(Int((max(0, min(1, v)) * 100).rounded()))%"
        case .spinning, .hidden: text = "…"
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2,
                                            y: bounds.midY - size.height / 2),
                                withAttributes: attrs)
    }
}

final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onScreenshot: (() -> Void)?
    var onMemo: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let borderView = BorderView()
    private let icon = NSImageView()
    /// 转写进度环：正好盖在图标的位置上，中间显示百分比
    private let ring = RingView()
    private let title = NSTextField(labelWithString: "把文件拖进来")
    private let subtitle = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "双击打开 Obsidian")
    private let shotButton = PillButton(title: "截屏", symbol: "camera.viewfinder")
    private let memoButton = PillButton(title: "灵感", symbol: "lightbulb")
    private var dragging = false
    private var dragOrigin: NSPoint = .zero
    private var windowOrigin: NSPoint = .zero
    private var didDrag = false
    private var hoverAreas: [NSTrackingArea] = []
    private var targetName: String = ""
    /// 1.7.0 重新设计：投放态用自绘 LogoMark，状态态仍用系统符号（录音/转写/成功等）
    private var iconSymbol = "logo"

    // 1.4.0：下拉形态才显示的搜索区。docked（160×176）时整块隐藏，
    // 面板回到 1.3.15 的样子——不发布一块「占着位置却什么都没有」的区域。
    // 不设 private：--render-preview 需要填入搜索词出 results/empty 基线
    let searchField = NSSearchField()
    private let results = SearchResultsView()
    private let divider = NSBox()
    private var wide = false
    /// 拖动结束后是否把坐标写进偏好（docked 才写）
    var persistDragPosition = true
    var onSearchText: ((String) -> Void)?
    var onPickRow: ((SearchRow) -> Void)?
    var onEscape: (() -> Void)?
    /// 底栏「打开 Obsidian」按钮（1.7.0）
    var onOpenObsidian: (() -> Void)?

    // 1.7.0 下拉面板的新组件；docked 形态整组隐藏，保持 1.6.0 外观。
    private let surface = DropSurfaceView()
    private let headerSurface = SceneHeaderView()
    private let sceneBadge = SceneBadgeView()
    private let headSep = NSBox()
    private let activity = ActivityStripView()
    private let footer = FooterBarView()
    private let panelBorder = PanelBorderView()
    private var currentScene: AIScene = .legacy
    private var currentWork: UIWorkState = .idle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = false
        registerForDraggedTypes([.fileURL])
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 20
        effect.layer?.masksToBounds = true
        effect.alphaValue = 0.98
        effect.layer?.cornerRadius = 18
        layer?.cornerRadius = 18
        addSubview(effect)

        // 头部表面 / 拖放高亮面（规格 B3：在内容之下、材质之上）
        surface.isHidden = true
        headerSurface.isHidden = true
        addSubview(surface)
        addSubview(headerSurface)

        icon.image = LogoMark.image(pointSize: 40, color: .controlAccentColor)
        icon.contentTintColor = .controlAccentColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.frame = NSRect(x: 0, y: bounds.height - 72, width: bounds.width, height: 46)
        icon.autoresizingMask = [.width, .minYMargin]
        addSubview(icon)

        // 进度环压在图标上面（同一块区域），转写时把图标隐掉，只留环和百分比
        ring.frame = Self.ringFrame(in: bounds)
        ring.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        addSubview(ring)

        title.alignment = .center
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: 6, y: 72, width: bounds.width - 12, height: 18)
        title.autoresizingMask = [.width, .maxYMargin]
        addSubview(title)

        subtitle.alignment = .center
        subtitle.font = .systemFont(ofSize: 10.5)
        subtitle.textColor = .secondaryLabelColor
        // 中间省略会把「已出 N 字」和剩余时长都吃掉半截，改成尾部省略
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: 8, y: 56, width: bounds.width - 16, height: 14)
        subtitle.autoresizingMask = [.width, .maxYMargin]
        addSubview(subtitle)

        let hint = hintLabel
        hint.alignment = .center
        hint.font = .systemFont(ofSize: 9)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 0, y: 42, width: bounds.width, height: 12)
        hint.autoresizingMask = [.width, .maxYMargin]
        addSubview(hint)

        // 底部两个按钮：截屏（先收窗再拍）、灵感（录音转文字）
        let bw: CGFloat = 68
        shotButton.frame = NSRect(x: 8, y: 12, width: bw, height: 24)
        shotButton.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        memoButton.frame = NSRect(x: bounds.width - 8 - bw, y: 12, width: bw, height: 24)
        memoButton.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        addSubview(shotButton)
        addSubview(memoButton)
        shotButton.setStyle(title: "截屏", symbol: "camera.viewfinder",
                            tint: .secondaryLabelColor, tip: "截图并归档到当前目标")
        memoButton.setStyle(title: "灵感", symbol: "lightbulb",
                            tint: .secondaryLabelColor, tip: "点一下开始录音，说完再点一下就转成文字存进库")

        // 搜索区（仅下拉形态可见）。必须加在 borderView 之前，
        // 否则虚线框会画在输入框上面，看着像「输入框缺了一角」。
        searchField.placeholderString = "搜索笔记…"
        searchField.font = .systemFont(ofSize: 12)
        searchField.controlSize = .small
        searchField.delegate = self
        searchField.isHidden = true
        addSubview(searchField)

        results.isHidden = true
        results.onPick = { [weak self] _ in
            guard let self, let row = self.results.selectedRow else { return }
            self.onPickRow?(row)
        }
        addSubview(results)

        divider.boxType = .separator
        divider.isHidden = true
        addSubview(divider)

        // 1.7.0：场景徽标 / 头部分隔 / activity / 底栏 / 外轮廓。
        sceneBadge.isHidden = true
        addSubview(sceneBadge)

        headSep.boxType = .separator
        headSep.isHidden = true
        addSubview(headSep)

        activity.isHidden = true
        addSubview(activity)

        footer.isHidden = true
        footer.onOpen = { [weak self] in self?.onOpenObsidian?() }
        footer.targetPill.title = ""
        addSubview(footer)

        // 最后一个加入，保证外轮廓绘制在所有内容之上
        panelBorder.isHidden = true
        panelBorder.frame = bounds
        panelBorder.autoresizingMask = [.width, .height]
        addSubview(panelBorder)

        borderView.frame = bounds
        borderView.autoresizingMask = [.width, .height]
        addSubview(borderView)
    }

    /// 两种形态共用一套视图，只按宽度重排。
    ///
    /// 1.3.15 的坐标是写死在 `build()` 里的；一旦下拉变成 360 宽，
    /// 图标和按钮会全挤在左边 160 的范围内，右边一片空白。
    override func layout() {
        super.layout()
        borderView.frame = bounds
        panelBorder.frame = bounds

        let b = bounds
        wide = b.width > 240
        // 1.7.0：下拉形态由 PanelLayout 一处给出全部 frame；docked 完全保持 1.6.0。
        let chrome: [NSView] = [surface, headerSurface, sceneBadge, headSep,
                                activity, footer, panelBorder]
        chrome.forEach { $0.isHidden = !wide }
        borderView.isHidden = wide
        searchField.isHidden = !wide
        results.isHidden = !wide
        divider.isHidden = !wide

        if wide {
            let f = PanelLayout.frames(b)
            surface.frame = f.surface
            headerSurface.frame = f.header
            icon.frame = f.icon
            ring.frame = f.ring
            title.frame = f.title
            subtitle.frame = f.subtitle
            sceneBadge.frame = f.badge
            sceneBadge.iconOnly = b.width < 360
            hintLabel.frame = f.hint
            shotButton.frame = f.shot
            memoButton.frame = f.memo
            headSep.frame = f.headSep
            searchField.frame = f.search
            activity.frame = f.activity
            activity.isHidden = f.compact
            divider.frame = f.resultsSep
            results.frame = f.results
            footer.frame = f.footer
            footer.apply(f)

            title.alignment = .left
            title.font = .systemFont(ofSize: 15, weight: .semibold)
            subtitle.alignment = .left
            subtitle.font = .systemFont(ofSize: 11)
            hintLabel.alignment = .left
            hintLabel.font = .systemFont(ofSize: 10)
            icon.imageScaling = .scaleProportionallyUpOrDown
            // 新 LogoMark 只有一种形态，形态切换不再换图标；状态图标仍由 setIcon 负责
            if hintLabel.stringValue == "双击打开 Obsidian"
                || hintLabel.stringValue == "拖进来即归档 · ⌘F 搜索"
                || hintLabel.stringValue.isEmpty {
                hintLabel.stringValue = "拖进来即归档 · ⌘F 搜索"
            }
            if currentWork == .idle, title.stringValue == "把文件拖进来" {
                title.stringValue = "拖入文件，开始整理"
            }
        } else {
            icon.frame = NSRect(x: 0, y: b.height - 72, width: b.width, height: 46)
            ring.frame = Self.ringFrame(in: b)

            title.alignment = .center
            title.frame = NSRect(x: 6, y: 72, width: b.width - 12, height: 18)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            subtitle.alignment = .center
            subtitle.frame = NSRect(x: 8, y: 56, width: b.width - 16, height: 14)
            subtitle.font = .systemFont(ofSize: 10.5)
            hintLabel.alignment = .center
            hintLabel.frame = NSRect(x: 0, y: 42, width: b.width, height: 12)
            hintLabel.font = .systemFont(ofSize: 9)

            let bw: CGFloat = 68
            shotButton.frame = NSRect(x: 8, y: 12, width: bw, height: 24)
            memoButton.frame = NSRect(x: b.width - 8 - bw, y: 12, width: bw, height: 24)
            if hintLabel.stringValue == "拖进来即归档 · ⌘F 搜索" {
                hintLabel.stringValue = "双击打开 Obsidian"
            }
            if title.stringValue == "拖入文件，开始整理" {
                title.stringValue = "把文件拖进来"
            }
        }
    }

    /// 切到下拉形态（显示搜索区）或回到常驻浮窗
    func setWide(_ on: Bool) {
        guard wide != on || searchField.isHidden == on else { return }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    // MARK: B6.2 Tab 焦点环：search → results → screenshot → memo → open → search
    /// 只给下拉形态用；docked 没有搜索与结果区，保持 1.6.0 的键盘行为。
    func focusChain() -> [NSView] {
        guard wide else { return [] }
        return [searchField, results, shotButton, memoButton, footer.openButton]
    }

    /// 焦点环里当前项的索引；字段编辑器要用 delegate 反查 searchField。
    func focusedIndex() -> Int? {
        let chain = focusChain()
        guard !chain.isEmpty else { return nil }
        let fr = window?.firstResponder
        return chain.firstIndex { v in
            if let tv = fr as? NSTextView, let d = tv.delegate,
               (d as AnyObject) === (v as AnyObject) { return true }
            if fr === v { return true }
            return (fr as? NSView)?.isDescendant(of: v) == true
        }
    }

    /// B6.2 复核修补：Tab 能聚焦截屏/灵感按钮，但动作只挂在鼠标命中里，
    /// Space/Return 按下去什么都不会发生。这里把焦点项的动作显式分发出去。
    func activateFocused() -> Bool {
        guard wide, let i = focusedIndex() else { return false }
        let v = focusChain()[i]
        if v === shotButton { onScreenshot?(); return true }
        if v === memoButton { onMemo?(); return true }
        if v === footer.openButton { footer.openButton.performClick(nil); return true }
        return false
    }

    func advanceFocus(backwards: Bool) {
        let chain = focusChain()
        guard !chain.isEmpty else { return }
        let current = focusedIndex()
        let next: Int
        if let i = current {
            next = (i + (backwards ? -1 : 1) + chain.count) % chain.count
        } else {
            next = backwards ? chain.count - 1 : 0
        }
        window?.makeFirstResponder(chain[next])
        if chain[next] === searchField {
            searchField.currentEditor()?.selectAll(nil)
        }
    }

    func clearSearch() {
        searchField.stringValue = ""
        results.setRows([], empty: "")
    }

    func setResults(_ rows: [SearchRow], empty: String) {
        // 只保留能看见的行：否则键盘能把选中项移到看不见的地方，鼠标也无从点起。
        // 1.7.0 下按 PanelLayout 的可见行数（默认 5 行，最小 2 行）裁剪。
        let usable = wide
            ? PanelLayout.frames(bounds).visibleRows
            : max(1, Int((bounds.height - PanelMetrics.dropZoneHeight - 44)
                         / PanelMetrics.rowHeight))
        results.setRows(Array(rows.prefix(usable)), empty: empty)
    }

    func setSearching(_ searching: Bool) {
        if searching { results.setRows([], empty: "搜索中…") }
    }

    var searchQuery: String { searchField.stringValue }

    /// 进度环的位置：水平居中、垂直居中在图标那块区域上（面板顶部）
    private static func ringFrame(in b: NSRect) -> NSRect {
        let s: CGFloat = 52
        let iconCenterY = b.height - 72 + 23
        return NSRect(x: (b.width - s) / 2, y: iconCenterY - s / 2, width: s, height: s)
    }

    func setTargetName(_ s: String) {
        targetName = s
        subtitle.stringValue = "→ " + s
        footer.targetPill.title = s
    }

    func flash(_ text: String, ok: Bool) {
        title.stringValue = text
        title.textColor = ok ? (PanelPalette.isDark(self) ? PanelPalette.successDark : PanelPalette.success)
            : (PanelPalette.isDark(self) ? PanelPalette.errorDark : PanelPalette.error)
        if wide {
            currentWork = ok ? .done : .failed
            sceneBadge.state = currentWork
            activity.set(currentWork, phase: text, detail: "")
        }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(resetTitle), object: nil)
        perform(#selector(resetTitle), with: nil, afterDelay: 2.5)
    }

    @objc private func resetTitle() { restoreIdle() }

    /// 回到常规状态（图标、标题、目标名、提示）
    private func restoreIdle() {
        ring.show(.hidden)
        // 1.7.0 重新设计：下拉与 docked 共用同一个 LogoMark，不再区分实心/线框
        setIcon("logo", tint: .controlAccentColor)
        title.stringValue = wide ? "拖入文件，开始整理" : "把文件拖进来"
        title.textColor = .labelColor
        subtitle.stringValue = targetName.isEmpty ? "" : "→ " + targetName
        hintLabel.stringValue = wide ? "拖进来即归档 · ⌘F 搜索" : "双击打开 Obsidian"
        currentWork = .idle
        sceneBadge.state = .idle
        activity.set(.idle, phase: "", detail: "")
        surface.dragging = false
        searchField.alphaValue = 1
        results.alphaValue = 1
    }

    // MARK: 1.7.0 场景 / AI / 批次状态（规格 B5、B7）

    func renderScene(_ scene: AIScene) {
        currentScene = scene
        sceneBadge.scene = scene
    }

    func renderAI(_ state: UIWorkState, phase: String, detail: String) {
        currentWork = state
        sceneBadge.state = state
        activity.set(state, phase: phase, detail: detail)
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                               selector: #selector(clearAIChrome), object: nil)
        if state == .done || state == .skipped || state == .failed {
            perform(#selector(clearAIChrome), with: nil, afterDelay: 2.5)
        }
    }

    @objc private func clearAIChrome() {
        currentWork = .idle
        sceneBadge.state = .idle
        activity.set(.idle, phase: "", detail: "")
    }

    func renderBatch(success: Int, failed: Int) {
        guard wide else { return }
        let text = failed == 0 ? "成功 \(success) 个" : "成功 \(success) · 失败 \(failed)"
        activity.set(failed == 0 ? .done : .failed, phase: text, detail: "")
    }

    func renderDropActivity(_ on: Bool) {
        guard wide else { return }
        if on {
            renderAI(.working, phase: "提取文字", detail: "请求模型 · 写入笔记")
        } else if currentWork == .working {
            clearAIChrome()
        }
    }

    /// 录音/转写状态。partial 是实时转写文字，用来证明「真的在听」。
    func renderMemo(_ state: MemoUI, partial: String) {
        // 进入业务状态时取消「闪一下再复位」的挂起任务，避免把录音界面冲掉
        if case .idle = state {} else {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(resetTitle), object: nil)
        }

        switch state {
        case .idle:
            restoreIdle()
            memoButton.setStyle(title: "灵感", symbol: "lightbulb",
                                tint: .secondaryLabelColor,
                                tip: "点一下开始录音，说完再点一下就转成文字存进库")
            shotButton.setStyle(title: "截屏", symbol: "camera.viewfinder",
                                tint: .secondaryLabelColor, tip: "截图并归档到当前目标")

        case .preparing(let note):
            ring.show(.hidden)
            setIcon("waveform", tint: .controlAccentColor)
            // 不写「准备录音…」：文件转写也走这个状态，统一说「准备中」，
            // 具体在准备什么由下面那行说清楚
            title.stringValue = "准备中…"
            title.textColor = .labelColor
            subtitle.stringValue = note.isEmpty ? "正在准备语音模型" : note
            hintLabel.stringValue = "首次使用需要下载模型"
            memoButton.setStyle(title: "取消", symbol: "xmark",
                                tint: .secondaryLabelColor, tip: "取消这次录音")
            shotButton.setStyle(title: "截屏", symbol: "camera.viewfinder",
                                tint: .tertiaryLabelColor, tip: "录音期间不可截屏")

        case .recording(let elapsed, let level):
            ring.show(.hidden)
            setIcon("mic.fill", tint: .systemRed)
            // 用说话音量驱动图标呼吸，一眼能看出确实在收音
            icon.alphaValue = 0.45 + 0.55 * CGFloat(min(1, max(0, level)))
            title.stringValue = "录音中 " + Memo.clock(elapsed)
            title.textColor = .systemRed
            // 1.3.11 起录音只存不转（转写等录完按文件做），所以这里不显示实时文字，
            // 改为「确认在收音」的两件事：音量呼吸 + 已录时长
            subtitle.stringValue = "说完点「结束」，再转成文字"
            hintLabel.stringValue = "音频先存到本地 · 不限时长"
            memoButton.setStyle(title: "结束", symbol: "stop.fill",
                                tint: .systemRed, tip: "结束录音并转成文字")
            shotButton.setStyle(title: "截屏", symbol: "camera.viewfinder",
                                tint: .tertiaryLabelColor, tip: "录音期间不可截屏")

        case .transcribing(let p):
            // 百分比交给进度环（画在图标位置），标题只写「在做什么」
            ring.show(p.percent.map { .value($0) } ?? .spinning)
            setIcon("text.viewfinder", tint: .controlAccentColor)
            // 环盖在图标上，图标本体隐掉——留着会跟中间的大字叠在一起
            icon.alphaValue = 0
            title.stringValue = p.stageTitle.isEmpty ? "转写中" : p.stageTitle
            title.textColor = .labelColor
            // 准备阶段的说明写在 headline 里（detail 为空），不能只认 detail——
            // 否则「下载语音模型…」这种最需要看到的话会整句消失。
            let sub = p.detail.isEmpty ? p.headline : p.detail
            subtitle.stringValue = sub.isEmpty ? "本机处理，不上传" : sub
            hintLabel.stringValue = p.stageTitle == "归档中"
                ? "写入本机库，不上传"
                : (p.stage == .preparing ? "首次使用要先下语音模型" : "本机转写，不上传")
            memoButton.setStyle(title: "稍候", symbol: "hourglass",
                                tint: .tertiaryLabelColor, tip: "正在转写")
            shotButton.setStyle(title: "截屏", symbol: "camera.viewfinder",
                                tint: .tertiaryLabelColor, tip: "转写期间不可截屏")
        }
        if wide { syncMemoChrome(state) }
    }

    /// 下拉形态下把录音/转写状态映射到场景徽标与 activity 条（只重绘这两块）。
    private func syncMemoChrome(_ state: MemoUI) {
        sceneBadge.scene = .transcript
        switch state {
        case .idle:
            currentWork = .idle
            sceneBadge.state = .idle
            activity.set(.idle, phase: "", detail: "")
        case .preparing(let note):
            currentWork = .working
            sceneBadge.state = .working
            activity.set(.working, phase: "准备中", detail: note)
        case .recording(let elapsed, _):
            currentWork = .working
            sceneBadge.state = .working
            activity.set(.working, phase: "录音中 " + Memo.clock(elapsed),
                         detail: "说完点结束")
        case .transcribing(let p):
            currentWork = .working
            sceneBadge.state = .working
            activity.set(.working,
                         phase: p.stageTitle.isEmpty ? "本机转写" : p.stageTitle,
                         detail: p.detail.isEmpty ? p.headline : p.detail)
        }
    }

    /// 图标按名字缓存，避免每 0.1 秒重建一次 NSImage。
    /// `logo` 是自绘标记（矢量，随 Retina 重绘），其余仍是系统状态符号。
    private func setIcon(_ symbol: String, tint: NSColor) {
        if iconSymbol != symbol {
            iconSymbol = symbol
            if symbol == "logo" {
                icon.image = LogoMark.image(pointSize: 40, color: tint)
            } else {
                icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            }
        }
        icon.contentTintColor = tint
        icon.alphaValue = 1
    }

    // 不设 private：--render-preview 要按真实拖放路径渲染 dragover 基线
    func setHighlight(_ on: Bool) {
        dragging = on
        borderView.dragging = on
        if wide {
            // 1.7.0：高亮只画在投放面，并把搜索/结果降到 0.55，不做整面板材质切换
            surface.dragging = on
            searchField.alphaValue = on ? 0.55 : 1
            results.alphaValue = on ? 0.55 : 1
        } else {
            effect.material = on ? .selection : .popover
        }
        title.stringValue = on ? "松手即归档"
            : (wide ? "拖入文件，开始整理" : "把文件拖进来")
        title.textColor = on ? .controlAccentColor : .labelColor
    }

    // 拖入
    // 命中区修正（2026-11-03）：本视图的子视图（毛玻璃层、图标、文字）会把
    // 拖放命中截断，导致只有没被覆盖的最外圈边框能触发。这里让整块面板都
    // 命中到自己，子视图一律不参与命中，拖到框内任何位置都能进 draggingEntered。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return super.hitTest(point) }
        guard bounds.contains(convert(point, from: sv)) else { return nil }
        // 下拉形态里，搜索框与结果列表必须自己接事件。
        // 1.3.15 的「整块命中自己」是为了让投放没有死区，但那会让 1.4.0 的
        // 搜索框「看得见、点不动」——这里只把这两块让出去，其余仍然归自己。
        if wide, let hit = super.hitTest(point),
           hit === searchField || hit.isDescendant(of: searchField) || isInResults(hit)
            || hit === footer || hit.isDescendant(of: footer) {
            return hit
        }
        return self
    }

    private func isInResults(_ v: NSView) -> Bool {
        var cur: NSView? = v
        while let c = cur, c !== self {
            if c === results { return true }
            cur = c.superview
        }
        return false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = readURLs(sender)
        guard !urls.isEmpty else { return [] }
        setHighlight(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        readURLs(sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHighlight(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !readURLs(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHighlight(false)
        let urls = readURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func readURLs(_ info: NSDraggingInfo) -> [URL] {
        let pb = info.draggingPasteboard
        let objs = pb.readObjects(forClasses: [NSURL.self],
                                  options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return objs ?? []
    }

    // 拖动窗口 / 双击 / 点底部按钮
    // 按钮不再自己接事件（见 PillButton.hitTest），改为在这里按坐标判定，
    // 这样按钮那块区域同样留在投放区内，拖文件过来不会出现死区。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in hoverAreas { removeTrackingArea(t) }
        hoverAreas = [shotButton, memoButton].map { b in
            NSTrackingArea(rect: b.frame,
                           options: [.mouseEnteredAndExited, .activeAlways],
                           owner: self, userInfo: nil)
        }
        for t in hoverAreas { addTrackingArea(t) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    private func refreshHover(at p: NSPoint, inside: Bool) {
        shotButton.setHovered(inside && shotButton.frame.contains(p))
        memoButton.setHovered(inside && memoButton.frame.contains(p))
    }

    override func mouseEntered(with event: NSEvent) {
        refreshHover(at: convert(event.locationInWindow, from: nil), inside: true)
    }

    override func mouseMoved(with event: NSEvent) {
        refreshHover(at: convert(event.locationInWindow, from: nil), inside: true)
    }

    override func mouseExited(with event: NSEvent) {
        refreshHover(at: .zero, inside: false)
    }

    override func resetCursorRects() {
        addCursorRect(shotButton.frame, cursor: .pointingHand)
        addCursorRect(memoButton.frame, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        // B6.1：下拉形态不可拖动窗口；但 mouseUp 仍要走按钮命中，所以这里只
        // 不初始化拖动原点，不能整个 return 掉事件链。
        guard !wide else { return }
        dragOrigin = NSEvent.mouseLocation
        windowOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        // B6.1：菜单栏下拉是个 popover，被随手拖走就会离开状态栏图标，
        // 只剩 docked 常驻浮窗允许移动。persistDragPosition 只防「写偏好」，
        // 拦不住窗口真的被拖走。
        guard !wide else { return }
        guard let w = window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragOrigin.x
        let dy = now.y - dragOrigin.y
        if abs(dx) > 2 || abs(dy) > 2 { didDrag = true }
        w.setFrameOrigin(NSPoint(x: windowOrigin.x + dx, y: windowOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            // 下拉面板被拖走后不该覆盖常驻位置，否则下次以 docked 启动
            // 会出现在一个「上次只是随手拖了一下」的坐标上。
            if persistDragPosition, let o = window?.frame.origin {
                UserDefaults.standard.set(Double(o.x), forKey: Cfg.posXKey)
                UserDefaults.standard.set(Double(o.y), forKey: Cfg.posYKey)
            }
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if shotButton.frame.contains(p) {
            onScreenshot?()
            return
        }
        if memoButton.frame.contains(p) {
            onMemo?()
            return
        }
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}

// MARK: - 搜索框事件

extension DropView: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onSearchText?(searchField.stringValue)
    }

    /// ↑↓ 选、回车开、ESC 收起。
    ///
    /// 不能用 `cancelOperation`：NSSearchField 的字段编辑器先吃掉 ESC，
    /// 面板根本收不到；必须在字段编辑器的命令层截下来。
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            results.moveSelection(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            results.moveSelection(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let row = results.selectedRow { onPickRow?(row) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
            return true
        case #selector(NSResponder.insertTab(_:)):
            // B6.2：字段编辑器会先吃掉 Tab，不从这里截一道就永远出不了搜索框
            advanceFocus(backwards: false)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            advanceFocus(backwards: true)
            return true
        default:
            return false
        }
    }
}

// MARK: - 面板

final class DropPanel: NSPanel {
    /// dropdown 形态要接键盘（ESC 收起、搜索框输入）；docked 形态保持「永不成为 key」，
    /// 否则常驻浮窗会把别的 App 的输入抢走。
    var mode: PanelMode = .docked
    var onEscape: (() -> Void)?
    /// B6.2：Tab 焦点环的控件来自内容视图，面板自己不复制一份坐标。
    weak var focusRoot: DropView?

    override var canBecomeKey: Bool { mode == .dropdown }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            onEscape?()
            return
        }
        // Tab / Shift+Tab：搜索框的字段编辑器走 DropView 的 delegate，
        // 其余控件到这里；两处共用同一条链，顺序才不会分叉。
        if mode == .dropdown, event.keyCode == 48 {
            focusRoot?.advanceFocus(backwards: event.modifierFlags.contains(.shift))
            return
        }
        // Space / Return / Enter：让焦点环里的截屏、灵感、打开按钮也能键盘触发。
        if mode == .dropdown, [36, 49, 76].contains(event.keyCode),
           focusRoot?.activateFocused() == true {
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var panel: DropPanel!
    private var dropView: DropView!
    private var statusItem: NSStatusItem!
    /// 「投递目标」子菜单：每次打开前重新扫描项目目录（QA-004）
    private var targetsMenu: NSMenu?
    private var lastTarget: String = Cfg.storedTarget
    private var capturing = false

    // MARK: 双触发与下拉（1.3.16）
    private var panelMode: PanelMode = .docked
    private var popupMenu: NSMenu?
    private var memoMenuItem: NSMenuItem?
    private var memoFileItems: [NSMenuItem] = []
    private var bottomMenuItem: NSMenuItem?
    private var autoOpenMenuItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?
    private var modeMenuItem: NSMenuItem?
    /// docked 模式下用户自己拖到的位置；切到 dropdown 再切回来要还原
    private var dockedOrigin: NSPoint?
    private var screenObserver: NSObjectProtocol?
    /// B6.3：点面板外与状态栏图标外立即收起下拉。全局监视器只收其它 App 的事件，
    /// 本 App 内的点击要靠本地监视器，两个一起装才没有死角。
    private var outsideClickMonitors: [Any] = []

    // MARK: 搜索与看板（1.4.x）
    private var searchDebounce: Timer?
    private var searchSeq = 0
    private var dashboardWC: DashboardWindowController?
    private var settingsWC: AISettingsWindowController?

    // 灵感录音
    private enum MemoState {
        case idle, preparing, recording, transcribing

        /// 日志里用的中文名。日志是给人看的，别让人对着 `transcribing` 猜。
        var text: String {
            switch self {
            case .idle:         return "空闲"
            case .preparing:    return "准备中"
            case .recording:    return "录音中"
            case .transcribing: return "转写中"
            }
        }
    }
    private var memoState: MemoState = .idle
    private var memoSession: AnyObject?      // MemoSession（macOS 26+ 才有）
    private var memoTimer: Timer?
    private var memoStartedAt: Date?
    private var memoTarget: String = ""
    private var lastPartial: String = ""
    private var lastLevel: Float = 0
    private var lastLevelPaint: Date = .distantPast
    /// 当前这一轮是「转写音频文件」而不是「现场录音」，用来选对提示文案
    private var memoFromFile = false
    /// 这一轮「灵感」的编号，每开始一次 +1。后台回调可能晚于收尾到达，
    /// 靠它把上一轮的进度丢掉（见 `MemoSink`）。
    private var memoRunID = 0
    /// 录音期间有没有真正收到过声音；3 秒还没声音就提醒一次
    private var memoSoundSeen = false
    private var didWarnNoSound = false

    // MARK: 黑匣子（1.3.13）
    //
    // 「界面卡在收尾中」这类问题，光看现象分不清三件事：
    //   ① 后台转写真的还没完；② 结果回了但界面没接住；③ 主线程被堵住，回调排着队。
    // 所以这一版做三样东西：事件在哪儿断的都留痕、主线程每秒打一次心跳、
    // 再加一个看门狗兜底——真卡死了自动恢复界面，不让用户干等。

    /// 最近一次收到本轮事件的时间。看门狗用它算「静默多久」。
    private var lastMemoEventAt = Date()
    /// 当前阶段的文字说明（准备/识别/收尾/归档），写进日志和心跳
    private var memoStageNote = "未开始"
    /// 看门狗定时器（1 秒一次）
    private var memoWatchdog: Timer?
    /// 本轮是否已经因为「久无事件」强制恢复过界面
    private var memoStallRecovered = false
    /// 已经就「静默」告警过的桶（每 10 秒一个），避免每秒刷一行
    private var memoStallWarnedAt = 0
    /// 是否已经闪提示「仍在处理」，每轮只闪一次
    private var memoStallFlashed = false
    /// 心跳计数（每 5 秒打一行）
    private var memoHeartbeat = 0
    /// 上一次把进度写进日志的时间（进度事件很密，不能每条都写）
    private var memoProgressLoggedAt = Date.distantPast
    /// 上一次写进日志的进度阶段
    private var lastMemoStage: TranscribeProgress.Stage?
    /// 定时器节流参考
    private var lastMemoFlashAt = Date.distantPast

    private var memoMenuTitle: String {
        switch memoState {
        case .idle:         return "灵光一现（录音转文字）"
        case .preparing:    return "取消录音准备"
        case .recording:    return "结束录音并转写"
        case .transcribing: return "转写中…"
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 每次启动都在日志里划一道线。没有这一行，事后拿到一份日志连
        // 「是哪个版本、哪台机器、库在哪」都要问用户，白白多一轮沟通。
        DiagLog.header("启动")
        buildStatusItem()
        migratePanelMode()
        buildPanel()
        lastTarget = Cfg.storedTarget
        dropView.setTargetName(lastTarget)
        applyPanelModeAtLaunch()

        // P4：换屏 / 改分辨率 / 拔掉外接屏后，把面板夹回当前屏。
        // 没有这一步，副屏拔掉后窗口会留在不存在的坐标上，用户只能通过菜单复位。
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.clampPanelIntoScreen()
            }
        // 切换 Space 后下拉面板会留在旧 Space 的坐标上，看着像「飘走了」
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, self.panelMode == .dropdown, self.panel.isVisible else { return }
                self.dismissDropdown()
            }
        installOutsideClickMonitors()
        // 失败留下的录音会攒在 Library/Application Support 里，超过 7 天自动清掉
        DispatchQueue.global(qos: .utility).async { RecordingStore.prune() }

        // 上次没写进笔记的结果：启动时补一次。
        // 文字在 pending 里、录音也还在，重试的成本只是几毫秒，收益是「内容不丢」。
        DispatchQueue.global(qos: .utility).async {
            let n = PendingStore.count
            guard n > 0 else { return }
            DiagLog.write("启动：发现 \(n) 条待归档结果，开始补归档")
            let r = MemoArchiveQueue.drain()
            DiagLog.write("启动补归档：成功 \(r.ok)，失败 \(r.failed)（失败会继续保留）")
        }

        // --dashboard / --ai-settings：让看板和设置也能从命令行直达（截图、验收都靠它）
        if AutoUI.openDashboard {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openDashboard()
            }
        }
        if AutoUI.openAISettings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openAISettings()
            }
        }
        if AutoUI.showDropdown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showDropdown(focusSearch: true)
            }
        }

        // --ui-memo：等界面起来后自动跑一轮「转写文件 → 归档 → 复位」，跑完自己退出
        if let f = AutoUI.memoFile {
            if let t = AutoUI.target { lastTarget = t }
            DiagLog.write("自动验收入口：\(f.lastPathComponent) → 目标「\(lastTarget)」")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                if #available(macOS 26.0, *) {
                    self.startFileTranscription(f)
                } else {
                    AutoUI.finish(2, "需要 macOS 26 或更新系统")
                }
            }
            // 硬截止：120 秒还没回到空闲，说明这一轮真的走不完
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                AutoUI.finish(2, "超时 120 秒：界面没有回到空闲（状态 \(self.memoState.text)）")
            }
        }
    }

    // 状态栏
    //
    // 双触发：左键点图标 → 面板从图标正下方下拉；右键 → 精简菜单。
    // `statusItem.menu` **永久保持 nil**：一旦挂上菜单，左键就只弹菜单，
    // 永远收不到 action。也刻意不用「临时挂上再 performClick」的写法——
    // 那依赖同步阻塞，状态残留过一次就很难查。
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = AppIcon.menuBarImage()
            b.image?.isTemplate = true
            b.target = self
            b.action = #selector(statusItemClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem.menu = nil
        buildMenu()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            presentMenu(with: event, in: sender)
        } else {
            togglePanel()
        }
    }

    private func presentMenu(with event: NSEvent, in view: NSView) {
        let menu = popupMenu ?? { buildMenu(); return popupMenu }() ?? NSMenu()
        refreshMenuState(menu)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    /// 菜单只建一次。1.3.15 的 `rebuildMenu()` 被 13 处调用，每次都 new 一整套
    /// NSMenu（16 个可见项 + 3 个子菜单），其中一处还在转写进度里每 0.3–0.4 秒调一次。
    private func buildMenu() {
        guard popupMenu == nil else { return }
        let m = NSMenu()
        m.delegate = self

        let panelItem = NSMenuItem(title: "面板", action: #selector(menuTogglePanel), keyEquivalent: "")
        panelItem.target = self
        m.addItem(panelItem)

        // 1.4.0 加的第八项：搜索必须跟功能同版本上线，否则点开是空面板
        let searchItem = NSMenuItem(title: "搜索笔记…", action: #selector(menuSearch), keyEquivalent: "f")
        searchItem.target = self
        m.addItem(searchItem)

        let shotHeader = NSMenuItem(title: "截图", action: nil, keyEquivalent: "")
        let shotMenu = NSMenu()
        addShotItem(shotMenu, "区域截图并归档", .area)
        addShotItem(shotMenu, "整屏截图并归档", .full)
        addShotItem(shotMenu, "窗口截图并归档", .window)
        shotMenu.addItem(.separator())
        addShotItem(shotMenu, "区域截图到剪贴板", .clipboard)
        shotHeader.submenu = shotMenu
        m.addItem(shotHeader)

        let memoHeader = NSMenuItem(title: "灵感", action: nil, keyEquivalent: "")
        let memoMenu = NSMenu()
        memoMenuItem = NSMenuItem(title: memoMenuTitle, action: #selector(startOrStopMemo), keyEquivalent: "")
        memoMenuItem?.target = self
        memoMenu.addItem(memoMenuItem!)

        // 没有麦克风的机器（比如 Mac mini）用这条：直接转写已有的音频文件
        let memoFileItem = NSMenuItem(title: "转写音频文件…",
                                      action: #selector(transcribeAudioFile), keyEquivalent: "")
        memoFileItem.target = self
        memoMenu.addItem(memoFileItem)
        memoFileItems.append(memoFileItem)

        // 兜底入口：文件被系统置灰（常见于外部拷来的 `brok` 文件）时，
        // 在 Finder 里 ⌘C 复制它，再点这里，绕开 NSOpenPanel 的类型判定。
        // 这是唯一绕不过去的自救路径，不能删。
        let memoClipItem = NSMenuItem(title: "转写剪贴板里的音频",
                                      action: #selector(transcribeAudioFromClipboard), keyEquivalent: "")
        memoClipItem.target = self
        memoMenu.addItem(memoClipItem)
        memoFileItems.append(memoClipItem)
        memoHeader.submenu = memoMenu
        m.addItem(memoHeader)

        let targetHeader = NSMenuItem(title: "投递目标", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.delegate = self
        targetsMenu = sub
        populateTargets()
        targetHeader.submenu = sub
        m.addItem(targetHeader)

        let openHeader = NSMenuItem(title: "打开", action: nil, keyEquivalent: "")
        let openMenu = NSMenu()
        addOpenItem(openMenu, "Obsidian", #selector(openObsidian))
        addOpenItem(openMenu, "库目录", #selector(openVault))
        addOpenItem(openMenu, "附件目录", #selector(openAttachments))
        // 出问题时要的第一样东西就是日志，别让用户去 Finder 里一层层翻。
        // 「复制日志路径」已删除：日志第一行就打印了路径。
        addOpenItem(openMenu, "运行日志", #selector(openLog))
        openMenu.addItem(.separator())
        addOpenItem(openMenu, "使用看板…", #selector(openDashboard))
        openMenu.addItem(.separator())
        addOpenItem(openMenu, "AI 模型配置…", #selector(openAISettings))
        openHeader.submenu = openMenu
        m.addItem(openHeader)

        let settingsHeader = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        let settings = NSMenu()
        bottomMenuItem = NSMenuItem(title: "窗口置于底层（不挡其他窗口）",
                                    action: #selector(toggleBottom), keyEquivalent: "")
        bottomMenuItem?.target = self
        settings.addItem(bottomMenuItem!)

        let reset = NSMenuItem(title: "复位窗口位置", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        settings.addItem(reset)

        autoOpenMenuItem = NSMenuItem(title: "投递后打开新笔记",
                                      action: #selector(toggleAutoOpen), keyEquivalent: "")
        autoOpenMenuItem?.target = self
        settings.addItem(autoOpenMenuItem!)

        loginMenuItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLogin), keyEquivalent: "")
        loginMenuItem?.target = self
        settings.addItem(loginMenuItem!)

        modeMenuItem = NSMenuItem(title: "恢复菜单栏下拉模式",
                                  action: #selector(togglePanelMode), keyEquivalent: "")
        modeMenuItem?.target = self
        settings.addItem(modeMenuItem!)
        settingsHeader.submenu = settings
        m.addItem(settingsHeader)

        m.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        m.addItem(quit)

        popupMenu = m
        refreshMenuState(m)
    }

    /// 只改会变的那几项（标题 / 勾选 / 可用性）
    private func refreshMenuState(_ m: NSMenu? = nil) {
        guard let menu = m ?? popupMenu else { return }
        guard let panelItem = menu.items.first else { return }
        panelItem.title = panelMode == .docked
            ? (panel?.isVisible == true ? "隐藏投放窗口" : "显示投放窗口")
            : "打开下拉面板"
        memoMenuItem?.title = memoMenuTitle
        memoMenuItem?.isEnabled = memoState != .transcribing
        for it in memoFileItems { it.isEnabled = memoState == .idle }
        bottomMenuItem?.state = UserDefaults.standard.bool(forKey: Cfg.bottomKey) ? .on : .off
        autoOpenMenuItem?.state = UserDefaults.standard.bool(forKey: "autoOpenNote") ? .on : .off
        loginMenuItem?.state = isLoginEnabled() ? .on : .off
        modeMenuItem?.title = panelMode == .docked ? "恢复菜单栏下拉模式" : "改为常驻浮窗"
    }

    /// 兼容旧调用点：语义从「重建」变成「刷新」
    private func rebuildMenu() {
        if popupMenu == nil { buildMenu() } else { refreshMenuState() }
    }

    private func addOpenItem(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        menu.addItem(it)
    }

    /// 重建「投递目标」列表。每次菜单打开前都会调用，
    /// 因此运行中新建的项目目录可以立即出现在菜单里（QA-004）。
    private func populateTargets() {
        guard let sub = targetsMenu else { return }
        sub.removeAllItems()
        for t in Targets.all(vault: Cfg.vault) {
            let it = NSMenuItem(title: t.name, action: #selector(chooseTarget(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = t.rel
            if t.rel == Cfg.storedTarget { it.state = .on }
            sub.addItem(it)
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === targetsMenu { populateTargets() }
    }

    // 面板
    private func buildPanel() {
        let size = PanelMetrics.docked
        panel = DropPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.mode = panelMode
        panel.onEscape = { [weak self] in self?.dismissDropdown() }

        dropView = DropView(frame: NSRect(origin: .zero, size: size))
        dropView.onDrop = { [weak self] urls in self?.handleDrop(urls) }
        dropView.onDoubleClick = { [weak self] in self?.openObsidian() }
        dropView.onOpenObsidian = { [weak self] in self?.openObsidian() }
        dropView.onScreenshot = { [weak self] in self?.takeScreenshot(.area) }
        dropView.onMemo = { [weak self] in self?.startOrStopMemo() }
        dropView.onRightClick = { [weak self] event in
            guard let self else { return }
            self.presentMenu(with: event, in: self.dropView)
        }
        dropView.onEscape = { [weak self] in self?.dismissDropdown() }
        dropView.onSearchText = { [weak self] q in self?.scheduleSearch(q) }
        dropView.onPickRow = { [weak self] row in self?.open(row) }
        panel.contentView = dropView
        panel.focusRoot = dropView

        // 还原位置，默认右下角
        let ud = UserDefaults.standard
        let hasPos = ud.object(forKey: Cfg.posXKey) != nil
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = hasPos
            ? NSPoint(x: ud.double(forKey: Cfg.posXKey), y: ud.double(forKey: Cfg.posYKey))
            : NSPoint(x: screen.maxX - size.width - 32, y: screen.minY + 32)
        panel.setFrameOrigin(origin)
        dockedOrigin = origin
        applyWindowLevel()
    }

    // MARK: 形态与下拉

    /// 迁移规则见方案 §3.3：新装默认下拉；存在任一旧键 → 老用户，保持常驻浮窗。
    private func migratePanelMode() {
        let ud = UserDefaults.standard
        if let raw = ud.string(forKey: Cfg.modeKey), let m = PanelMode(rawValue: raw) {
            panelMode = m
            return
        }
        let isLegacy = Cfg.legacyKeys.contains { ud.object(forKey: $0) != nil }
        panelMode = isLegacy ? .docked : .dropdown
        ud.set(panelMode.rawValue, forKey: Cfg.modeKey)
        DiagLog.write("面板模式：\(panelMode.rawValue)（\(isLegacy ? "老用户迁移" : "新装默认")）")
    }

    private func applyPanelModeAtLaunch() {
        panel.mode = panelMode
        switch panelMode {
        case .docked:
            let visible = UserDefaults.standard.object(forKey: Cfg.visibleKey) as? Bool ?? true
            setPanelVisible(visible)
        case .dropdown:
            // 下拉模式不常驻：启动时面板是隐藏的，点图标才出来。
            // 这里刻意**不写** visibleKey——临时可见不该变成下次启动的偏好。
            setPanelVisible(false, record: false)
        }
        applyWindowLevel()
        refreshMenuState()
    }

    private func setPanelVisible(_ v: Bool, record: Bool = true) {
        if v { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        // 下拉形态的可见性永远是临时的：录音时临时显示面板不能变成
        // 「下次以 docked 启动就把窗口摆出来」的偏好。
        if record && panelMode == .docked {
            UserDefaults.standard.set(v, forKey: Cfg.visibleKey)
        }
    }

    @objc private func resetPosition() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let s = panel.frame.size
        let p = NSPoint(x: screen.maxX - s.width - 32, y: screen.minY + 32)
        panel.setFrameOrigin(p)
        dockedOrigin = p
        UserDefaults.standard.set(Double(p.x), forKey: Cfg.posXKey)
        UserDefaults.standard.set(Double(p.y), forKey: Cfg.posYKey)
        setPanelVisible(true)
    }

    /// 左键统一入口：按模式分派（docked 显隐 / dropdown 展开收起）
    @objc private func togglePanel() {
        switch panelMode {
        case .docked:
            setPanelVisible(!panel.isVisible)
        case .dropdown:
            if panel.isVisible { dismissDropdown() } else { showDropdown(focusSearch: false) }
        }
        refreshMenuState()
    }

    @objc private func menuTogglePanel() {
        if panelMode == .dropdown {
            showDropdown(focusSearch: false)
        } else {
            togglePanel()
        }
    }

    /// 状态栏按钮在屏幕上的矩形。**不能用 NSScreen.main**：
    /// 副屏上点图标时 main 还是主屏，面板会飞到另一块屏幕上。
    private func statusButtonScreenFrame() -> (anchor: NSRect?, screen: NSScreen?) {
        guard let b = statusItem.button, let w = b.window else { return (nil, nil) }
        let inWindow = b.convert(b.bounds, to: nil)
        let onScreen = w.convertToScreen(inWindow)
        return (onScreen, w.screen)
    }

    private func showDropdown(focusSearch: Bool) {
        // 记录常驻位置：从 docked 拖到 dropdown 再回来时不能丢
        if panelMode == .docked, panel.isVisible { dockedOrigin = panel.frame.origin }
        panelMode = .dropdown
        panel.mode = .dropdown

        let (anchor, screen) = statusButtonScreenFrame()
        let visible = screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = PanelMetrics.dropdown
        let frame = dropdownFrame(anchor: anchor, visible: visible, size: size)
        panel.setFrame(frame, display: true)
        dropView.setWide(true)
        dropView.layoutSubtreeIfNeeded()
        cancelSearch()
        dropView.clearSearch()
        dropView.setResults([], empty: "输入关键词，同时搜库内笔记与本机文件")

        applyWindowLevel()
        panel.orderFrontRegardless()
        // 下拉要能接键盘（ESC / 搜索），但仍然不激活本 App
        panel.makeKey()
        if focusSearch { dropView.focusSearch() }
        UserDefaults.standard.set(PanelMode.dropdown.rawValue, forKey: Cfg.modeKey)
        DiagLog.write("下拉展开：anchor=\(anchor.map { NSStringFromRect($0) } ?? "nil") "
                      + "frame=\(NSStringFromRect(frame))")
        refreshMenuState()
    }

    /// 收起下拉。**模式保持不变**：点开又收起不等于「退回常驻浮窗」，
    /// 否则用户第二次点图标会突然冒出一个小窗，与「点图标下拉」的预期不符。
    /// 只在面板隐藏期间把 canBecomeKey 关掉，避免隐藏窗口抢键盘。
    /// 点其他应用（或切到别的 Space）时收起。注释里一直写着要收起，
    /// 但之前只实现了 Esc 与再点图标两条显式路径。
    func applicationDidResignActive(_ notification: Notification) {
        if panelMode == .dropdown, panel.isVisible { dismissDropdown() }
    }

    /// B6.3：点面板外立即收起。以前只有 Esc、再点图标、切 Space、App 失活四条路径，
    /// 点桌面或同 App 的另一个窗口时下拉会一直挂着。
    private func installOutsideClickMonitors() {
        let masks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let check: () -> Void = { [weak self] in
            guard let self, self.panelMode == .dropdown, self.panel.isVisible else { return }
            let p = NSEvent.mouseLocation
            if self.panel.frame.contains(p) { return }
            // 点在状态栏按钮上时不收起：左键入口自己会 toggle，右键还要弹菜单。
            if let r = self.statusItem.button?.window?.frame, r.contains(p) { return }
            self.dismissDropdown()
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: masks, handler: { _ in check() }) {
            outsideClickMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: masks, handler: { e in
            check()
            return e
        }) {
            outsideClickMonitors.append(l)
        }
    }

    private func dismissDropdown() {
        guard panelMode == .dropdown else { return }
        panel.orderOut(nil)
        panel.mode = .docked
        cancelSearch()
        dropView.clearSearch()
        DiagLog.write("下拉收起（模式仍为 dropdown）")
        refreshMenuState()
    }

    @objc private func togglePanelMode() {
        if panelMode == .dropdown {
            panel.orderOut(nil)
            panelMode = .docked
            panel.mode = .docked
            panel.setContentSize(PanelMetrics.docked)
            if let o = dockedOrigin { panel.setFrameOrigin(o) }
            dropView.setWide(false)
            cancelSearch()
            dropView.clearSearch()
            UserDefaults.standard.set(PanelMode.docked.rawValue, forKey: Cfg.modeKey)
            applyWindowLevel()
            setPanelVisible(true)
        } else {
            showDropdown(focusSearch: false)
        }
        refreshMenuState()
    }

    /// 屏幕变化后把面板夹回可见区域（P4）
    private func clampPanelIntoScreen() {
        guard panelMode == .docked, panel.isVisible else { return }
        let screen = panel.screen ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return }
        var f = panel.frame
        f.origin.x = min(max(f.origin.x, v.minX + 8), max(v.maxX - f.width - 8, v.minX + 8))
        f.origin.y = min(max(f.origin.y, v.minY + 8), max(v.maxY - f.height - 8, v.minY + 8))
        if f.origin != panel.frame.origin {
            panel.setFrameOrigin(f.origin)
            dockedOrigin = f.origin
            UserDefaults.standard.set(Double(f.origin.x), forKey: Cfg.posXKey)
            UserDefaults.standard.set(Double(f.origin.y), forKey: Cfg.posYKey)
            DiagLog.write("屏幕变化：面板已夹回可见区域 \(NSStringFromRect(f))")
        }
    }

    // 窗口层级：floating（默认，悬浮在所有窗口之上）/ 底层（压在桌面之上、所有窗口之下）
    private func applyWindowLevel() {
        // 下拉形态强制 floating：用户开着「置于底层」时，下拉面板会压在所有窗口
        // 后面，等于点不出来。
        if panelMode == .dropdown {
            panel.level = .floating
            return
        }
        let bottom = UserDefaults.standard.bool(forKey: Cfg.bottomKey)
        panel.level = bottom
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : .floating
    }

    @objc private func toggleBottom() {
        let cur = UserDefaults.standard.bool(forKey: Cfg.bottomKey)
        UserDefaults.standard.set(!cur, forKey: Cfg.bottomKey)
        applyWindowLevel()
        if panel.isVisible { panel.orderFrontRegardless() } else { setPanelVisible(true) }
        rebuildMenu()
    }

    @objc private func chooseTarget(_ sender: NSMenuItem) {
        guard let rel = sender.representedObject as? String else { return }
        Cfg.saveTarget(rel)
        lastTarget = rel
        dropView.setTargetName(rel)
        rebuildMenu()
    }

    @objc private func openObsidian() {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: "md.obsidian") {
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            ws.open(Cfg.vault)
        }
    }

    @objc private func openVault() { NSWorkspace.shared.open(Cfg.vault) }

    @objc private func openAttachments() {
        NSWorkspace.shared.open(Cfg.vault.appendingPathComponent("附件"))
    }

    @objc private func openLog() {
        openLogFile()
    }

    // MARK: 搜索（1.4.0）

    @objc private func menuSearch() {
        showDropdown(focusSearch: true)
    }

    /// 输入即搜，但要防抖：中文输入法每敲一个拼音字母都会触发一次回调，
    /// 不防抖就会把一个词拆成七八次索引查询。
    ///
    /// 序号在**文本一变**就推进，而不是等防抖定时器触发——否则新词已经显示在
    /// 输入框里，上一次查询的结果还可能在这 120ms 内回填上来。
    private func scheduleSearch(_ raw: String) {
        searchDebounce?.invalidate()
        searchDebounce = nil
        searchSeq += 1
        let seq = searchSeq
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            dropView.setResults([], empty: "输入关键词，同时搜库内笔记与本机文件")
            return
        }
        dropView.setSearching(true)
        let t = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
            self?.runSearch(q, seq: seq)
        }
        RunLoop.main.add(t, forMode: .common)
        searchDebounce = t
    }

    /// 收起面板 / 换形态 / 清空输入时统一取消：不然关闭期间仍会跑一次旧查询，
    /// 重新打开时先闪一眼上次的结果。
    private func cancelSearch() {
        searchDebounce?.invalidate()
        searchDebounce = nil
        searchSeq += 1
    }

    private func runSearch(_ query: String, seq: Int) {
        let vault = Cfg.vault
        let t0 = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = VaultIndex.blockingSearch(vault: vault, query: query, limit: 6)
            let local = SpotlightSearch.search(query, limit: 3)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)

            var rows: [SearchRow] = r.hits.map { h in
                // 文件名当标题，正文首行当上下文：搜索结果里最有用的两样东西
                let name = ((h.rel as NSString).lastPathComponent as NSString).deletingPathExtension
                return SearchRow(kind: .vault, path: h.rel, title: name,
                                 detail: h.snippet.isEmpty ? "第 \(h.line) 行" : h.snippet)
            }
            for l in local {
                rows.append(SearchRow(kind: .local, path: l.path, title: l.name,
                                      detail: l.path.replacingOccurrences(
                                        of: NSHomeDirectory(), with: "~")))
            }
            let empty = rows.isEmpty ? "没有匹配「\(query)」的笔记，换个词试试" : ""
            DiagLog.write("搜索「\(query)」：库内 \(r.hits.count) 条 / 库外 \(local.count) 条 / \(ms)ms")
            MetricsStore.shared.record(MetricEvent(kind: "search", ok: !rows.isEmpty,
                                                   target: "", noteRel: r.hits.first?.rel ?? "",
                                                   source: "panel", durationMs: ms))
            DispatchQueue.main.async {
                guard let self, seq == self.searchSeq else { return }
                self.dropView.setResults(rows, empty: empty)
            }
        }
    }

    /// 结果里按回车 / 点一行
    private func open(_ row: SearchRow) {
        switch row.kind {
        case .vault:
            openNote(rel: row.path)
            MetricsStore.shared.record(MetricEvent(kind: "open", target: "", noteRel: row.path,
                                                   source: "search"))
        case .local:
            NSWorkspace.shared.open(URL(fileURLWithPath: row.path))
            MetricsStore.shared.record(MetricEvent(kind: "open", source: "search-local"))
        }
        if panelMode == .dropdown { dismissDropdown() }
    }

    // MARK: 看板与设置

    @objc private func openDashboard() {
        if dashboardWC == nil { dashboardWC = DashboardWindowController() }
        dashboardWC?.show()
    }

    @objc private func openAISettings() {
        if settingsWC == nil { settingsWC = AISettingsWindowController() }
        settingsWC?.show()
    }

    @objc private func copyLogPath() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(DiagLog.path, forType: .string)
        dropView.flash("日志路径已复制", ok: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // 登录项
    private func isLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppServiceBridge.isEnabled
        }
        return false
    }

    @objc private func toggleLogin() {
        if #available(macOS 13.0, *) {
            let err = SMAppServiceBridge.toggle()
            if let err {
                let a = NSAlert()
                a.messageText = "无法设置开机启动"
                a.informativeText = err
                a.alertStyle = .warning
                a.runModal()
            }
        }
        rebuildMenu()
    }

    @objc private func toggleAutoOpen() {
        let cur = UserDefaults.standard.bool(forKey: "autoOpenNote")
        UserDefaults.standard.set(!cur, forKey: "autoOpenNote")
        rebuildMenu()
    }

    /// 用 obsidian:// 直接打开刚生成的笔记
    private func openNote(rel: String) {
        let vaultName = Cfg.vault.lastPathComponent
        let filePart = (rel as NSString).deletingPathExtension
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [
            URLQueryItem(name: "vault", value: vaultName),
            URLQueryItem(name: "file", value: filePart)
        ]
        if let u = comps.url { NSWorkspace.shared.open(u) }
    }

    // 截图
    private func addShotItem(_ menu: NSMenu, _ title: String, _ mode: Screenshot.Mode) {
        let it = NSMenuItem(title: title, action: #selector(runScreenshot(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = mode.rawValue
        menu.addItem(it)
    }

    @objc private func runScreenshot(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = Screenshot.Mode(rawValue: raw) else { return }
        takeScreenshot(mode)
    }

    /// 先把自己藏起来，再截屏；截完归档到当前目标
    private func takeScreenshot(_ mode: Screenshot.Mode) {
        guard !capturing else { return }
        guard memoState == .idle else {
            // 录音/转写期间不截屏：面板本来就要临时收起，截完再谈也更乱
            NSSound.beep()
            return
        }
        capturing = true

        let wasVisible = panel.isVisible
        panel.orderOut(nil)   // 只临时收起，不改写「面板可见」偏好

        // 等窗口真正消失，避免残影被拍进去
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Screenshot.capture(mode)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.capturing = false
                    if wasVisible { self.panel.orderFrontRegardless() }
                    self.finishScreenshot(result, mode: mode)
                }
            }
        }
    }

    private func finishScreenshot(_ r: (ok: Bool, file: URL?, message: String),
                                  mode: Screenshot.Mode) {
        if mode == .clipboard {
            if r.ok {
                dropView.flash("已复制到剪贴板", ok: true)
            } else {
                dropView.flash("已取消", ok: false)
            }
            return
        }

        guard r.ok, let file = r.file else {
            if r.message == "已取消" {
                dropView.flash("已取消", ok: false)
            } else {
                dropView.flash("截图失败", ok: false)
                let a = NSAlert()
                a.messageText = "截图失败"
                a.informativeText = r.message + "\n\n首次使用需要授权：系统设置 → 隐私与安全性 → 屏幕与系统录音 → 勾选 ObsidianDrop。授权后请重启本程序。"
                a.alertStyle = .warning
                a.addButton(withTitle: "打开设置")
                a.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn,
                   let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(u)
                }
            }
            return
        }

        // 1.7.0：截图识别最多 12 秒，绝不能在主线程同步跑。
        let target = lastTarget
        let vault = Cfg.vault
        let budget = AIBatchBudget(cap: AIConfigStore.config.effectiveBudget)
        let ctx = ArchiveContext(source: "screenshot", scene: .image, target: target,
                                 sourceURL: file, batchBudget: budget)
        dropView.renderScene(.image)
        dropView.renderAI(.working, phase: "识别图片", detail: "生成概览")
        DispatchQueue.global(qos: .userInitiated).async {
            let report: BatchReport
            do {
                report = try Filer(vault: vault).file([file], target: target, contexts: [ctx])
            } catch {
                // 归档抛错时保留临时 PNG：库里没有笔记，它是唯一副本。
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.dropView.renderAI(.failed, phase: "归档失败", detail: "")
                    self.dropView.flash("归档失败", ok: false)
                    let a = NSAlert()
                    a.messageText = "截图已生成，但归档失败"
                    a.informativeText = error.localizedDescription
                        + "\n\n源图已保留：\(file.path)"
                    a.alertStyle = .warning
                    NSApp.activate(ignoringOtherApps: true)
                    a.runModal()
                }
                return
            }
            // 只有确认笔记落盘且零失败才删源图；失败分支由下面弹窗告知保留路径。
            if ScreenshotCleanup.canDiscard(failures: report.failures.count,
                                            noteRel: report.outcomes.first?.noteRel ?? "") {
                try? FileManager.default.removeItem(at: file)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.finishScreenshotReport(report, target: target, sourceFile: file)
            }
        }
    }

    private func finishScreenshotReport(_ report: BatchReport, target: String,
                                        sourceFile: URL? = nil) {
        let first = report.outcomes.first
        MetricsStore.shared.record(MetricEvent(
            kind: "screenshot", ok: report.failures.isEmpty, target: target,
            noteRel: first?.noteRel ?? "", source: "panel",
            captureId: first?.captureId ?? "",
            failReason: report.failures.first?.reason ?? "",
            ai: first?.aiState.rawValue ?? "off"))
        if let o = first, !o.noteRel.isEmpty {
            MetricNoteMap.remember(noteId: MetricID.hash(o.noteRel), rel: o.noteRel)
        }
        if let failure = report.failures.first {
            dropView.renderAI(.failed, phase: "归档失败", detail: "")
            dropView.flash("截图归档失败", ok: false)
            let a = NSAlert()
            a.messageText = "截图已生成，但归档失败"
            a.informativeText = failure.reason
                + (sourceFile.map { "\n\n源图已保留：\($0.path)" } ?? "")
            a.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            return
        }
        let skipped = first?.aiState == .skipped
        dropView.renderAI(skipped ? .skipped : .done,
                          phase: skipped ? "已归档（AI 跳过）" : "已归档", detail: "")
        dropView.flash(skipped ? "截图已归档（AI 跳过）" : "截图已归档", ok: true)
        if let first {
            NSLog("ObsidianDrop: 截图 → \(first.fileRel)")
            if UserDefaults.standard.bool(forKey: "autoOpenNote") {
                openNote(rel: first.noteRel)
            }
        }
    }

    // 灵感：录音 → 转写 → 入库
    @objc private func startOrStopMemo() {
        switch memoState {
        case .idle:
            beginMemo()
        case .preparing:
            cancelMemo()
        case .recording:
            endMemo()
        case .transcribing:
            NSSound.beep()
        }
    }

    /// 转写已有的音频文件。
    ///
    /// 这台 Mac mini 没有内置麦克风，「灵光一现（现场录音）」用不了，
    /// 但「把一段录音变成文字」这件事本身是可以的——这条入口就是给这种情况的。
    @objc private func transcribeAudioFile() {
        guard #available(macOS 26.0, *) else {
            memoAlert(MemoError.needNewerOS)
            return
        }
        guard memoState == .idle else {
            // 别静默吞掉：状态不对时给个明确反馈，省得用户以为「点了没反应」
            dropView.flash("正在处理上一条，稍等", ok: false)
            NSSound.beep()
            return
        }

        let open = NSOpenPanel()
        open.title = "选择要转成文字的音频"
        open.allowsMultipleSelection = false
        open.canChooseDirectories = false
        // 不按类型过滤：文件在面板里能不能选，是 Launch Services 说了算。
        // 从外部（Windows / 手机 / 某些传输工具）拷来的文件常被打上 `brok` 类型码，
        // 系统于是判定它「不可用」，在面板里显示成灰色点不动 —— 这时再叠一层
        // allowedContentTypes 只会更糟。放开限制，选完由我们自己校验并给明确提示。
        open.allowedContentTypes = []
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK, let url = open.url else { return }

        startFileTranscription(url)
    }

    /// 不经过打开面板的入口：直接转写剪贴板里的文件。
    ///
    /// 给「文件在面板里是灰的、点不动」准备的兜底 —— 在 Finder 里 ⌘C 复制那个文件，
    /// 再点这里即可，全程不经过面板的类型/可用性判定。
    @objc private func transcribeAudioFromClipboard() {
        guard #available(macOS 26.0, *) else {
            memoAlert(MemoError.needNewerOS)
            return
        }
        guard memoState == .idle else {
            dropView.flash("正在处理上一条，稍等", ok: false)
            NSSound.beep()
            return
        }

        let pb = NSPasteboard.general
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        guard let url = urls.first(where: { !$0.hasDirectoryPath }) else {
            dropView.flash("剪贴板里没有文件", ok: false)
            NSSound.beep()
            return
        }
        startFileTranscription(url)
    }

    /// 转写一个文件（面板 / 剪贴板 / 拖拽共用这一段）
    @available(macOS 26.0, *)
    private func startFileTranscription(_ url: URL) {
        setPanelVisible(true)
        memoTarget = lastTarget
        lastPartial = ""
        lastLevel = 0
        memoFromFile = true
        memoState = .preparing
        memoRunID &+= 1
        let run = memoRunID
        dropView.renderMemo(.preparing("正在转写音频…"), partial: "")
        rebuildMenu()
        startWatchdog(run: run)
        DiagLog.round(run, "开始转写文件：\(url.lastPathComponent)（\(Filer.humanSize(url))）→ 目标「\(memoTarget)」")

        Task.detached(priority: .userInitiated) { [weak self] in
            // 验收用：模拟「结果没能交到界面」这个故障，验证看门狗能不能兜住。
            // 正常运行时这个变量不存在。
            let dropDone = ProcessInfo.processInfo.environment["OBSIDIANDROP_DROP_DONE"] == "1"
            do {
                let t0 = Date()
                let r = try await SpeechRunner.transcribeFile(at: url, localeID: Memo.localeID) { p in
                    Task { @MainActor [weak self] in
                        self?.memoProgress(p, run: run)
                    }
                }
                DiagLog.round(run, "文件转写返回：\(String(format: "%.1f", Date().timeIntervalSince(t0)))s，"
                              + "\(r.text.count) 字，交付 done")
                // 与录音入口同一套保命规则：文字先落盘，再谈交付。
                // 文件入口的音频属于用户，`audioPath` 留空——归档成功也不许删它。
                var pendingID = ""
                if !r.text.isEmpty {
                    let m = PendingMemo(id: UUID().uuidString,
                                        text: r.text,
                                        duration: r.seconds,
                                        target: self?.memoTarget ?? Cfg.storedTarget,
                                        vaultPath: Cfg.vault.path,
                                        engine: "DictationTranscriber / \(Memo.localeName)",
                                        audioPath: "",
                                        source: "file",
                                        createdAt: Date(),
                                        attempts: 0,
                                        aiState: AIConfigStore.config.enabled ? .pending : nil)
                    if (try? PendingStore.enqueue(m)) != nil {
                        pendingID = m.id
                        DiagLog.round(run, "结果已落盘：\(m.id)（\(m.text.count) 字）→ 待归档队列")
                    } else {
                        DiagLog.round(run, "结果落盘失败（继续交付）")
                    }
                }
                if dropDone {
                    DiagLog.round(run, "（验收模拟）结果不交付，等看门狗兜底")
                    return
                }
                // 验收用：把交付延后 N 秒，用来验证「看门狗恢复界面之后结果才到」时
                // 内容仍然会归档（MemoGate.acceptsDone 只看轮次）。
                if let s = ProcessInfo.processInfo.environment["OBSIDIANDROP_DELAY_DONE"],
                   let secs = Double(s), secs > 0 {
                    DiagLog.round(run, "（验收模拟）结果延后 \(Int(secs))s 交付")
                    try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                }
                Task { @MainActor [weak self] in
                    var o = MemoOutcome()
                    o.recorded = r.seconds
                    o.fed = r.seconds
                    o.chars = r.text.count
                    o.peak = 1        // 文件路径没有"音量"概念，不参与空结果判断
                    o.fromFile = true
                    o.pendingID = pendingID
                    o.recordingPath = url.path
                    self?.memoDone(text: r.text, duration: r.seconds, outcome: o, error: nil, run: run)
                }
            } catch {
                DiagLog.round(run, "文件转写抛错：\(error.localizedDescription)，交付 done")
                Task { @MainActor [weak self] in
                    self?.memoDone(text: "", duration: 0, outcome: MemoOutcome(fromFile: true), error: error, run: run)
                }
            }
        }
    }

    private func beginMemo() {
        guard memoState == .idle else { return }
        guard #available(macOS 26.0, *) else {
            memoAlert(MemoError.needNewerOS)
            return
        }
        setPanelVisible(true)
        memoTarget = lastTarget
        lastPartial = ""
        lastLevel = 0
        memoFromFile = false
        memoSoundSeen = false
        didWarnNoSound = false
        memoState = .preparing
        memoRunID &+= 1
        dropView.renderMemo(.preparing("检查麦克风…"), partial: "")
        rebuildMenu()
        startWatchdog(run: memoRunID)
        DiagLog.round(memoRunID, "本轮开始：现场录音 → 目标「\(memoTarget)」，语言 \(Memo.localeID)")

        // 目标与库在**开始时就冻结**并交给会话：结果可能几分钟后才归档，
        // 那时 memoTarget 可能已经换成别的目录，用新目标写旧内容就是串档。
        let s = MemoSession(localeID: Memo.localeID, run: memoRunID,
                            target: memoTarget, vault: Cfg.vault)
        memoSession = s
        s.start(sink: self)
    }

    /// 结束录音，进入转写
    private func endMemo() {
        stopMemoTimer()
        if #available(macOS 26.0, *), let s = memoSession as? MemoSession {
            s.stop()
        }
        // 这里仍然放掉引用：转写任务自己强持有会话，而结果投递已经不再依赖会话
        // 是否活着（见 `MemoDelivery`）。1.3.13 就是因为这一行加上弱引用投递，
        // 让「结果回来了」这件事永远到不了界面。
        memoSession = nil
        memoState = .transcribing
        rebuildMenu()
    }

    /// 准备阶段点「取消」
    private func cancelMemo() {
        DiagLog.round(memoRunID, "用户取消本轮（状态 \(memoState.text)）")
        stopWatchdog()
        stopMemoTimer()
        if #available(macOS 26.0, *), let s = memoSession as? MemoSession {
            s.cancel()
        }
        memoSession = nil
        memoState = .idle
        lastPartial = ""
        dropView.renderMemo(.idle, partial: "")
        dropView.flash("已取消", ok: false)
        rebuildMenu()
    }

    private func startMemoTimer() {
        stopMemoTimer()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.memoState == .recording else { return }
            let elapsed = self.memoStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            self.dropView.renderMemo(.recording(elapsed, self.lastLevel), partial: self.lastPartial)
            // 不设上限时只更新计时显示，录音一直继续，直到用户点「结束」
            if let cap = Memo.maxSeconds, elapsed >= cap {
                self.endMemo()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        memoTimer = t
    }

    private func stopMemoTimer() {
        memoTimer?.invalidate()
        memoTimer = nil
    }

    // MARK: 看门狗（1.3.13）

    /// 每轮开始计时。这既是「黑匣子的心跳」，也是「真卡死了别让用户干等」的兜底。
    private func startWatchdog(run: Int) {
        stopWatchdog()
        lastMemoEventAt = Date()
        memoStageNote = "启动"
        memoStallWarnedAt = 0
        memoStallRecovered = false
        memoStallFlashed = false
        memoHeartbeat = 0
        memoProgressLoggedAt = Date.distantPast
        lastMemoStage = nil
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        RunLoop.main.add(t, forMode: .common)
        memoWatchdog = t
    }

    private func stopWatchdog() {
        memoWatchdog?.invalidate()
        memoWatchdog = nil
    }

    /// 一秒一次：写心跳、判静默、必要时恢复界面。
    ///
    /// 为什么能靠「静默」判断卡死：正常流程里事件是连续的——
    /// 录音时音量每秒十几次，识别时进度每 0.3~0.4 秒一条，收尾时每 0.3 秒一条，
    /// 连下载语音模型都每 0.3 秒报一次「已等多少秒」。
    /// 因此**20 秒没有任何事件一定是异常**，而不是「慢」。
    ///
    /// 心跳行的另一半价值是反向证据：如果日志里连心跳都没有，说明主线程被堵住了，
    /// 而不是后台没干活——这两种情况的修法完全不同。
    private func watchdogTick() {
        guard memoState != .idle else { stopWatchdog(); return }
        memoHeartbeat += 1
        let silent = Date().timeIntervalSince(lastMemoEventAt)
        if memoHeartbeat % 5 == 0 {
            DiagLog.round(memoRunID, "心跳：状态 \(memoState.text)｜阶段 \(memoStageNote)"
                          + "｜静默 \(String(format: "%.1f", silent))s｜进程已运行 \(DiagLog.uptime())")
        }

        // 注意门槛要用「告警线」和「恢复线」里更小的那个：
        // 验收时会把恢复线调到 10 秒，若这里仍然写死 20，10~20 秒之间的恢复就被这一行挡住了，
        // 表现是「注入的阈值没生效」——排查工具本身不能骗人。
        guard silent >= min(20, stallRecoverSeconds) else { return }
        let bucket = Int(silent) / 10
        if bucket > memoStallWarnedAt {
            memoStallWarnedAt = bucket
            // 1.3.13 在这里一律写「主线程还活着，是后台没进展」——而现场日志证明
            // 后台早就转完了（51 字），是**结果交付这一跳**断的。判断错了，修法就全错。
            // 队列里有东西 = 文字已经产出，只是界面没收到。
            let queued = PendingStore.count
            let why = queued > 0
                ? "文字已落盘（待归档 \(queued) 条），是界面没收到交付"
                : "主线程心跳正常，事件没有到达界面（后台无进展，或投递被拦）"
            DiagLog.round(memoRunID, "警告：\(Int(silent)) 秒没有任何事件"
                          + "（状态 \(memoState.text)｜阶段 \(memoStageNote)）—— \(why)")
        }
        // 30 秒没动静：让人知道程序没死，还在处理，而不是盯着一个静止的画面
        if silent >= 30, !memoStallFlashed {
            memoStallFlashed = true
            dropView.flash("还在处理，请稍等…", ok: true)
        }

        // 150 秒还没有任何事件：确定是死在这里了。恢复界面，让人能继续做事；
        // 后台若之后真出结果，`memoDone` 仍会归档（见 MemoGate.acceptsDone）。
        // 阈值给到 150 秒而不是 90 秒，是因为「首次下载语音模型」前的那次检查
        // 最长可能安静 80 秒（20+60），不能把正常等待误杀。
        if silent >= stallRecoverSeconds, !memoStallRecovered {
            recoverFromStall(silent: silent)
        }
    }

    /// 多久没有事件就认定卡死。默认 150 秒；
    /// `OBSIDIANDROP_STALL_SECONDS` 可在验收时把它调小，用来验证恢复动作本身。
    private var stallRecoverSeconds: Double {
        if let s = ProcessInfo.processInfo.environment["OBSIDIANDROP_STALL_SECONDS"],
           let v = Double(s), v >= 5 {
            return v
        }
        return 150
    }

    private func recoverFromStall(silent: Double) {
        memoStallRecovered = true
        let stuckStage = memoStageNote
        let queued = PendingStore.count
        DiagLog.round(memoRunID, "看门狗：\(Int(silent)) 秒无事件（阶段 \(stuckStage)），强制恢复界面。"
                      + "待归档 \(queued) 条。日志：\(DiagLog.path)")
        // 界面先恢复：这一步不依赖磁盘 IO，不能等补归档。
        memoState = .idle
        memoSession = nil
        stopMemoTimer()
        stopWatchdog()
        lastPartial = ""
        dropView.renderMemo(.idle, partial: "")
        rebuildMenu()

        // P7：补归档要做「读 pending → 可能跑 AI → 写笔记」，
        // 原来整段在主线程执行，正好在最需要界面活着的时候把主线程堵住
        // （表现为恢复界面后仍转圈、菜单点不动）。改为后台执行，完成后回主线程收尾。
        let finish: ((ok: Int, failed: Int)) -> Void = { [weak self] drained in
            guard let self else { return }
            DiagLog.round(self.memoRunID, "看门狗：补归档成功 \(drained.ok) 条，失败 \(drained.failed) 条")
            self.dropView.flash(drained.ok > 0 ? "文字已归档，界面已恢复" : "转写卡住了，已恢复",
                                ok: drained.ok > 0)
            self.afterStallRecovery(drained: drained, stuckStage: stuckStage, silent: silent)
        }
        if queued > 0 {
            DispatchQueue.global(qos: .utility).async {
                let d = MemoArchiveQueue.drain()
                DispatchQueue.main.async { finish(d) }
            }
        } else {
            finish((ok: 0, failed: 0))
        }
    }

    /// 恢复界面之后的两种收尾：自动验收直接退出码，正常模式给一个能看懂的弹窗
    private func afterStallRecovery(drained: (ok: Int, failed: Int),
                                    stuckStage: String, silent: Double) {
        // 自动验收模式下没人点弹窗，直接给结论并退出。
        // 若这次是在验证「结果延后到达」，「延后到达」本身就是预期，不能在这里退出。
        if AutoUI.memoFile != nil {
            if ProcessInfo.processInfo.environment["OBSIDIANDROP_DELAY_DONE"] == nil {
                if drained.ok > 0 {
                    // 界面没收到结果，但文字靠队列补写成功——这不是失败，是兜底生效
                    AutoUI.finish(0, "看门狗恢复界面后由待归档队列补写成功 \(drained.ok) 条（卡在「\(stuckStage)」）")
                }
                AutoUI.finish(2, "看门狗已恢复界面：卡在「\(stuckStage)」\(Int(silent)) 秒无进展")
            }
            return
        }

        let a = NSAlert()
        a.messageText = "转写卡住了"
        let archiveNote = drained.ok > 0
            ? "这一轮的文字已经从待归档队列里补写进库（\(drained.ok) 条），录音也已处理。"
            : "如果稍后真的出了结果，笔记仍会自动写进库（界面会闪一下「灵感已归档」）。"
        a.informativeText = """
        界面已经恢复，可以继续用。停在「\(stuckStage)」已经 \(Int(silent)) 秒没有任何进展。

        \(archiveNote)

        排查用的日志在这里：
        \(DiagLog.path)
        """
        a.alertStyle = .warning
        a.addButton(withTitle: "打开日志")
        a.buttons.last?.tag = 1
        a.addButton(withTitle: "好")
        a.buttons.last?.tag = 0
        NSApp.activate(ignoringOtherApps: true)
        let resp = a.runModal()
        let idx = min(max(0, resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue),
                      a.buttons.count - 1)
        if a.buttons[idx].tag == 1 { openLogFile() }
    }

    private func openLogFile() {
        let url = URL(fileURLWithPath: DiagLog.path)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "（日志还没写出来）\n".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    /// 录音有段落没写进文件时，归档后必须明确告警（build 25）。
    ///
    /// 以前只把次数写进日志和「0 字诊断」，正常归档时用户看到的是「灵感已归档」，
    /// 完全不知道后面一截音频根本没录上。不限时长后一次录音可能几百 MB，
    /// 磁盘写满的概率不再可以忽略。
    private func warnIncompleteRecording(_ o: MemoOutcome) {
        guard o.incompleteRecording else { return }
        let n = o.writeErrors
        DiagLog.write("注意：本轮录音有 \(n) 段没写进文件，转写内容可能不完整")
        dropView.flash("录音有 \(n) 段没写进去", ok: false)
        let a = NSAlert()
        a.messageText = "录音没有完整写入"
        a.informativeText = "有 \(n) 段音频没写进文件（多半是磁盘空间不足或写入出错），"
            + "转写内容可能缺一截；已经识别出来的部分已入库。\n\n"
            + "录音文件：\(o.recordingPath.isEmpty ? "（未记录路径）" : o.recordingPath)"
        a.alertStyle = .warning
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func memoAlert(_ error: Error, saved: String = "") {
        let a = NSAlert()
        a.messageText = "录音失败"
        a.informativeText = error.localizedDescription
        a.alertStyle = .warning

        var settings: String? = nil
        var canCopy = false
        if let e = error as? MemoError {
            switch e {
            case .micDenied:
                settings = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .speechDenied:
                settings = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
            case .micUnavailable:
                // 走到这里说明设备和权限至少有一个不对劲，而错误文本里
                // 只是一行摘要。给一个「复制诊断信息」把五路探测结果整份带走，
                // 否则用户在另一台电脑上出问题，只能靠口述排查。
                canCopy = true
            case .audioUnreadable, .engineFailed:
                canCopy = true
            default:
                break
            }
        }
        if settings != nil {
            a.addButton(withTitle: "打开设置")
            a.buttons.last?.tag = 1
        }
        if canCopy {
            a.addButton(withTitle: "复制诊断信息")
            a.buttons.last?.tag = 2
        }
        // 录音已经落盘：给一个直达入口，比让用户照着路径去找有用得多
        if !saved.isEmpty {
            a.addButton(withTitle: "在访达中显示")
            a.buttons.last?.tag = 3
        }
        a.addButton(withTitle: "好")
        a.buttons.last?.tag = 0

        NSApp.activate(ignoringOtherApps: true)
        let resp = a.runModal()
        let idx = min(max(0, resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue),
                      a.buttons.count - 1)
        switch a.buttons[idx].tag {
        case 1:
            if let s = settings, let u = URL(string: s) { NSWorkspace.shared.open(u) }
        case 2:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(AudioProbe.report(), forType: .string)
        case 3:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: saved)])
        default:
            break
        }
    }

    // 投放
    private func handleDrop(_ urls: [URL]) {
        // 1.7.0：取文 / 压缩 / AI / 附件复制全部移出主线程，12 秒预算也不该卡住菜单栏。
        let target = lastTarget
        let vault = Cfg.vault
        dropView.renderDropActivity(true)
        DispatchQueue.global(qos: .userInitiated).async {
            // A7.4：SceneRouter.classify 会读文件属性（网络盘/坏挂载可能很慢），
            // 整批分类必须和 Filer 一起待在后台，不能卡菜单栏。
            let batch = AIBatchBudget(cap: AIConfigStore.config.effectiveBudget)
            let contexts = urls.map {
                ArchiveContext(source: "drop", scene: SceneRouter.classify(file: $0),
                               target: target, sourceURL: $0, batchBudget: batch)
            }
            let report: BatchReport
            do {
                report = try Filer(vault: vault).file(urls, target: target, contexts: contexts)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.dropView.renderDropActivity(false)
                    self.failArchive(error)
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dropView.renderDropActivity(false)
                self.finishDrop(report, target: target, contexts: contexts)
            }
        }
    }

    private func failArchive(_ error: Error) {
        dropView.flash("失败", ok: false)
        let a = NSAlert()
        a.messageText = "归档失败"
        a.informativeText = error.localizedDescription
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func finishDrop(_ report: BatchReport, target: String,
                            contexts: [ArchiveContext]) {
        let lastTarget = target
            // 逐文件埋点。以前一批只记一条 + count 加权，导致「成功率」按事件算、
            // 「总数」按文件算——部分失败的一批会既夸大失败又低估成功。
            // 只记「投了几次、成没成、到哪个目标（哈希）」，文件名与内容都不落。
            for o in report.outcomes {
                let ev = MetricEvent(kind: "drop", ok: true, target: lastTarget,
                                     noteRel: o.noteRel, source: "panel",
                                     captureId: o.captureId, ai: o.aiState.rawValue)
                MetricsStore.shared.record(ev)
                if !o.noteRel.isEmpty {
                    MetricNoteMap.remember(noteId: ev.noteId, rel: o.noteRel)
                }
            }
            for f in report.failures {
                let cap = contexts.first(where: { $0.sourceURL?.path == f.source })?.captureId
                    ?? UUID().uuidString
                MetricsStore.shared.record(MetricEvent(
                    kind: "drop", ok: false, target: lastTarget, source: "panel",
                    captureId: cap, failReason: f.reason))
            }
            if report.outcomes.isEmpty {
                // 全部失败：直接给出第一条原因，避免只闪一下「失败」
                let reason = report.failures.first?.reason ?? "未知原因"
                dropView.flash("失败", ok: false)
                let a = NSAlert()
                a.messageText = "归档失败"
                a.informativeText = reason
                a.alertStyle = .warning
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
                return
            }
            if report.partial {
                dropView.flash("成功 \(report.outcomes.count)，失败 \(report.failures.count)", ok: false)
                let a = NSAlert()
                a.messageText = "部分文件未归档"
                a.informativeText = report.failures
                    .map { "\(($0.source as NSString).lastPathComponent)：\($0.reason)" }
                    .joined(separator: "\n")
                a.alertStyle = .warning
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
            } else {
                let skipped = report.outcomes.filter { $0.aiState == .skipped }.count
                let msg = report.outcomes.count == 1 ? "已归档 1 个" : "已归档 \(report.outcomes.count) 个"
                // AI 跳过但笔记写成功，绝不能报「归档失败」
                dropView.flash(skipped > 0 ? msg + "（AI 跳过）" : msg, ok: true)
            }
            dropView.renderBatch(success: report.outcomes.count,
                                 failed: report.failures.count)
            NSLog("ObsidianDrop: \(report.outcomes.map { $0.fileRel }.joined(separator: ", "))")
            if UserDefaults.standard.bool(forKey: "autoOpenNote"), let first = report.outcomes.first {
                openNote(rel: first.noteRel)
            }
    }
}

// MARK: - 灵感回调

extension AppDelegate: MemoSink {
    /// 进度 / 音量：**轮次**要一致，且本轮已收尾就不再画。
    ///
    /// 1.3.12 修的头号问题：收尾阶段后台每 0.3 秒推一条进度，`memoDone` 又要写笔记，
    /// 最后那条进度常常晚于它执行——界面被重新画成「收尾中」，之后再无事件。
    ///
    /// 1.3.13 补的是**可观测性**：上一版丢弃是静默 return，日志里一个字都没有，
    /// 于是「后台没交上来」和「交上来了但被拦掉」完全无法区分。现在每种拒绝都留原因。
    private func acceptProgress(run: Int, _ what: String) -> Bool {
        if run != memoRunID {
            DiagLog.round(run, "丢弃\(what)：轮次不符（当前 run \(memoRunID)）")
            return false
        }
        if memoState == .idle {
            DiagLog.round(run, "丢弃\(what)：本轮已收尾（界面已回空闲）")
            return false
        }
        return true
    }

    /// 结果不再有「丢弃」这一说——轮次不符时转补归档，见 `memoDone`。

    /// 记一笔「本轮有事件」。看门狗据此把静默计时清零。
    private func touch(_ note: String) {
        lastMemoEventAt = Date()
        memoStageNote = note
        memoStallWarnedAt = 0
    }

    func memoPhase(_ phase: MemoPhase, note: String, run: Int) {
        guard acceptProgress(run: run, "阶段切换") else { return }
        let before = memoState.text
        switch phase {
        case .preparing:
            memoState = .preparing
            touch("准备：\(note)")
            dropView.renderMemo(.preparing(note), partial: "")
        case .recording:
            memoState = .recording
            memoStartedAt = Date()
            touch("录音中")
            dropView.renderMemo(.recording(0, 0), partial: lastPartial)
            startMemoTimer()
        case .transcribing:
            memoState = .transcribing
            stopMemoTimer()
            touch("转写：\(note)")
            dropView.renderMemo(.transcribing(.preparing(note)), partial: lastPartial)
        }
        DiagLog.round(run, "状态 \(before) → \(memoState.text)｜\(note.isEmpty ? "-" : note)")
        rebuildMenu()
    }

    /// 转写进度（准备 / 识别 / 收尾共用）
    ///
    /// 一律走 `.transcribing` 渲染，包括「准备」阶段：录音结束之后，
    /// 准备模型/引擎已经属于转写的一部分。原来这里把 `.preparing` 渲染成
    /// 「准备中…（按钮=取消）」，而那时录音会话已经结束，点「取消」什么也取消不了，
    /// 后台还在转，最后照样弹出一条笔记——界面在骗人。
    func memoProgress(_ progress: TranscribeProgress, run: Int) {
        guard acceptProgress(run: run, "进度") else { return }
        memoState = .transcribing
        stopMemoTimer()
        // 识别刚开始时构造的进度对象 stageTitle 是空的（只有 headline），
        // 直接在日志里拼会写出「进度 ｜…」这种看不出阶段的空标题。
        let stageName = progress.stageTitle.isEmpty
            ? (progress.headline.isEmpty ? "处理中" : progress.headline)
            : progress.stageTitle
        touch("\(stageName)：\(progress.detail.isEmpty ? progress.headline : progress.detail)")
        dropView.renderMemo(.transcribing(progress), partial: lastPartial)
        // 进度 0.3~0.4 秒一条，逐条写日志会把文件刷满 500 KB 只看得到进度。
        // 阶段变化必写，同阶段内最多每 3 秒写一条。
        let stageChanged = progress.stage != lastMemoStage
        if stageChanged || Date().timeIntervalSince(memoProgressLoggedAt) > 3 {
            lastMemoStage = progress.stage
            memoProgressLoggedAt = Date()
            let body = progress.detail.isEmpty
                ? (stageName == progress.headline ? "" : progress.headline)
                : progress.detail
            DiagLog.round(run, body.isEmpty ? "进度 \(stageName)" : "进度 \(stageName)｜\(body)")
        }
        rebuildMenu()
    }

    func memoLevel(_ level: Float, run: Int) {
        // 音量每秒来十几次，这里的拒绝**不写日志**（会把日志刷爆），
        // 只保证接受时把心跳时间推上去。
        guard run == memoRunID, memoState == .recording else { return }
        touch("录音中")

        // 录音开始 3 秒还一点声音都没收到，先提醒一次。
        // 这是「录了半天结果没字」最常见的原因：输入设备选错、输入音量被拉到 0、
        // 或者 MacBook 上外接耳机把内置麦克风顶掉了。早点说，别等转写完再猜。
        if level > 0.02 { memoSoundSeen = true }
        if !memoSoundSeen, !didWarnNoSound,
           let started = memoStartedAt, Date().timeIntervalSince(started) > 3 {
            didWarnNoSound = true
            dropView.flash("没听到声音，检查输入设备", ok: false)
        }

        let now = Date()
        guard now.timeIntervalSince(lastLevelPaint) > 0.1 else { return }
        lastLevelPaint = now
        lastLevel = level
        let elapsed = memoStartedAt.map { now.timeIntervalSince($0) } ?? 0
        dropView.renderMemo(.recording(elapsed, level), partial: lastPartial)
    }

    func memoPartial(_ text: String, run: Int) {
        guard run == memoRunID, memoState == .recording else { return }
        lastPartial = text
        let elapsed = memoStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        dropView.renderMemo(.recording(elapsed, lastLevel), partial: text)
    }

    func memoDone(text: String, duration: TimeInterval, outcome: MemoOutcome, error: Error?, run: Int) {
        // **到达就先记一笔**，在过闸之前。
        // 上一版是先过闸再写日志：一旦被拦掉，日志里连「结果回来了」都看不出来，
        // 现场表现就是永久停在「收尾中」，而原因可能在后台、也可能在闸门——无从判断。
        DiagLog.round(run, "收到结果：\(text.count) 字，时长 \(String(format: "%.1f", duration))s，"
                      + "来源 \(outcome.fromFile ? "文件" : "录音")，"
                      + (error.map { "错误 \($0.localizedDescription)" } ?? "正常")
                      + "｜界面 \(memoState.text)，当前 run \(memoRunID)")
        // 轮次不符不再「丢弃」。
        //
        // 看门狗恢复界面之后，用户完全可能马上开始新的一轮，`memoRunID` 就变了；
        // 而上一轮的结果**已经落盘**，用当时冻结的目标补写就行，没有理由扔。
        // 1.3.13 的 `acceptDone` 只比编号，一旦编号变了这段文字就彻底没人管了——
        // 那正是「结果回来了但什么都没发生」的另一条隐藏路径。
        if !MemoGate.acceptsDone(run: run, current: memoRunID) {
            DiagLog.round(run, "结果轮次不符（当前 run \(memoRunID)）：不画界面，转补归档")
            if !outcome.pendingID.isEmpty {
                Task.detached(priority: .utility) { _ = MemoArchiveQueue.drain() }
            }
            return
        }
        let wasRecovered = memoStallRecovered
        stopWatchdog()
        stopMemoTimer()
        memoSession = nil
        memoState = .idle
        memoStartedAt = nil
        lastLevel = 0
        rebuildMenu()
        defer { lastPartial = "" }
        if wasRecovered {
            DiagLog.round(run, "结果迟到送达（看门狗已恢复过界面），照常归档，内容不丢")
        }

        if let error {
            DiagLog.round(run, "本轮失败：\(error.localizedDescription)")
            dropView.renderMemo(.idle, partial: "")
            dropView.flash(memoFromFile ? "转写失败" : "录音失败", ok: false)
            AutoUI.finish(1, "失败：\(error.localizedDescription)")
            memoAlert(error, saved: outcome.recordingPath)
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard duration >= 0.6 else {
            DiagLog.round(run, "音频只有 \(String(format: "%.1f", duration))s，不生成笔记")
            dropView.renderMemo(.idle, partial: "")
            dropView.flash("太短了", ok: false)
            AutoUI.finish(1, "失败：音频太短（\(String(format: "%.1f", duration))s）")
            return
        }
        guard !trimmed.isEmpty else {
            DiagLog.round(run, "转写结果为空：录音 \(Memo.clock(outcome.recorded))，"
                          + "送入 \(Memo.clock(outcome.fed))，峰值 \(Int(outcome.peak * 100))%，格式失败 \(outcome.broken)")
            // 0 字不能只闪一句「没听清」——那等于什么都没说。
            // 把「录到多少音频、音量多大、为什么可能是空」讲清楚，
            // 用户自己就能判断是设备问题还是设置问题。
            dropView.renderMemo(.idle, partial: "")
            dropView.flash("没识别出文字", ok: false)
            AutoUI.finish(1, "失败：转写结果为空")
            let a = NSAlert()
            a.messageText = outcome.fromFile ? "这个文件里没有识别出语音" : "听到了声音，但没转出文字"
            a.informativeText = outcome.fromFile
                ? "音频时长 \(Memo.clock(outcome.recorded))，一个字都没识别出来。\n\n" + outcome.diagnosis
                : "录音 \(Memo.clock(outcome.recorded))，送入识别 \(Memo.clock(outcome.fed))，音量峰值 \(Int(outcome.peak * 100))%。\n\n" + outcome.diagnosis
            a.alertStyle = .warning
            a.addButton(withTitle: "复制诊断信息")
            a.buttons.last?.tag = 1
            if !outcome.recordingPath.isEmpty {
                a.addButton(withTitle: "在访达中显示录音")
                a.buttons.last?.tag = 2
            }
            a.addButton(withTitle: "好")
            a.buttons.last?.tag = 0
            NSApp.activate(ignoringOtherApps: true)
            let resp = a.runModal()
            let idx = min(max(0, resp.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue),
                          a.buttons.count - 1)
            if a.buttons[idx].tag == 2 {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: outcome.recordingPath)])
            } else if a.buttons[idx].tag == 1 {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString("""
                ObsidianDrop 转写诊断
                时间：\(ISO8601DateFormatter().string(from: Date())) |
                机型：\(AudioProbe.machineModel()) |
                系统：\(ProcessInfo.processInfo.operatingSystemVersionString) |
                语言包：\(Memo.localeName) |
                录音时长：\(Memo.clock(outcome.recorded)) |
                送入引擎：\(String(format: "%.2f", outcome.fed)) 秒 |
                音量峰值：\(Int(outcome.peak * 100))% |
                格式转换失败：\(outcome.broken ? "是" : "否") |
                录音文件：\(outcome.recordingPath.isEmpty ? "已删除" : outcome.recordingPath) |
                识别字数：\(outcome.chars)
                """, forType: .string)
            }
            return
        }

        // 写库放到后台：库在 iCloud 上、或附件较大时这一步要几秒。
        // 原来它是同步跑在主线程、而且发生在界面重绘**之前**——写库期间窗口
        // 既不响应也还显示着「收尾中」，和转写卡死看起来一模一样。
        dropView.renderMemo(.transcribing(.saving(trimmed.count)), partial: "")
        let engine = "DictationTranscriber / \(Memo.localeName)"
        let autoOpen = UserDefaults.standard.bool(forKey: "autoOpenNote")

        // 三种情况必须分开处理，混在一起就会写出重复笔记：
        //   ① 队列里还有这条 → 正常归档；
        //   ② 有编号但队列里已经没了 → **已经被补归档写过了**（看门狗/启动时的 drain），
        //      只能视为成功，绝不能再落一条新的（1.3.14 的验收就是在这里抓到重复笔记的）；
        //   ③ 根本没有编号 → 文件入口或落盘失败，这里补写一条再归档。
        if !outcome.pendingID.isEmpty, PendingStore.load(id: outcome.pendingID) == nil {
            DiagLog.round(run, "这条已被补归档写过（pending \(outcome.pendingID) 已消失），不重复写")
            dropView.renderMemo(.idle, partial: "")
            dropView.flash("灵感已归档", ok: true)
            warnIncompleteRecording(outcome)
            AutoUI.finish(0, "OK 已由补归档写入：\(trimmed.count) 字")
            return
        }

        let item: PendingMemo
        if !outcome.pendingID.isEmpty, let m = PendingStore.load(id: outcome.pendingID) {
            item = m
        } else {
            let m = PendingMemo(id: UUID().uuidString,
                                text: trimmed,
                                duration: duration,
                                target: memoTarget,
                                vaultPath: Cfg.vault.path,
                                engine: engine,
                                // 文件入口的音频是用户自己的文件，绝不能由我们删
                                audioPath: memoFromFile ? "" : outcome.recordingPath,
                                source: memoFromFile ? "file" : "record",
                                createdAt: Date(),
                                attempts: 0)
            item = m
            if (try? PendingStore.enqueue(m)) == nil {
                DiagLog.round(run, "待归档落盘失败，直接归档（不经过队列，仍先写笔记后删录音）")
            }
        }
        DiagLog.round(run, "进入归档：\(trimmed.count) 字 → 目标「\(item.target)」，库 \(item.vault.path)")
        let archiveStart = Date()

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let out = try MemoArchiveQueue.archive(item)
                if let out {
                    DiagLog.round(run, "归档完成：\(String(format: "%.2f", Date().timeIntervalSince(archiveStart)))s → \(out.noteRel)")
                } else {
                    DiagLog.round(run, "这条已由补归档写过了（pending 已消失），不重复写笔记")
                }
                await MainActor.run {
                    // 归档期间可能已经开始了新的一轮，别再改界面
                    guard let self else { return }
                    guard run == self.memoRunID else {
                        DiagLog.round(run, "归档完成但轮次已变（当前 \(self.memoRunID)），不改界面")
                        return
                    }
                    self.dropView.renderMemo(.idle, partial: "")
                    self.dropView.flash("灵感已归档", ok: true)
                    self.warnIncompleteRecording(outcome)
                    if let out { NSLog("ObsidianDrop: 灵感 → \(out.noteRel)") }
                    if autoOpen, let out { self.openNote(rel: out.noteRel) }
                    AutoUI.finish(0, "OK 界面已复位并归档：\(out?.noteRel ?? "（已由其他路径归档）")")
                }
            } catch {
                DiagLog.round(run, "归档失败：\(String(format: "%.2f", Date().timeIntervalSince(archiveStart)))s ｜ \(error.localizedDescription)"
                              + "（文字仍在待归档队列 \(item.id)，录音保留）")
                MetricsStore.shared.record(MetricEvent(
                    kind: "memo", ok: false, target: item.target, source: "ui",
                    failReason: error.localizedDescription, ai: item.ai.rawValue))
                await MainActor.run {
                    guard let self else { return }
                    guard run == self.memoRunID else { return }
                    self.dropView.renderMemo(.idle, partial: "")
                    self.dropView.flash("归档失败", ok: false)
                    AutoUI.finish(1, "失败：归档失败 \(error.localizedDescription)")
                    let a = NSAlert()
                    a.messageText = "已经转成文字，但没写进笔记"
                    a.informativeText = error.localizedDescription
                        + "\n\n文字已经存进待归档队列，下次启动会自动再试一次。"
                        + "\n现在也可以直接复制走。"
                    a.alertStyle = .warning
                    a.addButton(withTitle: "复制文本")
                    a.buttons.last?.tag = 1
                    a.addButton(withTitle: "好")
                    a.buttons.last?.tag = 0
                    NSApp.activate(ignoringOtherApps: true)
                    let resp = a.runModal()
                    if resp.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(trimmed, forType: .string)
                    }
                }
            }
        }
    }
}

// MARK: - SMAppService 桥接（避免全局 import）

enum SMAppServiceBridge {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// 返回 nil 表示成功，否则是错误说明
    static func toggle() -> String? {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
                return nil
            } catch {
                return "\(error.localizedDescription)\n\n可改用：系统设置 → 通用 → 登录项，手动添加。"
            }
        }
        return "系统版本过低"
    }
}

// MARK: - 自检（--self-test）

/// 回归自检：不启动 UI、不碰真实库，全部在临时目录里完成。
/// 覆盖路径穿越、绝对路径、符号链接逃逸、标签生成、批量部分成功与附件提示文案。
/// 自检用的接收端：只验证「投递是否到达」，其他回调一律空实现。
private final class DeliveryProbe: MemoSink {
    var got = 0
    func memoPhase(_ phase: MemoPhase, note: String, run: Int) {}
    func memoProgress(_ progress: TranscribeProgress, run: Int) {}
    func memoLevel(_ level: Float, run: Int) {}
    func memoPartial(_ text: String, run: Int) {}
    func memoDone(text: String, duration: TimeInterval, outcome: MemoOutcome,
                  error: Error?, run: Int) {}
}

enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            passed += 1
            print("PASS  \(name)")
        } else {
            failed += 1
            print("FAIL  \(name)\(detail.isEmpty ? "" : "  → \(detail)")")
        }
    }

    private static func expectReject(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            check(name, false, "本应拒绝但通过了")
        } catch {
            check(name, true)
        }
    }

    static func run() -> Int32 {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("obsidiandrop-selftest-\(UUID().uuidString)")
        let vault = root.appendingPathComponent("vault")
        defer { try? fm.removeItem(at: root) }

        do {
            try fm.createDirectory(at: vault, withIntermediateDirectories: true)
            for d in ["00-收件箱", "10-项目/验收项目", "20-领域", "30-资源"] {
                try fm.createDirectory(at: vault.appendingPathComponent(d), withIntermediateDirectories: true)
            }
        } catch {
            print("FAIL  准备测试库：\(error.localizedDescription)")
            return 1
        }

        // 1. 路径守卫：应当拒绝的写法
        for bad in ["../escape", "../../etc", "/tmp/escape", "~", "~/x",
                    "10-项目/../../escape", "..", "", "  ", "00-收件箱/../../out"] {
            expectReject("拒绝非法目标「\(bad)」") {
                _ = try VaultGuard.resolve(target: bad, vault: vault)
            }
        }
        expectReject("拒绝库根目录本身") {
            _ = try VaultGuard.resolve(target: ".", vault: vault)
        }

        // 2. 路径守卫：应当接受的写法（含 . 与多余分隔符）
        for good in ["00-收件箱", "10-项目/验收项目", "20-领域", "./20-领域", "20-领域/"] {
            do {
                _ = try VaultGuard.resolve(target: good, vault: vault)
                check("接受合法目标「\(good)」", true)
            } catch {
                check("接受合法目标「\(good)」", false, error.localizedDescription)
            }
        }

        // 3. 符号链接逃逸：库内软链指向库外目录，必须被拒
        let outside = root.appendingPathComponent("outside")
        let link = vault.appendingPathComponent("50-软链")
        do {
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: outside)
            expectReject("拒绝符号链接指向库外") {
                _ = try VaultGuard.resolve(target: "50-软链", vault: vault)
            }
        } catch {
            check("准备符号链接用例", false, error.localizedDescription)
        }

        // 3b. 附件目录本身是软链指向库外：必须整体拒绝
        // 否则会出现「笔记在库内、附件跑到库外」的分裂状态（比 --target 逃逸更隐蔽）
        let symVault = root.appendingPathComponent("vault-sym-attach")
        let symOut = root.appendingPathComponent("outside-attach")
        do {
            try fm.createDirectory(at: symVault.appendingPathComponent("00-收件箱"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: symOut, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: symVault.appendingPathComponent("附件"),
                                      withDestinationURL: symOut)
            let src = root.appendingPathComponent("sym-src.txt")
            try? "x".write(to: src, atomically: true, encoding: .utf8)
            do {
                _ = try Filer(vault: symVault).file([src], target: "00-收件箱")
                check("附件目录软链指向库外被拒绝", false, "本应拒绝但通过了")
            } catch {
                check("附件目录软链指向库外被拒绝", true)
            }
            let leaked = (try? fm.subpathsOfDirectory(atPath: symOut.path)) ?? []
            check("软链附件目录未写入库外", leaked.isEmpty, leaked.joined(separator: ","))
        } catch {
            check("准备附件软链用例", false, error.localizedDescription)
        }

        // 3c. 项目「文档」目录是软链指向库外：同样拒绝
        let projVault = root.appendingPathComponent("vault-sym-doc")
        let projOut = root.appendingPathComponent("outside-doc")
        do {
            try fm.createDirectory(at: projVault.appendingPathComponent("10-项目/P1"),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: projOut, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: projVault.appendingPathComponent("10-项目/P1/文档"),
                                      withDestinationURL: projOut)
            let src = root.appendingPathComponent("sym-src2.txt")
            try? "y".write(to: src, atomically: true, encoding: .utf8)
            do {
                _ = try Filer(vault: projVault).file([src], target: "10-项目/P1")
                check("项目文档软链指向库外被拒绝", false, "本应拒绝但通过了")
            } catch {
                check("项目文档软链指向库外被拒绝", true)
            }
            let leaked = (try? fm.subpathsOfDirectory(atPath: projOut.path)) ?? []
            check("软链文档目录未写入库外", leaked.isEmpty, leaked.joined(separator: ","))
        } catch {
            check("准备项目文档软链用例", false, error.localizedDescription)
        }

        // 3d. 源文件是软链：必须归档真实内容的独立副本，而不是把链接本身放进库里
        let linkVault = root.appendingPathComponent("vault-link-src")
        do {
            try fm.createDirectory(at: linkVault.appendingPathComponent("00-收件箱"),
                                   withIntermediateDirectories: true)
            let realDir = root.appendingPathComponent("realsrc")
            try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
            let real = realDir.appendingPathComponent("real.txt")
            try "real-content".write(to: real, atomically: true, encoding: .utf8)
            let srcLink = root.appendingPathComponent("src-link.txt")
            try fm.createSymbolicLink(at: srcLink, withDestinationURL: real)

            let report = try Filer(vault: linkVault).file([srcLink], target: "00-收件箱")
            check("软链源归档成功", report.outcomes.count == 1,
                  report.failures.first?.reason ?? "")
            if let o = report.outcomes.first {
                let copied = linkVault.appendingPathComponent(o.fileRel)
                let isLink = (try? fm.destinationOfSymbolicLink(atPath: copied.path)) != nil
                check("库内产物不是软链", fm.fileExists(atPath: copied.path) && !isLink)
                check("副本内容是真实文件内容",
                      (try? String(contentsOf: copied, encoding: .utf8)) == "real-content")
                check("笔记里的文件字段是库内相对路径", o.fileRel.hasPrefix("附件/"), o.fileRel)
            }
        } catch {
            check("准备源软链用例", false, error.localizedDescription)
        }

        // 3e. 笔记不可写：该项应判失败，且不得在库里留下孤儿附件
        let noWrite = root.appendingPathComponent("vault-nowrite")
        do {
            let notes = noWrite.appendingPathComponent("00-收件箱")
            try fm.createDirectory(at: notes, withIntermediateDirectories: true)
            let src = root.appendingPathComponent("nowrite-src.txt")
            try "z".write(to: src, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: notes.path)
            let report = try Filer(vault: noWrite).file([src], target: "00-收件箱")
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: notes.path)
            check("笔记不可写时该项被判失败", report.failures.count == 1 && report.outcomes.isEmpty)
            let leftovers = ((try? fm.subpathsOfDirectory(atPath: noWrite.path)) ?? [])
                .filter { rel in
                    var d: ObjCBool = false
                    fm.fileExists(atPath: noWrite.appendingPathComponent(rel).path, isDirectory: &d)
                    return !d.boolValue
                }
            check("失败后库内无孤儿附件", leftovers.isEmpty, leftovers.joined(separator: ","))
        } catch {
            try? fm.setAttributes([.posixPermissions: 0o700],
                                  ofItemAtPath: noWrite.appendingPathComponent("00-收件箱").path)
            check("准备笔记不可写用例", false, error.localizedDescription)
        }

        // 4. 标签：与目标一致，不再一律「收件箱」
        check("收件箱标签", ArchiveTarget(rel: "00-收件箱", name: "").tag == "收件箱")
        check("项目标签", ArchiveTarget(rel: "10-项目/验收项目", name: "").tag == "项目")
        check("领域标签", ArchiveTarget(rel: "20-领域", name: "").tag == "领域")
        check("资源标签", ArchiveTarget(rel: "30-资源", name: "").tag == "资源")
        check("自定义标签去编号", ArchiveTarget(rel: "40-归档", name: "").tag == "归档")

        // 4b. 目标写法规范化：`./` 前缀与首尾空格不能改变目标类别
        check("规范化去掉 ./ 前缀", VaultGuard.normalize("./20-领域") == "20-领域")
        check("规范化去掉首尾空格", VaultGuard.normalize(" 20-领域 ") == "20-领域")
        check("规范化去掉重复分隔符", VaultGuard.normalize("20-领域//") == "20-领域")
        check("规范化后仍是项目目标",
              ArchiveTarget(rel: VaultGuard.normalize("./10-项目/验收项目"), name: "").kind == .project)

        let monthFmt = DateFormatter()
        monthFmt.locale = Locale(identifier: "en_US_POSIX")
        monthFmt.dateFormat = "yyyy-MM"
        let month = monthFmt.string(from: Date())

        // 5. 批量部分成功：一个存在 + 一个不存在
        let goodFile = root.appendingPathComponent("good.txt")
        let missingFile = root.appendingPathComponent("missing.txt")
        try? "hello".write(to: goodFile, atomically: true, encoding: .utf8)

        do {
            let report = try Filer(vault: vault).file([goodFile, missingFile], target: "00-收件箱")
            check("批量：成功项仍被保留", report.outcomes.count == 1, "\(report.outcomes.count)")
            check("批量：失败项被记录", report.failures.count == 1, "\(report.failures.count)")
            check("批量：判定为部分成功", report.partial)
            check("批量：不算全部成功", !report.allSucceeded)

            if let noteRel = report.outcomes.first?.noteRel {
                if let text = try? String(contentsOf: vault.appendingPathComponent(noteRel), encoding: .utf8) {
                    check("提示含实际月份目录", text.contains("附件/\(month)/"), text)
                    check("收件箱笔记标签正确", text.contains("- \"收件箱\""), text)
                } else {
                    check("读取收件箱笔记", false)
                }
            } else {
                check("批量：产出笔记路径", false)
            }
        } catch {
            check("批量归档执行", false, error.localizedDescription)
        }

        // 6. 非收件箱目标：标签不带「收件箱」，附件进项目文档目录
        do {
            let report = try Filer(vault: vault).file([goodFile], target: "10-项目/验收项目")
            if let o = report.outcomes.first {
                check("项目附件进「文档/」", o.fileRel.hasPrefix("10-项目/验收项目/文档/"), o.fileRel)
                if let text = try? String(contentsOf: vault.appendingPathComponent(o.noteRel), encoding: .utf8) {
                    check("项目笔记不再标成收件箱", !text.contains("收件箱"), text)
                    check("项目笔记标签为「项目」", text.contains("- \"项目\""), text)
                } else {
                    check("读取项目笔记", false)
                }
            } else {
                check("项目归档产出", false)
            }
        } catch {
            check("项目归档执行", false, error.localizedDescription)
        }

        // 6b. 带 `./` 前缀或首尾空格的项目目标，仍须按项目处理（附件进 <项目>/文档）
        do {
            let report = try Filer(vault: vault).file([goodFile], target: "./10-项目/验收项目")
            if let o = report.outcomes.first {
                check("规范化目标仍进项目文档目录",
                      o.fileRel.hasPrefix("10-项目/验收项目/文档/"), o.fileRel)
                if let text = try? String(contentsOf: vault.appendingPathComponent(o.noteRel),
                                          encoding: .utf8) {
                    check("规范化目标标签仍为「项目」", text.contains("- \"项目\""), text)
                }
            } else {
                check("规范化目标归档", false, report.failures.first?.reason ?? "")
            }
        } catch {
            check("规范化目标归档", false, error.localizedDescription)
        }

        // 7. 目标非法时不应产生任何文件
        do {
            _ = try Filer(vault: vault).file([goodFile], target: "../escape")
            check("非法目标被拒绝", false, "未抛错")
        } catch {
            check("非法目标被拒绝", true)
            check("非法目标未在库外落盘", !fm.fileExists(atPath: root.appendingPathComponent("escape").path))
        }

        // 8. 运行中新建的项目能被扫描到（QA-004 的数据来源）
        do {
            try fm.createDirectory(at: vault.appendingPathComponent("10-项目/运行中新建"),
                                   withIntermediateDirectories: true)
            let rels = Targets.all(vault: vault).map { $0.rel }
            check("新项目可被 Targets.all 扫到", rels.contains("10-项目/运行中新建"), rels.joined(separator: ","))
        } catch {
            check("准备新项目用例", false, error.localizedDescription)
        }

        // 9. 音频输入探测与错误文案
        //    回归背景：1.3.8 及以前只用 DiscoverySession(deviceTypes: []) 判断
        //    「有没有麦克风」，空数组在部分系统上被解释成「不匹配任何类型」，
        //    于是有内置麦克风的 MacBook Air 也被判成没有输入设备，且文案写死
        //    「Mac mini 没有内置麦克风」——用户以为装错了机器。
        do {
            let p = AudioProbe.run()
            check("音频探测可执行", !p.detail.isEmpty, p.detail)
            check("usable 与各路结果自洽",
                  p.usable == (!p.captured.isEmpty || !p.coreAudio.isEmpty || p.sampleRate > 0),
                  p.detail)

            let advice = Memo.noMicAdvice(p)
            check("无设备文案不写死机型", !advice.contains("Mac mini"), advice)
            check("无设备文案带实测结果",
                  advice.contains("AVFoundation 设备") && advice.contains("麦克风授权"), advice)
            check("无设备文案指向诊断命令", advice.contains("--audio-check"))

            let rep = AudioProbe.report()
            check("诊断报告含机型与结论",
                  rep.contains("机型：") && rep.contains("结论："), rep)
            check("诊断报告列出两层设备来源",
                  rep.contains("CoreAudio 设备：") && rep.contains("AVFoundation 设备："), rep)
        }

        // 10. 转写进度与「0 字」释义（1.3.10）
        //     背景：转写出来是空的时候，原来只闪一句「没听清」，
        //     用户和开发者都分不清是没录到、没声音、格式坏了还是语言不对。
        do {
            check("人话时长：42 秒", Memo.humanDuration(42) == "42 秒", Memo.humanDuration(42))
            check("人话时长：3 分 12 秒", Memo.humanDuration(192) == "3 分 12 秒", Memo.humanDuration(192))
            check("人话时长：1 小时 02 分", Memo.humanDuration(3720) == "1 小时 02 分", Memo.humanDuration(3720))

            let a = TranscribeProgress.analyzing(processed: 30, total: 120, chars: 10)
            check("识别进度带百分比", a.headline.contains("25%"), a.headline)
            check("识别进度带字数", a.detail.contains("10 字"), a.detail)
            let pct = a.percent ?? -1
            check("百分比数值正确", pct > 0.24 && pct < 0.26, "\(pct)")

            let f = TranscribeProgress.finishing(processed: 120, total: 120, chars: 88, waited: 5)
            check("收尾阶段标记正确", f.stage == .finishing)
            check("收尾进度显示已等时长", f.headline.contains("0:05"), f.headline)

            var o = MemoOutcome()
            o.recorded = 10
            o.fed = 0
            check("0 字释义：没收到音频", o.diagnosis.contains("几乎没收到音频"), o.diagnosis)
            o.fed = 10
            o.peak = 0
            check("0 字释义：全程没声音", o.diagnosis.contains("几乎没有声音"), o.diagnosis)
            o.peak = 0.5
            o.broken = true
            check("0 字释义：格式转换失败", o.diagnosis.contains("格式转换"), o.diagnosis)
            o.broken = false
            check("0 字释义：语言可能不匹配", o.diagnosis.contains("语言"), o.diagnosis)
            o.recordingPath = "/tmp/x.caf"
            check("0 字释义带上录音文件路径", o.diagnosis.contains("/tmp/x.caf"), o.diagnosis)
        }

        // 11. 录音落盘（1.3.11）
        //     背景：录音改成「先存文件、再按文件转写」之后，成败全压在这一层。
        //     这里用合成 buffer 走一遍写盘 → 回读，验证格式与时长都对得上。
        do {
            let dir = root.appendingPathComponent("recordings")
            do {
                let store = try RecordingStore(directory: dir)
                let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 48000, channels: 1, interleaved: false)!
                let chunk: AVAudioFrameCount = 4096
                let blocks = 117   // 117 * 4096 ≈ 479232 帧 ≈ 9.98 秒
                for i in 0..<blocks {
                    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk)!
                    buf.frameLength = chunk
                    if let p = buf.floatChannelData?[0] {
                        for j in 0..<Int(chunk) {
                            p[j] = sinf(Float(i * Int(chunk) + j) * 0.01) * 0.2
                        }
                    }
                    store.append(buf)
                }
                store.close()
                check("录音文件写入成功", FileManager.default.fileExists(atPath: store.url.path), store.url.path)
                check("录音写入无失败", store.writeErrors == 0, "\(store.writeErrors)")
                check("录音时长为 9.98 秒（关文件后仍可算）",
                      abs(store.seconds - 9.984) < 0.05, "\(store.seconds)")
                check("录音文件不是空的", store.sizeBytes > 100_000, "\(store.sizeBytes)")

                let back = try AVAudioFile(forReading: store.url)
                check("录音文件可回读且帧数一致",
                      abs(Double(back.length) - Double(blocks * Int(chunk))) < 1,
                      "\(back.length)")
                check("回读采样率一致", back.processingFormat.sampleRate == 48000,
                      "\(back.processingFormat.sampleRate)")

                // 关文件后再来一块：不能把文件重建/覆盖
                let late = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk)!
                late.frameLength = chunk
                store.append(late)
                let after = try AVAudioFile(forReading: store.url)
                check("关文件后不再写入", after.length == back.length, "\(after.length)")

                store.discard()
                check("丢弃后文件已删除",
                      !FileManager.default.fileExists(atPath: store.url.path))
            } catch {
                check("录音落盘用例", false, error.localizedDescription)
            }

            // 文件名带时间戳，同一目录连录两次不能互相覆盖
            do {
                let a = try RecordingStore(directory: dir)
                Thread.sleep(forTimeInterval: 1.05)
                let b = try RecordingStore(directory: dir)
                check("两次录音文件名不冲突", a.url != b.url,
                      "\(a.url.lastPathComponent) / \(b.url.lastPathComponent)")
                a.discard(); b.discard()
            } catch {
                check("录音文件名用例", false, error.localizedDescription)
            }
        }

        // 12. 进度环语义（1.3.11）
        //     百分比从标题里挪到图标上的环里，标题必须只剩「在做什么」；
        //     收尾阶段不能给 100%（音频早送完了，给百分比会让人以为卡住）。
        do {
            let a = TranscribeProgress.analyzing(processed: 30, total: 120, chars: 10)
            check("标题不含百分比", !a.stageTitle.contains("%"), a.stageTitle)
            check("标题只写状态", a.stageTitle == "转写中", a.stageTitle)
            check("百分比数据仍保留给进度环", a.percent != nil, "\(String(describing: a.percent))")
            let f = TranscribeProgress.finishing(processed: 120, total: 120, chars: 88, waited: 5)
            check("收尾阶段不给百分比（改转圈）", f.percent == nil, "\(String(describing: f.percent))")
            check("收尾阶段标题正确", f.stageTitle == "收尾中", f.stageTitle)
            let p = TranscribeProgress.preparing("检查语音模型…")
            check("准备阶段标题正确", p.stageTitle == "准备中", p.stageTitle)
        }

        // 12b. 迟到回调的判据（1.3.12 / 1.3.13）
        //     这是「一直在转写收尾中」的直接原因：收尾阶段后台每 0.3 秒推一条进度，
        //     最后一条晚于 memoDone 执行，界面被画回收尾中且再无人更新。
        //     进度要同时管「轮次」和「是否已收尾」；结果只比轮次——
        //     看门狗可能已经把界面恢复成空闲，此时后台那一轮的结果不该被丢。
        do {
            check("同轮、未收尾 → 进度接受",
                  MemoGate.acceptsProgress(run: 3, current: 3, stateIsIdle: false))
            check("上一轮的进度 → 丢弃",
                  !MemoGate.acceptsProgress(run: 2, current: 3, stateIsIdle: false))
            check("本轮但已收尾 → 进度丢弃",
                  !MemoGate.acceptsProgress(run: 3, current: 3, stateIsIdle: true))
            check("未开始的进度 → 丢弃",
                  !MemoGate.acceptsProgress(run: 0, current: 0, stateIsIdle: true))
            check("同轮 → 结果接受", MemoGate.acceptsDone(run: 3, current: 3))
            check("上一轮的结果 → 丢弃", !MemoGate.acceptsDone(run: 2, current: 3))
            check("看门狗恢复后结果仍接受（内容不能丢）",
                  MemoGate.acceptsDone(run: 3, current: 3))
        }

        // 13. 电平计算（1.3.11）
        //     录音只靠电平判断「到底有没有声音」。原来只认 float32，
        //     老声卡/VoIP 设备给 int16 时电平恒为 0 → 误报「没听到声音」。
        if #available(macOS 26.0, *) {
            let f32 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                    channels: 1, interleaved: false)!
            let b32 = AVAudioPCMBuffer(pcmFormat: f32, frameCapacity: 1600)!
            b32.frameLength = 1600
            for i in 0..<1600 { b32.floatChannelData![0][i] = 0.3 * sinf(Float(i) * 0.1) }
            check("float32 输入能量非 0", SpeechRunner.level(b32) > 0.3,
                  "\(SpeechRunner.level(b32))")

            let i16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                    channels: 1, interleaved: false)!
            let b16 = AVAudioPCMBuffer(pcmFormat: i16, frameCapacity: 1600)!
            b16.frameLength = 1600
            for i in 0..<1600 { b16.int16ChannelData![0][i] = Int16(9000 * sinf(Float(i) * 0.1)) }
            check("int16 输入能量非 0（不再恒为 0）", SpeechRunner.level(b16) > 0.3,
                  "\(SpeechRunner.level(b16))")

            let quiet = AVAudioPCMBuffer(pcmFormat: f32, frameCapacity: 1600)!
            quiet.frameLength = 1600
            check("静音判为 0", SpeechRunner.level(quiet) < 0.02,
                  "\(SpeechRunner.level(quiet))")
        }

        // 14. 结果落盘与投递生命周期（1.3.14）
        //     1.3.13 的三条断点，一条比一条隐蔽：
        //     ① 投递闭包 `[weak self]` 弱引用会话，会话一释放结果就没了；
        //     ② 转写完先删录音、后投递，投递失败则文字和录音同时消失；
        //     ③ 只记总字数，判不出「没说几句」和「丢了一大半」。
        do {
            // ① 投递不依赖生产者存活
            let probe = DeliveryProbe()
            MemoDelivery.post(run: 7, what: "done", to: probe, logLag: false) { s, r in
                if r == 7 { (s as? DeliveryProbe)?.got += 1 }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            check("结果投递不依赖产生回调的对象存活", probe.got == 1, "\(probe.got)")

            // ② 落盘 → 读回 → 清理
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("od-pending-\(UUID().uuidString)")
            PendingStore.overrideDirectory = dir
            defer {
                PendingStore.overrideDirectory = nil
                try? FileManager.default.removeItem(at: dir)
            }
            let m = PendingMemo(id: UUID().uuidString, text: "第一句。第二句。", duration: 12.5,
                                target: "00-收件箱", vaultPath: "/tmp/vault",
                                engine: "test", audioPath: "/tmp/a.caf",
                                source: "record", createdAt: Date(), attempts: 0)
            let wrote = (try? PendingStore.enqueue(m)) != nil
            check("转写结果能原子落盘", wrote)
            let back = PendingStore.all()
            check("落盘后能原样读回", back.count == 1 && back.first?.text == m.text, "\(back.count) 条")
            check("目标与库一起冻结", back.first?.target == "00-收件箱"
                  && back.first?.vaultPath == "/tmp/vault",
                  "\(back.first?.target ?? "-")/\(back.first?.vaultPath ?? "-")")
            check("录音路径随结果一起留存", back.first?.audioPath == "/tmp/a.caf")
            // 半截 JSON 不能冒充一条有效结果
            try? "{\"id\":\"broken\"".write(to: dir.appendingPathComponent("junk.json"),
                                           atomically: true, encoding: .utf8)
            check("半截 JSON 被跳过", PendingStore.all().count == 1, "\(PendingStore.all().count)")
            PendingStore.remove(id: m.id)
            check("归档后能清掉", PendingStore.all().isEmpty)

            // ②.5 录音不限时长（build 23）：上限开关必须为空，且超过 1 小时能正确显示
            check("录音不设时长上限", Memo.maxSeconds == nil)
            var partial = MemoOutcome()
            partial.writeErrors = 3
            check("录音写失败会标记为不完整",
                  partial.incompleteRecording && !MemoOutcome().incompleteRecording)
            check("超过 1 小时显示 h:mm:ss",
                  Memo.clock(3661) == "1:01:01" && Memo.clock(7200) == "2:00:00",
                  "\(Memo.clock(3661)) / \(Memo.clock(7200))")
            check("1 小时以内仍是 m:ss",
                  Memo.clock(59) == "0:59" && Memo.clock(65) == "1:05" && Memo.clock(3599) == "59:59",
                  "\(Memo.clock(3599))")

            // ③ 覆盖率：文字盖住了音频的哪些段落
            if #available(macOS 26.0, *) {
                let box = SpeechRunner.TextBox()
                func span(_ a: Double, _ b: Double) -> CMTimeRange {
                    CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600),
                                end: CMTime(seconds: b, preferredTimescale: 600))
                }
                box.push("甲", isFinal: true, range: span(0, 10))
                box.push("乙", isFinal: true, range: span(10, 20))
                box.push("丙", isFinal: true, range: span(40, 50))
                let c = box.coverage(total: 60)
                check("覆盖率按区间并集算", abs(c.covered - 30) < 0.01, "\(c.covered)")
                check("最长空白算对", abs(c.maxGap - 20) < 0.01, "\(c.maxGap)")
                check("定稿段数正确", c.segments == 3 && box.parts.final == 3, "\(c.segments)")
                // 空白在中间（20..40）也要算进来，不能只看尾部
                let c2 = box.coverage(total: 50)
                check("尾部之外的空缺也计入", abs(c2.covered - 30) < 0.01, "\(c2.covered)")
            }
        }

        // ===== 1.3.16 下拉定位（纯函数，不建窗口）=====
        do {
            let vis = NSRect(x: 0, y: 0, width: 1440, height: 860)
            let size = PanelMetrics.dropdown
            let anchor = NSRect(x: 1200, y: 878, width: 24, height: 24)
            let f = dropdownFrame(anchor: anchor, visible: vis, size: size)
            check("下拉贴顶", abs(f.maxY - vis.maxY) < 1, NSStringFromRect(f))
            check("下拉不越右边界", f.maxX <= vis.maxX - 8, NSStringFromRect(f))
            check("下拉尺寸等于 PanelMetrics.dropdown",
                  f.width == PanelMetrics.dropdown.width && f.height == PanelMetrics.dropdown.height,
                  "\(f.size)")

            let negVis = NSRect(x: -1920, y: 0, width: 1920, height: 1055)
            let negAnchor = NSRect(x: -1900, y: 1078, width: 24, height: 24)
            let nf = dropdownFrame(anchor: negAnchor, visible: negVis, size: size)
            check("副屏负坐标仍在屏内", nf.minX >= negVis.minX && nf.maxX <= negVis.maxX,
                  NSStringFromRect(nf))

            let narrow = NSRect(x: 0, y: 0, width: 300, height: 700)
            let wf = dropdownFrame(anchor: NSRect(x: 250, y: 720, width: 24, height: 24),
                                   visible: narrow, size: size)
            check("窄屏裁宽度", wf.width <= narrow.width - 16, "\(wf.width)")

            let short = NSRect(x: 0, y: 0, width: 1440, height: 200)
            let hf = dropdownFrame(anchor: NSRect(x: 700, y: 220, width: 24, height: 24),
                                   visible: short, size: size)
            check("矮屏裁高度", hf.height <= short.height - 16 && hf.maxY <= short.maxY,
                  NSStringFromRect(hf))

            let nilF = dropdownFrame(anchor: nil, visible: vis, size: size)
            check("无锚点时顶部居中", abs(nilF.midX - vis.midX) < 1 && abs(nilF.maxY - vis.maxY) < 1,
                  NSStringFromRect(nilF))
        }

        // ===== 1.4.0 搜索 =====
        do {
            let sv = root.appendingPathComponent("searchvault")
            try? fm.createDirectory(at: sv.appendingPathComponent("30-资源"),
                                    withIntermediateDirectories: true)
            try? fm.createDirectory(at: sv.appendingPathComponent("10-项目/强强"),
                                    withIntermediateDirectories: true)
            try? fm.createDirectory(at: sv.appendingPathComponent(".obsidian"),
                                    withIntermediateDirectories: true)
            try? "# 预焙阳极工艺参数\n煅烧温度 1250℃，成型压力 160MPa"
                .write(to: sv.appendingPathComponent("30-资源/预焙阳极工艺参数.md"),
                       atomically: true, encoding: .utf8)
            try? "# 评审记录\n预焙阳极车间数据采集频次需与 MES 对齐\n煅烧曲线要留存"
                .write(to: sv.appendingPathComponent("10-项目/强强/评审记录.md"),
                       atomically: true, encoding: .utf8)
            try? "# 无关笔记\n今天买了两斤苹果"
                .write(to: sv.appendingPathComponent("30-资源/杂物.md"),
                       atomically: true, encoding: .utf8)
            try? "// should be skipped"
                .write(to: sv.appendingPathComponent(".obsidian/workspace.md"),
                       atomically: true, encoding: .utf8)

            let docs = VaultIndexer.scan(vault: sv)
            check("索引只收库内 md", docs.count == 3, "\(docs.count)")
            check("索引跳过 .obsidian", !docs.contains { $0.rel.contains(".obsidian") })

            let hits = VaultSearch.search(docs, query: "预焙阳极", limit: 10)
            check("正文命中能搜到", hits.count == 2, "\(hits.count)")
            check("文件名命中排前", hits.first?.rel.contains("预焙阳极工艺参数") == true,
                  hits.first?.rel ?? "-")
            check("命中带行号与片段", (hits.first?.line ?? 0) >= 1 && !(hits.first?.snippet.isEmpty ?? true),
                  "\(hits.first?.line ?? -1)")

            let andHits = VaultSearch.search(docs, query: "煅烧 压力", limit: 10)
            check("多词走 AND", andHits.count == 1, "\(andHits.count)")
            check("无命中返回空", VaultSearch.search(docs, query: "zzz不存在", limit: 10).isEmpty)
            check("空查询返回空", VaultSearch.search(docs, query: "   ", limit: 10).isEmpty)
        }

        // ===== 1.4.1 看板口径 =====
        do {
            let now = Date()
            func ev(_ kind: String, _ ok: Bool, _ daysAgo: Double, ms: Int = 100,
                    ai: String = "off") -> MetricEvent {
                MetricEvent(kind: kind, ok: ok, target: "00-收件箱", noteRel: "30-资源/a.md",
                            source: "selftest", durationMs: ms, ai: ai,
                            at: now.addingTimeInterval(-daysAgo * 86400))
            }
            let events = [ev("drop", true, 0), ev("drop", false, 0), ev("memo", true, 1),
                          ev("search", true, 0), ev("open", true, 0)]
            let s = MetricsQuery.summary(events: events, now: now, days: 7)
            check("成功率只算投递类", abs(s.successRate - 2.0 / 3.0) < 0.001, "\(s.successRate)")
            check("搜索不计入成功率分母", s.ok + s.failed == 3, "\(s.ok + s.failed)")
            check("打开率按成功投递算", abs(s.openRate - 0.5) < 0.001, "\(s.openRate)")
            check("7 天补齐空白日", s.daily.count == 7, "\(s.daily.count)")
            check("样本不足不给 p95", s.p95Ms == nil)
            check("目标按哈希聚合", s.byTarget.first?.count == 3, "\(s.byTarget.count)")
            check("哈希只有 8 位且不含明文", s.byTarget.first?.id.count == 8
                  && s.byTarget.first?.id != "00-收件箱", s.byTarget.first?.id ?? "-")

            let many = (0..<40).map { ev("drop", true, 0, ms: 100 + $0) }
            let s2 = MetricsQuery.summary(events: many, now: now, days: 7)
            check("样本够时给 p95", s2.p95Ms != nil, "\(s2.p95Ms ?? -1)")
            check("p95 不小于中位数", (s2.p95Ms ?? 0) >= MetricsQuery.percentile((100..<140).map { $0 }, 0.5))

            // 同一次投递会写两条事件（ai + 投递）。两条都算就翻倍，
            // 看板上「AI 完成 2」实际只处理了 1 次——这个口径错得很隐蔽。
            let cap = "same-capture"
            let dup = [
                MetricEvent(kind: "ai", ok: true, target: "00-收件箱", source: "archive",
                            captureId: cap, ai: "done"),
                MetricEvent(kind: "memo", ok: true, target: "00-收件箱", noteRel: "a.md",
                            source: "archive", captureId: cap, ai: "done"),
            ]
            let s3 = MetricsQuery.summary(events: dup, now: now, days: 7)
            check("AI 同一次投递只计一次", s3.aiDone == 1, "\(s3.aiDone)")
            check("AI 同一次投递也不误记跳过", s3.aiSkipped == 0 && s3.aiOff == 0,
                  "\(s3.aiSkipped)/\(s3.aiOff)")

            // 打开率问的是「多少产出被看过」，同一篇点三次不能算三次
            let opens = [
                MetricEvent(kind: "memo", ok: true, noteRel: "a.md", source: "archive"),
                MetricEvent(kind: "open", noteRel: "a.md", source: "dashboard"),
                MetricEvent(kind: "open", noteRel: "a.md", source: "dashboard"),
                MetricEvent(kind: "open", noteRel: "b.md", source: "search-local"),
            ]
            let s4 = MetricsQuery.summary(events: opens, now: now, days: 7)
            check("同一篇打开多次只算一次", s4.opened == 2, "\(s4.opened)")
            check("打开率不超过 100%", s4.openRate <= 1.0, "\(s4.openRate)")

            // 跨夏令时的日子不能丢：按 Calendar 递推而不是减 86400 秒。
            // 2026-03-08 美东夏令时开始，那天只有 23 小时；从 3/9 00:30 往回退
            // 86400 秒会直接落到 3/7，3/8 整段消失（旧算法在这里只出 6 个日期）。
            var cals = Calendar(identifier: .gregorian)
            cals.timeZone = TimeZone(identifier: "America/New_York") ?? .current
            let dstNow = cals.date(from: DateComponents(year: 2026, month: 3, day: 9,
                                                        hour: 0, minute: 30)) ?? now
            let dstEvent = MetricEvent(kind: "drop", ok: true, target: "00-收件箱",
                                       at: cals.date(from: DateComponents(year: 2026, month: 3,
                                                                         day: 8, hour: 12)) ?? dstNow)
            let s5 = MetricsQuery.summary(events: [dstEvent], now: dstNow, days: 7,
                                          calendar: cals)
            check("跨夏令时 7 天不重不漏", Set(s5.daily.map { $0.label }).count == 7,
                  "\(s5.daily.map { $0.label }.joined(separator: ","))")
            check("夏令时当天的事件落在当天",
                  s5.daily.first { $0.label == "03-08" }?.total == 1,
                  "03-08=\(s5.daily.first { $0.label == "03-08" }?.total ?? -1)")
        }

        // ===== 归档完成标记（P1-9）：删 pending 前崩溃不写第二篇 =====
        do {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("od-marker-\(UUID().uuidString)")
            let old = PendingStore.overrideDirectory
            PendingStore.overrideDirectory = dir
            defer {
                PendingStore.overrideDirectory = old
                try? FileManager.default.removeItem(at: dir)
            }
            let id = UUID().uuidString
            ArchiveMarker.mark(id: id, rel: "00-收件箱/2026-01-01 灵感.md")
            check("完成标记能读回", ArchiveMarker.doneRel(id: id) == "00-收件箱/2026-01-01 灵感.md",
                  ArchiveMarker.doneRel(id: id) ?? "-")
            ArchiveMarker.clear(id: id)
            check("清掉后标记不再存在", ArchiveMarker.doneRel(id: id) == nil)

            // 有标记 + pending 还在 = 上次写完没来得及删 → 只清理，不再写笔记
            let vm = PendingMemo(id: id, text: "已经写过一次的内容", duration: 3,
                                 target: "00-收件箱", vaultPath: dir.path,
                                 engine: "test", audioPath: "", source: "record",
                                 createdAt: Date(), attempts: 0)
            try? PendingStore.enqueue(vm)
            ArchiveMarker.mark(id: id, rel: "00-收件箱/已存在.md")
            let again: DropOutcome? = (try? MemoArchiveQueue.archive(vm)) ?? nil
            check("有完成标记时不再写第二篇", again == nil)
            check("同时把残留 pending 清掉", PendingStore.count == 0, "\(PendingStore.count)")
            check("清理后标记也一并删除", ArchiveMarker.doneRel(id: id) == nil)

            // 最后一段窗口：笔记写完、标记还没落盘。这一段只能靠正文查重兜住。
            let vault = dir.appendingPathComponent("vault")
            try? FileManager.default.createDirectory(
                at: vault.appendingPathComponent("00-收件箱"), withIntermediateDirectories: true)
            let text = "崩溃前已经写进笔记的一段文字，长度足够触发查重，不会被当成太短。"
            let note = vault.appendingPathComponent("00-收件箱/2026-01-01 灵感.md")
            try? ("---\n类型: 灵感速记\n---\n\n" + text)
                .write(to: note, atomically: true, encoding: .utf8)
            let past = Date().addingTimeInterval(-180)
            check("恢复时按正文认出已经写过",
                  RecoveryDedupe.existingNote(vault: vault, text: text, createdAt: past) != nil)
            check("刚创建的 pending 不走查重",
                  RecoveryDedupe.existingNote(vault: vault, text: text, createdAt: Date()) == nil)
            check("太短的文字不做查重",
                  RecoveryDedupe.existingNote(vault: vault, text: "收到", createdAt: past) == nil)
            check("正文没出现在库里就不算写过",
                  RecoveryDedupe.existingNote(vault: vault,
                                              text: "这段话从来没有被写进任何笔记，属于新内容。",
                                              createdAt: past) == nil)
        }

        // ===== 1.5.0 AI 配置与解析 =====
        do {
            check("接受 https 并去尾斜杠",
                  (try? AIConfig.normalize(base: "https://api.openai.com/v1/")) == "https://api.openai.com/v1")
            check("拒绝带 query 的地址", (try? AIConfig.normalize(base: "https://x.com/v1?a=1")) == nil)
            check("拒绝外网 http", (try? AIConfig.normalize(base: "http://example.com/v1")) == nil)
            check("允许本机 http", (try? AIConfig.normalize(base: "http://127.0.0.1:11434/v1")) != nil)
            check("拒绝带用户名的地址", (try? AIConfig.normalize(base: "https://u:p@x.com/v1")) == nil)

            let raw = "好的：\n```json\n{\"title\":\"煅烧温度记录\",\"summary\":\"记录三段温度\",\"tags\":[\"#工艺\",\"工艺\",\"MES\"]}\n```"
            let r = try? AIService.parseResult(raw, model: "m", ms: 12)
            check("能剥掉代码块解析", r?.title == "煅烧温度记录", r?.title ?? "nil")
            check("标签去重且去 #", r?.tags == ["工艺", "MES"], "\(r?.tags ?? [])")

            let long = String(repeating: "字", count: 200)
            let r2 = try? AIService.parseResult("{\"title\":\"\(long)\",\"summary\":\"\(long)\",\"tags\":[]}",
                                                model: "m", ms: 1)
            check("标题摘要超长被截断", (r2?.title.count ?? 0) <= 40 && (r2?.summary.count ?? 0) <= 160)

            var off = AIConfig()
            off.enabled = false
            let (st, _, _) = AIService.decorate(text: "x", target: "00-收件箱", config: off)
            check("未启用时状态为 off", st == .off, st.rawValue)

            let json = """
            {"id":"x","text":"t","duration":1,"target":"00-收件箱","vaultPath":"/tmp/v",\
            "engine":"e","audioPath":"","source":"record","createdAt":"2026-11-05T00:00:00Z","attempts":0}
            """
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let old = try? dec.decode(PendingMemo.self, from: Data(json.utf8))
            check("旧 pending 无 aiState 也能解码", old != nil && old?.ai == .off)
            check("旧 pending 的 scene 解释为 transcript", old?.scene == .transcript)
        }

        // ===== 1.7.0 三场景 / 独占发布 / 新布局 =====
        do {
            let t = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("od-170-selftest-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: t, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: t) }

            func touch(_ name: String, _ s: String = "预焙阳极焙烧曲线记录，煅烧温度与成型压力的对应关系。") -> URL {
                let u = t.appendingPathComponent(name)
                try? s.write(to: u, atomically: true, encoding: .utf8)
                return u
            }
            func png(_ name: String, w: Int, h: Int) -> URL? {
                let img = NSImage(size: NSSize(width: w, height: h))
                img.lockFocus()
                NSColor.systemBlue.setFill()
                NSRect(x: 0, y: 0, width: w, height: h).fill()
                img.unlockFocus()
                guard let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let d = rep.representation(using: .png, properties: [:]) else { return nil }
                let u = t.appendingPathComponent(name)
                try? d.write(to: u)
                return u
            }

            let md = touch("周会记录.md"), txt = touch("note.txt"), csv = touch("data.csv")
            let zip = touch("bundle.zip"), svg = touch("icon.svg"), mp4 = touch("clip.mp4")
            let shot = png("shot.png", w: 2400, h: 1200)
            check("md/txt/csv 归 document",
                  [md, txt, csv].allSatisfy { SceneRouter.classify(file: $0) == .document })
            check("png 归 image", shot.map { SceneRouter.classify(file: $0) == .image } ?? false)
            check("截图来源的 PNG 仍是 image",
                  shot.map { SceneRouter.classify(file: $0, origin: "screenshot") == .image } ?? false)
            let noExt = t.appendingPathComponent("shot-noext")
            if let shot, let d = try? Data(contentsOf: shot) { try? d.write(to: noExt) }
            check("无扩展名截图用 ImageIO 首帧判为 image（不靠后缀）",
                  SceneRouter.classify(file: noExt, origin: "screenshot") == .image
                    && SceneRouter.classify(file: noExt, origin: "drop") == .legacy)
            check("svg/zip/mp4/未知类型归 legacy",
                  [zip, svg, mp4, touch("noext")].allSatisfy {
                      SceneRouter.classify(file: $0) == .legacy
                  })
            let dir = t.appendingPathComponent("文件夹", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            check("文件夹归 legacy", SceneRouter.classify(file: dir) == .legacy)
            check("pending 转写优先于扩展名",
                  SceneRouter.classify(file: zip, origin: "record") == .transcript)

            let big = touch("big.txt", String(repeating: "字", count: 11 * 1024 * 1024 / 3 + 1))
            check("超过 10MiB 的文本归 legacy",
                  SceneRouter.classify(file: big) == .legacy)
            check("假 PDF 无文字层时回落 legacy",
                  SceneRouter.resolve(file: touch("fake.pdf", "not a pdf"), origin: "drop") == .legacy)

            if let shot {
                let enc = try? ImagePayload.encode(shot)
                check("图片缩到 2048 且是 JPEG data URI",
                      enc?.dataURI.hasPrefix("data:image/jpeg;base64,") == true
                        && max(enc?.width ?? 9999, enc?.height ?? 9999) <= 2048,
                      "\(enc?.width ?? 0)×\(enc?.height ?? 0)")
                let prepared = SceneMaterial.prepare(url: shot, origin: "screenshot",
                                                     target: "00-收件箱")
                check("截图材料准备为 image", prepared.scene == .image)
                if let input = prepared.input,
                   let body = AISceneService.requestBody(input: input, config: AIConfig()),
                   let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let msgs = obj["messages"] as? [[String: Any]],
                   let user = msgs.last?["content"] as? [[String: Any]] {
                    check("视觉请求含 text + image_url 两部分", user.count == 2)
                    let iu = user.last?["image_url"] as? [String: Any]
                    check("视觉请求 detail=high 且模型用视觉模型",
                          iu?["detail"] as? String == "high"
                            && obj["model"] as? String == AIConfig().effectiveVisionModel)
                } else { check("视觉请求体可解析", false) }
            }

            check("转录提示词保留原文三条要求",
                  AIPrompts.transcript.contains("保留原文的全部信息")
                    && AIPrompts.transcript.contains("拿不准时保持原文")
                    && AIPrompts.transcript.contains("不补充原文没有的"))
            let input = AISceneInput.transcript(text: "今天部署测试环境，访问 https://example.com/a 后验证 12345",
                                                target: "00-收件箱", engine: "cli", duration: 3)
            let bad = "{\"title\":\"测试\",\"summary\":\"概要\",\"tags\":[],\"polishedText\":\"太短\",\"edits\":[]}"
            check("润色稿过短被拒绝",
                  (try? AISceneService.parse(bad, input: input, model: "m", ms: 1)) == nil)
            let noURL = "{\"title\":\"测试\",\"summary\":\"概要\",\"tags\":[],\"polishedText\":\""
                + "今天部署测试环境，访问后验证 12345，一切正常，稍后再看看日志和告警面板。" + "\",\"edits\":[]}"
            check("润色稿丢失 URL 被拒绝",
                  (try? AISceneService.parse(noURL, input: input, model: "m", ms: 1)) == nil)
            check("关键项提取含 URL 与连续数字",
                  AISceneService.keyTokens("见 https://x.com/a 编号 12345").count >= 2)

            let u1 = try? ExclusiveNoteWriter.publish(text: "第一篇", dir: t, base: "同名")
            let u2 = try? ExclusiveNoteWriter.publish(text: "第二篇", dir: t, base: "同名")
            let s1 = u1.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            check("同名连写生成 -2 且不覆盖", u1?.lastPathComponent == "同名.md"
                    && u2?.lastPathComponent == "同名-2.md" && s1 == "第一篇",
                  "\(u1?.lastPathComponent ?? "-") / \(u2?.lastPathComponent ?? "-")")

            let spent = AIBatchBudget(now: Date().addingTimeInterval(-20))
            check("预算耗尽后不再请求", spent.attemptBudget(pending: 1) == nil)
            let fresh = AIBatchBudget(now: Date())
            check("预算按剩余项分摊且不超过 12s",
                  (fresh.attemptBudget(pending: 3) ?? 99) <= 12)

            let f = PanelLayout.frames(NSRect(x: 0, y: 0, width: 400, height: 520))
            check("头部表面 (12,396,376,108)",
                  f.surface.origin.x == 12 && f.surface.origin.y == 396
                    && f.surface.width == 376 && f.surface.height == 108)
            check("搜索框 (16,344,368,32)",
                  f.search.origin.x == 16 && f.search.origin.y == 344
                    && f.search.width == 368 && f.search.height == 32)
            check("结果区 (16,60,368,234) 且 5 行",
                  f.results.origin.y == 60 && f.results.width == 368
                    && f.results.height == 234 && f.visibleRows == 5)
            check("底栏 (12,12,376,36) 与打开按钮 104×28",
                  f.footer.origin.y == 12 && f.footer.width == 376
                    && f.footer.height == 36 && f.open.width == 104 && f.open.height == 28)
            check("截屏/灵感按钮 76×30 / 72×30 且底边 406",
                  f.shot.width == 76 && f.shot.height == 30
                    && f.memo.width == 72 && f.memo.height == 30
                    && f.shot.origin.y == 406 && f.memo.origin.y == 406)
            check("B2 按钮 x：截屏 224 / 灵感 308 / 快捷键 248",
                  f.shot.origin.x == 224 && f.memo.origin.x == 308
                    && f.shortcut.origin.x + f.footer.origin.x == 248)
            let ddView = DropView(frame: NSRect(x: 0, y: 0, width: 400, height: 520))
            ddView.layoutSubtreeIfNeeded()
            check("B6.2 下拉焦点链 5 项且首项是搜索框",
                  ddView.focusChain().count == 5
                    && ddView.focusChain().first is NSSearchField)
            let dkView = DropView(frame: NSRect(x: 0, y: 0,
                                                width: PanelMetrics.docked.width,
                                                height: PanelMetrics.docked.height))
            dkView.layoutSubtreeIfNeeded()
            check("B6.2 docked 不建焦点链（保持 1.6.0 键盘行为）",
                  dkView.focusChain().isEmpty)
            check("B6.2 截屏/灵感按钮能真正接受键盘焦点",
                  ddView.focusChain().dropFirst(2).prefix(2)
                    .allSatisfy { $0.acceptsFirstResponder })

            // 重新检查修补①：截图临时源图必须等确认笔记落盘才删。
            check("截图归档失败时必须保留源图",
                  !ScreenshotCleanup.canDiscard(failures: 1, noteRel: "")
                    && !ScreenshotCleanup.canDiscard(failures: 0, noteRel: ""))
            check("截图零失败且产出笔记才允许删源图",
                  ScreenshotCleanup.canDiscard(failures: 0, noteRel: "00-收件箱/x.md"))

            // 重新检查修补②：恢复查重不再只用前 60 字前缀判重。
            let samePrefix = String(repeating: "嗯那个今天我们讨论一下预焙阳极的焙烧曲线和成型工序，", count: 3)
            let firstMemo = samePrefix + "第一段录音的独有结论：温度控制在一千二百度。"
            let secondMemo = samePrefix + "第二段录音的独有结论：需要复核焙烧曲线并调整风量。"
            do {
                try firstMemo.write(to: vault.appendingPathComponent("已归档笔记.md"),
                                    atomically: true, encoding: .utf8)
                let old = Date().addingTimeInterval(-120)
                check("恢复查重不再按前 60 字误删不同录音",
                      RecoveryDedupe.existingNote(vault: vault, text: secondMemo,
                                                  createdAt: old) == nil)
                check("恢复查重仍能识别整段原文已入库",
                      RecoveryDedupe.existingNote(vault: vault, text: firstMemo,
                                                  createdAt: old) != nil)
            } catch {
                check("恢复查重测试夹具可写", false)
            }

            // 重新检查修补③：润色稿不能悄悄换掉金额、编号、星期。
            var rejectedBadPolish = false
            do {
                try AISceneService.validatePolish(
                    original: "张三负责上海项目，预算200元，周五交付。",
                    polished: "李四负责北京项目，预算900元，周一交付。")
            } catch { rejectedBadPolish = true }
            check("润色稿改写金额/星期必须被拒绝", rejectedBadPolish)
            var acceptedNormalPolish = true
            do {
                try AISceneService.validatePolish(
                    original: "嗯那个今天部署一下测试环境，访问 https://example.com/a 之后验证一下 12345。一切正常。",
                    polished: "今天部署测试环境，访问 https://example.com/a 后验证 12345。一切正常。")
            } catch { acceptedNormalPolish = false }
            check("只去口头禅、保留关键项的润色仍允许", acceptedNormalPolish)

            // 第二轮复核：--target 是 1.6.0 旧用法共用的参数，不能算「场景标志」。
            check("1.6.0 旧 --ai-run <文字> 仍走 AICLI",
                  SceneCLI.isLegacyAIUsage(["--ai-run", "一段文字"]))
            check("旧用法带 --target 仍走 AICLI（--target 不是场景标志）",
                  SceneCLI.isLegacyAIUsage(["--ai-run", "一段文字",
                                            "--target", "00-收件箱"]))
            check("出现任一 1.7.0 标志才走场景 CLI",
                  !SceneCLI.isLegacyAIUsage(["--ai-run", "a.md", "--dry-run"])
                    && !SceneCLI.isLegacyAIUsage(["--ai-run", "a.md", "--json"])
                    && !SceneCLI.isLegacyAIUsage(["--ai-run", "a.md", "--scene", "auto"]))
            check("显式 --scene 不被 origin=record 覆盖",
                  SceneMaterial.prepare(url: nil, origin: "record",
                                        target: "00-收件箱",
                                        forcedScene: .legacy).scene == .legacy)
            check("未指定场景时 origin=record 仍判 transcript（旧行为不变）",
                  SceneMaterial.prepare(url: nil, origin: "record",
                                        target: "00-收件箱").scene == .transcript)
            check("A11 归档退出码：全成 0 / 全败 1 / 部分成 3",
                  SceneCLI.archiveExitCode(ok: 3, total: 3) == 0
                    && SceneCLI.archiveExitCode(ok: 0, total: 3) == 1
                    && SceneCLI.archiveExitCode(ok: 2, total: 3) == 3)

            let frame = dropdownFrame(anchor: nil,
                                      visible: NSRect(x: 0, y: 0, width: 800, height: 600),
                                      size: PanelMetrics.dropdown)
            check("400×520 下拉贴顶且居中",
                  frame.width == 400 && frame.height == 520 && frame.origin.y == 80
                    && frame.origin.x == 200)

            let now = Date()
            let ev = { (kind: String, ai: String) in
                MetricEvent(kind: kind, ok: true, source: "archive",
                            captureId: "cap-1", ai: ai, at: now)
            }
            let sum = MetricsQuery.summary(events: [ev("ai", "done"), ev("drop", "done")],
                                           now: now, days: 7)
            check("同 captureId 的 ai + 投递只计一次 AI", sum.aiDone == 1, "\(sum.aiDone)")

            let doc = SceneMaterial.prepare(url: md, origin: "drop", target: "00-收件箱")
            check("文档取文成功且带文件类型",
                  doc.scene == .document && doc.reason.isEmpty)
            var offCfg = AIConfig(); offCfg.enabled = false
            AIConfigStore.overrideConfig = offCfg
            let report = try? Filer(vault: t).file([md], target: "00-收件箱")
            AIConfigStore.overrideConfig = nil
            let note: String? = {
                guard let rel = report?.outcomes.first?.noteRel else { return nil }
                return try? String(contentsOf: t.appendingPathComponent(rel), encoding: .utf8)
            }()
            check("AI 关闭时文件笔记不含 1.7 新字段",
                  note?.contains("AI场景") == false && note?.contains("摘要:") == false
                    && note?.contains("类型: 文件归档") == true)

            // A6.3 / A6.4：transcript 成功的 AI 行是单个 YAML 标量；
            // 旧 done pending 没有润色稿，必须逐字保持 1.6.0，不升级模板。
            let sr = AISceneResult(scene: .transcript, title: "部署记录",
                                   summary: "部署测试环境并验证访问", tags: ["部署"],
                                   polishedText: "今天部署测试环境。\n\n访问地址已验证，编号 12345。",
                                   visibleText: "", edits: [], model: "m1", ms: 7,
                                   truncated: false)
            func readNote(_ o: DropOutcome?) -> String? {
                guard let rel = o?.noteRel, !rel.isEmpty else { return nil }
                return try? String(contentsOf: t.appendingPathComponent(rel), encoding: .utf8)
            }
            let polished = try? Filer(vault: t).memo(
                text: "今天部署测试环境 访问地址已验证 编号 12345",
                target: "00-收件箱", duration: 3, engine: "测试",
                ai: sr.legacy, aiState: .done, sceneResult: sr)
            let polishedNote = readNote(polished)
            check("transcript 成功：AI 行整体加引号 + AI场景",
                  polishedNote?.contains("AI: \"m1（7ms）\"") == true
                    && polishedNote?.contains("AI场景: \"transcript\"") == true)
            check("transcript 成功：润色正文与原始转写折叠引用",
                  polishedNote?.contains("> [!quote]- 原始转写") == true
                    && polishedNote?.contains("访问地址已验证") == true)
            let oldPending = try? Filer(vault: t).memo(
                text: "旧的一条转写", target: "00-收件箱", duration: 2,
                engine: "测试", ai: sr.legacy, aiState: .done)
            let oldNote = readNote(oldPending)
            check("旧 done pending 逐字保持 1.6.0 AI 行且不升级场景",
                  oldNote?.contains("AI: \"m1\"（7ms）") == true
                    && oldNote?.contains("AI场景") == false
                    && oldNote?.contains("[!quote]") == false)
            check("天生 legacy 不记成 skipped",
                  SceneMaterial.prepare(url: zip, origin: "drop",
                                        target: "00-收件箱").reason.isEmpty)
        }

        print("")
        print("自检结果：通过 \(passed)，失败 \(failed)")
        return failed == 0 ? 0 : 1
    }
}

// MARK: - 入口

// MARK: - 界面链路自验（--ui-memo）

/// 用**真实的界面代码路径**跑一遍「转写文件 → 进度 → 归档 → 界面复位」。
///
/// 为什么要这个：这台机器没有麦克风，录音那半截没法在本机验证；
/// 但「一直停在转写收尾中」出问题的是**后半截**——进度回调、结果交付、界面复位。
/// 后半截正好可以用「转写音频文件…」这条入口完整跑一遍，然后断言界面回到了空闲。
enum AutoUI {
    static var memoFile: URL?
    static var target: String?
    /// 启动后直接打开看板 / AI 设置（`--dashboard` / `--ai-settings`）
    static var openDashboard = false
    static var openAISettings = false
    /// 验收用：启动后直接展开下拉面板（没有辅助功能权限时也能截图核对）
    static var showDropdown = false
    private static var finished = false

    static func finish(_ code: Int32, _ message: String) {
        guard memoFile != nil, !finished else { return }
        finished = true
        print(message)
        exit(code)
    }
}

@main
struct AppMain {
    static var delegate: AppDelegate?

    // MARK: 批量结果的两种输出

    /// 人类可读输出：逐项给出成功/失败，末尾给汇总
    static func printHuman(_ report: BatchReport) {
        for o in report.outcomes {
            print("✓ \(o.source)")
            print("  笔记: \(o.noteRel)")
            if !o.fileRel.isEmpty { print("  文件: \(o.fileRel)") }
        }
        for f in report.failures {
            print("✗ \(f.source)")
            print("  原因: \(f.reason)")
        }
        if report.allSucceeded {
            print("成功 \(report.outcomes.count)，失败 0")
        } else if report.partial {
            print("成功 \(report.outcomes.count)，失败 \(report.failures.count) —— 部分成功（退出码 3）")
        } else {
            print("成功 0，失败 \(report.failures.count) —— 全部失败（退出码 1）")
        }
    }

    /// 结构化输出：给脚本/自动化解析用
    static func jsonString(_ report: BatchReport) -> String {
        let items: [[String: Any]] = report.outcomes.map {
            ["source": $0.source, "note": $0.noteRel, "file": $0.fileRel]
        }
        let fails: [[String: Any]] = report.failures.map {
            ["source": $0.source, "error": $0.reason]
        }
        let payload: [String: Any] = [
            "ok": report.allSucceeded,
            "partial": report.partial,
            "total": report.total,
            "succeeded": report.outcomes.count,
            "failed": report.failures.count,
            "exit_code": report.allSucceeded ? 0 : (report.partial ? 3 : 1),
            "items": items,
            "failures": fails,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ), let s = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"序列化失败\"}"
        }
        return s
    }

    static func main() {
        let args = CommandLine.arguments

        // CLI 全是「打完日志就 exit」，异步日志队列里最后几条会被一起带走。
        // 挂在 atexit 上，所有退出路径都能先排空（信号杀死除外，那种本来也没救）。
        atexit { DiagLog.flush() }

        // 全局：--vault <路径> 覆盖库位置（只影响本次进程，不写入偏好）
        if let v = args.firstIndex(of: "--vault"), v + 1 < args.count {
            let p = (args[v + 1] as NSString).expandingTildeInPath
            Cfg.overrideVault = URL(fileURLWithPath: p).standardizedFileURL
        }

        // 诊断：ObsidianDrop --audio-check [--json]
        // 只读探测，不请求权限、不启动采集。用来在「另一台电脑」上定位
        // 「点录音说没有麦克风」到底是设备问题、权限问题，还是上层发现失败。
        // 退出码：0 = 有可用输入设备；1 = 没有。
        if args.contains("--audio-check") {
            let p = AudioProbe.run()
            if args.contains("--json") {
                let payload: [String: Any] = [
                    "machineModel": AudioProbe.machineModel(),
                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "avfoundationDevices": p.captured,
                    "coreAudioDevices": p.coreAudio,
                    "defaultInput": p.defaultName ?? "",
                    "sampleRate": p.sampleRate,
                    "channels": p.channels,
                    "micAuth": p.auth,
                    "usable": p.usable,
                ]
                if let d = try? JSONSerialization.data(
                    withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
                   let s = String(data: d, encoding: .utf8) {
                    print(s)
                } else {
                    print("{\"error\":\"序列化失败\"}")
                }
            } else {
                print(AudioProbe.report())
            }
            exit(p.usable ? 0 : 1)
        }

        // 自检：纯逻辑与文件行为回归，不启动 UI，不碰真实库
        if args.contains("--self-test") {
            exit(SelfTest.run())
        }

        // 库内搜索：ObsidianDrop --search <关键词> [--limit N] [--json] [--no-spotlight]
        // 退出码：0 有结果 / 1 无命中 / 2 用法或库错误
        if let i = args.firstIndex(of: "--search") {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                FileHandle.standardError.write(
                    "用法：ObsidianDrop --search <关键词> [--limit N] [--json] [--no-spotlight]\n"
                        .data(using: .utf8)!)
                exit(2)
            }
            var limit = 20
            if let l = args.firstIndex(of: "--limit"), l + 1 < args.count,
               let n = Int(args[l + 1]) {
                limit = min(max(n, 1), 100)
            }
            exit(SearchCLI.run(query: args[i + 1], limit: limit,
                               json: args.contains("--json"),
                               includeSpotlight: !args.contains("--no-spotlight")))
        }

        // 使用看板数据：--metrics [--json] [--days N] [--raw]
        if args.contains("--metrics") {
            var days = 7
            if let i = args.firstIndex(of: "--days"), i + 1 < args.count,
               let n = Int(args[i + 1]) {
                days = min(max(n, 1), 365)
            }
            exit(MetricsCLI.run(json: args.contains("--json"), days: days,
                                raw: args.contains("--raw")))
        }

        // AI 诊断：连接测试与单次处理，不启动界面
        if args.contains("--ai-config") { exit(AICLI.config()) }
        if args.contains("--ai-test") { exit(AICLI.test()) }
        if let i = args.firstIndex(of: "--ai-set") {
            var pairs: [String] = []
            var j = i + 1
            while j < args.count, !args[j].hasPrefix("--") {
                pairs.append(args[j]); j += 1
            }
            guard !pairs.isEmpty else {
                FileHandle.standardError.write(
                    "用法：--ai-set enabled=on base=https://… model=… key=…\n".data(using: .utf8)!)
                exit(2)
            }
            exit(AICLI.set(pairs))
        }
        // 1.7.0：场景化入口（--scene / --source / --archive / --mock-*）。
        // 不带这些标志时 SceneCLI 会自动退回 1.6.0 的 --ai-run <文字> 行为。
        // 批量 `--file a --file b` 允许不写 --ai-run，但只要带场景标志就必须
        // 走这里，不能被下面 1.6.0 的 `--file` 归档命令截走并报「未知选项」。
        let sceneOnlyFlags: Set<String> = ["--scene", "--source", "--archive", "--dry-run",
                                           "--mock-response", "--mock-error", "--vision",
                                           "--text"]
        let sceneRoute = args.contains("--ai-run")
            || (args.contains("--file") && args.contains(where: { sceneOnlyFlags.contains($0) }))
        if sceneRoute {
            if let i = args.firstIndex(of: "--ai-run") {
                guard i + 1 < args.count else {
                    FileHandle.standardError.write("用法：--ai-run <文件路径|文字> [--scene …]\n".data(using: .utf8)!)
                    exit(2)
                }
            }
            exit(SceneCLI.run(args))
        }

        // 归档链路自验：把一段文字当成「刚转写完的结果」走完 pending → AI → 笔记。
        // 没有麦克风的机器也能验这一段，而且验的正是 1.5.0 唯一挂载点是否真的生效。
        if let i = args.firstIndex(of: "--memo-test") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write("用法：--memo-test <文字> [--target 目标]\n"
                    .data(using: .utf8)!)
                exit(2)
            }
            var target = Cfg.storedTarget
            if let t = args.firstIndex(of: "--target") {
                guard t + 1 < args.count, !args[t + 1].hasPrefix("--") else {
                    FileHandle.standardError.write("用法：--target 缺少目标值\n".data(using: .utf8)!)
                    exit(2)
                }
                target = args[t + 1]
            }
            let tmpPending = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("od-memo-test-\(UUID().uuidString)", isDirectory: true)
            PendingStore.overrideDirectory = tmpPending
            defer { try? FileManager.default.removeItem(at: tmpPending) }
            let m = PendingMemo(id: UUID().uuidString, text: args[i + 1], duration: 3,
                                target: target, vaultPath: Cfg.vault.path,
                                engine: "cli-test", audioPath: "", source: "record",
                                createdAt: Date(), attempts: 0)
            do {
                try PendingStore.enqueue(m)
                guard let out = try MemoArchiveQueue.archive(m) else {
                    print("没有归档（pending 已被别的路径处理）")
                    exit(1)
                }
                print("笔记: \(out.noteRel)")
                let full = Cfg.vault.appendingPathComponent(out.noteRel)
                if let text = try? String(contentsOf: full, encoding: .utf8) {
                    let head = text.components(separatedBy: "\n").prefix(9).joined(separator: "\n")
                    print("—— 前 9 行 ——")
                    print(head)
                }
                let left = PendingStore.count
                print("剩余 pending: \(left)")
                exit(0)
            } catch {
                FileHandle.standardError.write("错误：\(error.localizedDescription)\n"
                    .data(using: .utf8)!)
                exit(1)
            }
        }

        // 界面入口：--dashboard / --ai-settings（启动 App 并直接打开那个窗口）
        if args.contains("--dashboard") { AutoUI.openDashboard = true }
        if args.contains("--show-dropdown") { AutoUI.showDropdown = true }
        if args.contains("--ai-settings") { AutoUI.openAISettings = true }

        // 命令行模式：开机启动开关
        if args.contains("--login") {
            if #available(macOS 13.0, *) {
                let on = args.contains("on") || !args.contains("off")
                do {
                    if on, SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    } else if !on, SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                    print("登录项状态：\(SMAppService.mainApp.status.rawValue == 1 ? "已启用" : "当前状态 \(SMAppService.mainApp.status.rawValue)")")
                    exit(0)
                } catch {
                    FileHandle.standardError.write("失败：\(error.localizedDescription)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
            exit(1)
        }

        // 命令行模式：ObsidianDrop --shot full|area|window|clipboard [--target 00-收件箱]
        if let i = args.firstIndex(of: "--shot") {
            guard i + 1 < args.count, let mode = Screenshot.Mode(rawValue: args[i + 1]) else {
                FileHandle.standardError.write("用法：ObsidianDrop --shot full|area|window|clipboard [--target <目标>]\n".data(using: .utf8)!)
                exit(2)
            }
            var target = Cfg.storedTarget
            if let t = args.firstIndex(of: "--target") {
                // 少了目标值就报用法错误。退回「上次用的目标」等于把笔误投到别处。
                guard t + 1 < args.count, !args[t + 1].hasPrefix("--") else {
                    FileHandle.standardError.write("用法：--target 缺少目标值\n".data(using: .utf8)!)
                    exit(2)
                }
                target = args[t + 1]
            }
            let r = Screenshot.capture(mode)
            // 剪贴板模式**不产生文件**，不能走下面「必须有文件」的判定。
            // 原来这里成功（ok=true, file=nil）也会掉进 guard 里报「未截图」并 exit 1。
            if mode == .clipboard {
                print(r.message)
                exit(0)   // 复制成功、用户取消，都算正常结束
            }
            guard r.ok, let f = r.file else {
                print("未截图：\(r.message)")
                exit(r.message == "已取消" ? 0 : 1)
            }
            do {
                // 1.7.0：命令行截图也是截图。以前这里没带 context，来源退化成 drop、
                // 来源目录写成临时路径，无扩展名截图也走不到 ImageIO 的截图专用分支。
                // 与 GUI 的 finishScreenshot 用同一套上下文。
                let budget = AIBatchBudget(cap: AIConfigStore.config.effectiveBudget)
                let ctx = ArchiveContext(source: "screenshot", scene: .image,
                                         target: target, sourceURL: f, batchBudget: budget)
                let report = try Filer(vault: Cfg.vault).file([f], target: target,
                                                              contexts: [ctx])
                // 失败时保留临时 PNG：库里没有笔记、附件也回滚了，它是唯一副本。
                if let failure = report.failures.first {
                    FileHandle.standardError.write(
                        "错误：\(failure.reason)\n源图已保留：\(f.path)\n".data(using: .utf8)!)
                    exit(1)
                }
                if ScreenshotCleanup.canDiscard(failures: report.failures.count,
                                                noteRel: report.outcomes.first?.noteRel ?? "") {
                    try? FileManager.default.removeItem(at: f)
                }
                for x in report.outcomes {
                    print("笔记: \(x.noteRel)")
                    print("文件: \(x.fileRel)")
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(
                    "错误：\(error.localizedDescription)\n源图已保留：\(f.path)\n".data(using: .utf8)!)
                exit(1)
            }
        }

        // 调试：ObsidianDrop --render-preview <目录>
        //
        // 把面板的各个状态离屏渲染成 PNG。录音要真麦克风才能触发，
        // 但「长什么样」这件事没必要等真机——排版错了应该在这里就看见。
        if let i = args.firstIndex(of: "--render-preview") {
            let dir = i + 1 < args.count
                ? (args[i + 1] as NSString).expandingTildeInPath
                : NSTemporaryDirectory()
            _ = NSApplication.shared
            // --appearance light|dark：把基线钉死在指定外观，不受「系统自动切深色」
            // 影响。否则同一条命令白天/晚上拍出来的图不一样，没法做回归对比。
            if let a = args.firstIndex(of: "--appearance"), a + 1 < args.count {
                switch args[a + 1] {
                case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                case "light": NSApp.appearance = NSAppearance(named: .aqua)
                default: break
                }
            }
            let out = URL(fileURLWithPath: dir)
            do {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            } catch {
                FileHandle.standardError.write("错误：无法创建 \(out.path)：\(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }

            // 只读沙箱里曾经 21 张全写失败却仍打印「已输出」并 exit 0——
            // 那会让「界面基线通过」变成一句空话。逐张记成败，少一张就退出 1。
            var failedShots: [String] = []
            // 尺寸现在有两种：常驻 160×176 / 下拉 400×520（1.7.0）。
            // 排版错没错不该靠猜——两种形态、所有状态都出一张图。
            func shot(_ name: String, size: NSSize = PanelMetrics.docked,
                      _ body: (DropView) -> Void) {
                let v = DropView(frame: NSRect(origin: .zero, size: size))
                // 真机里面板是「先显示、再进状态」，离屏也先排一次版，
                // 否则状态先设定会跳过 layout 里的 idle 标题替换，基线图就失真了。
                v.layoutSubtreeIfNeeded()
                body(v)
                v.layoutSubtreeIfNeeded()
                guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
                    failedShots.append("\(name)（无法离屏缓存）")
                    return
                }
                // 毛玻璃在离屏渲染里是空心的，先铺底色才看得清排版
                NSGraphicsContext.saveGraphicsState()
                if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                    NSGraphicsContext.current = ctx
                    let isDark = v.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    NSColor(calibratedWhite: isDark ? 0.10 : 0.98, alpha: 1).setFill()
                    NSRect(origin: .zero, size: v.bounds.size).fill()
                }
                v.cacheDisplay(in: v.bounds, to: rep)
                NSGraphicsContext.restoreGraphicsState()
                if let data = rep.representation(using: .png, properties: [:]) {
                    do {
                        try data.write(to: out.appendingPathComponent("\(name).png"),
                                       options: .atomic)
                    } catch {
                        failedShots.append("\(name)（写入失败）")
                    }
                } else {
                    failedShots.append("\(name)（无法编码）")
                }
            }

            shot("1-idle") { _ in }
            shot("2-recording") { $0.renderMemo(.recording(7, 0.55), partial: "") }
            shot("3-analyzing-45") {
                $0.renderMemo(.transcribing(.analyzing(processed: 40, total: 120, chars: 63)),
                              partial: "")
            }
            shot("4-finishing") {
                $0.renderMemo(.transcribing(.finishing(processed: 120, total: 120,
                                                       chars: 120, waited: 5)), partial: "")
            }
            shot("5-preparing-model") {
                $0.renderMemo(.transcribing(.preparing("首次使用，正在下载「中文」语音模型（几百 MB，最长等 10 分钟）…")),
                              partial: "")
            }
            shot("6-saving") { $0.renderMemo(.transcribing(.saving(312)), partial: "") }

            shot("7-dropdown-empty", size: PanelMetrics.dropdown) { _ in }
            shot("8-dropdown-results", size: PanelMetrics.dropdown) { v in
                v.setResults([
                    SearchRow(kind: .vault, path: "30-资源/预焙阳极工艺参数.md",
                              title: "预焙阳极工艺参数",
                              detail: "煅烧温度 1250–1300℃，成型压力 160MPa…"),
                    SearchRow(kind: .vault, path: "10-项目/强强碳素/评审问题清单.md",
                              title: "评审问题清单",
                              detail: "预焙阳极车间数据采集频次需要与 MES 对齐…"),
                    SearchRow(kind: .local, path: "~/Downloads/预焙阳极行业报告.pdf",
                              title: "预焙阳极行业报告.pdf", detail: "~/Downloads/预焙阳极行业报告.pdf"),
                ], empty: "")
            }
            shot("9-dropdown-noresult", size: PanelMetrics.dropdown) { v in
                v.setResults([], empty: "没有匹配「预焙阳极」的笔记，换个词试试")
            }

            // ===== 1.7.0 规格 B：下拉形态的 10 个状态基线 =====
            let dd = PanelMetrics.dropdown
            let rows = [
                SearchRow(kind: .vault, path: "30-资源/预焙阳极工艺参数.md",
                          title: "预焙阳极工艺参数",
                          detail: "煅烧温度 1250–1300℃，成型压力 160MPa…"),
                SearchRow(kind: .vault, path: "10-项目/强强碳素/评审问题清单.md",
                          title: "评审问题清单",
                          detail: "预焙阳极车间数据采集频次需要与 MES 对齐…"),
                SearchRow(kind: .local, path: "~/Downloads/预焙阳极行业报告.pdf",
                          title: "预焙阳极行业报告.pdf", detail: "~/Downloads/预焙阳极行业报告.pdf"),
            ]
            // idle 走真实入口：目标名 + 结果区空态提示（showDropdown 时由控制器写入）
            func idle(_ v: DropView) {
                v.setTargetName("00-收件箱")
                v.setResults([], empty: "输入关键词，同时搜库内笔记与本机文件")
                v.renderScene(.legacy)
            }
            shot("10-v170-idle", size: dd) { idle($0) }
            shot("11-v170-dragover", size: dd) { idle($0); $0.setHighlight(true) }
            shot("12-v170-recording", size: dd) {
                idle($0)
                $0.renderMemo(.recording(23, 0.62), partial: "")
            }
            shot("13-v170-transcribing", size: dd) {
                idle($0)
                $0.renderMemo(.transcribing(.analyzing(processed: 40, total: 120, chars: 63)),
                              partial: "")
            }
            shot("14-v170-ai-document", size: dd) {
                idle($0)
                $0.renderScene(.document)
                $0.renderAI(.working, phase: "提取文字", detail: "生成摘要概览")
            }
            shot("15-v170-ai-transcript", size: dd) {
                idle($0)
                $0.renderScene(.transcript)
                $0.renderAI(.working, phase: "润色分段", detail: "生成概览 · 修正错病语")
            }
            shot("16-v170-ai-image", size: dd) {
                idle($0)
                $0.renderScene(.image)
                $0.renderAI(.working, phase: "识别图片", detail: "生成概览")
            }
            shot("17-v170-success", size: dd) {
                idle($0)
                $0.renderScene(.document)
                $0.flash("已归档 3 个", ok: true)
                $0.renderBatch(success: 3, failed: 0)
            }
            shot("18-v170-error", size: dd) {
                idle($0)
                $0.renderScene(.image)
                $0.flash("失败", ok: false)
                $0.renderAI(.failed, phase: "识别失败", detail: "已按原模式归档")
            }
            shot("19-v170-searching", size: dd) {
                idle($0)
                $0.searchField.stringValue = "预焙阳极"
                $0.setSearching(true)
                $0.renderAI(.working, phase: "搜索中", detail: "库内全文 + Spotlight")
            }
            shot("20-v170-results", size: dd) {
                idle($0)
                $0.searchField.stringValue = "预焙阳极"
                $0.setResults(rows, empty: "")
            }
            shot("21-v170-empty", size: dd) {
                idle($0)
                $0.searchField.stringValue = "不存在的词"
                $0.setResults([], empty: "没有匹配的笔记，换个词试试")
            }
            if !failedShots.isEmpty {
                FileHandle.standardError.write(
                    "错误：\(failedShots.count) 张界面基线图未生成：\(failedShots.joined(separator: "、"))\n"
                        .data(using: .utf8)!)
                exit(1)
            }
            print("已输出到 \(out.path)")
            exit(0)
        }

        // 诊断：ObsidianDrop --record-test <音频文件>
        //
        // 模拟「麦克风录音」这条链路：按录音 tap 的方式（4096 帧一块）把音频
        // 写进 RecordingStore，再把生成的文件交给文件转写。本机没有麦克风时，
        // 这是唯一能端到端验证「先落盘、再转写」的办法——写入格式、文件可读性、
        // 转写产出三件事一次验完。
        if let i = args.firstIndex(of: "--record-test") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write("用法：ObsidianDrop --record-test <音频>\n".data(using: .utf8)!)
                exit(2)
            }
            let path = (args[i + 1] as NSString).expandingTildeInPath
            if #available(macOS 26.0, *) {
                let sem = DispatchSemaphore(value: 0)
                var failure: String?
                var textOut = ""
                var info = ""
                Task.detached(priority: .userInitiated) {
                    do {
                        let src = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                        let fmt = src.processingFormat
                        // 刻意写到**真实录音目录**，顺带验证那儿的写权限与剩余空间
                        let store = try RecordingStore()
                        let chunk: AVAudioFrameCount = 4096
                        while src.framePosition < src.length {
                            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
                            do {
                                try src.read(into: buf, frameCount: chunk)
                            } catch let e as NSError
                                where e.domain == NSOSStatusErrorDomain && e.code == -39 {
                                break
                            }
                            if buf.frameLength == 0 { break }
                            store.append(buf)
                        }
                        store.close()
                        info = "写入 \(store.url.lastPathComponent)："
                            + "\(String(format: "%.1f", store.seconds)) 秒 / \(store.sizeBytes) 字节"
                            + "，写入失败 \(store.writeErrors) 次"
                        let cli = CLIProgress()
                        let r = try await SpeechRunner.transcribeFile(at: store.url,
                                                                     localeID: Memo.localeID) { p in
                            cli.emit(p)
                        }
                        textOut = r.text
                        let back = try AVAudioFile(forReading: store.url)
                        info += " · 回读 \(String(format: "%.1f", Double(back.length) / back.processingFormat.sampleRate)) 秒"
                            + " · 转写 \(r.text.count) 字"
                        store.discard()
                    } catch {
                        failure = error.localizedDescription
                    }
                    sem.signal()
                }
                while sem.wait(timeout: .now() + 0.05) == .timedOut {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                if let failure {
                    FileHandle.standardError.write("错误：\(failure)\n".data(using: .utf8)!)
                    exit(1)
                }
                FileHandle.standardError.write("· \(info)\n".data(using: .utf8)!)
                print(textOut)
                exit(0)
            } else {
                FileHandle.standardError.write("需要 macOS 26 或更新系统\n".data(using: .utf8)!)
                exit(1)
            }
        }

        // 诊断：ObsidianDrop --transcribe-stream <音频文件>
        //
        // 用「实时录音」那条代码路径（make → feed → finish）转写同一段音频，
        // 用来和 --transcribe 的 analyzeSequence 结果对照：
        //   · 两边都出字  → 引擎没问题，问题在采集端（麦克风/权限/音量）
        //   · 只有这边出字不对 → 流式投喂或收尾有问题
        if let i = args.firstIndex(of: "--transcribe-stream") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write("用法：ObsidianDrop --transcribe-stream <音频>\n".data(using: .utf8)!)
                exit(2)
            }
            let path = (args[i + 1] as NSString).expandingTildeInPath
            if #available(macOS 26.0, *) {
                let sem = DispatchSemaphore(value: 0)
                var failure: String?
                var textOut = ""
                var statsLine = ""
                Task.detached(priority: .userInitiated) {
                    let cli = CLIProgress()
                    do {
                        let runner = try await SpeechRunner.make(localeID: Memo.localeID) { p in cli.emit(p) }
                        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                        let fmt = audio.processingFormat
                        let chunk: AVAudioFrameCount = 4096
                        while audio.framePosition < audio.length {
                            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
                            do {
                                try audio.read(into: buf, frameCount: chunk)
                            } catch let e as NSError where e.domain == NSOSStatusErrorDomain && e.code == -39 {
                                break
                            }
                            if buf.frameLength == 0 { break }
                            runner.feed(buf)
                        }
                        textOut = await runner.finish { p in cli.emit(p) }
                        statsLine = runner.stats
                    } catch {
                        failure = error.localizedDescription
                    }
                    sem.signal()
                }
                while sem.wait(timeout: .now() + 0.05) == .timedOut {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                if let failure {
                    FileHandle.standardError.write("错误：\(failure)\n".data(using: .utf8)!)
                    exit(1)
                }
                print(textOut)
                FileHandle.standardError.write("· \(statsLine)\n".data(using: .utf8)!)
                exit(textOut.isEmpty ? 1 : 0)
            } else {
                FileHandle.standardError.write("需要 macOS 26 或更高版本\n".data(using: .utf8)!)
                exit(1)
            }
        }

        // 命令行模式：ObsidianDrop --transcribe <音频文件> [--target 目标]
        // 把一段音频转成文字；带 --target 时顺便写成灵感笔记（用于自测与批量处理）
        if let i = args.firstIndex(of: "--transcribe") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write("用法：ObsidianDrop --transcribe <音频> [--target <目标>]\n".data(using: .utf8)!)
                exit(2)
            }
            let path = (args[i + 1] as NSString).expandingTildeInPath
            var target: String? = nil
            if let t = args.firstIndex(of: "--target") {
                // 与 --file 一致：给了 --target 却没给值，就是笔误，不能静默降级成「不写笔记」
                guard t + 1 < args.count, !args[t + 1].hasPrefix("--") else {
                    FileHandle.standardError.write("用法：--target 缺少目标值\n".data(using: .utf8)!)
                    exit(2)
                }
                target = args[t + 1]
            }
            // 可选：把结果（或错误）写进文件，便于从脚本/自动化里读取
            var outFile: URL? = nil
            if let o = args.firstIndex(of: "--out"), o + 1 < args.count {
                outFile = URL(fileURLWithPath: (args[o + 1] as NSString).expandingTildeInPath)
            }

            if #available(macOS 26.0, *) {
                let sem = DispatchSemaphore(value: 0)
                var failure: String? = nil
                var textOut = ""
                var secondsOut: Double = 0
                var noteRelOut: String?
                // 必须用 detached：`main()` 跑在主 actor 上，普通 Task 会继承主 actor 隔离，
                // 而下面要等信号量——主线程被占住，主 actor 上的任务永远排不上队 → 死锁。
                Task.detached(priority: .userInitiated) {
                    let cliProgress = CLIProgress()
                    do {
                        let r = try await SpeechRunner.transcribeFile(
                            at: URL(fileURLWithPath: path),
                            localeID: Memo.localeID
                        ) { p in
                            cliProgress.emit(p)
                        }
                        let text = r.text
                        let seconds = r.seconds
                        secondsOut = seconds
                        if text.isEmpty {
                            // 带上时长，便于区分「文件没读到音频」和「读到了但没人说话」
                            failure = String(format: "没有识别到语音（音频 %.1f 秒）. 可以先用 --transcribe-stream 复跑一遍，确认是引擎还是音频内容的问题", seconds)
                        } else {
                            textOut = text
                            if let outFile {
                                try? text.write(to: outFile, atomically: true, encoding: .utf8)
                            }
                            if let target {
                                let out = try Filer(vault: Cfg.vault).memo(text: text,
                                                                           target: target,
                                                                           duration: seconds,
                                                                           engine: "DictationTranscriber / \(Memo.localeName)")
                                noteRelOut = out.noteRel
                            }
                        }
                    } catch {
                        failure = error.localizedDescription
                    }
                    sem.signal()
                }
                // 等的时候要让主循环继续转，别把主线程堵死
                while sem.wait(timeout: .now() + 0.05) == .timedOut {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                if let failure {
                    FileHandle.standardError.write("错误：\(failure)\n".data(using: .utf8)!)
                    if let outFile {
                        try? "ERROR: \(failure)\n".write(to: outFile, atomically: true, encoding: .utf8)
                    }
                    exit(1)
                }
                if !textOut.isEmpty {
                    // 结果释义：字数 / 音频时长，脚本里一眼能看出这次转写是否正常
                    FileHandle.standardError.write(
                        "· 识别完成：\(textOut.count) 字 / \(Memo.humanDuration(secondsOut)) 音频\n"
                            .data(using: .utf8)!)
                    print(textOut)
                }
                if let noteRelOut { print("笔记: \(noteRelOut)") }
                exit(0)
            } else {
                FileHandle.standardError.write("需要 macOS 26 或更高版本\n".data(using: .utf8)!)
                exit(1)
            }
        }

        // 命令行模式：ObsidianDrop --file <path> [更多路径...] [--target 号-目录] [--json]
        //
        // 退出码约定（QA-001）：
        //   0 = 全部成功；3 = 部分成功；1 = 全部失败（或目标非法/库缺失）；2 = 用法错误
        // 部分成功单独给 3，调用方只需重试失败项，不会因为整批重跑而重复写入。
        if let i = args.firstIndex(of: "--file") {
            // 参数错误一律 exit 2 且不写任何文件。
            // 原来 --target 少给值会被静默忽略、退回「上次使用的目标」并归档成功，
            // 相当于把笔误投递到用户没预期的目录——比直接报错危险得多。
            let usage = "用法：ObsidianDrop --file <路径...> [--target <目标>] [--vault <库>] [--json]\n"
            let known: Set<String> = ["--file", "--target", "--vault", "--json"]
            // 单连字符（`-z`）也按未知选项处理；单独的 `-` 放行，可当普通值
            if let unknown = args.dropFirst().first(where: { arg in
                guard arg.hasPrefix("-"), arg != "-" else { return false }
                return !known.contains(arg)
            }) {
                FileHandle.standardError.write("错误：未知选项 \(unknown)\n\(usage)".data(using: .utf8)!)
                exit(2)
            }
            if let v = args.firstIndex(of: "--vault"),
               v + 1 >= args.count || args[v + 1].hasPrefix("--") {
                FileHandle.standardError.write("错误：--vault 缺少库路径\n\(usage)".data(using: .utf8)!)
                exit(2)
            }

            var paths: [String] = []
            var j = i + 1
            while j < args.count, !args[j].hasPrefix("--") {
                paths.append(args[j]); j += 1
            }
            var target = Cfg.storedTarget
            if let t = args.firstIndex(of: "--target") {
                guard t + 1 < args.count, !args[t + 1].hasPrefix("--") else {
                    FileHandle.standardError.write("错误：--target 缺少目标值\n\(usage)".data(using: .utf8)!)
                    exit(2)
                }
                target = args[t + 1]
            }
            let jsonOut = args.contains("--json")
            let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            guard !urls.isEmpty else {
                FileHandle.standardError.write(usage.data(using: .utf8)!)
                exit(2)
            }
            do {
                let report = try Filer(vault: Cfg.vault).file(urls, target: target)
                if jsonOut {
                    print(jsonString(report))
                } else {
                    printHuman(report)
                }
                if report.allSucceeded { exit(0) }
                exit(report.partial ? 3 : 1)
            } catch {
                FileHandle.standardError.write("错误：\(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
        }

        // 诊断：ObsidianDrop --ui-memo <音频> [--target 目标] [--vault 库]
        //
        // 走**完整界面链路**（与点菜单「转写音频文件…」完全同一条代码），
        // 结束时自动退出：0 = 界面已回到空闲且已归档；1 = 中途失败；2 = 120 秒没走完。
        // 这是「永远停在收尾中」这类问题的可重复验收入口——不需要麦克风。
        if let i = args.firstIndex(of: "--ui-memo") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(
                    "用法：ObsidianDrop --ui-memo <音频> [--target <目标>]\n".data(using: .utf8)!)
                exit(2)
            }
            AutoUI.memoFile = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
            if let t = args.firstIndex(of: "--target"), t + 1 < args.count {
                AutoUI.target = args[t + 1]
            }
        }

        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
