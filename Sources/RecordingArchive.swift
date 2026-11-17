import AVFoundation
import Foundation

/// 把录音原文件（设备原生 48k float32 caf）转成 AAC 16k 单声道，落到库里留档。
///
/// 为什么必须存：
/// 1.7.0 及以前转写成功就 `discard()` 删掉原文件。后果是「用户感觉少了一截」时
/// 既不能确认当时到底说没说话，也不能确认是真丢字，更没法换更好的模型重转写——
/// 唯一的复核依据被自己删了。原文件的价值不在「回听」，在于**可复核、可重跑**。
///
/// 格式选择实测（同一段 536.5s 语音，四次转写字数 1962 / 2047 / 2093 / 2152）：
/// 字数波动 ±4.6%，与编码无关；16k 无损的 2047 正好落在原文件两次结果中间。
/// 所以 AAC 压缩没有额外识别损失，体积却只有 16k 无损（16MB）的 1/10、
/// 原始 caf（23MB，60 分钟约 664MB）的 1/61 —— 约 10.9 MB/小时。
enum RecordingArchive {
    enum Failure: LocalizedError {
        case encodeFailed(String)
        case verifyFailed(String)
        case noSpace(need: Int64, free: Int64)

        var errorDescription: String? {
            switch self {
            case .encodeFailed(let m): return "录音原文件转换失败：\(m)"
            case .verifyFailed(let m): return "录音原文件校验失败：\(m)"
            case .noSpace(let need, let free):
                return "磁盘空间不足：转换约需 \(RecordingArchive.mb(need))，当前可用 \(RecordingArchive.mb(free))。原始录音已保留，可稍后手动转换"
            }
        }
    }

    struct Outcome {
        /// 库内 m4a 的绝对路径
        let url: URL
        /// 相对库根的路径，写进笔记 frontmatter 与正文链接
        let relPath: String
        let seconds: Double
        let bytes: Int64
    }

    /// AAC-LC 单声道 48 kbps，**保留源采样率**（真机是 48 kHz）。
    ///
    /// 早期版本用 16 kHz / 24 kbps，体积只有一半，但实测掉 8.8% 的识别内容：
    /// 同一段 536.5s 语音，原文件稳定出 2152 字，16k/24k 稳定出 1962 字（各跑 3 次）。
    /// 改到 48 kbps 后是 2142 字（-0.5%），体积从 10.9 涨到约 21 MB/小时。
    /// 这份文件的核心价值是「可重转写」，为省一半空间丢掉近一成的字不划算。
    static let bitRate = 48000

    static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    /// 预估产物体积（用于磁盘预检）。AAC 恒定码率，误差很小。
    static func estimatedBytes(seconds: Double) -> Int64 {
        Int64(max(0, seconds) * Double(bitRate) / 8.0 * 1.05) + 64 * 1024
    }

    /// 库内目标目录：`<库>/附件/录音/YYYY-MM`
    static func directory(vault: URL, at date: Date) throws -> URL {
        let fm = FileManager.default
        let month = dateFormatter("yyyy-MM").string(from: date)
        let raw = vault.appendingPathComponent("附件")
            .appendingPathComponent("录音")
            .appendingPathComponent(month)
        // 与 Filer 一致：库里可能已存在同名软链，建目录前后各校验一次。
        // createDirectory 对「目录已存在」不报错，只靠它成功与否判断会漏掉逃逸。
        _ = try VaultGuard.ensureInside(raw, vault: vault, label: "录音目录")
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        return try VaultGuard.ensureInside(raw, vault: vault, label: "录音目录")
    }

    /// 库内该路径是否已有一份可用的录音。
    ///
    /// 补归档会重新走一遍 `archive()`：如果上一次「转码成功、笔记没写成」，
    /// 这次必须直接复用库内那份，不能转第二遍（否则每次都多一个 `-2` 文件，
    /// 永久的录音会越堆越多）。
    static func existing(rel: String, vault: URL) -> Outcome? {
        guard !rel.isEmpty else { return nil }
        let url = vault.appendingPathComponent(rel)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        // 只是「文件在」不够：崩溃可能留下 0 字节或半个 m4a
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value, size > 1024
        else { return nil }
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0, file.length > 0
        else { return nil }   // 打不开就是坏文件，交给调用方重转
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        return Outcome(url: url, relPath: rel, seconds: seconds, bytes: size)
    }

    /// 转码并落库。
    ///
    /// - Parameters:
    ///   - caf: 录音原始文件（设备原生格式）
    ///   - vault: 库根
    ///   - date: 录音开始时间，决定目录与文件名
    /// - Returns: 库内 m4a 信息；调用方成功后才可以删原始 caf
    static func export(caf: URL, vault: URL, at date: Date = Date()) throws -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: caf.path) else {
            throw Failure.encodeFailed("原始录音不存在：\(caf.path)")
        }

        let src: AVAudioFile
        do { src = try AVAudioFile(forReading: caf) }
        catch { throw Failure.encodeFailed("打不开原始录音：\(error.localizedDescription)") }

        let srcSeconds = src.processingFormat.sampleRate > 0
            ? Double(src.length) / src.processingFormat.sampleRate : 0
        guard srcSeconds > 0 else {
            throw Failure.encodeFailed("原始录音时长为 0（\(caf.lastPathComponent)）")
        }

        // 磁盘预检：不留余量的话，转一半失败会留下半个 m4a，比不转更糟
        let need = estimatedBytes(seconds: srcSeconds)
        if let free = availableBytes(at: vault), free < need * 2 {
            throw Failure.noSpace(need: need, free: free)
        }

        let dir = try directory(vault: vault, at: date)
        let stamp = dateFormatter("yyyyMMdd-HHmmss").string(from: date)
        let dst = uniqueURL(in: dir, base: "\(stamp)-灵感", ext: "m4a")

        // 先写到临时目录，校验通过再落进库。
        // 直接写最终路径的话，编码或校验中途失败/崩溃会在库里留下半个 m4a，
        // 下次重名检查会把它当成「已有录音」，真正的新录音被挤成 -2。
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("obsidiandrop-\(UUID().uuidString).m4a")
        defer { try? fm.removeItem(at: tmp) }

        _ = try encode(src: src, to: tmp)

        // 回读校验：编码器没 flush 干净时这里会失败（ExtAudioFileOpenURL / 1685348671），
        // 让问题在「保存原文件」这一步暴露，而不是等用户点了链接才发现播不了。
        let back: AVAudioFile
        do { back = try AVAudioFile(forReading: tmp) }
        catch { throw Failure.verifyFailed("产物打不开：\(error.localizedDescription)") }
        let backSeconds = back.processingFormat.sampleRate > 0
            ? Double(back.length) / back.processingFormat.sampleRate : 0
        // AAC 有编码延迟（通常几十毫秒），差 0.5 秒以上认为是真问题
        guard abs(backSeconds - srcSeconds) < 0.5 else {
            throw Failure.verifyFailed(
                String(format: "产物时长 %.2fs 与原始 %.2fs 相差过大", backSeconds, srcSeconds))
        }

        try moveIntoPlace(from: tmp, to: dst)

        let bytes = (try? fm.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber
        let relPath = relativePath(of: dst, vault: vault)
        return Outcome(url: dst, relPath: relPath, seconds: backSeconds,
                       bytes: bytes?.int64Value ?? 0)
    }

    /// 把校验过的临时件搬进库里。
    ///
    /// 同一卷用 `moveItem`（原子）；库在 iCloud/外置盘时目标卷不同，move 会失败，
    /// 退回「复制 → 比对大小 → 删临时件」。跨卷复制不是原子的，所以必须比对大小，
    /// 否则磁盘满会留下一个看起来正常、其实截断的 m4a。
    private static func moveIntoPlace(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if (try? fm.moveItem(at: src, to: dst)) != nil { return }

        do { try fm.copyItem(at: src, to: dst) }
        catch { throw Failure.encodeFailed("落库失败：\(error.localizedDescription)") }

        let a = (try? fm.attributesOfItem(atPath: src.path))?[.size] as? NSNumber
        let b = (try? fm.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber
        guard a?.int64Value == b?.int64Value else {
            try? fm.removeItem(at: dst)
            throw Failure.encodeFailed("落库后大小与校验前不一致（可能磁盘已满）")
        }
    }

    // MARK: - 编码

    /// 编码到 AAC。返回写出的帧数。
    ///
    /// 关键：`AVAudioFile` 的写入句柄**必须先释放**，调用方才能回读/移动产物。
    /// 句柄还活着时 moov box 没落盘，AVAudioFile 回读会报
    /// `ExtAudioFileOpenURL` 失败（Code=1685348671）。所以这里用 optional 变量，
    /// 编码结束立刻置 nil，不依赖作用域结束时的 ARC 时机。
    private static func encode(src: AVAudioFile, to dstURL: URL) throws -> AVAudioFramePosition {
        // 保留源采样率：刻意降到 16k 会额外丢字（实测 16k 无损 2047 字 vs 原文件 2152）
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: src.processingFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]

        var file: AVAudioFile?
        do {
            file = try AVAudioFile(forWriting: dstURL, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw Failure.encodeFailed("建不了输出文件：\(error.localizedDescription)")
        }
        guard let dst = file else { throw Failure.encodeFailed("输出文件为空") }

        guard let conv = AVAudioConverter(from: src.processingFormat, to: dst.processingFormat) else {
            throw Failure.encodeFailed(
                "不支持的转换：\(Int(src.processingFormat.sampleRate))Hz/"
                + "\(src.processingFormat.channelCount)ch → \(Int(dst.processingFormat.sampleRate))Hz/1ch")
        }

        let inCap: AVAudioFrameCount = 16384
        let outCap: AVAudioFrameCount = 8192
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: inCap),
              let outBuf = AVAudioPCMBuffer(pcmFormat: dst.processingFormat, frameCapacity: outCap)
        else { throw Failure.encodeFailed("分配缓冲区失败") }

        var total: AVAudioFramePosition = 0
        var eof = false
        var guardCount = 0

        while true {
            guardCount += 1
            // 死循环保护：输入读完就该退出，转不完说明转换器状态异常
            if guardCount > 5_000_000 { throw Failure.encodeFailed("转换未能在合理轮次内结束") }

            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
                if eof {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    inBuf.frameLength = 0
                    try src.read(into: inBuf, frameCount: inCap)
                } catch {
                    eof = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    eof = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if let err { throw Failure.encodeFailed(err.localizedDescription) }
            if status == .error { throw Failure.encodeFailed("转换器返回错误状态") }

            if outBuf.frameLength > 0 {
                do {
                    try dst.write(from: outBuf)
                    total += AVAudioFramePosition(outBuf.frameLength)
                } catch { throw Failure.encodeFailed(error.localizedDescription) }
            }
            if status == .endOfStream { break }
        }

        // 先关句柄，再由调用方回读
        file = nil
        _ = file
        return total
    }

    // MARK: - 工具

    private static func dateFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// 重名时加 `-2`、`-3`，不覆盖已有录音
    private static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private static func relativePath(of url: URL, vault: URL) -> String {
        let v = vault.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(v + "/") else { return p }
        return String(p.dropFirst(v.count + 1))
    }

    private static func availableBytes(at url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let n = v?.volumeAvailableCapacityForImportantUsage { return n }
        let a = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (a?[.systemFreeSize] as? NSNumber)?.int64Value
    }
}
