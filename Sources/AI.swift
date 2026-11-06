import Foundation
import Security

// MARK: - 入库前的 AI 处理环节（1.5.0）
//
// 位置很关键：AI 只能挂在 `MemoArchiveQueue.archive()` 里，不能挂在界面的
// 「转写完成」回调上——后者会被看门狗、启动补归档、轮次顶掉这三条路径绕过，
// 于是同一段文字有时过了 AI、有时没过，而且**看不见**。
//
// 状态必须是显式的四态。用 `decoration == nil` 表示「还没处理」是错的：
// 它同时意味着「AI 关着」「处理失败」「处理完了但没结果」，重试逻辑会重复计费。

enum AIState: String, Codable {
    /// 没启用（或没配置），本次不处理
    case off
    /// 已排队，还没结果
    case pending
    /// 处理完成，结果已写进笔记
    case done
    /// 尝试过但失败/超时，已按「原样入库」继续
    case skipped
}

struct AIResult: Codable, Equatable {
    var title: String
    var summary: String
    var tags: [String]
    var model: String
    var ms: Int
}

enum AIError: LocalizedError {
    case notConfigured(String)
    case badURL(String)
    case http(Int, String)
    case badResponse(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConfigured(let m): return m
        case .badURL(let m): return m
        case .http(let code, let body):
            let b = body.count > 200 ? String(body.prefix(200)) + "…" : body
            return "接口返回 HTTP \(code)：\(b)"
        case .badResponse(let m): return "响应无法解析：\(m)"
        case .timeout: return "超过时间预算，已放弃（原文照常入库）"
        }
    }
}

// MARK: - 配置

struct AIConfig: Codable, Equatable {
    var enabled = false
    /// 只允许 OpenAI 兼容的 base（会自动拼 `/chat/completions`）
    var baseURL = "https://api.openai.com/v1"
    var model = "gpt-4o-mini"
    /// 1.7.0：图像场景使用的视觉模型。nil / 空串表示复用 `model`。
    /// 用可选而不是默认值，旧版写下的配置缺这个键也能照常解码。
    var visionModel: String?
    /// 单次处理的绝对预算（秒）。硬上限 12s：比这更久，用户已经忘了自己刚丢过东西。
    var budget: Double = 12
    /// 最近用过的模型，供设置界面下拉切换
    var history: [String] = []

    var effectiveVisionModel: String {
        let v = visionModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? model : v
    }

    static let maxBudget: Double = 12

    var effectiveBudget: Double { min(max(budget, 3), Self.maxBudget) }

    /// 校验并规范化 base：https，或本机 http（Ollama / LM Studio 在 127.0.0.1）。
    /// 拒绝 query / fragment / userinfo——把 key 拼进 URL 是最常见的泄漏方式。
    static func normalize(base raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw AIError.badURL("接口地址为空") }
        guard var c = URLComponents(string: s) else { throw AIError.badURL("接口地址不是合法 URL") }
        guard let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw AIError.badURL("只支持 https（本机可用 http://127.0.0.1）")
        }
        guard c.host?.isEmpty == false else { throw AIError.badURL("缺少主机名") }
        if c.user != nil || c.password != nil {
            throw AIError.badURL("地址里不要带用户名/密码，Key 请填在独立字段")
        }
        if c.query != nil || c.fragment != nil {
            throw AIError.badURL("地址里不要带 ? 或 #")
        }
        if scheme == "http" {
            let h = (c.host ?? "").lowercased()
            guard h == "127.0.0.1" || h == "localhost" || h == "::1" else {
                throw AIError.badURL("http 只允许本机地址")
            }
        }
        while c.path.hasSuffix("/") { c.path.removeLast() }
        guard var out = c.url?.absoluteString else { throw AIError.badURL("接口地址无法解析") }
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }
}

enum AIConfigStore {
    private static let key = "aiConfig.v1"
    static let keychainService = "com.lw.obsidiandrop.ai"
    static let keychainAccount = "api-key"

    /// 1.7.0：场景 CLI 用的进程内覆盖，绝不写用户偏好。
    /// 测试能强制 enabled / 换模型，同时保证真实设置不受影响。
    static var overrideConfig: AIConfig?

    static var config: AIConfig {
        get {
            if let o = overrideConfig { return o }
            guard let d = UserDefaults.standard.data(forKey: key),
                  let c = try? JSONDecoder().decode(AIConfig.self, from: d) else { return AIConfig() }
            return c
        }
        set {
            if overrideConfig != nil { overrideConfig = newValue; return }
            if let d = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(d, forKey: key)
            }
        }
    }

    /// 界面上「模型切换」不只改当前值，还留一条历史，下次下拉能直接选
    static func useModel(_ m: String) {
        var c = config
        let v = m.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        c.model = v
        if !c.history.contains(v) {
            c.history.insert(v, at: 0)
            c.history = Array(c.history.prefix(8))
        }
        config = c
    }

    static var hasKey: Bool { AIKeychain.load()?.isEmpty == false }
    static var isReady: Bool { config.enabled && hasKey }
}

// MARK: - 钥匙串

enum AIKeychain {
    /// 场景 CLI 的进程内 Key 覆盖（空串表示「故意没有 Key」）
    static var overrideKey: String?

    static func save(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AIConfigStore.keychainService,
            kSecAttrAccount as String: AIConfigStore.keychainAccount,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, b in b }
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func load() -> String? {
        if let k = overrideKey { return k }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AIConfigStore.keychainService,
            kSecAttrAccount as String: AIConfigStore.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let d = item as? Data, let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AIConfigStore.keychainService,
            kSecAttrAccount as String: AIConfigStore.keychainAccount,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}

// MARK: - 传输

/// 只依赖这一层做网络。换成别的后端（或测试里的假后端）不需要改业务逻辑。
protocol AITransport {
    func post(url: URL, key: String, body: Data, budget: Double) throws -> Data
    func get(url: URL, key: String, budget: Double) throws -> Data
}

struct HTTPTransport: AITransport {
    func post(url: URL, key: String, body: Data, budget: Double) throws -> Data {
        try send(url: url, key: key, body: body, budget: budget, method: "POST")
    }

    func get(url: URL, key: String, budget: Double) throws -> Data {
        try send(url: url, key: key, body: nil, budget: budget, method: "GET")
    }

    private func send(url: URL, key: String, body: Data?, budget: Double,
                      method: String) throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = budget
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = body

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = budget
        cfg.timeoutIntervalForResource = budget
        cfg.httpAdditionalHeaders = ["User-Agent": "ObsidianDrop/\(DiagLog.versionText)"]
        // 跟随重定向时只允许同源：否则一个合法的 https 地址可以把你导到任意 host，
        // 把 Authorization 头带出去（AIConfig.normalize 只管入口，管不到跳转）。
        let session = URLSession(configuration: cfg, delegate: RedirectGuard.shared,
                                 delegateQueue: nil)

        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error>?
        let task = session.dataTask(with: req) { data, resp, err in
            if let err { result = .failure(err) }
            else { result = .success((data ?? Data(), resp ?? URLResponse())) }
            sem.signal()
        }
        task.resume()
        // 预算 + 200ms 余量：让 URLSession 自己的 timeout 先触发，这里只兜底
        if sem.wait(timeout: .now() + budget + 0.2) == .timedOut {
            task.cancel()
            throw AIError.timeout
        }
        session.finishTasksAndInvalidate()
        guard let result else { throw AIError.timeout }
        switch result {
        case .failure(let e):
            if (e as NSError).code == NSURLErrorTimedOut { throw AIError.timeout }
            throw e
        case .success(let (data, resp)):
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                throw AIError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            return data
        }
    }
}

// MARK: - 服务

enum AIService {
    static var transport: AITransport = HTTPTransport()

    static let systemPrompt = """
    你是中文知识库的整理助手。用户会给你一段刚录下的灵感文字和它要归档的目录。
    请只输出一个 JSON 对象，不要输出解释、不要用代码块包裹，字段如下：
    {"title": "不超过 20 字的中文标题，不带标点结尾",
     "summary": "不超过 80 字的中文摘要，客观陈述，不加评价",
     "tags": ["2 到 4 个中文或英文标签，不带 #"]}
    """

    static func requestBody(text: String, target: String, model: String) -> Data? {
        // 长文本按字符截断：模型不在乎整篇，只在乎主题；截断也保证请求体可控
        let clipped = text.count > 4000 ? String(text.prefix(4000)) : text
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "归档目录：\(target)\n\n文字：\n\(clipped)"],
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    static func chatURL(base: String) -> URL? {
        URL(string: base + "/chat/completions")
    }

    static func modelsURL(base: String) -> URL? {
        URL(string: base + "/models")
    }

    /// 从 OpenAI 兼容响应里取出 content。抽成纯函数，方便自检直接喂字符串。
    static func extractContent(_ data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.badResponse("不是 JSON")
        }
        if let err = obj["error"] as? [String: Any], let m = err["message"] as? String {
            throw AIError.badResponse(m)
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw AIError.badResponse("没有 choices[0].message.content")
        }
        return content
    }

    /// 模型经常把 JSON 包在 ```json 里，或在前面加一句「好的」。
    /// 取第一个 `{` 到最后一个 `}`，比要求模型「严格遵守格式」现实得多。
    static func parseResult(_ content: String, model: String, ms: Int) throws -> AIResult {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = t.firstIndex(of: "{"), let e = t.lastIndex(of: "}"), s < e else {
            throw AIError.badResponse("没有 JSON 对象：\(t.prefix(80))")
        }
        let json = String(t[s...e])
        guard let d = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw AIError.badResponse("JSON 解析失败")
        }
        var title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(of: "\n", with: " ")
        if title.count > 40 { title = String(title.prefix(40)) }
        var summary = (obj["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        summary = summary.replacingOccurrences(of: "\n", with: " ")
        if summary.count > 160 { summary = String(summary.prefix(160)) }

        var tags: [String] = []
        if let raw = obj["tags"] as? [String] {
            for t in raw {
                var v = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if v.hasPrefix("#") { v.removeFirst() }
                v = v.replacingOccurrences(of: " ", with: "-")
                if v.isEmpty || v.count > 16 || tags.contains(v) { continue }
                tags.append(v)
                if tags.count >= 4 { break }
            }
        }
        guard !title.isEmpty || !summary.isEmpty || !tags.isEmpty else {
            throw AIError.badResponse("字段全空")
        }
        return AIResult(title: title, summary: summary, tags: tags, model: model, ms: ms)
    }

    /// 处理一段文字。**不抛错**：失败一律降级为 .skipped 并带原因，
    /// 因为「AI 挂了」绝不能变成「这条灵感没入库」。
    static func decorate(text: String, target: String,
                         config: AIConfig = AIConfigStore.config) -> (AIState, AIResult?, String) {
        guard config.enabled else { return (.off, nil, "未启用") }
        guard let key = AIKeychain.load(), !key.isEmpty else {
            return (.skipped, nil, "没有配置 API Key")
        }
        let base: String
        do { base = try AIConfig.normalize(base: config.baseURL) }
        catch { return (.skipped, nil, error.localizedDescription) }
        guard let url = chatURL(base: base), let body = requestBody(text: text, target: target,
                                                                    model: config.model) else {
            return (.skipped, nil, "请求构造失败")
        }
        let t0 = Date()
        do {
            let data = try transport.post(url: url, key: key, body: body,
                                          budget: config.effectiveBudget)
            let content = try extractContent(data)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let r = try parseResult(content, model: config.model, ms: ms)
            return (.done, r, "")
        } catch {
            return (.skipped, nil, error.localizedDescription)
        }
    }

    /// 连接测试：真的发一次最小请求，而不是只 ping 域名。
    /// 只有「能拿到合法响应」才算连通——401 也必须报出来。
    static func test(config: AIConfig, key: String) -> (ok: Bool, message: String, ms: Int) {
        let base: String
        do { base = try AIConfig.normalize(base: config.baseURL) }
        catch { return (false, error.localizedDescription, 0) }
        guard !key.isEmpty else { return (false, "API Key 为空", 0) }
        guard let url = chatURL(base: base) else { return (false, "接口地址无法拼出请求路径", 0) }
        let body = requestBody(text: "连接测试，请回复一句「收到」", target: "00-收件箱",
                               model: config.model)
        let t0 = Date()
        do {
            let data = try transport.post(url: url, key: key, body: body ?? Data(),
                                          budget: config.effectiveBudget)
            let content = try extractContent(data)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            return (true, "连接正常（\(ms)ms）：\(content.prefix(60))", ms)
        } catch {
            return (false, error.localizedDescription, Int(Date().timeIntervalSince(t0) * 1000))
        }
    }

    /// 拉模型列表，供「模型切换」下拉。失败返回空数组，不抛错。
    static func listModels(config: AIConfig, key: String) -> [String] {
        guard let base = try? AIConfig.normalize(base: config.baseURL),
              let url = modelsURL(base: base), !key.isEmpty else { return [] }
        guard let data = try? transport.get(url: url, key: key, budget: config.effectiveBudget),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["id"] as? String }.sorted()
    }
}

// MARK: - AI 命令行

enum AICLI {
    /// --ai-config / --ai-set / --ai-test / --ai-run
    static func config() -> Int32 {
        let c = AIConfigStore.config
        print("启用：\(c.enabled ? "是" : "否")")
        print("接口：\(c.baseURL)")
        print("模型：\(c.model)")
        print("视觉模型：\(c.effectiveVisionModel)"
              + ((c.visionModel ?? "").isEmpty ? "（跟随文字模型）" : ""))
        print("预算：\(Int(c.effectiveBudget))s")
        print("Key：\(AIConfigStore.hasKey ? "已保存在钥匙串" : "未配置")")
        if !c.history.isEmpty { print("最近用过：\(c.history.joined(separator: ", "))") }
        return 0
    }

    static func set(_ pairs: [String]) -> Int32 {
        var c = AIConfigStore.config
        for p in pairs {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else {
                FileHandle.standardError.write("用法：--ai-set enabled=on base=https://… model=… key=…\n"
                    .data(using: .utf8)!)
                return 2
            }
            switch kv[0] {
            case "enabled":
                c.enabled = ["on", "true", "1", "yes"].contains(kv[1].lowercased())
            case "base":
                do { c.baseURL = try AIConfig.normalize(base: kv[1]) }
                catch {
                    FileHandle.standardError.write("错误：\(error.localizedDescription)\n".data(using: .utf8)!)
                    return 2
                }
            case "model":
                c.model = kv[1]
            case "vision":
                c.visionModel = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
            case "budget":
                c.budget = Double(kv[1]) ?? c.budget
            case "key":
                guard AIKeychain.save(kv[1]) else {
                    FileHandle.standardError.write("错误：写入钥匙串失败\n".data(using: .utf8)!)
                    return 1
                }
            default:
                FileHandle.standardError.write("未知字段：\(kv[0])\n".data(using: .utf8)!)
                return 2
            }
        }
        AIConfigStore.config = c
        print("已保存")
        return 0
    }

    static func test() -> Int32 {
        let c = AIConfigStore.config
        guard let key = AIKeychain.load(), !key.isEmpty else {
            print("未配置 API Key（先 --ai-set key=…）")
            return 2
        }
        let r = AIService.test(config: c, key: key)
        print((r.ok ? "✓ " : "✗ ") + r.message)
        return r.ok ? 0 : 1
    }

    static func run(text: String, target: String) -> Int32 {
        let c = AIConfigStore.config
        guard c.enabled else { print("AI 未启用（--ai-set enabled=on）"); return 2 }
        let (state, result, reason) = AIService.decorate(text: text, target: target, config: c)
        switch state {
        case .done:
            if let r = result {
                let payload: [String: Any] = ["state": state.rawValue, "title": r.title,
                                             "summary": r.summary, "tags": r.tags,
                                             "model": r.model, "ms": r.ms]
                if let d = try? JSONSerialization.data(withJSONObject: payload,
                                                       options: [.sortedKeys, .withoutEscapingSlashes]),
                   let s = String(data: d, encoding: .utf8) { print(s) }
            }
            return 0
        case .off:
            print("state=off")
            return 2
        case .pending:
            print("state=pending")
            return 1
        case .skipped:
            print("state=skipped reason=\(reason)")
            return 1
        }
    }
}

/// 只允许同源重定向的会话代理。跨源一律拒绝，调用方会看到 3xx 并按失败降级。
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectGuard()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = task.originalRequest?.url, let to = request.url else {
            completionHandler(nil)
            return
        }
        let sameOrigin = from.scheme?.lowercased() == to.scheme?.lowercased()
            && from.host?.lowercased() == to.host?.lowercased()
            && from.port == to.port
        if sameOrigin {
            completionHandler(request)
        } else {
            DiagLog.write("AI 请求被拒绝跟随跨源重定向：\(from.host ?? "-") → \(to.host ?? "-")")
            completionHandler(nil)
        }
    }
}
