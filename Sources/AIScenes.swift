import Foundation
import Darwin
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - 1.7.0 AI 场景基础设施（规格 A2 / A3）
//
// 这一层只负责「把输入变成模型能吃的料」，不含提示词、网络或落盘：
//   · 分类：一次投递到底走 document / transcript / image / legacy
//   · 取文：文本 / PDF / 现代 Office / 旧 .doc
//   · 编码：图片首帧 → 白底 JPEG → base64 data URI
// 之所以能独立自检：全是纯函数式的「文件进、结果出」，不依赖 GUI 与网络。

enum AIScene: String, Codable, Equatable, CaseIterable {
    case document
    case transcript
    case image
    case legacy

    var label: String {
        switch self {
        case .document: return "文档摘要"
        case .transcript: return "转录整理"
        case .image: return "图像概览"
        case .legacy: return "原样归档"
        }
    }

    var usesModel: Bool { self != .legacy }
}

// MARK: - 分类

enum SceneRouter {
    static let textExts: Set<String> = [
        "md", "markdown", "txt", "text", "csv", "tsv", "json", "jsonl", "yaml", "yml",
        "xml", "html", "htm", "log", "py", "swift", "js", "ts", "sh", "rb", "go",
        "java", "c", "h", "cpp", "sql", "css", "scss", "ini", "conf", "tex", "org",
    ]
    static let richTextExts: Set<String> = ["rtf", "rtfd"]
    static let pdfExts: Set<String> = ["pdf"]
    /// 现代 OOXML（可用 /usr/bin/unzip 只读抽文本）
    static let ooxmlExts: Set<String> = ["docx", "xlsx", "pptx"]
    /// 旧式 Word：textutil 可转；旧 xls/ppt 直接 legacy
    static let legacyWordExts: Set<String> = ["doc"]
    /// SVG 是矢量文本，但按规格不进视觉、也不当文档摘要
    static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "avif",
    ]
    static let legacyExts: Set<String> = [
        "zip", "7z", "rar", "gz", "bz2", "tar", "dmg", "svg", "svgz",
        "mp3", "wav", "m4a", "aac", "flac", "ogg", "mp4", "mov", "avi", "mkv",
        "xls", "ppt", "app", "dylib", "o", "bin", "exe", "iso", "pkg",
    ]

    static let textMax = 10 * 1024 * 1024
    static let officeMax = 32 * 1024 * 1024
    static let hardMax = 100 * 1024 * 1024

    /// UTType 为主、扩展名为兜底。系统没给出类型时（无扩展名 / 自定义后缀）才看后缀。
    static func kind(of url: URL) -> (ext: String, type: String) {
        let ext = url.pathExtension.lowercased()
        var type = "application/octet-stream"
        if let ut = UTType(filenameExtension: ext) { type = ut.identifier }
        if SceneRouter.textExts.contains(ext) { type = "text/\(ext == "md" ? "markdown" : "plain")" }
        if ext == "pdf" { type = "application/pdf" }
        if ext == "json" { type = "application/json" }
        return (ext, type)
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// 用 ImageIO 真解一次首帧；只看扩展名会把无后缀截图误判成 legacy。
    static func decodableImage(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              CGImageSourceCreateImageAtIndex(src, 0, nil) != nil else { return false }
        return true
    }

    /// 按规格 A2 的优先级命中即停。
    /// `origin` 只用来表达 pending 转写（最高优先级）与截图来源。
    static func classify(file url: URL?, origin: String = "drop") -> AIScene {
        if origin == "record" || origin == "file" { return .transcript }
        guard let url else { return .legacy }
        let real = url.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real.path, isDirectory: &isDir),
              !isDir.boolValue else { return .legacy }
        let size = fileSize(real)
        guard size > 0, size <= hardMax else { return .legacy }
        let (ext, _) = kind(of: real)
        if legacyExts.contains(ext) { return .legacy }
        if origin == "screenshot" {
            // A2：截图必须按「能不能真的解出位图首帧」判定，不靠扩展名。
            // 屏幕截图可能没有扩展名；反过来临时目录里普通带扩展名的图片
            // 也不是截图，来源文案由 ArchiveContext.source 决定，不靠路径猜。
            return decodableImage(real) ? .image : .legacy
        }
        if imageExts.contains(ext) { return size <= hardMax ? .image : .legacy }
        if textExts.contains(ext) || richTextExts.contains(ext) {
            return size <= textMax ? .document : .legacy
        }
        if pdfExts.contains(ext) || ooxmlExts.contains(ext) || legacyWordExts.contains(ext) {
            return size <= officeMax ? .document : .legacy
        }
        return .legacy
    }

    /// 分类 + 真实试提取。取不到文字/解不了图的，一律回落 legacy，
    /// 绝不把二进制或空串交给模型。
    static func resolve(file url: URL?, origin: String = "drop") -> AIScene {
        let s = classify(file: url, origin: origin)
        guard s == .document, let url else { return s }
        do { _ = try DocumentText.extract(url) ; return .document }
        catch { return .legacy }
    }
}

// MARK: - 文档取文

enum DocumentText {
    static let defaultLimit = 12_000

    struct Extracted: Equatable {
        var text: String
        var truncated: Bool
        var kind: String        // plain / pdf / rtf / ooxml / word97
        var fileType: String
    }

    static func extract(_ url: URL, limit: Int = defaultLimit) throws -> Extracted {
        let real = url.resolvingSymlinksInPath()
        let (ext, mime) = SceneRouter.kind(of: real)
        let size = SceneRouter.fileSize(real)
        guard size > 0, size <= SceneRouter.hardMax else { throw SceneError.notReadable("文件过大或为空") }

        let raw: String
        let kind: String
        if SceneRouter.pdfExts.contains(ext) {
            raw = try pdfText(real, limit: limit)
            kind = "pdf"
        } else if SceneRouter.ooxmlExts.contains(ext) {
            raw = try ooxmlText(real, ext: ext, limit: limit)
            kind = "ooxml"
        } else if SceneRouter.legacyWordExts.contains(ext) {
            raw = try word97Text(real, limit: limit)
            kind = "word97"
        } else if SceneRouter.richTextExts.contains(ext) {
            guard let a = try? NSAttributedString(url: real, options: [:],
                                                  documentAttributes: nil) else {
                throw SceneError.notReadable("RTF 无法读取")
            }
            raw = a.string
            kind = "rtf"
        } else if SceneRouter.textExts.contains(ext) {
            raw = try plainText(real)
            kind = "plain"
        } else {
            throw SceneError.notReadable("不支持的类型 .\(ext)")
        }

        let cleaned = clean(raw)
        guard cleaned.count >= 12 else { throw SceneError.notReadable("正文太短或没有可提取文字") }
        let truncated = cleaned.count > limit
        return Extracted(text: truncated ? String(cleaned.prefix(limit)) : cleaned,
                         truncated: truncated, kind: kind, fileType: mime)
    }

    private static func plainText(_ url: URL) throws -> String {
        guard let d = try? Data(contentsOf: url) else { throw SceneError.notReadable("读不到文件") }
        // NUL 占比 > 1% 视为二进制，避免把可执行文件的乱码送给模型
        let nul = d.prefix(64 * 1024).filter { $0 == 0 }.count
        if !d.isEmpty, Double(nul) / Double(min(d.count, 64 * 1024)) > 0.01 {
            throw SceneError.notReadable("二进制内容")
        }
        if let s = String(data: d, encoding: .utf8) { return s }
        if let s = decodeUTF16(d) { return s }
        var used: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &used) { return s }
        if let s = String(data: d, encoding: .isoLatin1) { return s }
        throw SceneError.notReadable("无法解码文本")
    }

    private static func decodeUTF16(_ d: Data) -> String? {
        if d.starts(with: [0xFF, 0xFE]) { return String(data: d, encoding: .utf16LittleEndian) }
        if d.starts(with: [0xFE, 0xFF]) { return String(data: d, encoding: .utf16BigEndian) }
        return nil
    }

    private static func pdfText(_ url: URL, limit: Int) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw SceneError.notReadable("PDF 打不开") }
        var out = ""
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i)?.string else { continue }
            out += p + "\n"
            if out.count >= limit { break }
        }
        // 只有空白、页码、页眉的扫描件：去掉非字母数字后几乎没内容
        let meaningful = out.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        guard meaningful >= 20 else { throw SceneError.notReadable("PDF 没有文字层（可能是扫描件）") }
        return out
    }

    /// 用系统 unzip **只读**指定 XML 到内存，不落盘、不递归解包。
    private static func ooxmlText(_ url: URL, ext: String, limit: Int) throws -> String {
        guard SceneRouter.fileSize(url) <= SceneRouter.officeMax else {
            throw SceneError.notReadable("Office 文件过大")
        }
        let entries = unzipList(url)
        guard !entries.isEmpty, entries.count <= 2000 else {
            throw SceneError.notReadable("压缩包条目异常")
        }
        let wanted: [String]
        switch ext {
        case "docx": wanted = ["word/document.xml"]
        case "xlsx": wanted = ["xl/sharedStrings.xml"]
            + entries.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }.sorted()
        default: wanted = entries.filter {
            $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml")
        }.sorted { a, b in
            let na = Int((a as NSString).lastPathComponent
                .replacingOccurrences(of: "slide", with: "")
                .replacingOccurrences(of: ".xml", with: "")) ?? 0
            let nb = Int((b as NSString).lastPathComponent
                .replacingOccurrences(of: "slide", with: "")
                .replacingOccurrences(of: ".xml", with: "")) ?? 0
            return na < nb
        }
        }
        var out = ""
        for (i, entry) in wanted.enumerated() {
            guard let xml = unzipEntry(url, entry), xml.count <= 8 * 1024 * 1024 else { continue }
            let text = plainFromXML(xml)
            if text.isEmpty { continue }
            if ext == "pptx" { out += "幻灯片 \(i + 1)\n" }
            if ext == "xlsx" && entry.hasPrefix("xl/worksheets/") {
                out += "工作表 \(i)\n"
            }
            out += text + "\n"
            if out.count >= limit { break }
        }
        guard out.trimmed.count >= 12 else { throw SceneError.notReadable("Office 里没有可提取文字") }
        return out
    }

    private static func word97Text(_ url: URL, limit: Int) throws -> String {
        guard let out = runProcess("/usr/bin/textutil",
                                   ["-convert", "txt", "-stdout", url.path],
                                   timeout: 3, limitBytes: limit * 4),
              out.trimmed.count >= 12 else {
            throw SceneError.notReadable("旧版 .doc 无法取文")
        }
        return out
    }

    /// 只抽 <w:t>/<a:t>/<t> 的文本节点，用段落/行标签切行；不做 XML 解析，
    /// 因为这里只需要「可读文字」，而且恶意 XML 不该被当成文档执行。
    private static func plainFromXML(_ xml: String) -> String {
        var s = xml
            .replacingOccurrences(of: "</w:p>", with: "\n")
            .replacingOccurrences(of: "</a:p>", with: "\n")
            .replacingOccurrences(of: "</row>", with: "\n")
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                       ("&quot;", "\""), ("&apos;", "'"), ("&#10;", "\n")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func unzipList(_ url: URL) -> [String] {
        guard let out = runProcess("/usr/bin/unzip", ["-Z1", url.path], timeout: 3,
                                   limitBytes: 512 * 1024) else { return [] }
        return out.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private static func unzipEntry(_ url: URL, _ entry: String) -> String? {
        runProcess("/usr/bin/unzip", ["-p", url.path, entry], timeout: 4,
                   limitBytes: 8 * 1024 * 1024)
    }

    /// 带硬超时的外部命令。超时直接 terminate，避免恶意压缩包把进程挂死。
    private static func runProcess(_ path: String, _ args: [String], timeout: TimeInterval,
                                   limitBytes: Int) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let pid = p.processIdentifier
        // 两级超时：先 TERM，1 秒后仍活着就 KILL。
        // 只发一次 TERM 不够：忽略 SIGTERM 的子进程会让 availableData / waitUntilExit
        // 永久挂住，而这里是归档队列上的同步调用，一次卡住就拖死整批投递。
        let q = DispatchQueue.global()
        let term = DispatchSource.makeTimerSource(queue: q)
        term.schedule(deadline: .now() + timeout)
        term.setEventHandler { if p.isRunning { p.terminate() } }
        term.resume()
        let killer = DispatchSource.makeTimerSource(queue: q)
        killer.schedule(deadline: .now() + timeout + 1)
        killer.setEventHandler {
            if p.isRunning { _ = Darwin.kill(pid, SIGKILL) }
        }
        killer.resume()
        defer { term.cancel(); killer.cancel() }

        // 分块读：到上限立刻停，不再无界 readDataToEndOfFile()。
        let fh = pipe.fileHandleForReading
        var data = Data()
        var overflow = false
        while true {
            let chunk = fh.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > limitBytes { overflow = true; break }
        }
        if overflow {
            // 关读端让写端收 EPIPE，子进程自然退出；SIGKILL 定时器是最后兜底。
            fh.closeFile()
            if p.isRunning { p.terminate() }
        }
        p.waitUntilExit()
        guard !overflow, p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 去掉控制字符、压缩连续空行。PDFKit 抽出的文本常夹 NUL，原样塞 JSON 会 400。
    static func clean(_ s: String) -> String {
        let scalars = s.unicodeScalars.filter { sc in
            let v = sc.value
            return v == 10 || v == 13 || v == 9 || v >= 32
        }
        let t = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var out: [String] = []
        var blank = false
        for l in t.components(separatedBy: "\n") {
            let line = l.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if blank { continue }
                blank = true
            } else { blank = false }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmed
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum SceneError: LocalizedError {
    case notReadable(String)
    case tooLarge(Int)
    case imageTooLarge(Int)
    case imageUndecodable

    var errorDescription: String? {
        switch self {
        case .notReadable(let m): return "无法取文：\(m)"
        case .tooLarge(let n): return "文件过大（\(n / 1024 / 1024)MB），不做摘要"
        case .imageTooLarge(let n): return "图片压缩后仍超过 \(n / 1024 / 1024)MB，跳过识别"
        case .imageUndecodable: return "图片无法解码或像素总数超限"
        }
    }
}

// MARK: - 图片材料（规格 A3.4 / A8）

enum ImagePayload {
    static let maxBytes = 4 * 1024 * 1024
    static let maxPixels = 100_000_000
    /// (最长边, JPEG 质量) 三档，依次尝试
    static let steps: [(CGFloat, CGFloat)] = [(2048, 0.85), (1600, 0.78), (1280, 0.70)]

    struct Encoded: Equatable {
        var dataURI: String
        var width: Int
        var height: Int
        var bytes: Int
    }

    static func encode(_ url: URL) throws -> Encoded {
        let real = url.resolvingSymlinksInPath()
        guard let source = CGImageSourceCreateWithURL(real as CFURL, nil) else {
            throw SceneError.imageUndecodable
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let w0 = props[kCGImagePropertyPixelWidth] as? Int,
              let h0 = props[kCGImagePropertyPixelHeight] as? Int,
              w0 > 0, h0 > 0, w0 * h0 <= maxPixels else {
            throw SceneError.imageUndecodable
        }
        for (side, quality) in steps {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailWithTransform: true, // 应用 EXIF 方向
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
                  let d = jpeg(cg, quality: quality), d.count <= maxBytes else { continue }
            return Encoded(dataURI: "data:image/jpeg;base64," + d.base64EncodedString(),
                           width: cg.width, height: cg.height, bytes: d.count)
        }
        throw SceneError.imageTooLarge(maxBytes)
    }

    /// 透明像素铺白底，否则 PNG 转 JPEG 时模型看到一张黑图。
    private static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        let m = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(m, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, out,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return m as Data
    }
}

// MARK: - 材料准备（分类 → 提取/编码 → 模型输入）

enum SceneMaterial {
    struct Prepared {
        var scene: AIScene
        var input: AISceneInput?
        var reason: String     // 仅脱敏短句，可进日志/埋点
    }

    /// 一次完成所有本地准备工作。失败时 scene 回落 legacy、input = nil。
    static func prepare(url: URL?, origin: String, target: String,
                        transcriptText: String? = nil, engine: String = "",
                        duration: Double = 0,
                        forcedScene: AIScene? = nil) -> Prepared {
        // A1：调用方已经定下场景时（ArchiveContext.scene / CLI --scene）就以它为准，
        // 不再分类第二次。以前 Filer 会忽略传入场景，导致报告与实际处理对不上。
        let s = forcedScene ?? SceneRouter.classify(file: url, origin: origin)
        // 显式场景优先：调用方已定下场景（CLI --scene / ArchiveContext.scene）时，
        // 不能因为 origin 恰好是 record/file 又悄悄改回 transcript，否则报告与实际处理不一致。
        let implicitTranscript = forcedScene == nil
            && (origin == "record" || origin == "file")
        if s == .transcript || implicitTranscript {
            let text = transcriptText ?? ""
            return Prepared(scene: .transcript,
                            input: .transcript(text: text, target: target, engine: engine,
                                               duration: duration),
                            reason: "")
        }
        guard let url else { return Prepared(scene: .legacy, input: nil, reason: "没有源文件") }
        // 天生 legacy 不是失败：reason 留空，最终状态 off，也不写 ai 事件（规格 A10）。
        if s == .legacy { return Prepared(scene: .legacy, input: nil, reason: "") }
        if s == .document {
            do {
                let x = try DocumentText.extract(url)
                return Prepared(scene: .document,
                                input: .document(text: x.text, filename: url.lastPathComponent,
                                                 target: target, fileType: x.fileType,
                                                 truncated: x.truncated),
                                reason: "")
            } catch {
                return Prepared(scene: .legacy, input: nil,
                                reason: error.localizedDescription)
            }
        }
        do {
            let img = try ImagePayload.encode(url)
            return Prepared(scene: .image,
                            input: .image(dataURI: img.dataURI,
                                          filename: url.lastPathComponent, target: target,
                                          width: img.width, height: img.height,
                                          origin: origin),
                            reason: "")
        } catch {
            return Prepared(scene: .legacy, input: nil, reason: error.localizedDescription)
        }
    }
}
