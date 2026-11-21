import Foundation

/// 软件源模型
///
/// 代表一个 IPA 应用分发源（类似 Cydia 源），
/// 包含源的基本信息和该源下的所有可下载应用列表。
///
/// 源的 JSON 数据格式：
/// ```json
/// {
///   "name": "源名称",
///   "identifier": "source.id",
///   "sourceURL": "https://example.com/source",
///   "sourceicon": "https://example.com/icon.png",
///   "message": "源描述/公告",
///   "apps": [...]
/// }
/// ```
struct AppSource: Identifiable, Codable, Hashable {

    /// 唯一标识（使用 sourceURL 作为唯一性判断）
    var id: String { sourceURL }

    /// 源的 URL 地址（用于拉取应用列表）
    var sourceURL: String = ""

    /// 源名称
    var name: String = ""

    /// 源的公告/描述信息
    var message: String = ""

    /// 源标识符
    var identifier: String = ""

    /// 源图标 URL
    var sourceicon: String = ""

    /// 解锁接口地址 (源级别).
    ///
    /// 与 FreeSign 等老版工具协议保持一致:
    /// `GET {unlockURL}?udid=<UDID>&code=<解锁码>` → `{ "msg": "..." }`
    /// msg 含 "成功" 视为解锁通过, 后续刷新源即可拿到带 downloadURL 的应用。
    var unlockURL: String = ""

    /// 购买/获取解锁码的页面地址 (源级别).
    /// 用户点击"获取解锁码"按钮时, 用 Safari 打开该地址。
    var payURL: String = ""

    /// 该源下的所有应用
    var apps: [AppModel] = []

    func hash(into hasher: inout Hasher) {
        hasher.combine(sourceURL)
    }

    static func == (lhs: AppSource, rhs: AppSource) -> Bool {
        lhs.sourceURL == rhs.sourceURL
    }

    // MARK: - 容错解码

    enum CodingKeys: String, CodingKey {
        case sourceURL, name, message, identifier, sourceicon, unlockURL, payURL, apps
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceURL = (try? c.decode(String.self, forKey: .sourceURL)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        identifier = (try? c.decode(String.self, forKey: .identifier)) ?? ""
        sourceicon = (try? c.decode(String.self, forKey: .sourceicon)) ?? ""
        unlockURL = (try? c.decode(String.self, forKey: .unlockURL)) ?? ""
        payURL = (try? c.decode(String.self, forKey: .payURL)) ?? ""
        // 逐个解码 apps，跳过失败的
        if var appsContainer = try? c.nestedUnkeyedContainer(forKey: .apps) {
            var list: [AppModel] = []
            while !appsContainer.isAtEnd {
                if let app = try? appsContainer.decode(AppModel.self) {
                    list.append(app)
                } else {
                    // 跳过解码失败的元素
                    _ = try? appsContainer.decode(AnyCodable.self)
                }
            }
            apps = list
        }
    }
}

/// 软件源中的单个应用模型
///
/// 代表源中的一个可下载应用，包含名称、版本、下载链接等信息
struct AppModel: Identifiable, Codable, Hashable {

    /// 在源列表中的位置（不参与持久化，解析/读取缓存时重建）
    /// 用于保证 ForEach 的 id 唯一：源里常有同名同版本的应用（如两个"抖音"）
    var rowIndex: Int = -1

    /// 唯一标识
    var id: String { "\(sourceName)_\(sourceIdentifier)_\(rowIndex)_\(name)_\(version)" }

    /// 应用名称
    var name: String = ""

    /// 应用版本号
    var version: String = ""

    /// 版本发布日期
    var versionDate: String = ""

    /// 版本更新说明
    var versionDescription: String = ""

    /// IPA 下载地址
    var downloadURL: String = ""

    /// 应用图标 URL
    var iconURL: String = ""

    /// 应用主题色（十六进制，如 "95b5d6"）
    var tintColor: String = "95b5d6"

    /// 文件大小描述（如 "120MB"）
    var size: String = ""

    /// 排序权重（数值越大越靠前）
    var weigh: Int = 0

    /// 应用分类（如 "游戏"、"工具"、"影音" 等）
    var type: String = ""

    /// 是否需要解锁（付费/密码）
    var lock: Bool = false

    /// 所属源的标识符
    var sourceIdentifier: String = ""

    /// 所属源的名称
    var sourceName: String = ""

    /// 生成本地保存的文件名
    var fileName: String {
        "\(name)_\(version)_\(sourceIdentifier.isEmpty ? versionDate : sourceIdentifier).ipa"
    }

    // MARK: - 容错解码（兼容旧版 HandyJSON 的宽松类型转换）

    enum CodingKeys: String, CodingKey {
        case name, version, versionDate, versionDescription, downloadURL
        case iconURL, tintColor, size, weigh, type, lock
        case sourceIdentifier, sourceName
    }

    /// 兼容大小写变体的图标字段名 (icon / Icon).
    /// 没有放进 `CodingKeys`, 否则 Swift 自动合成的 `encode(to:)` 会要求对应字段,
    /// 反过来导致 Encodable 一致性失败。
    private struct AlternateIconKeys: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
        static let icon = AlternateIconKeys(stringValue: "icon")!
        static let iconUpper = AlternateIconKeys(stringValue: "Icon")!
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenientString(forKey: .name)
        version = c.lenientString(forKey: .version)
        versionDate = c.lenientString(forKey: .versionDate)
        versionDescription = c.lenientString(forKey: .versionDescription)
        downloadURL = c.lenientString(forKey: .downloadURL)

        // 图标字段名在不同源中差异较大, 依次尝试: iconURL → icon → Icon
        var icon = c.lenientString(forKey: .iconURL)
        if icon.isEmpty {
            let alt = try? decoder.container(keyedBy: AlternateIconKeys.self)
            if let alt {
                if let v = try? alt.decode(String.self, forKey: .icon), !v.isEmpty {
                    icon = v
                } else if let v = try? alt.decode(String.self, forKey: .iconUpper), !v.isEmpty {
                    icon = v
                }
            }
        }
        iconURL = icon

        tintColor = c.lenientString(forKey: .tintColor, default: "95b5d6")
        size = c.lenientString(forKey: .size)
        weigh = c.lenientInt(forKey: .weigh)
        type = c.lenientString(forKey: .type)
        lock = c.lenientBool(forKey: .lock)
        sourceIdentifier = c.lenientString(forKey: .sourceIdentifier)
        sourceName = c.lenientString(forKey: .sourceName)
    }
}

// MARK: - 容错解码辅助

/// 用于跳过无法解码的数组元素
struct AnyCodable: Codable {
    init(from decoder: Decoder) throws {
        _ = try decoder.singleValueContainer()
    }
    func encode(to encoder: Encoder) throws {}
}

extension KeyedDecodingContainer {
    /// 宽松读取 String（自动从 Int/Double/Bool 转换）
    func lenientString(forKey key: Key, default defaultValue: String = "") -> String {
        if let v = try? decode(String.self, forKey: key) { return v }
        if let v = try? decode(Int.self, forKey: key) { return String(v) }
        if let v = try? decode(Double.self, forKey: key) { return String(v) }
        if let v = try? decode(Bool.self, forKey: key) { return v ? "1" : "0" }
        return defaultValue
    }

    /// 宽松读取 Int（自动从 String/Double/Bool 转换）
    func lenientInt(forKey key: Key, default defaultValue: Int = 0) -> Int {
        if let v = try? decode(Int.self, forKey: key) { return v }
        if let v = try? decode(String.self, forKey: key) { return Int(v) ?? defaultValue }
        if let v = try? decode(Double.self, forKey: key) { return Int(v) }
        if let v = try? decode(Bool.self, forKey: key) { return v ? 1 : 0 }
        return defaultValue
    }

    /// 宽松读取 Bool（自动从 String/Int 转换）
    func lenientBool(forKey key: Key, default defaultValue: Bool = false) -> Bool {
        if let v = try? decode(Bool.self, forKey: key) { return v }
        if let v = try? decode(Int.self, forKey: key) { return v != 0 }
        if let v = try? decode(String.self, forKey: key) { return v == "1" || v == "true" }
        return defaultValue
    }
}

/// 下载任务模型
///
/// 代表一个正在进行或已完成的 IPA 文件下载任务
struct DownloadTask: Identifiable, Codable {

    /// 唯一标识
    let id: UUID

    /// 下载 URL
    let url: String

    /// 文件名
    let fileName: String

    /// 所属源名称（可选）
    let sourceName: String?

    /// 下载状态
    var status: DownloadStatus

    /// 下载进度（0.0 ~ 1.0）
    var progress: Double

    /// 文件大小（字节）
    var totalBytes: Int64

    /// 已下载大小（字节）
    var downloadedBytes: Int64

    /// 下载开始时间
    let startTime: Date

    /// 下载完成时间
    var endTime: Date?

    /// 本地文件路径（下载完成后设置）
    var localFileURL: URL?

    /// 下载状态枚举
    enum DownloadStatus: String, Codable {
        case waiting = "等待中"
        case downloading = "下载中"
        case paused = "已暂停"
        case completed = "已完成"
        case failed = "失败"
    }
}
