import AppKit
import UniformTypeIdentifiers
import ServiceManagement
import AVFoundation
import CoreAudio
import Speech
import os

// MARK: - 常量

enum Cfg {
    static let vaultKey = "vaultPath"
    static let targetKey = "targetRel"
    static let posXKey = "panelX"
    static let posYKey = "panelY"
    static let visibleKey = "panelVisible"
    /// 窗口是否置于底层（不挡其他窗口）
    static let bottomKey = "panelBottom"

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
    static func all(vault: URL) -> [ArchiveTarget] {
        var list: [ArchiveTarget] = [ArchiveTarget(rel: "00-收件箱", name: "00-收件箱")]
        let fm = FileManager.default
        let projectsDir = vault.appendingPathComponent("10-项目")
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
        return list
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

    init(source: String = "", noteRel: String, fileRel: String) {
        self.source = source
        self.noteRel = noteRel
        self.fileRel = fileRel
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

    func file(_ urls: [URL], target rel: String) throws -> BatchReport {
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

        // 逐个处理：单个文件失败不再中断整批，成功项与失败项都要留痕（QA-001）
        var report = BatchReport()
        for src in urls {
            do {
                report.outcomes.append(try archive(src, target: target, noteDir: noteDir, fileDir: fileDir))
            } catch {
                report.failures.append(BatchFailure(source: src.path, reason: error.localizedDescription))
            }
        }
        return report
    }

    /// 归档单个源文件；失败只抛出这一项的错误
    private func archive(_ src: URL, target: ArchiveTarget, noteDir: URL, fileDir: URL) throws -> DropOutcome {
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

        // 生成笔记
        let noteBase = uniqueURL(in: noteDir, base: "\(day) \(base)", ext: "md")
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
        var srcDir = (src.path as NSString).deletingLastPathComponent
        let tmpResolved = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath
        if (srcDir as NSString).resolvingSymlinksInPath == tmpResolved {
            srcDir = "本机屏幕截图"
        }
        let stamp = Filer.stampFmt.string(from: Date())
        // 提示里的目录直接取自实际落盘位置，避免和真实路径脱节（QA-005）
        let destDirRel = (destRel as NSString).deletingLastPathComponent
        let placeHint = target.kind == .project
            ? "`\(destDirRel)/`，会同步到 iPhone"
            : "`\(destDirRel)/`，会随库同步到手机"

        let front = """
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
        // 先复制附件、再写笔记：笔记写失败时必须把刚复制的附件也删掉。
        // 否则会「报告该项失败，但库里已经多了一份附件」，调用方按失败项重试就会重复。
        do {
            try front.write(to: noteBase, atomically: true, encoding: .utf8)
        } catch {
            try? fm.removeItem(at: dest)
            throw FilerError.noteFailed(noteBase.lastPathComponent, error.localizedDescription)
        }
        return DropOutcome(source: src.path, noteRel: relPath(noteBase), fileRel: destRel)
    }

    /// 把一段语音转写文稿写成笔记（不产生附件）
    func memo(text: String, target rel: String, duration: TimeInterval, engine: String) throws -> DropOutcome {
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
        let noteBase = uniqueURL(in: noteDir, base: "\(day) 灵感 \(hms)", ext: "md")
        let dur = Memo.clock(duration)

        // 正文按空行分段，读起来像随手记而不是一整坨
        let paragraphs = text
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let body = """
        ---
        类型: 灵感速记
        创建时间: \(stamp)
        时长: \(dur)
        目标: \(rel)
        转写: 端上本机（\(engine)）
        tags:
        \(Filer.yamlTags(["灵感", target.tag]))
        ---

        # 灵感 \(stamp)

        \(paragraphs)

        > [!note] 录制信息
        > - 时长：\(dur)
        > - 转写：Mac 本机完成，未上传云端
        > - 由 ObsidianDrop 于 \(stamp) 录在「\(rel)」

        """
        try body.write(to: noteBase, atomically: true, encoding: .utf8)
        return DropOutcome(noteRel: relPath(noteBase), fileRel: "")
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
    /// 单次录音上限（秒）。超时自动结束并转写。
    static let maxSeconds: Double = 300

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
        let stamp = DateFormatter()
        stamp.dateFormat = "MM-dd HH:mm:ss.SSS"
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > limit {
                try? fm.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
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
        let finalizeLimit = min(max(15.0, seconds / 20.0), 180.0)
        let finalizeOK = await runWithTimeout(seconds: finalizeLimit) {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        DiagLog.write("收尾：用时 \(String(format: "%.1f", Date().timeIntervalSince(finStart)))s"
                      + "（限 \(Int(finalizeLimit))s），" + (finalizeOK ? "正常" : "超时") + "，字数 \(box.count)")
        if !finalizeOK { NSLog("ObsidianDrop: 文件转写收尾超时（\(Int(finalizeLimit))s），返回已识别内容") }
        let drainOK = await runWithTimeout(seconds: 5) { _ = await collector.value }
        if !drainOK {
            // 收尾都结束了结果流还没走完：后面这批结果就是「已经识别出来但没读走」，
            // 不说出来，下次还会被当成丢字去查引擎。
            DiagLog.write("注意：结果流 5 秒内没有收完（collector 超时），可能有结果没被读走")
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
    /// 超时上限**跟着音频长度走**：实时录音（≤5 分钟）边录边转、积压很少，10 秒够了；
    /// 但「转写音频文件」是把整个文件按最大速度灌进分析器，喂完时分析器里还积压着
    /// 大段未消化的音频（实测 1 小时音频灌入只要十几秒，分析却要几十秒），
    /// 固定 10 秒会把尾巴整段丢掉。
    func finish(progress: @escaping (TranscribeProgress) -> Void = { _ in }) async -> String {
        // 0) 先把转换器里没吐完的尾巴 flush 出来，否则最后一点音频会丢
        for input in feeder.flush() { continuation.yield(input) }

        // 1) 通知分析器：没有更多音频了
        continuation.finish()

        let audioSeconds = fedSeconds
        // 约 30 倍实时（下限 10s，上限 3 分钟）——实测分析吞吐在 90 倍实时左右，留足余量
        let finalizeLimit = min(max(10.0, audioSeconds / 30.0), 180.0)
        // 结果流收尾只需等分析器把最后一批结果吐完，比 finalize 短
        let drainLimit = min(max(5.0, audioSeconds / 120.0), 30.0)

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
        _ = try? fm.removeItem(at: final)
        try fm.moveItem(at: tmp, to: final)
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

    static func load(id: String) -> PendingMemo? { all().first { $0.id == id } }

    static func remove(id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }

    static var count: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".json") }.count ?? 0
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
    static func archive(_ m: PendingMemo) throws -> DropOutcome? {
        try queue.sync {
            // 已经在别处归档过：pending 被删掉就是唯一事实，别信内存里的状态
            guard FileManager.default.fileExists(atPath: path(m.id)) else { return nil }
            let out = try Filer(vault: m.vault).memo(text: m.text, target: m.target,
                                                     duration: m.duration, engine: m.engine)
            // **先确认笔记写成功，再删 pending 和录音**。
            // 顺序反了就等于「删完才发现没写成」——1.3.13 的丢数据正是这么来的。
            PendingStore.remove(id: m.id)
            if !m.audioPath.isEmpty { try? FileManager.default.removeItem(atPath: m.audioPath) }
            return out
        }
    }

    /// 补归档：把还没写进笔记的结果补上（启动时 / 看门狗恢复时 / 轮次被顶掉时）。
    @discardableResult
    static func drain(limit: Int = 5) -> (ok: Int, failed: Int) {
        var ok = 0, failed = 0
        for m in PendingStore.all().prefix(limit) {
            do {
                if let out = try archive(m) {
                    ok += 1
                    DiagLog.write("补归档完成：\(m.id) → \(out.noteRel)（\(m.text.count) 字）")
                }
            } catch {
                failed += 1
                DiagLog.write("补归档失败：\(m.id) ｜ \(error.localizedDescription)"
                              + "（pending 与录音都保留）")
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
                //    5 分钟上限也不会触发（计时器已经停了）。
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
                                        attempts: 0)
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

    /// 完全不参与命中测试
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setHovered(_ v: Bool) { hovered = v }

    /// 录音时会换成「结束」+ 红色
    func setStyle(title: String, symbol: String, tint: NSColor, tip: String? = nil) {
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        baseTint = tint
        if let tip { toolTip = tip }
        refresh()
    }

    private func refresh() {
        contentTintColor = hovered ? .controlAccentColor : baseTint
        layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(hovered ? 0.14 : 0.07).cgColor
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
        let t = Timer(timeInterval: 0.055, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase = (self.phase + 0.055).truncatingRemainder(dividingBy: 1)
            self.needsDisplay = true
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
    private var iconSymbol = "arrow.down.doc"

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
        effect.alphaValue = 0.97
        addSubview(effect)

        icon.image = NSImage(systemSymbolName: "arrow.down.doc",
                             accessibilityDescription: "投放")
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

        // 最后一个加入，保证虚线边框绘制在所有内容之上
        borderView.frame = bounds
        borderView.autoresizingMask = [.width, .height]
        addSubview(borderView)
    }

    override func layout() {
        super.layout()
        borderView.frame = bounds
        ring.frame = Self.ringFrame(in: bounds)
    }

    /// 进度环的位置：水平居中、垂直居中在图标那块区域上（面板顶部）
    private static func ringFrame(in b: NSRect) -> NSRect {
        let s: CGFloat = 52
        let iconCenterY = b.height - 72 + 23
        return NSRect(x: (b.width - s) / 2, y: iconCenterY - s / 2, width: s, height: s)
    }

    func setTargetName(_ s: String) {
        targetName = s
        subtitle.stringValue = "→ " + s
    }

    func flash(_ text: String, ok: Bool) {
        title.stringValue = text
        title.textColor = ok ? .systemGreen : .systemRed
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(resetTitle), object: nil)
        perform(#selector(resetTitle), with: nil, afterDelay: 2.5)
    }

    @objc private func resetTitle() { restoreIdle() }

    /// 回到常规状态（图标、标题、目标名、提示）
    private func restoreIdle() {
        ring.show(.hidden)
        setIcon("arrow.down.doc", tint: .controlAccentColor)
        title.stringValue = "把文件拖进来"
        title.textColor = .labelColor
        subtitle.stringValue = targetName.isEmpty ? "" : "→ " + targetName
        hintLabel.stringValue = "双击打开 Obsidian"
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
            hintLabel.stringValue = "音频先存到本地 · 最长 5 分钟"
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
    }

    /// 图标按名字缓存，避免每 0.1 秒重建一次 NSImage
    private func setIcon(_ symbol: String, tint: NSColor) {
        if iconSymbol != symbol {
            iconSymbol = symbol
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        }
        icon.contentTintColor = tint
        icon.alphaValue = 1
    }

    private func setHighlight(_ on: Bool) {
        dragging = on
        borderView.dragging = on
        effect.material = on ? .selection : .popover
        title.stringValue = on ? "松手即归档" : "把文件拖进来"
        title.textColor = on ? .controlAccentColor : .labelColor
    }

    // 拖入
    // 命中区修正（2026-11-03）：本视图的子视图（毛玻璃层、图标、文字）会把
    // 拖放命中截断，导致只有没被覆盖的最外圈边框能触发。这里让整块面板都
    // 命中到自己，子视图一律不参与命中，拖到框内任何位置都能进 draggingEntered。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return super.hitTest(point) }
        return bounds.contains(convert(point, from: sv)) ? self : nil
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
        dragOrigin = NSEvent.mouseLocation
        windowOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragOrigin.x
        let dy = now.y - dragOrigin.y
        if abs(dx) > 2 || abs(dy) > 2 { didDrag = true }
        w.setFrameOrigin(NSPoint(x: windowOrigin.x + dx, y: windowOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            if let o = window?.frame.origin {
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

// MARK: - 面板

final class DropPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
        buildPanel()
        lastTarget = Cfg.storedTarget
        dropView.setTargetName(lastTarget)
        let visible = UserDefaults.standard.object(forKey: Cfg.visibleKey) as? Bool ?? true
        setPanelVisible(visible)
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
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill",
                              accessibilityDescription: "ObsidianDrop")
            b.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "显示/隐藏 投放窗口", action: #selector(togglePanel), keyEquivalent: "").target = self
        m.addItem(withTitle: "把窗口移到右下角", action: #selector(resetPosition), keyEquivalent: "").target = self

        let bottom = NSMenuItem(title: "窗口置于底层（不挡其他窗口）",
                                action: #selector(toggleBottom), keyEquivalent: "")
        bottom.target = self
        bottom.state = UserDefaults.standard.bool(forKey: Cfg.bottomKey) ? .on : .off
        m.addItem(bottom)

        let shotHeader = NSMenuItem(title: "截图", action: nil, keyEquivalent: "")
        let shotMenu = NSMenu()
        addShotItem(shotMenu, "区域截图并归档", .area)
        addShotItem(shotMenu, "整屏截图并归档", .full)
        addShotItem(shotMenu, "窗口截图并归档", .window)
        shotMenu.addItem(.separator())
        addShotItem(shotMenu, "区域截图到剪贴板", .clipboard)
        shotHeader.submenu = shotMenu
        m.addItem(shotHeader)

        let memoItem = NSMenuItem(title: memoMenuTitle, action: #selector(startOrStopMemo), keyEquivalent: "")
        memoItem.target = self
        memoItem.isEnabled = memoState != .transcribing
        m.addItem(memoItem)

        // 没有麦克风的机器（比如 Mac mini）用这条：直接转写已有的音频文件
        let memoFileItem = NSMenuItem(title: "转写音频文件…",
                                      action: #selector(transcribeAudioFile), keyEquivalent: "")
        memoFileItem.target = self
        memoFileItem.isEnabled = memoState == .idle
        m.addItem(memoFileItem)

        // 兜底入口：文件在面板里被系统置灰（常见于外部拷来的文件）时，
        // 在 Finder 里 ⌘C 复制它，再点这里，绕开面板判定。
        let memoClipItem = NSMenuItem(title: "转写剪贴板里的音频",
                                      action: #selector(transcribeAudioFromClipboard), keyEquivalent: "")
        memoClipItem.target = self
        memoClipItem.isEnabled = memoState == .idle
        m.addItem(memoClipItem)

        m.addItem(.separator())

        let targetHeader = NSMenuItem(title: "投递目标", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.delegate = self
        targetsMenu = sub
        populateTargets()
        targetHeader.submenu = sub
        m.addItem(targetHeader)

        m.addItem(.separator())
        m.addItem(withTitle: "打开 Obsidian", action: #selector(openObsidian), keyEquivalent: "").target = self
        m.addItem(withTitle: "打开库目录", action: #selector(openVault), keyEquivalent: "").target = self
        m.addItem(withTitle: "打开附件目录", action: #selector(openAttachments), keyEquivalent: "").target = self
        // 出问题时要的第一样东西就是日志。别让用户去 Finder 里一层层翻。
        m.addItem(withTitle: "打开运行日志", action: #selector(openLog), keyEquivalent: "").target = self
        m.addItem(withTitle: "复制日志路径", action: #selector(copyLogPath), keyEquivalent: "").target = self

        let autoOpen = NSMenuItem(title: "投递后打开新笔记", action: #selector(toggleAutoOpen), keyEquivalent: "")
        autoOpen.target = self
        autoOpen.state = UserDefaults.standard.bool(forKey: "autoOpenNote") ? .on : .off
        m.addItem(autoOpen)

        let login = NSMenuItem(title: "开机自动启动", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = isLoginEnabled() ? .on : .off
        m.addItem(login)

        m.addItem(.separator())
        m.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = m
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
        let size = NSSize(width: 160, height: 176)
        panel = DropPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        dropView = DropView(frame: NSRect(origin: .zero, size: size))
        dropView.onDrop = { [weak self] urls in self?.handleDrop(urls) }
        dropView.onDoubleClick = { [weak self] in self?.openObsidian() }
        dropView.onScreenshot = { [weak self] in self?.takeScreenshot(.area) }
        dropView.onMemo = { [weak self] in self?.startOrStopMemo() }
        dropView.onRightClick = { [weak self] event in
            guard let self, let m = self.statusItem.menu else { return }
            NSMenu.popUpContextMenu(m, with: event, for: self.dropView)
        }
        panel.contentView = dropView

        // 还原位置，默认右下角
        let ud = UserDefaults.standard
        let hasPos = ud.object(forKey: Cfg.posXKey) != nil
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = hasPos
            ? NSPoint(x: ud.double(forKey: Cfg.posXKey), y: ud.double(forKey: Cfg.posYKey))
            : NSPoint(x: screen.maxX - size.width - 32, y: screen.minY + 32)
        panel.setFrameOrigin(origin)
        applyWindowLevel()
    }

    private func setPanelVisible(_ v: Bool) {
        if v { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        UserDefaults.standard.set(v, forKey: Cfg.visibleKey)
    }

    @objc private func resetPosition() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let s = panel.frame.size
        let p = NSPoint(x: screen.maxX - s.width - 32, y: screen.minY + 32)
        panel.setFrameOrigin(p)
        UserDefaults.standard.set(Double(p.x), forKey: Cfg.posXKey)
        UserDefaults.standard.set(Double(p.y), forKey: Cfg.posYKey)
        setPanelVisible(true)
    }

    @objc private func togglePanel() {
        setPanelVisible(!(panel.isVisible))
    }

    // 窗口层级：floating（默认，悬浮在所有窗口之上）/ 底层（压在桌面之上、所有窗口之下）
    private func applyWindowLevel() {
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

        do {
            let report = try Filer(vault: Cfg.vault).file([file], target: lastTarget)
            try? FileManager.default.removeItem(at: file)
            if let failure = report.failures.first {
                dropView.flash("截图归档失败", ok: false)
                let a = NSAlert()
                a.messageText = "截图已生成，但归档失败"
                a.informativeText = failure.reason
                a.alertStyle = .warning
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
                return
            }
            dropView.flash("截图已归档", ok: true)
            if let first = report.outcomes.first {
                NSLog("ObsidianDrop: 截图 → \(first.fileRel)")
                if UserDefaults.standard.bool(forKey: "autoOpenNote") {
                    openNote(rel: first.noteRel)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            dropView.flash("归档失败", ok: false)
            let a = NSAlert()
            a.messageText = "截图已生成，但归档失败"
            a.informativeText = error.localizedDescription
            a.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
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
                                        attempts: 0)
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
            if elapsed >= Memo.maxSeconds {
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
        // 恢复界面只是「让人能继续操作」，不是「这一轮作废」。
        // 队列里有文字就先补写——这是 1.3.13 完全缺失的一步：
        // 那时结果被丢弃后既没归档也没人管，用户等 2.5 分钟只等到一句「卡住了」。
        var drained = (ok: 0, failed: 0)
        if queued > 0 {
            drained = MemoArchiveQueue.drain()
            DiagLog.round(memoRunID, "看门狗：补归档成功 \(drained.ok) 条，失败 \(drained.failed) 条")
        }
        memoState = .idle
        memoSession = nil
        stopMemoTimer()
        stopWatchdog()
        lastPartial = ""
        dropView.renderMemo(.idle, partial: "")
        dropView.flash(drained.ok > 0 ? "文字已归档，界面已恢复" : "转写卡住了，已恢复", ok: drained.ok > 0)
        rebuildMenu()

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
        let filer = Filer(vault: Cfg.vault)
        do {
            let report = try filer.file(urls, target: lastTarget)
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
                let msg = report.outcomes.count == 1 ? "已归档 1 个" : "已归档 \(report.outcomes.count) 个"
                dropView.flash(msg, ok: true)
            }
            NSLog("ObsidianDrop: \(report.outcomes.map { $0.fileRel }.joined(separator: ", "))")
            if UserDefaults.standard.bool(forKey: "autoOpenNote"), let first = report.outcomes.first {
                openNote(rel: first.noteRel)
            }
        } catch {
            dropView.flash("失败", ok: false)
            let a = NSAlert()
            a.messageText = "归档失败"
            a.informativeText = error.localizedDescription
            a.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
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
                    if let out { NSLog("ObsidianDrop: 灵感 → \(out.noteRel)") }
                    if autoOpen, let out { self.openNote(rel: out.noteRel) }
                    AutoUI.finish(0, "OK 界面已复位并归档：\(out?.noteRel ?? "（已由其他路径归档）")")
                }
            } catch {
                DiagLog.round(run, "归档失败：\(String(format: "%.2f", Date().timeIntervalSince(archiveStart)))s ｜ \(error.localizedDescription)"
                              + "（文字仍在待归档队列 \(item.id)，录音保留）")
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
                let report = try Filer(vault: Cfg.vault).file([f], target: target)
                try? FileManager.default.removeItem(at: f)
                if let failure = report.failures.first {
                    FileHandle.standardError.write("错误：\(failure.reason)\n".data(using: .utf8)!)
                    exit(1)
                }
                for x in report.outcomes {
                    print("笔记: \(x.noteRel)")
                    print("文件: \(x.fileRel)")
                }
                exit(0)
            } catch {
                FileHandle.standardError.write("错误：\(error.localizedDescription)\n".data(using: .utf8)!)
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
            let size = NSSize(width: 160, height: 176)
            let out = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            func shot(_ name: String, _ body: (DropView) -> Void) {
                let v = DropView(frame: NSRect(origin: .zero, size: size))
                body(v)
                v.layoutSubtreeIfNeeded()
                guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                // 毛玻璃在离屏渲染里是空心的，先铺底色才看得清排版
                NSGraphicsContext.saveGraphicsState()
                if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                    NSGraphicsContext.current = ctx
                    NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
                    NSRect(origin: .zero, size: v.bounds.size).fill()
                }
                v.cacheDisplay(in: v.bounds, to: rep)
                NSGraphicsContext.restoreGraphicsState()
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: out.appendingPathComponent("\(name).png"))
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
