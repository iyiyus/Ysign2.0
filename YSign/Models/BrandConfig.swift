import Foundation

 /// 贴牌配置模型
 ///
 /// 这个结构体对应 PHP 项目里 `fa_signtool` 的核心字段，
 /// 目标是让 YSign 运行时和导出 IPA 时都使用同一份品牌配置。
 ///
 /// 设计原则：
 /// 1. 字段名尽量与 PHP 接口保持一致，便于迁移旧配置
 /// 2. 对 URL 列表和布尔值做宽松解析，兼容字符串 / 数组 / 0/1
 /// 3. 允许包内放一份 `BrandConfig.json`，让编译出的 App 天然具备贴牌能力
struct BrandConfig: Codable, Equatable {
     /// 分销前缀，对应 PHP 中的 `short_site`
     /// 常用于区分不同贴牌渠道，例如 `demo`、`abc`。
    var shortSite: String

     /// 贴牌后的 Bundle ID。
     /// 当 YSign 自己被做成贴牌 IPA 时，运行时可据此展示当前品牌标识。
    var appBundleID: String

     /// 贴牌后的应用名称。
     /// 运行时用于设置页、关于页等品牌展示；导出 IPA 时也会同步写入 Info.plist。
    var appName: String

     /// 安装服务器地址（通常是 `plist.php`）。
     /// 这里保留旧版字段，兼容 PHP 侧一条主安装地址的存储方式。
    var plistURL: String

     /// 默认软件源列表。
     /// 首次启动时，如果用户还没有手动添加任何软件源，就会自动注入这些源。
    var defaultAppSourceURLs: [String]

     /// 贴牌图标的远程 URL。
     /// 该字段主要用于品牌配置同步；真正导出 IPA 时可直接使用本地图片数据覆盖图标。
    var appIconURL: String

     /// 贴牌启动图的远程 URL。
     /// 与 `appIconURL` 类似，运行时保存品牌信息，导出 IPA 时可转化为实际图片资源。
    var appLaunchIconURL: String

     /// QQ 群 / 社群信息。
     /// 有些贴牌方不一定提供链接，因此保留为普通字符串。
    var group: String

     /// 联系我们链接。
    var contactURL: String

     /// 购买链接。
    var buyURL: String

     /// 教程链接。
    var tutorialURL: String

     /// 公告文案。
     /// 可用于在软件源页 / 设置页展示品牌公告。
    var notice: String

     /// 是否开启兑换能力。
     /// 当前版本主要做配置透传，后续可以据此控制入口显隐。
    var exchange: Bool

     /// 是否开启黑白名单能力。
     /// 当前版本同样先保留到运行时配置文件中，便于后续扩展。
    var whitelist: Bool

     /// 是否允许导入。
     /// 在 YSign 中会直接影响「导入 IPA」和「手动添加软件源」入口是否可用。
    var importPermissions: Bool

     /// 安装服务器列表。
     /// 相比 `plistURL`，这个字段支持多条服务器地址，适合 YSign 的自动切换安装逻辑。
    var installServerURLs: [String]

     /// 是否启用在线贴牌配置。
     ///
     /// 开启后，应用启动时会优先尝试从远程地址拉取最新 `BrandConfig`，
     /// 以支持品牌、公告、软件源、安装服务器等内容的在线更新。
    var onlineBrandingEnabled: Bool

     /// 远程 `BrandConfig` 地址。
     ///
     /// 该地址返回的 JSON 应当可以直接或间接解码为 `BrandConfig`。
     /// 如果设置页里存在覆盖值，则运行时会优先使用设置页中的 URL。
    var remoteConfigURL: String

     /// 授权校验使用的域名。
     ///
     /// 若为空，运行时会回退为远程配置 URL 的 Host，
     /// 也就是“当前调用方的实际域名”。
    var licenseDomain: String

     /// 域名授权校验接口地址。
     ///
     /// 默认指向用户提供的授权系统接口：
     /// `https://ysign.iosk.cn/api/v1/license/domain-verify`
    var licenseVerifyURL: String

     /// 域名授权校验的应用 ID。
     ///
     /// 当前按用户要求默认固定为 `1`，但仍保留成配置字段，
     /// 便于未来同一套代码服务多个应用项目。
    var licenseAppID: Int

     /// 缺省配置。
     /// 当包内没有 `BrandConfig.json`，或文件损坏无法解析时，应用会退回到这组默认值。
    static let fallback = BrandConfig(
        shortSite: "",
        appBundleID: "com.ysign.app",
        appName: "YSign",
        plistURL: "",
        defaultAppSourceURLs: [],
        appIconURL: "",
        appLaunchIconURL: "",
        group: "",
        contactURL: "https://t.me/ysign",
        buyURL: "",
        tutorialURL: "https://docs.qq.com/doc/DUmZhR2JhYld2U2Z5",
        notice: "",
        exchange: true,
        whitelist: false,
        importPermissions: true,
        installServerURLs: [],
        onlineBrandingEnabled: false,
        remoteConfigURL: "",
        licenseDomain: "",
        licenseVerifyURL: "https://ysign.iosk.cn/api/v1/license/domain-verify",
        licenseAppID: 1
    )

     /// JSON / PHP 字段名映射。
     /// 这里显式声明 snake_case 键名，保证和旧后端导出的字段完全一致。
    enum CodingKeys: String, CodingKey {
        case shortSite = "short_site"
        case appBundleID = "app_bundle_id"
        case appName = "app_name"
        case plistURL = "plist_url"
        case defaultAppSourceURLs = "default_app_source_urls"
        case appIconURL = "app_icon_url"
        case appLaunchIconURL = "app_launch_icon_url"
        case group
        case contactURL = "contact_url"
        case buyURL = "buy_url"
        case tutorialURL = "tutorial_url"
        case notice
        case exchange
        case whitelist
        case importPermissions = "import_permissions"
        case installServerURLs = "install_server_urls"
        case onlineBrandingEnabled = "online_branding_enabled"
        case remoteConfigURL = "remote_config_url"
        case licenseDomain = "license_domain"
        case licenseVerifyURL = "license_verify_url"
        case licenseAppID = "license_app_id"
    }

     /// 手动初始化器。
     /// 主要用于代码里构造默认配置、覆盖局部字段、导出新配置等场景。
    init(
        shortSite: String = "",
        appBundleID: String = "",
        appName: String = "",
        plistURL: String = "",
        defaultAppSourceURLs: [String] = [],
        appIconURL: String = "",
        appLaunchIconURL: String = "",
        group: String = "",
        contactURL: String = "",
        buyURL: String = "",
        tutorialURL: String = "",
        notice: String = "",
        exchange: Bool = true,
        whitelist: Bool = false,
        importPermissions: Bool = true,
        installServerURLs: [String] = [],
        onlineBrandingEnabled: Bool = false,
        remoteConfigURL: String = "",
        licenseDomain: String = "",
        licenseVerifyURL: String = Self.fallback.licenseVerifyURL,
        licenseAppID: Int = Self.fallback.licenseAppID
    ) {
        self.shortSite = shortSite
        self.appBundleID = appBundleID
        self.appName = appName
        self.plistURL = plistURL
        self.defaultAppSourceURLs = defaultAppSourceURLs
        self.appIconURL = appIconURL
        self.appLaunchIconURL = appLaunchIconURL
        self.group = group
        self.contactURL = contactURL
        self.buyURL = buyURL
        self.tutorialURL = tutorialURL
        self.notice = notice
        self.exchange = exchange
        self.whitelist = whitelist
        self.importPermissions = importPermissions
        self.installServerURLs = installServerURLs
        self.onlineBrandingEnabled = onlineBrandingEnabled
        self.remoteConfigURL = remoteConfigURL
        self.licenseDomain = licenseDomain
        self.licenseVerifyURL = licenseVerifyURL
        self.licenseAppID = licenseAppID
    }

     /// 自定义解码逻辑。
     ///
     /// 这里不直接依赖标准 `decode(_:forKey:)`，而是尽量兼容旧后端可能返回的：
     /// - `String`
     /// - `Int`
     /// - `Bool`
     /// - 逗号分隔的 URL 字符串
     /// - URL 数组
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shortSite = c.lenientString(forKey: .shortSite)
        appBundleID = c.lenientString(forKey: .appBundleID, default: Self.fallback.appBundleID)
        appName = c.lenientString(forKey: .appName, default: Self.fallback.appName)
        plistURL = c.lenientString(forKey: .plistURL)
        defaultAppSourceURLs = Self.decodeURLList(container: c, key: .defaultAppSourceURLs)
        appIconURL = c.lenientString(forKey: .appIconURL)
        appLaunchIconURL = c.lenientString(forKey: .appLaunchIconURL)
        group = c.lenientString(forKey: .group)
        contactURL = c.lenientString(forKey: .contactURL, default: Self.fallback.contactURL)
        buyURL = c.lenientString(forKey: .buyURL)
        tutorialURL = c.lenientString(forKey: .tutorialURL, default: Self.fallback.tutorialURL)
        notice = c.lenientString(forKey: .notice)
        exchange = c.lenientBool(forKey: .exchange, default: Self.fallback.exchange)
        whitelist = c.lenientBool(forKey: .whitelist, default: Self.fallback.whitelist)
        importPermissions = c.lenientBool(forKey: .importPermissions, default: Self.fallback.importPermissions)
        installServerURLs = Self.decodeURLList(container: c, key: .installServerURLs)
        onlineBrandingEnabled = c.lenientBool(forKey: .onlineBrandingEnabled, default: Self.fallback.onlineBrandingEnabled)
        remoteConfigURL = c.lenientString(forKey: .remoteConfigURL)
        licenseDomain = c.lenientString(forKey: .licenseDomain)
        licenseVerifyURL = c.lenientString(forKey: .licenseVerifyURL, default: Self.fallback.licenseVerifyURL)
        licenseAppID = c.lenientInt(forKey: .licenseAppID, default: Self.fallback.licenseAppID)
    }

     /// 归一化后的默认软件源列表。
     ///
     /// 会自动：
     /// - 去除首尾空格
     /// - 补全缺失的 `https://`
     /// - 去重
    var normalizedDefaultAppSourceURLs: [String] {
        Self.normalizeURLs(defaultAppSourceURLs)
    }

     /// 归一化后的安装服务器列表。
     ///
     /// 如果 `install_server_urls` 为空，则回退使用单值字段 `plist_url`。
    var normalizedInstallServerURLs: [String] {
        let raw = installServerURLs.isEmpty ? [plistURL] : installServerURLs
        return Self.normalizeURLs(raw)
    }

     /// 归一化后的远程配置地址。
     ///
     /// 若为空字符串，表示当前品牌包未配置在线贴牌能力，
     /// 运行时应直接回退到本地包内 / 缓存配置。
    var normalizedRemoteConfigURL: String {
        Self.normalizeSingleURL(remoteConfigURL)
    }

     /// 归一化后的授权域名。
     ///
     /// 若未显式配置，则保持为空，由运行时根据远程配置 URL 的 Host 自动推导。
    var normalizedLicenseDomain: String {
        licenseDomain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

     /// 归一化后的授权接口地址。
    var normalizedLicenseVerifyURL: String {
        let value = Self.normalizeSingleURL(licenseVerifyURL)
        return value.isEmpty ? Self.fallback.licenseVerifyURL : value
    }

     /// 导出为 JSON 数据。
     ///
     /// 导出的内容会在签名流程中嵌入到目标 IPA 内，
     /// 让贴牌后的 YSign 在运行时读取到新的品牌配置。
    var exportData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(self)
    }

     /// 从主应用 Bundle 中读取 `BrandConfig.json`。
     ///
     /// 这是运行时品牌配置的入口：
     /// - 若存在并可解析，则使用包内配置
     /// - 否则退回 `fallback`
    static func loadFromBundle() -> BrandConfig {
        guard let url = Bundle.main.url(forResource: "BrandConfig", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(BrandConfig.self, from: data) else {
            return .fallback
        }
        return config
    }

     /// 宽松解析 URL 列表字段。
     ///
     /// 支持两种来源：
     /// - 标准数组：`["https://a", "https://b"]`
     /// - 字符串：`"https://a,https://b"`
    private static func decodeURLList(container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> [String] {
        if let list = try? container.decode([String].self, forKey: key) {
            return normalizeURLs(list)
        }
        if let raw = try? container.decode(String.self, forKey: key) {
            return normalizeURLs(splitURLList(raw))
        }
        return []
    }

     /// 将逗号 / 分号 / 换行拼接的 URL 文本拆分成数组。
    private static func splitURLList(_ raw: String) -> [String] {
        raw
            .components(separatedBy: CharacterSet(charactersIn: ",;\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

     /// 标准化单个 URL。
     ///
     /// 规则与列表标准化保持一致：
     /// - 去除首尾空格
     /// - 若缺失协议头，自动补全为 `https://`
    private static func normalizeSingleURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if !value.hasPrefix("http://") && !value.hasPrefix("https://") {
            value = "https://\(value)"
        }
        return value
    }

     /// 标准化 URL 列表。
     ///
     /// 这里不会校验远端地址是否真的可访问，
     /// 只负责把本地配置整理成统一格式，减少 UI 和存储层的判断成本。
    private static func normalizeURLs(_ urls: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        for item in urls {
            let url = normalizeSingleURL(item)
            guard !url.isEmpty else { continue }
            guard seen.insert(url).inserted else { continue }
            result.append(url)
        }

        return result
    }
 }
