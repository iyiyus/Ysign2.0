import Foundation

/// 描述文件（Provisioning Profile）模型
/// 对应 .mobileprovision 文件，包含应用的权限、设备列表、团队信息等
/// 签名时必须将此文件嵌入到 .app 包中（作为 embedded.mobileprovision）
struct MobileProvision: Identifiable, Hashable {

    /// 唯一标识符
    let id: UUID

    /// 描述文件名称（Xcode 中显示的名字）
    let name: String

    /// App ID 名称（如 "YSign App"）
    let appIDName: String

    /// 开发者团队名称
    let teamName: String

    /// 开发者团队 ID（10位字母数字）
    let teamID: String

    /// 关联的 Bundle Identifier（如 com.example.*）
    let bundleIdentifier: String

    /// 描述文件创建时间
    let creationDate: Date

    /// 描述文件过期时间
    let expirationDate: Date

    /// Entitlements 权限字典（包含推送、iCloud、App Groups 等权限）
    let entitlements: [String: Any]

    /// 已注册的设备 UDID 列表（企业证书和 App Store 为 nil）
    let provisionedDevices: [String]?

    /// 是否为通配符描述文件（Bundle ID 以 * 结尾）
    let isWildcard: Bool

    /// 描述文件类型
    let profileType: ProfileType

    /// 文件在磁盘上的路径
    let fileURL: URL

    /// 描述文件类型枚举
    enum ProfileType: String {
        case development = "开发"    // 开发证书，需要设备 UDID
        case adHoc = "Ad Hoc"       // Ad Hoc 分发，需要设备 UDID
        case appStore = "App Store" // App Store 分发，无设备限制
        case enterprise = "企业"     // 企业证书，无设备限制
    }

    /// 是否已过期
    var isExpired: Bool {
        expirationDate < Date()
    }

    // MARK: - Hashable（基于 id）

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MobileProvision, rhs: MobileProvision) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - 解析方法

    /// 从文件 URL 解析描述文件
    /// - Parameter url: .mobileprovision 文件路径
    /// - Returns: 解析后的 MobileProvision 对象
    static func parse(from url: URL) throws -> MobileProvision {
        let data = try Data(contentsOf: url)
        return try parse(from: data, fileURL: url)
    }

    /// 从二进制数据解析描述文件
    /// 描述文件本质上是一个 CMS（PKCS#7）签名信封，内部包含一段 plist XML
    /// 解析步骤：1. 从 CMS 信封中提取 plist → 2. 反序列化 plist → 3. 提取各字段
    static func parse(from data: Data, fileURL: URL = URL(fileURLWithPath: "/dev/null")) throws -> MobileProvision {
        // 第一步：从 CMS/PKCS7 二进制数据中找到嵌入的 plist XML
        guard let plistData = extractPlist(from: data) else {
            throw SigningError.invalidProvisioningProfile("无法解析描述文件")
        }

        // 第二步：将 plist XML 反序列化为字典
        guard let plist = try PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil
        ) as? [String: Any] else {
            throw SigningError.invalidProvisioningProfile("描述文件格式错误")
        }

        // 第三步：提取各个字段
        let name = plist["Name"] as? String ?? "Unknown"
        let appIDName = plist["AppIDName"] as? String ?? ""
        let teamName = (plist["TeamName"] as? String) ?? ""
        let teamIDs = plist["TeamIdentifier"] as? [String] ?? []
        let teamID = teamIDs.first ?? ""
        let creationDate = plist["CreationDate"] as? Date ?? Date()
        let expirationDate = plist["ExpirationDate"] as? Date ?? Date()
        let devices = plist["ProvisionedDevices"] as? [String]
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]

        // 从 application-identifier 中提取 Bundle ID（去掉前缀的 Team ID 部分）
        // 格式为: "TEAMID.com.example.app" → 提取 "com.example.app"
        let appID = entitlements["application-identifier"] as? String ?? ""
        let bundleID = appID.components(separatedBy: ".").dropFirst().joined(separator: ".")
        let isWildcard = bundleID.hasSuffix("*")

        // 判断描述文件类型：
        // - ProvisionsAllDevices=true → 企业证书
        // - 有设备列表 + get-task-allow=true → 开发证书
        // - 有设备列表 + get-task-allow=false → Ad Hoc
        // - 无设备列表 → App Store
        let profileType: ProfileType
        let provisionsAllDevices = plist["ProvisionsAllDevices"] as? Bool ?? false
        if provisionsAllDevices {
            profileType = .enterprise
        } else if devices != nil {
            let getTaskAllow = entitlements["get-task-allow"] as? Bool ?? false
            profileType = getTaskAllow ? .development : .adHoc
        } else {
            profileType = .appStore
        }

        return MobileProvision(
            id: UUID(),
            name: name,
            appIDName: appIDName,
            teamName: teamName,
            teamID: teamID,
            bundleIdentifier: bundleID,
            creationDate: creationDate,
            expirationDate: expirationDate,
            entitlements: entitlements,
            provisionedDevices: devices,
            isWildcard: isWildcard,
            profileType: profileType,
            fileURL: fileURL
        )
    }

    // MARK: - 私有方法

    /// 从 CMS/PKCS7 签名数据中提取内嵌的 plist XML
    /// 原理：在二进制数据中查找 "<?xml" 开头和 "</plist>" 结尾的区间
    private static func extractPlist(from data: Data) -> Data? {
        let startMarker = "<?xml".data(using: .utf8)!
        let endMarker = "</plist>".data(using: .utf8)!

        guard let startRange = data.range(of: startMarker),
              let endRange = data.range(of: endMarker) else {
            return nil
        }

        let plistEnd = endRange.upperBound
        return data.subdata(in: startRange.lowerBound..<plistEnd)
    }
}
