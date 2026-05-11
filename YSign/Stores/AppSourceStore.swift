import Foundation
import Security

/// 软件源管理器
///
/// 与旧版 SourceAPI 逻辑一致：
/// - 添加源时先请求并解析，成功后才保存 URL
/// - 支持普通 JSON 源和 RSA 加密源（"result" 字段）
/// - 源数据缓存到本地
///
/// 源数据存储在 Documents/YSign/Sources/ 目录下
actor AppSourceStore {

    /// RSA 私钥（用于解密加密源，与旧版 SourcePrivateKey 一致）
    static let sourcePrivateKey = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEpQIBAAKCAQEArzX27YBOi0fHf38zy1YixtNGW7GKBNsppFBhT95obvpAr5vw
    ZLvakizcWtTK5Jzdvhx0SvyEWX9KUrp9O0oj+9zxLgVZU6w2yPvirZ+WOwz/of53
    IQuWUgSnE+wUetFsFATnjoQjNX9T3JsdzrqQEdRBV4s5YJjoMmX3dkyjbi+oKs5+
    XCNiI7KiRcv/ELUcT8pvVVgzkf19w2fnm7Lk0x/BfIPnLQHAa2XzzturJ9pSyyFB
    XJ7jVbDEs+Dyb5KSwYy+Q6sA0NrLARcfxK6vI4tdbkLKDI8izRLMqMrAUPyiO9WJ
    TZc8pA7x6sDCVpV0hs72t7IWmXw8KYvoglBYhQIDAQABAoIBAAaiA1wQXGjXac0A
    0sQi2aQvQV2dRf1TEqt+w4BTih6RaLt9KseVePvJqPnjTl8DNT3KM/jWwGfm8rhZ
    CP6imuQhBBxa5XvObDCFoJo0DWrk3hSS3o2os6MdO/n8GPZhUTcczGtPw0l2LYWP
    dbxqwaN7JpIa2iw2/atSwuB+nD1CjoQhli9q9Nr5ScotbP5TvW1Db8agXxMh9GgH
    GXoPhc8N8s4i8/6+7FnJ9LYeUKRP8pN/79pIPMmkyPg6qgzUgf74Q9LKS7hT3vyN
    CQERS15hZTfR+AAXPwHtAStWJ1GlMRTVllNSNoboOsRJdE9FTZ1oI+qxWB4Ql+ts
    pie30y0CgYEA5Vytmqvcq0HMnZMW7SVcx4v3gGxfVDpGA+enMtNvWJnQeYBDZw5y
    907t+8jSvJlRE7DXN82vV+6yNrSCAIYUTDx+RtiLR+91qAYw0UalRDfbkP7EYB4Q
    Uz1bNmm6ywhPeTyEa7vcMPZIum6FM2ykgP0pWD8j17dCEAu9UpY7NfMCgYEAw49H
    WC7eXfHgkvDntz7zphLgjKwUCmvwEYp+ncF0KTXt/jMrvzIr0m1vxALVXU/XrZEa
    vhurb44KxTMam7PHqEoCGxAaaDqxDDxrW2E3s81f+bYNchO4K8pTE1+inlIDc0mK
    XcJgxm4IFPftfUw2Z/WaVqwEg6pUy6MqXBnl/acCgYEArZuW9Eo9/4sQm/0oD1yG
    e6xgLN7a0WBCetYvYnNUBpZ2jGEfo7P2JWejD0AU8xiBnAvw+5Y+sKpGTs4W0Nqs
    JoBrfKiP1GVWg1YcQWvd0GMPWRLeBXr8FGWO0wL4lpG1xiieewV5R75DkonxXNlR
    Myls0BUKxk86O/cG2KpKKy0CgYEArhQCrCq8YuAGyoaLnYD6HmE7Zb1f8Y73moWw
    A/nKz0xkWB1w2bdtbtlf3hmvmGqUULqUFZpH1vuX9sZw7xzvo4yNp02EVDe6lmvK
    HQPDM9ijkINQILYRAVoO7XX6KfhTffJ+qst2newgYZn428pVu+DSzEg/lHyxErxh
    3q5nHo0CgYEA1IOPGGpvqxgoe+AD3yCccRaoJOij1T2bHcu1H1GcOcuWrIdjgQDb
    MYu4QiwjQiydMeXxokQcPUKi/S7pgA7fB4cCe0axJVLnyyYj/P9dXH7i2C+S3iRk
    A4vszKOKgwB/Kmogk0TQxiON/8KU3Q0ukoB0HBt+TnIxeKEY776C450=
    -----END RSA PRIVATE KEY-----
    """

    /// 存储目录
    private let storeDirectory: URL

    /// 源列表索引文件
    private let indexFile: URL

    /// 应用数据缓存文件
    private let cacheFile: URL

    init() {
        self.storeDirectory = YSInternalStorage.directory("Sources")
        self.indexFile = storeDirectory.appendingPathComponent("sources.json")
        self.cacheFile = storeDirectory.appendingPathComponent("apps_cache.json")
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

        // 先请求并解析
        guard let source = await fetchSource(url: normalized) else {
            throw AppSourceError.fetchFailed("无法获取或解析该源数据，请检查地址是否正确")
        }

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
              let sources = try? JSONDecoder().decode([AppSource].self, from: data) else {
            return []
        }
        return sources
    }

    // MARK: - 网络请求

    /// 从 URL 拉取软件源数据
    ///
    /// 支持三种格式（与旧版 SourceAPI 一致）：
    /// 1. 加密源：JSON 包含 "result" 字段 → RSA 解密后解析
    /// 2. 标准源：JSON 可直接解码为 AppSource
    /// 3. 简单源：JSON 包含 "apps" 数组，手动拼装
    func fetchSource(url: String) async -> AppSource? {
        guard let requestURL = URL(string: url) else { return nil }

        do {
            var request = URLRequest(url: requestURL)
            request.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: request)

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            // 情况A：加密源（包含 "result" 字段，RSA 解密）
            if let encryptedResult = json["result"] as? String {
                print("[AppSourceStore] 检测到加密源，正在解密...")
                if let decrypted = rsaDecrypt(encryptedResult),
                   let decryptedData = decrypted.data(using: .utf8),
                   let decryptedJson = try? JSONSerialization.jsonObject(with: decryptedData) as? [String: Any] {
                    return parseSourceFromDict(decryptedJson, url: url)
                }
                // 解密失败，尝试直接解析
                print("[AppSourceStore] 解密失败，尝试直接解析...")
            }

            // 情况B/C：普通源（直接解析）
            return parseSourceFromDict(json, url: url)

        } catch {
            print("[AppSourceStore] 请求失败: \(url) - \(error.localizedDescription)")
            return nil
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
                // 与旧版一致：lock=true 但有 downloadURL → 实际已解锁
                if source.apps[i].lock && !source.apps[i].downloadURL.isEmpty {
                    source.apps[i].lock = false
                }
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

            if let appsData = try? JSONSerialization.data(withJSONObject: appsArray) {
                source.apps = (try? JSONDecoder().decode([AppModel].self, from: appsData)) ?? []
            }
            for i in source.apps.indices {
                source.apps[i].sourceIdentifier = source.identifier
                source.apps[i].sourceName = source.name
                if source.apps[i].lock && !source.apps[i].downloadURL.isEmpty {
                    source.apps[i].lock = false
                }
            }
            return source
        }

        return nil
    }

    // MARK: - RSA 解密

    /// RSA PKCS1 解密（与旧版 String.rsa_decrypt 一致）
    private func rsaDecrypt(_ base64String: String) -> String? {
        guard let encryptedData = Data(base64Encoded: base64String) else { return nil }

        // 从 PEM 提取 DER
        let pemLines = Self.sourcePrivateKey.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        let base64Key = pemLines.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyData = Data(base64Encoded: base64Key) else { return nil }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            print("[AppSourceStore] RSA 私钥创建失败: \(error?.takeRetainedValue().localizedDescription ?? "")")
            return nil
        }

        // RSA 密钥一次最多解密 keySize 长度的数据，需要分块
        let blockSize = SecKeyGetBlockSize(privateKey)
        var decryptedBytes = [UInt8]()

        var offset = 0
        while offset < encryptedData.count {
            let chunkSize = min(blockSize, encryptedData.count - offset)
            let chunk = encryptedData[offset..<offset + chunkSize]

            guard let decryptedChunk = SecKeyCreateDecryptedData(
                privateKey,
                .rsaEncryptionPKCS1,
                chunk as CFData,
                &error
            ) else {
                print("[AppSourceStore] RSA 解密分块失败: \(error?.takeRetainedValue().localizedDescription ?? "")")
                return nil
            }

            decryptedBytes.append(contentsOf: decryptedChunk as Data)
            offset += chunkSize
        }

        return String(bytes: decryptedBytes, encoding: .utf8)
    }

    // MARK: - 辅助

    /// 规范化源 URL
    private func normalizeSourceURL(_ url: String) -> String {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = normalized.range(of: "/index/index/apiface") {
            normalized = String(normalized[..<range.lowerBound])
        }
        if normalized.hasSuffix("/index/index") {
            normalized = String(normalized.dropLast("/index/index".count))
        } else if normalized.hasSuffix("/index") {
            normalized = String(normalized.dropLast("/index".count))
        }
        while normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        return normalized
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
