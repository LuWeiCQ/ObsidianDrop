import Foundation

// MARK: - 1.7.0 场景化命令行（规格 A11）
//
// 保留 `--ai-run <文字>` 的旧用法；带 --scene/--source/--archive/--mock-* 时走这里。
// 默认 --dry-run：只分类、提取、给出 payload 摘要，不写库、不联网。
// --archive 必须显式给 --vault：绝不允许把测试笔记写进真实库。
// 文件参数可重复；整批共用一个 12 秒 AI 预算，JSON 逐项输出结果。

struct MockTransport: AITransport {
    let content: String?
    let error: Error?

    func post(url: URL, key: String, body: Data, budget: Double) throws -> Data {
        if let error { throw error }
        let payload: [String: Any] = [
            "choices": [["message": ["content": content ?? "{}"]]],
            "model": "mock",
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    func get(url: URL, key: String, budget: Double) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": [["id": "mock-model"]]])
    }
}

enum SceneCLI {
    private static let valueFlags: Set<String> = [
        "--scene", "--source", "--target", "--vault", "--text", "--file",
        "--mock-response", "--mock-error", "--vision",
    ]
    private static let switchFlags: Set<String> = ["--archive", "--dry-run", "--json"]

    /// 只有 1.7.0 新增的标志才算「走场景 CLI」。
    /// `--target` 是 1.6.0 旧用法 `--ai-run "一段文字" --target 目标` 就在用的参数，
    /// 不能因为它出现在命令行里就把旧用法截到新链路（第二轮复核发现的回归）。
    private static let sceneOnlyFlags: Set<String> = [
        "--scene", "--source", "--vault", "--text", "--file",
        "--mock-response", "--mock-error", "--vision",
        "--archive", "--dry-run", "--json",
    ]

    /// 纯函数，供内置自检断言：旧 AICLI 用法（可带 --target）必须原样保留。
    static func isLegacyAIUsage(_ args: [String]) -> Bool {
        !args.contains(where: { sceneOnlyFlags.contains($0) })
    }

    /// A11 归档退出码：0 全成功 / 1 一项没成 / 3 部分成功。抽成纯函数供自检断言。
    static func archiveExitCode(ok: Int, total: Int) -> Int32 {
        let failed = total - ok
        return failed == 0 ? 0 : (ok == 0 ? 1 : 3)
    }

    static func run(_ args: [String]) -> Int32 {
        // 旧用法：--ai-run "一段文字" [--target 目标]
        if isLegacyAIUsage(args) {
            // `--target` 缺值 exit 2 是跨版本硬约束，旧链路同样不能静默回退。
            if let bad = missingValue(in: args) { return fail(bad, code: 2) }
            let i = args.firstIndex(of: "--ai-run") ?? 0
            let raw = i + 1 < args.count ? args[i + 1] : ""
            let p = (raw as NSString).expandingTildeInPath
            let text = (FileManager.default.fileExists(atPath: p)
                        ? (try? String(contentsOfFile: p, encoding: .utf8)) : nil) ?? raw
            let target = value(of: "--target", in: args) ?? Cfg.storedTarget
            return AICLI.run(text: text, target: target)
        }

        // A11：出现但缺值的参数一律 exit 2，不许静默回退到默认值。
        // 1.6.0 的 `--target` 缺值 exit 2 是硬约束，场景 CLI 不能开后门。
        if let bad = missingValue(in: args) { return fail(bad, code: 2) }

        let sceneArg = value(of: "--scene", in: args) ?? "auto"
        let forced: AIScene? = sceneArg == "auto" ? nil : AIScene(rawValue: sceneArg)
        if sceneArg != "auto", forced == nil {
            return fail("--scene 只接受 auto|document|transcript|image|legacy，收到「\(sceneArg)」",
                        code: 2)
        }
        let source = value(of: "--source", in: args) ?? "drop"
        guard ["drop", "transcript", "screenshot"].contains(source) else {
            return fail("--source 只接受 drop|transcript|screenshot，收到「\(source)」", code: 2)
        }
        // 矛盾输入要明说，不能让 --scene 被 --source 悄悄吃掉，也不能反过来。
        if source == "transcript", let forced, forced != .transcript {
            return fail("--source transcript 与 --scene \(forced.rawValue) 冲突；"
                        + "转录请用 --scene transcript 或 auto", code: 2)
        }
        let target = value(of: "--target", in: args) ?? "00-收件箱"
        let archive = args.contains("--archive")
        let vaultOverride = value(of: "--vault", in: args)
        if archive && (vaultOverride == nil || (vaultOverride ?? "").isEmpty) {
            return fail("--archive 必须显式给 --vault <临时库>", code: 2)
        }

        let text = value(of: "--text", in: args)
        let fromFileFlag = !allValues(of: "--file", in: args).isEmpty
        var files = allValues(of: "--file", in: args)
        files.append(contentsOf: positionalFiles(in: args))
        // 同一个路径被 --file 和位置参数各给一次时不要重复归档
        var seen = Set<String>()
        files = files.filter { seen.insert($0).inserted }
        if let text, !files.isEmpty {
            return fail("--text 与文件参数不能同时给", code: 2)
        }
        let inputs: [String] = text.map { [$0] } ?? files
        guard !inputs.isEmpty else {
            return fail("缺少输入：--ai-run <路径> 或 --text <文字>", code: 2)
        }
        // `--source transcript` 且给的是「一段文字」才算文本输入；显式 --file
        // 或路径确实存在时按文件处理，别把文件路径本身当成转写内容。
        let isTextOnly = text != nil
            || (!fromFileFlag && source == "transcript"
                && inputs.allSatisfy { !FileManager.default.fileExists(
                    atPath: ($0 as NSString).expandingTildeInPath) })
        if isTextOnly, inputs.count > 1 {
            return fail("转录场景一次只接受一个 --text", code: 2)
        }
        if archive, forced == .transcript, text == nil {
            return fail("--archive --scene transcript 请用 --text <文字> 指定转写内容", code: 2)
        }

        // 场景 CLI 用进程内配置快照：强制启用、Key 用内存假值，不写偏好也不碰钥匙串。
        var cliConfig = AIConfigStore.config
        cliConfig.enabled = true
        if let vm = value(of: "--vision", in: args) { cliConfig.visionModel = vm }
        AIConfigStore.overrideConfig = cliConfig
        AIKeychain.overrideKey = "scene-cli-mock-key"

        if let mock = value(of: "--mock-response", in: args) {
            let content = (try? String(contentsOfFile: mock, encoding: .utf8)) ?? "{}"
            AIService.transport = MockTransport(content: content, error: nil)
        } else if let e = value(of: "--mock-error", in: args) {
            let err: Error
            switch e {
            case "timeout": err = AIError.timeout
            case "malformed": err = AIError.badResponse("mock malformed")
            case "vision-unsupported": err = AIError.http(415, "mock vision unsupported")
            case "no-key":
                AIKeychain.overrideKey = ""
                err = AIError.notConfigured("没有配置 API Key")
            default: return fail("未知 --mock-error：\(e)", code: 2)
            }
            AIService.transport = MockTransport(content: nil, error: err)
        }

        return runScene(inputs: inputs, isTextOnly: isTextOnly, forced: forced,
                        source: source, target: target, archive: archive,
                        mockError: value(of: "--mock-error", in: args))
    }

    private struct Item {
        var input: String
        var url: URL?
        var prepared: SceneMaterial.Prepared
        var scene: AIScene
    }

    private static func runScene(inputs: [String], isTextOnly: Bool, forced: AIScene?,
                                 source: String, target: String, archive: Bool,
                                 mockError: String?) -> Int32 {
        let origin = source == "transcript" ? "record" : source
        var items: [Item] = []
        // A11 修补：一个缺失文件不能中止整批。记成单项失败，继续归档其余项，
        // 最终由 archiveExitCode 给 0/1/3；以前这里直接 return 1，有效项一个都不会写。
        var missing: [(input: String, reason: String)] = []
        for raw in inputs {
            let url: URL? = isTextOnly ? nil
                : URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            if let url, !FileManager.default.fileExists(atPath: url.path) {
                missing.append((raw, "文件不存在：\(url.path)"))
                continue
            }
            // 强制 transcript 且给的是文件时，把文件正文当作转写文字
            var transcriptText: String? = isTextOnly ? raw : nil
            if forced == .transcript, transcriptText == nil {
                transcriptText = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            }
            let prepared = SceneMaterial.prepare(url: url, origin: origin, target: target,
                                                 transcriptText: transcriptText,
                                                 engine: "cli", duration: 0,
                                                 forcedScene: forced)
            items.append(Item(input: raw, url: url, prepared: prepared,
                              scene: forced ?? prepared.scene))
        }

        let missingInfos: [[String: Any]] = missing.map {
            ["input": ($0.input as NSString).lastPathComponent,
             "scene": "none", "aiState": "off", "fallbackReason": $0.reason,
             "template": "none", "noteRel": "", "error": $0.reason]
        }

        if !archive {
            var infos = items.map { dryRunInfo($0) }
            // 取文失败（有 reason 且没有 payload）算输入失败；天生 legacy 的 reason 为空，不算。
            var failed = items.filter { $0.prepared.input == nil && !$0.prepared.reason.isEmpty }.count
            infos.append(contentsOf: missingInfos)
            failed += missing.count
            let code: Int32 = failed == 0 ? 0 : (failed == infos.count ? 1 : 3)
            if infos.count == 1 {
                return printJSON(infos[0],
                                 human: items.first.map { "场景 \($0.scene.rawValue)" } ?? "文件不存在",
                                 code: code)
            }
            return printJSON(["count": infos.count, "items": infos, "failed": failed],
                             human: "批量 \(infos.count) 项", code: code)
        }

        let vault = Cfg.vault
        if items.isEmpty {
            if missingInfos.count == 1 {
                return printJSON(missingInfos[0], human: "文件不存在", code: 1)
            }
            return printJSON(["count": missing.count, "items": missingInfos,
                              "succeeded": 0, "failed": missing.count],
                             human: "批量 \(missing.count) 项全部失败", code: 1)
        }
        do {
            if isTextOnly {
                let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("od-scene-cli-\(UUID().uuidString)", isDirectory: true)
                PendingStore.overrideDirectory = tmp
                defer {
                    PendingStore.overrideDirectory = nil
                    try? FileManager.default.removeItem(at: tmp)
                }
                let m = PendingMemo(id: UUID().uuidString, text: inputs[0], duration: 0,
                                    target: target, vaultPath: vault.path, engine: "cli",
                                    audioPath: "", source: "record", createdAt: Date(),
                                    attempts: 0, aiState: .pending, aiScene: .transcript)
                try PendingStore.enqueue(m)
                guard let out = try MemoArchiveQueue.archive(m) else {
                    return fail("归档没有产生笔记", code: 3)
                }
                let state = aiStateOf(noteAt: vault.appendingPathComponent(out.noteRel))
                return printJSON(resultInfo(scene: items[0].scene, state: state,
                                            noteRel: out.noteRel, captureId: m.id,
                                            mockError: mockError),
                                 human: "笔记 \(out.noteRel) · AI \(state.rawValue)", code: 0)
            }

            // 批量：整批一个 12 秒预算，context 里带上「用户明确指定的场景」，
            // Filer 不再二次分类（A1 / A11）。
            let budget = AIBatchBudget(cap: AIConfigStore.config.effectiveBudget)
            let urls = items.compactMap(\.url)
            let contexts = items.map {
                // 用「取文之前」的分类：文档取文失败要让 Filer 再试一次并标 skipped，
                // 而不是把已经回落成 legacy 的结果直接当 off 跳过 AI 埋点。
                ArchiveContext(source: source,
                               scene: forced ?? SceneRouter.classify(file: $0.url, origin: origin),
                               target: target, sourceURL: $0.url, batchBudget: budget)
            }
            let report = try Filer(vault: vault).file(urls, target: target, contexts: contexts)
            var infos: [[String: Any]] = []
            for (i, it) in items.enumerated() {
                let want = it.url?.path ?? it.input
                if let o = report.outcomes.first(where: { $0.source == want }) {
                    infos.append(resultInfo(scene: it.scene, state: o.aiState,
                                            noteRel: o.noteRel, captureId: o.captureId,
                                            mockError: mockError))
                } else {
                    let reason = report.failures.first(where: { $0.source == want })?.reason
                        ?? "该项没有产出笔记"
                    infos.append(["input": it.url?.lastPathComponent ?? "",
                                  "scene": it.scene.rawValue, "aiState": "off",
                                  "fallbackReason": reason, "template": "none",
                                  "noteRel": "", "captureId": contexts[i].captureId])
                }
            }
            infos.append(contentsOf: missingInfos)
            // A11 退出码：0 全部归档成功（AI 可 done/skipped）；1 一项笔记都没产出；
            // 3 部分成功（有写入失败）。以前一律返回 0，自动化会拿到「全失败但成功」的假阳性。
            let okCount = infos.filter { !(($0["noteRel"] as? String) ?? "").isEmpty }.count
            let failed = infos.count - okCount
            let code = archiveExitCode(ok: okCount, total: infos.count)
            if infos.count == 1 {
                return printJSON(infos[0], human: "笔记 \(infos[0]["noteRel"] ?? "")", code: code)
            }
            return printJSON(["count": infos.count, "items": infos,
                              "succeeded": okCount, "failed": failed],
                             human: "批量归档 \(infos.count) 项", code: code)
        } catch {
            return fail(error.localizedDescription, code: 3)
        }
    }

    private static func dryRunInfo(_ it: Item) -> [String: Any] {
        let chars: Int
        switch it.prepared.input {
        case .some(.document(let t, _, _, _, _)): chars = t.count
        case .some(.transcript(let t, _, _, _)): chars = t.count
        case .some(.image(let uri, _, _, _, _, _)): chars = uri.count
        case .none: chars = 0
        }
        var info: [String: Any] = [
            "input": it.url?.lastPathComponent ?? "text",
            "scene": it.scene.rawValue,
            "preparedScene": it.prepared.scene.rawValue,
            "chars": chars,
            "hasPayload": it.prepared.input != nil,
            "reason": it.prepared.reason,
            "template": it.prepared.input == nil ? "legacy" : it.scene.rawValue,
        ]
        if let inp = it.prepared.input,
           let body = AISceneService.requestBody(input: inp, config: AIConfigStore.config),
           let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            info["model"] = obj["model"] ?? ""
            info["messages"] = (obj["messages"] as? [Any])?.count ?? 0
            // payload 摘要不能带图片数据
            info["payloadBytes"] = body.count
        }
        return info
    }

    private static func resultInfo(scene: AIScene, state: AIState, noteRel: String,
                                   captureId: String, mockError: String?) -> [String: Any] {
        [
            "scene": scene.rawValue,
            "aiState": state.rawValue,
            "fallbackReason": state == .skipped ? (mockError ?? "skipped") : "",
            "template": state == .done ? scene.rawValue : "legacy",
            "noteRel": noteRel,
            "captureId": captureId,
        ]
    }

    private static func aiStateOf(noteAt url: URL) -> AIState {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return .off }
        if s.contains("AI: 跳过") { return .skipped }
        if s.contains("AI: \"") { return .done }
        return .off
    }

    private static func missingValue(in args: [String]) -> String? {
        for (i, a) in args.enumerated() where valueFlags.contains(a) {
            if i + 1 >= args.count || args[i + 1].hasPrefix("--") {
                return "\(a) 缺少值"
            }
        }
        return nil
    }

    private static func value(of flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count,
              !args[i + 1].hasPrefix("--") else { return nil }
        return args[i + 1]
    }

    /// 文件参数可重复（A11）：收集所有 `--file <路径>`。
    private static func allValues(of flag: String, in args: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == flag, i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                out.append(args[i + 1])
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    /// `--ai-run` 后面连续的非 `--` 参数都是文件；`--ai-run --text "…"` 时为空。
    private static func positionalFiles(in args: [String]) -> [String] {
        guard let i = args.firstIndex(of: "--ai-run") else { return [] }
        var out: [String] = []
        var j = i + 1
        while j < args.count, !args[j].hasPrefix("--") {
            out.append(args[j])
            j += 1
        }
        return out
    }

    private static func printJSON(_ obj: [String: Any], human: String, code: Int32) -> Int32 {
        if let d = try? JSONSerialization.data(withJSONObject: obj,
                                               options: [.sortedKeys, .withoutEscapingSlashes]),
           let s = String(data: d, encoding: .utf8) {
            print(s)
        } else {
            print(human)
        }
        return code
    }

    private static func fail(_ m: String, code: Int32) -> Int32 {
        FileHandle.standardError.write(("错误：" + m + "\n").data(using: .utf8)!)
        return code
    }
}
