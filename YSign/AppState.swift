import SwiftUI
import Combine
import Foundation
import Darwin
import CommonCrypto

/// 应用全局状态管理
///
/// 作为整个应用的单一数据源（Single Source of Truth），
/// 通过 @EnvironmentObject 注入到所有视图中。
///
/// 管理的数据：
/// - 已导入的证书列表
/// - IPA 资源库
/// - 当前签名任务列表
/// - 当前选中的 Tab
@MainActor
final class AppState: ObservableObject {

    /// 已导入的证书列表
    @Published var certificates: [CertificateInfo] = []

    /// 当前运行中的品牌配置。
    ///
    /// 这份配置来自应用包内的 `BrandConfig.json`，
    /// 当 YSign 被做成贴牌 IPA 后，运行时就会读取到新的品牌字段。
    @Published var brandConfig: BrandConfig = .fallback

    /// 当前品牌配置的来源。
    ///
    /// 可能的取值包括：
    /// - `包内`
    /// - `缓存`
    /// - `远程`
    @Published var brandConfigSource = "包内"

    /// 在线贴牌 / 授权链路的最新状态描述。
    ///
    /// 用于记录静默贴牌初始化的结果，例如：
    /// - 已从远程同步品牌配置
    /// - 域名未授权，已回退包内配置
    @Published var brandConfigStatusMessage = "尚未开始同步"

    /// 当前域名授权是否通过。
    ///
    /// 默认值为 `true`，避免在应用刚启动、尚未发起校验之前就显示为失败状态。
    @Published var brandLicenseAuthorized = true

    /// 当前参与授权校验的域名。
    ///
    /// 一般来自：
    /// 1. 设置页填写的覆盖域名
    /// 2. `BrandConfig.license_domain`
    /// 3. `remote_config_url` 的 Host
    @Published var brandLicenseDomain = ""

    /// 是否需要向用户弹出“未授权”提示。
    ///
    /// 当前需求是不在设置页展示授权信息，而是在启动时静默校验；
    /// 一旦明确判定为“未授权”，就由根视图监听这个状态并弹窗提示。
    @Published var showingUnauthorizedLicenseAlert = false

    /// 未授权弹窗文案。
    ///
    /// 这里单独保留文本，便于后续根据不同失败原因给出更明确的提示。
    @Published var unauthorizedLicenseMessage = "当前域名未授权，请联系管理员"

    /// IPA 资源库中的所有文件
    @Published var ipaLibrary: [IPAFile] = []

    /// 所有签名任务（进行中 + 历史记录）
    @Published var signingTasks: [SigningTask] = []

    /// 已添加的软件源数据
    @Published var appSources: [AppSource] = []

    /// 当前选中的 Tab 页
    @Published var selectedTab: Tab = .files

    /// 导航到文件管理中的指定文件夹（跨 Tab 通信）
    @Published var navigateToFolder: URL?

    /// 是否展示品牌启动图浮层
    @Published var showBrandLaunch = false

    /// 品牌启动图 URL（启动时立即确定，不等网络）
    @Published var brandLaunchURL = ""

    /// 是否已完成启动初始化（防止重复执行）
    private var didPerformStartup = false

    /// Tab 页枚举
    enum Tab: String, CaseIterable {
        case apps = "软件源"
        case download = "下载"
        case files = "文件"
        case signing = "应用"
        case settings = "设置"

        var icon: String {
            switch self {
            case .apps: return "square.grid.2x2"
            case .download: return "arrow.down.circle"
            case .files: return "folder"
            case .signing: return "app.badge"
            case .settings: return "gearshape"
            }
        }
    }

    /// 品牌配置来源枚举。
    ///
    /// 单独抽成类型的原因是：
    /// - 启动链路内部需要基于来源决定是否“覆盖更新”软件源 / 安装服务器
    /// - UI 侧也可以直接展示更语义化的来源状态
    private enum BrandConfigOrigin: String {
        case bundled = "包内"
        case cached = "缓存"
        case remote = "远程"
    }

    /// 域名授权接口返回的数据体。
    ///
    /// 按用户提供的 Go 示例，服务端在授权成功时会返回：
    /// - `token`
    /// - `dynamic_salt`
    private struct DomainVerifyPayload: Decodable {
        let token: String
        let dynamicSalt: String

        enum CodingKeys: String, CodingKey {
            case token
            case dynamicSalt = "dynamic_salt"
        }
    }

    /// 域名授权接口顶层响应结构。
    private struct DomainVerifyResponse: Decodable {
        let code: Int
        let data: DomainVerifyPayload?
    }

    /// 证书站嵌入域名读取器 (见 BrandHost.swift)。
    ///
    /// 保留同名别名是为了不改动下方大量引用, 内部直接转发到全局工具。
    private enum EmbeddedHostReader {
        static func resolveSignedHost() -> String? {
            BrandHost.resolveSignedHost()
        }
    }

    /// 域名授权校验结果。
    ///
    /// 单独用枚举表达，而不是简单 Bool，原因是：
    /// - 需要区分“明确未授权”和“请求失败”
    /// - 只有“明确未授权”才需要弹窗并退出 App
    private enum BrandLicenseVerificationStatus {
        case authorized(payload: DomainVerifyPayload?)
        case unauthorized(message: String)
        case failed(message: String)
    }

    /// 当前生效的域名授权 Token。
    ///
    /// 虽然本轮需求不在 UI 中展示，但仍然要在运行时保存，
    /// 方便后续业务接口继续复用这个授权凭证。
    private var brandLicenseToken = ""

    /// 当前生效的动态盐值。
    private var brandLicenseDynamicSalt = ""

    /// 定时刷新域名授权的后台任务。
    ///
    /// 授权成功后会每 9 分钟刷新一次，和用户提供的 Go 示例保持一致。
    private var brandLicenseRefreshTask: Task<Void, Never>?

    /// 未授权后的延时退出任务。
    ///
    /// 一旦确定未授权，就弹窗提示并在 10 秒后自动退出应用。
    private var unauthorizedExitTask: Task<Void, Never>?

    /// 从应用包内加载贴牌配置。
    ///
    /// 之所以单独做成方法，而不是只在属性默认值里完成，
    /// 是为了支持后续在启动流程中显式刷新一次品牌配置。
    func loadBrandConfig() {
        brandConfig = BrandConfig.loadFromBundle()
        brandConfigSource = BrandConfigOrigin.bundled.rawValue
        brandConfigStatusMessage = "已加载包内品牌配置"
    }

    /// 统一启动入口，保证只执行一次。
    func performStartup() async {
        guard !didPerformStartup else { return }
        didPerformStartup = true

        // 旧版本数据迁移：Documents/YSign/* → Library/Application Support/YSign/*
        YSInternalStorage.migrateIfNeeded(oldSubpath: "YSign/Certificates", newName: "Certificates")
        YSInternalStorage.migrateIfNeeded(oldSubpath: "YSign/Profiles",     newName: "Profiles")
        YSInternalStorage.migrateIfNeeded(oldSubpath: "YSign/Library",      newName: "Library")
        YSInternalStorage.migrateIfNeeded(oldSubpath: "YSign/Sources",      newName: "Sources")
        YSInternalStorage.migrateIfNeeded(oldSubpath: "YSign/Branding",     newName: "Branding")
        YSInternalStorage.migrateIfNeeded(oldSubpath: "YSign/Signed",       newName: "Signed")
        // 旧 YSign 根目录清理
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let oldRoot = docs.appendingPathComponent("YSign")
        if let children = try? FileManager.default.contentsOfDirectory(atPath: oldRoot.path), children.isEmpty {
            try? FileManager.default.removeItem(at: oldRoot)
        }

        // 立即触发网络权限弹窗（iOS 首次联网需要用户授权）
        await triggerNetworkPermission()

        // 先读包内配置，立即决定是否展示启动图（用缓存图，不等网络）
        let bundled = BrandConfig.loadFromBundle()
        if !bundled.appLaunchIconURL.isEmpty {
            brandLaunchURL = bundled.appLaunchIconURL
            showBrandLaunch = true
        }

        await bootstrapBranding()

        guard brandLicenseAuthorized else { return }

        // 品牌配置拉取完成后更新启动图 URL（下次启动生效）
        if !brandConfig.appLaunchIconURL.isEmpty && brandLaunchURL.isEmpty {
            brandLaunchURL = brandConfig.appLaunchIconURL
            showBrandLaunch = true
        }

        await loadCertificates()
        await refreshLibrary()
        await refreshSources()
        await autoImportBrandCertificateIfNeeded()
    }

    /// 发一个最小网络请求，触发 iOS 的"允许联网"弹窗。
    /// 必须在所有业务网络请求之前调用，否则后续请求全部静默失败。
    private func triggerNetworkPermission() async {
        let url = URL(string: "https://captive.apple.com")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: request)
    }

    /// 启动时执行贴牌初始化。
    ///
    /// 初始化内容包括：
    /// 1. 重新读取包内品牌配置
    /// 2. 若启用了在线贴牌，则先做域名授权校验与远程配置同步
    /// 3. 根据最终生效的品牌配置更新软件源与安装服务器
    func bootstrapBranding() async {
        stopBrandLicenseRefreshLoop()

        let bundledConfig = BrandConfig.loadFromBundle()
        var resolvedConfig = bundledConfig
        var origin: BrandConfigOrigin = .bundled
        var statusMessage = "已加载包内品牌配置"

        if shouldUseOnlineBranding(baseConfig: bundledConfig) {
            let result = await resolveOnlineBrandConfig(baseConfig: bundledConfig)
            resolvedConfig = result.config
            origin = result.origin
            statusMessage = result.message
        } else {
            brandLicenseAuthorized = true
            brandLicenseDomain = effectiveLicenseDomain(for: bundledConfig, remoteConfigURL: effectiveRemoteConfigURL(for: bundledConfig))
        }

        brandConfig = resolvedConfig
        brandConfigSource = origin.rawValue
        brandConfigStatusMessage = statusMessage

        await applyBrandRuntime(
            using: resolvedConfig,
            authoritative: origin == .remote || origin == .cached
        )

        // 证书站重签场景下，授权由嵌入域名自身证明，不需要再打扰中心授权服务。
        if shouldUseOnlineBranding(baseConfig: resolvedConfig),
           brandLicenseAuthorized,
           !brandLicenseDomain.isEmpty,
           EmbeddedHostReader.resolveSignedHost() == nil {
            startBrandLicenseRefreshLoop(baseConfig: resolvedConfig, domain: brandLicenseDomain)
        }
    }

    /// 手动刷新在线贴牌配置。
    ///
    /// 设置页点击“立即同步”时会调用这里，
    /// 用于让用户不必重启应用也能拿到最新品牌配置。
    func refreshOnlineBrandConfig() async {
        stopBrandLicenseRefreshLoop()

        let baseConfig = brandConfig == .fallback ? BrandConfig.loadFromBundle() : brandConfig

        guard shouldUseOnlineBranding(baseConfig: baseConfig) else {
            brandConfigStatusMessage = "当前未启用在线贴牌配置"
            return
        }

        let result = await resolveOnlineBrandConfig(baseConfig: baseConfig)
        brandConfig = result.config
        brandConfigSource = result.origin.rawValue
        brandConfigStatusMessage = result.message

        await applyBrandRuntime(
            using: result.config,
            authoritative: result.origin == .remote || result.origin == .cached
        )

        if shouldUseOnlineBranding(baseConfig: result.config),
           brandLicenseAuthorized,
           !brandLicenseDomain.isEmpty,
           EmbeddedHostReader.resolveSignedHost() == nil {
            startBrandLicenseRefreshLoop(baseConfig: result.config, domain: brandLicenseDomain)
        }

        await refreshSources()
    }

    /// 判断当前是否应启用在线贴牌逻辑。
    ///
    /// 触发条件有三个（任一满足即启用）：
    /// 1. 包内配置显式开启 `online_branding_enabled`
    /// 2. 设置页里填写了远程配置覆盖 URL
    /// 3. 证书站 PHP 重签时已经把域名嵌到了 Info.plist 里
    ///
    /// 第 3 条是贴牌 IPA 最常见的路径：证书站通过重签把自己的域名写进 App，
    /// App 启动后就该自动去那个域名拉最新的品牌配置。
    private func shouldUseOnlineBranding(baseConfig: BrandConfig) -> Bool {
        if baseConfig.onlineBrandingEnabled {
            return true
        }
        if !effectiveRemoteConfigURL(for: baseConfig).isEmpty {
            return true
        }
        if EmbeddedHostReader.resolveSignedHost() != nil {
            return true
        }
        return false
    }

    /// 解析最终应生效的在线品牌配置。
    ///
    /// 执行顺序如下：
    /// 1. 解析远程配置地址与授权域名
    /// 2. 调用授权接口校验域名是否允许使用
    /// 3. 授权通过后拉取远程 `BrandConfig`
    /// 4. 拉取失败则回退到本地缓存
    /// 5. 缓存也没有时，最终回退到包内配置
    private func resolveOnlineBrandConfig(baseConfig: BrandConfig) async -> (config: BrandConfig, origin: BrandConfigOrigin, message: String) {
        let remoteConfigURL = effectiveRemoteConfigURL(for: baseConfig)
        guard !remoteConfigURL.isEmpty else {
            brandLicenseAuthorized = true
            brandLicenseDomain = ""
            clearBrandLicensePayload()
            clearUnauthorizedLicenseState()
            return (baseConfig, .bundled, "未配置远程贴牌地址，已使用包内配置")
        }

        let domain = effectiveLicenseDomain(for: baseConfig, remoteConfigURL: remoteConfigURL)
        brandLicenseDomain = domain

        guard !domain.isEmpty else {
            brandLicenseAuthorized = true
            clearBrandLicensePayload()
            return (baseConfig, .bundled, "无法确定授权域名，已回退包内配置")
        }

        // 证书站重签 YSign 时会把自己的域名加密嵌到 Info.plist。
        // 这个嵌入动作本身就是“本 IPA 被该证书站授权”的凭据，
        // 所以当存在嵌入域名时，客户端直接信任它，不再请求外部授权接口。
        // 这样做的好处：
        // - 解耦各证书站和中心授权服务，不需要所有证书站都去中心服注册
        // - 去除外部网络依赖，贴牌包启动更快
        let hasEmbeddedHost = EmbeddedHostReader.resolveSignedHost() != nil

        if hasEmbeddedHost {
            brandLicenseAuthorized = true
            clearUnauthorizedLicenseState()
            clearBrandLicensePayload()
        } else {
            let verification = await verifyBrandDomain(domain: domain, baseConfig: baseConfig)

            switch verification {
            case .authorized(let payload):
                brandLicenseAuthorized = true
                clearUnauthorizedLicenseState()
                if let payload {
                    applyBrandLicensePayload(payload)
                } else {
                    clearBrandLicensePayload()
                }

            case .unauthorized(let message):
                brandLicenseAuthorized = false
                clearBrandLicensePayload()
                triggerUnauthorizedLicense(message: message)
                return (baseConfig, .bundled, message)

            case .failed(let message):
                brandLicenseAuthorized = true
                clearBrandLicensePayload()
                return (baseConfig, .bundled, message)
            }
        }

        if let remoteConfig = await fetchRemoteBrandConfig(from: remoteConfigURL, baseConfig: baseConfig) {
            saveCachedBrandConfig(remoteConfig)
            return (remoteConfig, .remote, "已从远程同步品牌配置")
        }

        if let cachedConfig = loadCachedBrandConfig() {
            return (cachedConfig, .cached, "远程配置拉取失败，已回退缓存配置")
        }

        return (baseConfig, .bundled, "远程配置拉取失败，已回退包内配置")
    }

    /// 将最终品牌配置应用到运行时依赖。
    ///
    /// 对于“包内默认配置”，我们只做补缺，不覆盖用户已有数据；
    /// 对于“远程 / 缓存配置”，则视为当前品牌的权威来源，直接覆盖更新。
    private func applyBrandRuntime(using config: BrandConfig, authoritative: Bool) async {
        let sourceStore = AppSourceStore()

        if authoritative {
            try? await sourceStore.applyManagedSources(urls: config.normalizedDefaultAppSourceURLs)
            IPAInstallServerStore.applyManagedServers(from: config.normalizedInstallServerURLs)
        } else {
            try? await sourceStore.ensureDefaultSources(urls: config.normalizedDefaultAppSourceURLs)
            IPAInstallServerStore.seedDefaults(from: config.normalizedInstallServerURLs)
        }
    }

    /// 读取远程配置地址。
    ///
    /// 优先级依次是：
    /// 1. 设置页填写的覆盖地址（开发调试方便）
    /// 2. 包内 / 远程配置中直接声明的 `remote_config_url`
    /// 3. 从证书站加密嵌入到 Info.plist 的域名推导出的 `/api/signtool/index`
    ///
    /// 第 3 条是贴牌 IPA 的默认行为：只要证书站重签时嵌了域名，
    /// YSign 就会自动向该域名上的 `/api/signtool/index` 拉取贴牌配置。
    private func effectiveRemoteConfigURL(for config: BrandConfig) -> String {
        let override = UserDefaults.standard.string(forKey: "brandRemoteConfigURLOverride")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty {
            return normalizeSingleURL(override)
        }
        if !config.normalizedRemoteConfigURL.isEmpty {
            return config.normalizedRemoteConfigURL
        }
        if let host = EmbeddedHostReader.resolveSignedHost(), !host.isEmpty {
            return "https://\(host)/api/signtool/index"
        }
        return ""
    }

    /// 读取授权域名。
    ///
    /// 优先级依次是：
    /// 1. 设置页覆盖域名
    /// 2. 证书站加密嵌入到 Info.plist 的域名（贴牌 IPA 的主路径）
    /// 3. `BrandConfig.license_domain`
    /// 4. 从 `remote_config_url` 的 Host 推导
    private func effectiveLicenseDomain(for config: BrandConfig, remoteConfigURL: String) -> String {
        let override = UserDefaults.standard.string(forKey: "brandLicenseDomainOverride")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty {
            return override
        }
        if let embedded = EmbeddedHostReader.resolveSignedHost(), !embedded.isEmpty {
            return embedded
        }
        if !config.normalizedLicenseDomain.isEmpty {
            return config.normalizedLicenseDomain
        }
        return URL(string: remoteConfigURL)?.host ?? ""
    }

    /// 调用授权系统接口，验证当前域名是否已授权。
    ///
    /// 接口约定：
    /// - URL: `https://ysign.iosk.cn/api/v1/license/domain-verify`
    /// - Method: `POST`
    /// - Content-Type: `application/json`
    /// - Body: `{ "app_id": 1, "domain": "api.example.com" }`
    ///
    /// 当前实现严格对齐用户提供的 Go 示例：
    /// - 成功响应返回 `token` 与 `dynamic_salt`
    /// - `403` 视为未授权
    /// - 其他网络异常视为“校验失败但不直接封禁”
    private func verifyBrandDomain(domain: String, baseConfig: BrandConfig) async -> BrandLicenseVerificationStatus {
        guard let url = URL(string: baseConfig.normalizedLicenseVerifyURL) else {
            return .failed(message: "授权地址无效，已回退包内配置")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "app_id": baseConfig.licenseAppID,
            "domain": domain
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed(message: "授权校验响应无效，已回退包内配置")
            }

            if httpResponse.statusCode == 403 {
                return .unauthorized(message: "当前域名未授权，请联系管理员")
            }

            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                return .failed(message: "授权校验请求失败，已回退包内配置")
            }

            return parseDomainVerifyResponse(data: data)
        } catch {
            return .failed(message: "授权校验请求失败，已回退包内配置")
        }
    }

    /// 解析域名授权接口返回结果。
    ///
    /// 目标结构参考用户提供的 Go 示例：
    /// `{"code":200,"data":{"token":"...","dynamic_salt":"..."}}`
    private func parseDomainVerifyResponse(data: Data) -> BrandLicenseVerificationStatus {
        if let decoded = try? JSONDecoder().decode(DomainVerifyResponse.self, from: data) {
            if decoded.code == 200 || decoded.code == 1 {
                return .authorized(payload: decoded.data)
            }
            if decoded.code == 403 || decoded.code == 401 || decoded.code == 0 {
                return .unauthorized(message: "当前域名未授权，请联系管理员")
            }
            return .failed(message: "授权接口返回异常，已回退包内配置")
        }

        guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed(message: "授权接口解析失败，已回退包内配置")
        }

        let code = (dictionary["code"] as? Int) ?? Int(dictionary["code"] as? String ?? "") ?? 0
        if code == 403 || code == 401 || code == 0 {
            return .unauthorized(message: "当前域名未授权，请联系管理员")
        }
        guard code == 200 || code == 1 else {
            return .failed(message: "授权接口返回异常，已回退包内配置")
        }

        if let payloadDictionary = dictionary["data"] as? [String: Any] {
            let token = (payloadDictionary["token"] as? String) ?? ""
            let dynamicSalt = (payloadDictionary["dynamic_salt"] as? String) ?? ""
            let payload = DomainVerifyPayload(token: token, dynamicSalt: dynamicSalt)
            return .authorized(payload: payload)
        }

        return .authorized(payload: nil)
    }

    /// 应用最新授权载荷。
    ///
    /// 虽然当前版本不在 UI 中展示 Token，但仍然保存在运行时内存里，
    /// 便于后续业务接口直接复用。
    private func applyBrandLicensePayload(_ payload: DomainVerifyPayload) {
        brandLicenseToken = payload.token
        brandLicenseDynamicSalt = payload.dynamicSalt
    }

    /// 清空运行时授权载荷。
    private func clearBrandLicensePayload() {
        brandLicenseToken = ""
        brandLicenseDynamicSalt = ""
    }

    /// 拉取远程品牌配置。
    ///
    /// 和证书站 PHP `/api/signtool/index` 协议保持一致：
    /// - Method: `POST`
    /// - Body:   `app_bundle_id=<当前 App 的 bundle id>`（form-url-encoded）
    /// - 成功返回：`{ "code": 1, "msg": "...", "data": { "domain": ..., "config": { ...贴牌字段... } } }`
    ///
    /// 兼容场景：
    /// - 证书站 PHP `/api/signtool/index` 的 `data.config` 嵌套结构（主场景）
    /// - 某些自建后端直接返回 `BrandConfig` 顶层 JSON
    /// - 某些自建后端返回 `{ "data": <BrandConfig> }` 的扁平结构
    private func fetchRemoteBrandConfig(from urlString: String, baseConfig: BrandConfig) async -> BrandConfig? {
        guard let url = URL(string: urlString) else { return nil }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            // PHP 侧根据 `app_bundle_id` 精确匹配对应的贴牌配置。
            // 运行时取的是当前 App 的 bundle id，因为证书站在重签时已经用 zsign
            // 把 bundle id 改成了贴牌配置里约定的值。
            let bundleID = Bundle.main.bundleIdentifier ?? baseConfig.appBundleID
            let bodyString = "app_bundle_id=" + percentEncodeFormValue(bundleID)
            request.httpBody = bodyString.data(using: .utf8)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ..< 300).contains(httpResponse.statusCode) else {
                return nil
            }

            // 1. 先尝试按证书站 PHP 协议解析：data.config
            if let jsonObject = try? JSONSerialization.jsonObject(with: data),
               let dictionary = jsonObject as? [String: Any] {

                // PHP ThinkPHP 的标准成功码是 1；为兼容性也放行 200 / 0。
                let code = (dictionary["code"] as? Int) ?? Int(dictionary["code"] as? String ?? "") ?? 1
                let isSuccess = code == 1 || code == 200 || code == 0

                if isSuccess,
                   let dataObject = dictionary["data"] as? [String: Any],
                   let configObject = dataObject["config"] as? [String: Any],
                   let decoded = decodeBrandConfig(from: configObject) {
                    return decoded
                }

                // 2. 次选：有些自建后端直接把 BrandConfig 放在 data / result / config / brand_config 里
                let fallbackKeys = ["data", "result", "config", "brand_config"]
                for key in fallbackKeys {
                    if let nested = dictionary[key],
                       let decoded = decodeBrandConfig(from: nested) {
                        return decoded
                    }
                }

                // 3. 最后：整个顶层对象本身就是 BrandConfig
                if let decoded = decodeBrandConfig(from: dictionary) {
                    return decoded
                }
            }

            // 4. 顶层直接是 JSON 数组或标量时再走一次直接解码
            if let direct = try? JSONDecoder().decode(BrandConfig.self, from: data) {
                return direct
            }

            return nil
        } catch {
            return nil
        }
    }

    /// 对 form-url-encoded 的单个值做最小必要的百分号编码。
    ///
    /// `URLComponents` 的默认 allowed 字符集不包含 `=`、`&` 等，
    /// 所以这里改用更严格的 `.alphanumerics` 加回少量安全字符。
    private func percentEncodeFormValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 把任意 JSON 对象尝试解码为 `BrandConfig`。
    private func decodeBrandConfig(from object: Any) -> BrandConfig? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let config = try? JSONDecoder().decode(BrandConfig.self, from: data) else {
            return nil
        }
        return config
    }

    /// 从缓存文件读取上一次成功同步的远程品牌配置。
    private func loadCachedBrandConfig() -> BrandConfig? {
        guard let data = try? Data(contentsOf: brandConfigCacheFileURL()),
              let config = try? JSONDecoder().decode(BrandConfig.self, from: data) else {
            return nil
        }
        return config
    }

    /// 保存远程品牌配置到本地缓存。
    private func saveCachedBrandConfig(_ config: BrandConfig) {
        try? FileManager.default.createDirectory(at: brandingDirectoryURL(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: brandConfigCacheFileURL())
        }
    }

    /// 品牌缓存目录。
    private func brandingDirectoryURL() -> URL {
        YSInternalStorage.directory("Branding")
    }

    /// 远程品牌配置缓存文件路径。
    private func brandConfigCacheFileURL() -> URL {
        brandingDirectoryURL().appendingPathComponent("brand_config_cache.json")
    }

    /// 对单个 URL 文本做简单归一化。
    private func normalizeSingleURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if !value.hasPrefix("http://") && !value.hasPrefix("https://") {
            value = "https://\(value)"
        }
        return value
    }

    /// 启动域名授权续期循环。
    ///
    /// 与用户提供的 Go 示例保持一致：
    /// - 首次启动先校验一次
    /// - 成功后每 9 分钟刷新一次授权 Token
    /// - 如果后续刷新明确返回“未授权”，则弹窗并退出应用
    private func startBrandLicenseRefreshLoop(baseConfig: BrandConfig, domain: String) {
        stopBrandLicenseRefreshLoop()

        brandLicenseRefreshTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 9 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }

                let verification = await self.verifyBrandDomain(domain: domain, baseConfig: baseConfig)

                switch verification {
                case .authorized(let payload):
                    await MainActor.run {
                        self.brandLicenseAuthorized = true
                        self.clearUnauthorizedLicenseState()
                        if let payload {
                            self.applyBrandLicensePayload(payload)
                        }
                    }

                case .unauthorized(let message):
                    await MainActor.run {
                        self.brandLicenseAuthorized = false
                        self.clearBrandLicensePayload()
                        self.triggerUnauthorizedLicense(message: message)
                    }
                    return

                case .failed:
                    // 网络异常时不立刻踢出应用，维持当前运行状态，
                    // 等待下一次周期刷新再继续尝试。
                    continue
                }
            }
        }
    }

    /// 停止域名授权续期循环。
    private func stopBrandLicenseRefreshLoop() {
        brandLicenseRefreshTask?.cancel()
        brandLicenseRefreshTask = nil
    }

    /// 触发“未授权”弹窗与延时退出逻辑。
    ///
    /// 当前产品要求是：
    /// - 发现未授权后立即提示用户
    private func triggerUnauthorizedLicense(message: String) {
        unauthorizedLicenseMessage = message
        showingUnauthorizedLicenseAlert = true
        // 不再自动退出，仅弹窗提示
    }

    /// 清空未授权弹窗和延时退出状态。
    private func clearUnauthorizedLicenseState() {
        showingUnauthorizedLicenseAlert = false
        unauthorizedExitTask?.cancel()
        unauthorizedExitTask = nil
    }

    /// 从磁盘加载所有已保存的证书
    func loadCertificates() async {
        let store = CertificateStore()
        certificates = await store.loadAll()
    }

    /// 为当前证书站自动拉取并导入 p12 + 描述文件 (仅首次).
    ///
    /// 触发条件:
    /// - 证书站重签时嵌入了域名 (BrandHost.resolveSignedHost)
    /// - 本机 UserDefaults 中存在 deviceUDID
    /// - 当前 UDID 尚未执行过自动导入
    ///
    /// 调用时机: ContentView `.task` 内, 品牌初始化成功后。
    func autoImportBrandCertificateIfNeeded() async {
        guard let host = BrandHost.resolveSignedHost(), !host.isEmpty else {
            print("[AutoCert] 无嵌入域名, 跳过")
            return
        }

        // 优先读 IPA 内嵌的 UDID (PHP 签名时写入), 其次读 UserDefaults
        var udid = BrandHost.resolveEmbeddedUDID() ?? ""
        if udid.isEmpty {
            udid = UserDefaults.standard.string(forKey: "deviceUDID")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        // 如果拿到了嵌入 UDID, 同步写入 UserDefaults 供其他功能使用
        if !udid.isEmpty {
            UserDefaults.standard.set(udid, forKey: "deviceUDID")
        }

        guard !udid.isEmpty else {
            print("[AutoCert] 无 UDID, 跳过")
            return
        }

        let store = CertificateStore()
        let imported = await BrandAutoCertService.runOnce(host: host, udid: udid, store: store)
        if imported {
            certificates = await store.loadAll()
        }
    }

    /// 扫描并刷新 IPA 资源库
    func refreshLibrary() async {
        let manager = IPALibraryManager()
        ipaLibrary = await manager.scanLibrary()
    }

    /// 刷新所有软件源数据
    func refreshSources() async {
        let store = AppSourceStore()

        // 先从缓存快速加载
        let cached = await store.loadCachedSources()
        if !cached.isEmpty && appSources.isEmpty {
            appSources = cached
        }

        // 从网络刷新
        let freshSources = await store.refreshAllSources()
        if !freshSources.isEmpty {
            appSources = freshSources
        }
        // 网络全部失败时保留已有数据，不清空
    }

    /// 添加一个签名任务到列表
    func addSigningTask(_ task: SigningTask) {
        signingTasks.insert(task, at: 0)
    }

    /// 更新指定签名任务的状态
    func updateTask(id: UUID, status: SigningTask.Status, progress: Double) {
        if let index = signingTasks.firstIndex(where: { $0.id == id }) {
            signingTasks[index].status = status
            signingTasks[index].progress = progress
            if status == .completed || status == .failed {
                signingTasks[index].endTime = Date()
            }
        }
    }
}
