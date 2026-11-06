import Foundation
import Darwin

// MARK: - 1.7.0 归档公共上下文
//
// 规格 A1/A7：一次投递从「源文件」到「笔记 + 埋点」全程共用一个 captureId，
// 12 秒 AI 预算是**整批**的，不是每个文件各 12 秒。这两件事必须显式建模，
// 否则批量拖 10 个文档就会让界面卡两分钟。

struct ArchiveContext {
    let captureId: String
    /// drop / record / file / screenshot / cli —— 只决定埋点 kind 与文案
    let source: String
    /// document / transcript / image / legacy —— 只决定 AI 请求与正文模板
    var scene: AIScene
    let target: String
    let sourceURL: URL?
    let batchBudget: AIBatchBudget

    init(captureId: String = UUID().uuidString, source: String, scene: AIScene,
         target: String, sourceURL: URL? = nil,
         batchBudget: AIBatchBudget = AIBatchBudget()) {
        self.captureId = captureId
        self.source = source
        self.scene = scene
        self.target = target
        self.sourceURL = sourceURL
        self.batchBudget = batchBudget
    }
}

/// 整批共享的绝对 deadline。所有请求从这里取预算，不从 Date() 重新起跑。
final class AIBatchBudget {
    let deadline: Date
    let cap: Double

    init(total: Double = AIConfig().effectiveBudget, cap: Double = AIConfig().effectiveBudget,
         now: Date = Date()) {
        self.deadline = now.addingTimeInterval(total)
        self.cap = cap
    }

    var remaining: TimeInterval { deadline.timeIntervalSinceNow }

    /// 还剩 N 项需要请求时，本次请求能拿到的预算。
    /// nil = 预算耗尽，调用方直接标 skipped 并按旧模板落盘。
    func attemptBudget(pending n: Int) -> Double? {
        guard n > 0 else { return nil }
        let r = remaining
        guard r >= 1.1 else { return nil }
        return min(cap, max(0.9, (r - 0.2) / Double(n)))
    }
}

// MARK: - 独占发布笔记
//
// 规格 A6.7：只新建、不覆盖。先写隐藏临时文件并 fsync，再用 link(2) 原子发布；
// EEXIST 说明同一瞬间有人抢先占了名字，换下一个候选名重试（最多 100 次）。
// write(atomically:) 在「先 uniqueURL 再写」的窗口里仍可能覆盖别人刚建的笔记。

enum ExclusiveNoteWriter {
    enum PublishError: LocalizedError {
        case noFreeName(String)
        case tempWrite(String)
        case linkFailed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .noFreeName(let b): return "100 次重试都撞名：\(b)"
            case .tempWrite(let m): return "临时笔记写入失败：\(m)"
            case .linkFailed(let p, let e): return "笔记发布失败：\(p)（errno \(e)）"
            }
        }
    }

    /// 返回原子发布后的 URL。fileName 不含扩展名。
    @discardableResult
    static func publish(text: String, dir: URL, base: String,
                        ext: String = "md") throws -> URL {
        let fm = FileManager.default
        sweepStaleTemp(in: dir)
        let tmp = dir.appendingPathComponent(".od-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tmp) }
        do {
            try Data(text.utf8).write(to: tmp, options: .atomic)
            let fh = try FileHandle(forUpdating: tmp)
            try fh.synchronize()
            try fh.close()
        } catch {
            throw PublishError.tempWrite(error.localizedDescription)
        }
        _ = try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)

        for i in 0..<100 {
            let name = i == 0 ? "\(base).\(ext)" : "\(base)-\(i + 1).\(ext)"
            let dest = dir.appendingPathComponent(name)
            if Darwin.link(tmp.path, dest.path) == 0 {
                // 文件本身已 fsync，但目录项也要落盘，否则断电后 link 可能丢。
                // NSFileHandle 对目录的 fsync 是 best-effort，失败不影响本次发布成功。
                if let dh = try? FileHandle(forReadingFrom: dir) {
                    try? dh.synchronize()
                    try? dh.close()
                }
                return dest
            }
            if errno == EEXIST { continue }
            throw PublishError.linkFailed(dest.path, errno)
        }
        throw PublishError.noFreeName(base)
    }

    /// 进程在「写完临时文件、还没 link」被强杀，会留下一个隐藏 `.od-*.tmp`。
    /// 只清超过 1 小时的，避免误删同一瞬间另一进程正在写的那一份。
    static func sweepStaleTemp(in dir: URL, olderThan: TimeInterval = 3600) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let cutoff = Date().addingTimeInterval(-olderThan)
        for n in names where n.hasPrefix(".od-") && n.hasSuffix(".tmp") {
            let u = dir.appendingPathComponent(n)
            guard let a = try? fm.attributesOfItem(atPath: u.path),
                  let m = a[.modificationDate] as? Date, m < cutoff else { continue }
            try? fm.removeItem(at: u)
        }
    }
}
