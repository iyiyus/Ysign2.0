import Foundation

/// 软件源管理器
///
/// 添加源流程：
/// - 添加源时先请求并解析，成功后才保存 URL
/// - 支持普通 JSON 源和加密源（"appstore" / "result" 字段）
/// - 加密源统一走软件源官方解密接口解密
/// - 源数据缓存到本地
///
/// 源数据存储在 Documents/YSign/Sources/ 目录下
actor AppSourceStore {

    /// 存储目录
    private let storeDirectory: URL

    /// 源列表索引文件
    private let indexFile: URL

    /// 应用数据缓存文件
    private let cacheFile: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.storeDirectory = docs.appendingPathComponent("YSign/Sources")
        self.indexFile = storeDirectory.appendingPathComponent("sources.json")
        self.cacheFile = storeDirectory.appendingPathComponent("apps_cache.json")
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 源 URL 管理

    /// 获取所有已添加的源 URL 列表
    func getSourceURLs() -> [String] {
        guard let data = try? Data(contentsOf: indexFile),
              let urls = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return urls
    }

    /// 保存源 URL 到索引
    private func saveSourceURL(_ url: String) throws {
        var urls = getSourceURLs()
        guard !urls.contains(url) else { throw AppSourceError.alreadyExists }
        urls.append(url)
        let data = try JSONEncoder().encode(urls)
        try data.write(to: indexFile)
    }

    /// 删除指定的软件源
    func removeSource(url: String) throws {
        var urls = getSourceURLs()
        urls.removeAll { $0 == url }
        let data = try JSONEncoder().encode(urls)
        try data.write(to: indexFile)
    }

    /// 注入默认软件源。
    ///
    /// 这个方法专门给贴牌配置使用，策略是“只补缺，不覆盖”：
    /// - 如果品牌配置里没有默认源，直接跳过
    /// - 如果用户本地已经手动添加过源，也不强行覆盖
    /// - 只有在本地完全为空时，才把贴牌默认源写入索引文件
    ///
    /// 这样既能满足贴牌包开箱即用，也不会影响用户后续的自定义操作。
    func ensureDefaultSources(urls: [String]) throws {
        let normalized = urls
            .map { normalizeSourceURL($0) }
            .filter { !$0.isEmpty }

        guard !normalized.isEmpty else { return }

        let existing = getSourceURLs()
        guard existing.isEmpty else { return }

        let data = try JSONEncoder().encode(Array(Set(normalized)).sorted())
        try data.write(to: indexFile)
    }

    /// 按品牌配置覆盖更新软件源。
    ///
    /// 与 `ensureDefaultSources` 不同，这个方法用于“在线贴牌同步”场景：
    /// 远端下发的品牌配置被视为当前品牌包的权威来源，
    /// 因此会直接使用最新 URL 列表覆盖本地索引文件，确保：
    /// - 新增的软件源能立刻出现
    /// - 已下线的软件源能被及时移除
    /// - 品牌方调整后的顺序能在下次刷新时生效
    func applyManagedSources(urls: [String]) throws {
        let normalized = urls
            .map { normalizeSourceURL($0) }
            .filter { !$0.isEmpty }

        let data = try JSONEncoder().encode(normalized)
        try data.write(to: indexFile)
    }

    // MARK: - 添加源（先请求，成功才保存）

    /// 添加软件源
    ///
    /// 与旧版逻辑一致：先请求 URL 获取数据，解析成功后才保存。
    /// 如果请求失败或格式无法解析，直接报错，不保存 URL。
    ///
    /// - Parameter url: 源 URL
    /// - Returns: 成功解析的 AppSource
    func addSource(url: String) async throws -> AppSource {
        let normalized = normalizeSourceURL(url)

        guard normalized.hasPrefix("http"), URL(string: normalized) != nil else {
            throw AppSourceError.invalidURL
        }

        // 检查是否已存在
        let existing = getSourceURLs()
        if existing.contains(normalized) {
            throw AppSourceError.alreadyExists
        }

        // 先请求并解析（失败时带上具体原因）
        let source = try await fetchSourceDetailed(url: normalized)

        // 成功了才保存 URL
        try saveSourceURL(normalized)

        return source
    }

    // MARK: - 刷新所有源

    /// 刷新所有源，并发拉取
    func refreshAllSources() async -> [AppSource] {
        let urls = getSourceURLs()
        var sources: [AppSource] = []

        await withTaskGroup(of: AppSource?.self) { group in
            for url in urls {
                group.addTask {
                    await self.fetchSource(url: url)
                }
            }
            for await source in group {
                if let s = source { sources.append(s) }
            }
        }

        // 缓存到本地
        if let data = try? JSONEncoder().encode(sources) {
            try? data.write(to: cacheFile)
        }
        return sources
    }

    /// 从本地缓存加载
    func loadCachedSources() -> [AppSource] {
        guard let data = try? Data(contentsOf: cacheFile),
              var sources = try? JSONDecoder().decode([AppSource].self, from: data) else {
            return []
        }
        // rowIndex 不参与持久化, 解码后重建, 保证 ForEach 的 id 唯一
        for i in sources.indices {
            for j in sources[i].apps.indices {
                sources[i].apps[j].rowIndex = j
            }
        }
        return sources
    }

    // MARK: - 网络请求

    /// 从 URL 拉取软件源数据（静默版本，刷新时使用）
    ///
    /// 支持三种格式（与旧版 SourceAPI 一致）：
    /// 1. 加密源：JSON 包含 "appstore" 或 "result" 字段 → RSA 解密后解析
    /// 2. 标准源：JSON 可直接解码为 AppSource
    /// 3. 简单源：JSON 包含 "apps" 数组，手动拼装
    ///
    /// 注意: 必须带上 `udid` query 参数, 否则服务端无法判定该设备是否已激活卡密,
    /// 已解锁应用的 `downloadURL` 会一直返回空, 导致 UI 显示"未解锁"。
    func fetchSource(url: String) async -> AppSource? {
        try? await fetchSourceDetailed(url: url)
    }

    /// 拉取软件源数据，失败时抛出具体原因（添加源时供 UI 提示）
    func fetchSourceDetailed(url: String) async throws -> AppSource {
        // 取系统设备 UDID, 没有就传空字符串 (服务端能容忍)
        let udid = UserDefaults.standard.string(forKey: "deviceUDID")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard var components = URLComponents(string: url) else {
            throw AppSourceError.fetchFailed("源地址格式不正确")
        }
        var queryItems = components.queryItems ?? []
        // 去掉用户在 URL 上已经手填的 udid, 避免重复
        queryItems.removeAll { $0.name.lowercased() == "udid" }
        queryItems.append(URLQueryItem(name: "udid", value: udid))
        components.queryItems = queryItems

        guard let requestURL = components.url else {
            throw AppSourceError.fetchFailed("源地址格式不正确")
        }

        do {
            var request = URLRequest(url: requestURL)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            // 部分加密源服务器校验 User-Agent（第三方中转解密脚本统一使用 iPhone UA），
            // URLSession 默认 UA 不含 "iPhone" 会被拒绝，保持一致
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, _) = try await URLSession.shared.data(for: request)

            // 清理响应: UTF-8 BOM / 首尾空白（部分源服务端带 BOM，JSONSerialization 会解析失败）
            var bodyText = String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
            bodyText = bodyText.trimmingCharacters(
                in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
            )
            guard let jsonData = bodyText.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                print("[AppSourceStore] 响应非 JSON: \(String(bodyText.prefix(120)))")
                throw AppSourceError.fetchFailed("源返回的不是 JSON 数据（可能被服务器拦截，或地址不对）")
            }

            // 加密源识别: 服务端可能把密文放在 `appstore` 或 `result` 字段
            // - "软件源一键搭建" PHP: `{"appstore":"<base64 RSA cipher>"}`
            // - 老版 FreeSign 协议:    `{"result":"<base64 RSA cipher>"}`
            var decryptFailed = false
            let encryptedKeys = ["appstore", "result"]
            for key in encryptedKeys {
                if let cipher = json[key] as? String, !cipher.isEmpty {
                    print("[AppSourceStore] 检测到加密源 (字段=\(key))，调用官方解密接口...")
                    if let decrypted = await remoteDecrypt(cipher),
                       let decryptedData = decrypted.data(using: .utf8),
                       let decryptedJson = try? JSONSerialization.jsonObject(with: decryptedData) as? [String: Any],
                       let source = parseSourceFromDict(decryptedJson, url: url) {
                        return source
                    }
                    decryptFailed = true
                    print("[AppSourceStore] \(key) 字段解密失败")
                }
            }
            if decryptFailed {
                throw AppSourceError.fetchFailed("加密源解密失败：官方解密接口无法解开该源的密文，请稍后重试")
            }

            // 普通源（直接解析）
            guard let source = parseSourceFromDict(json, url: url) else {
                throw AppSourceError.fetchFailed("源数据格式无法识别（缺少 apps 列表）")
            }
            return source

        } catch let error as AppSourceError {
            throw error
        } catch {
            print("[AppSourceStore] 请求失败: \(url) - \(error.localizedDescription)")
            throw AppSourceError.fetchFailed("网络请求失败：\(error.localizedDescription)")
        }
    }

    /// 从 JSON 字典解析 AppSource
    private func parseSourceFromDict(_ dict: [String: Any], url: String) -> AppSource? {
        // 尝试整体解码
        if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
           var source = try? JSONDecoder().decode(AppSource.self, from: jsonData) {
            source.sourceURL = url
            for i in source.apps.indices {
                source.apps[i].sourceIdentifier = source.identifier
                source.apps[i].sourceName = source.name
                source.apps[i].rowIndex = i
            }
            return source
        }

        // 包含 apps 数组的简单格式
        if let appsArray = dict["apps"] as? [[String: Any]] {
            var source = AppSource()
            source.sourceURL = url
            source.name = dict["name"] as? String ?? "未知源"
            source.identifier = dict["identifier"] as? String ?? ""
            source.message = dict["message"] as? String ?? ""
            source.sourceicon = dict["sourceicon"] as? String ?? ""
            source.unlockURL = dict["unlockURL"] as? String ?? ""
            source.payURL = dict["payURL"] as? String ?? ""

            if let appsData = try? JSONSerialization.data(withJSONObject: appsArray) {
                source.apps = (try? JSONDecoder().decode([AppModel].self, from: appsData)) ?? []
            }
            for i in source.apps.indices {
                source.apps[i].sourceIdentifier = source.identifier
                source.apps[i].sourceName = source.name
                source.apps[i].rowIndex = i
            }
            return source
        }

        return nil
    }

    // MARK: - RSA 解密

    /// 软件源官方解密接口
    ///
    /// 加密源统一由此接口解密：
    /// - Method: POST `content=<base64 密文>`（application/x-www-form-urlencoded）
    /// - 返回: base64(明文 JSON)，也可能直接返回 JSON
    private static let decryptAPI = "https://api.nuosike.com/api.php"

    /// 调用官方解密接口解密源密文
    private func remoteDecrypt(_ cipher: String) async -> String? {
        guard let url = URL(string: Self.decryptAPI) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)",
            forHTTPHeaderField: "User-Agent"
        )
        let encoded = cipher.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cipher
        request.httpBody = "content=\(encoded)".data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

            // 实测直接返回 JSON 明文
            if let d = text.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: d)) != nil {
                return text
            }
            // 兼容返回 base64(明文) 的形态
            guard let decoded = Data(base64Encoded: text),
                  let plain = String(data: decoded, encoding: .utf8) else {
                print("[AppSourceStore] 官方解密接口返回格式异常: \(String(text.prefix(80)))")
                return nil
            }
            return plain
        } catch {
            print("[AppSourceStore] 官方解密接口请求失败: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 辅助

    /// 规范化源 URL.
    ///
    /// 做几件事:
    /// - 去前后空白
    /// - 去掉 `/index/index/apiface`、`/index/index`、`/index` 等冗余后缀
    /// - 去掉末尾的斜杠
    /// - 去掉 `udid` query 参数 (这个由请求时根据当前设备动态注入,
    ///   保存到索引文件里会导致换设备/换 UDID 时还在用旧值)
    private func normalizeSourceURL(_ url: String) -> String {
        var raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = raw.range(of: "/index/index/apiface") {
            raw = String(raw[..<range.lowerBound])
        }

        // 用 URLComponents 处理 query, 比手撸字符串安全
        if var components = URLComponents(string: raw) {
            if let items = components.queryItems {
                let filtered = items.filter { $0.name.lowercased() != "udid" }
                components.queryItems = filtered.isEmpty ? nil : filtered
            }
            if let cleaned = components.url?.absoluteString {
                raw = cleaned
            }
        }

        if raw.hasSuffix("/index/index") {
            raw = String(raw.dropLast("/index/index".count))
        } else if raw.hasSuffix("/index") {
            raw = String(raw.dropLast("/index".count))
        }
        while raw.hasSuffix("/") {
            raw = String(raw.dropLast())
        }
        return raw
    }

    // MARK: - 解锁

    /// 调用源的解锁接口验证用户输入的解锁码。
    ///
    /// 协议与 FreeSign 等老版工具一致:
    /// - URL: `{source.unlockURL}`
    /// - Method: `GET`
    /// - Query: `udid=<UDID>&code=<用户输入>`
    /// - 成功响应: `{ "msg": "解锁成功" }` (msg 含 "成功" 视为通过)
    ///
    /// - Parameters:
    ///   - unlockURL: 源声明的解锁接口
    ///   - udid: 设备 UDID
    ///   - code: 用户输入的解锁码
    /// - Returns: 服务端返回的提示文案 (供 UI 直接展示)
    /// - Throws: 接口异常 / 服务端明确返回失败时抛出
    func unlockSource(unlockURL: String, udid: String, code: String) async throws -> (success: Bool, message: String) {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            throw AppSourceError.fetchFailed("请输入解锁码")
        }

        guard !unlockURL.isEmpty,
              var components = URLComponents(string: unlockURL) else {
            throw AppSourceError.fetchFailed("软件源的解锁地址不正确")
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "udid", value: udid))
        queryItems.append(URLQueryItem(name: "code", value: trimmedCode))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw AppSourceError.fetchFailed("软件源的解锁地址不正确")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw AppSourceError.fetchFailed("解锁服务暂不可用")
            }

            // 解析 msg, 兼容两种返回形态:
            // 1) {"code":0,"msg":"ok，解锁成功"} (软件源 PHP 接口的实际返回, code 永远是 0)
            // 2) {"code":1,"msg":"...","data":{...}} (其他源)
            //
            // 策略: msg 含"成功"视为解锁通过; 否则严格按 code 判断 (1/200 通过)。
            // 不同时使用两个条件, 避免 code=0 + msg=失败 的情况被误判成功。
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AppSourceError.fetchFailed("解锁服务返回格式错误")
            }
            let msg = (json["msg"] as? String)
                ?? (json["message"] as? String)
                ?? "操作完成"

            // msg 是判定主依据
            if msg.contains("成功") || msg.localizedCaseInsensitiveContains("success") {
                return (true, msg)
            }

            // msg 没有"成功", 看 code 是否明确成功 (兼容自定义后端)
            let codeValue = (json["code"] as? Int) ?? Int(json["code"] as? String ?? "") ?? -1
            if codeValue == 1 || codeValue == 200 {
                return (true, msg)
            }

            return (false, msg)
        } catch let error as AppSourceError {
            throw error
        } catch {
            throw AppSourceError.fetchFailed("网络异常：\(error.localizedDescription)")
        }
    }
}

/// 软件源相关错误
enum AppSourceError: LocalizedError {
    case invalidURL
    case alreadyExists
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的源地址"
        case .alreadyExists: return "该软件源已存在"
        case .fetchFailed(let msg): return msg
        }
    }
}
