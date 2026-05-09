import Foundation

/// 证书信息模型
///
/// 代表一个已导入的 P12 签名证书及其关联的描述文件。
/// P12 和描述文件配对存储，签名时两者缺一不可。
/// 遵循 Codable 以支持 JSON 持久化存储。
struct CertificateInfo: Identifiable, Codable, Hashable {

    /// 唯一标识符（存储时使用）
    let id: UUID

    /// 证书通用名称（如 "iPhone Distribution: 公司名 (TEAMID)"）
    let name: String

    /// 开发者团队名称（组织名）
    let teamName: String

    /// 组织单位（OU）
    let organizationalUnit: String

    /// 开发者团队 ID（10位字母数字组合）
    let teamID: String

    /// 证书序列号（唯一标识证书本身）
    let serialNumber: String

    /// 证书过期时间
    let expirationDate: Date

    /// 证书创建/生效时间
    let creationDate: Date

    /// P12 文件的原始二进制数据（用于签名时重新解析私钥）
    let p12Data: Data

    /// P12 文件的保护密码（加密存储）
    let password: String

    /// 关联的描述文件名称（nil 表示未导入描述文件）
    var profileName: String?

    /// 关联的描述文件 Bundle ID
    var profileBundleID: String?

    /// 关联的描述文件类型
    var profileType: String?

    /// 关联的描述文件过期时间
    var profileExpirationDate: Date?

    /// 关联的描述文件中的设备 UDID 列表
    var provisionedDevices: [String]?

    /// 关联的描述文件中的 Entitlements 键名列表（用于展示）
    var entitlementKeys: [String]?

    /// 描述文件的存储文件名（用于读取原始数据）
    var profileFileName: String?

    /// 是否已导入描述文件
    var hasProfile: Bool {
        profileFileName != nil
    }

    /// 证书是否已过期
    var isExpired: Bool {
        expirationDate < Date()
    }

    /// 距离过期还有多少天（负数表示已过期）
    var daysUntilExpiry: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: expirationDate).day ?? 0
    }

    /// 人类可读的有效期状态文字
    var displayExpiryStatus: String {
        if isExpired {
            return "已过期"
        } else if daysUntilExpiry <= 7 {
            return "即将过期 (\(daysUntilExpiry)天)"
        } else {
            return "有效 (剩余\(daysUntilExpiry)天)"
        }
    }

    /// 证书类型描述（根据 CN 判断）
    var certificateType: String {
        if name.contains("Distribution") {
            return "发布证书"
        } else if name.contains("Development") {
            return "开发证书"
        } else {
            return "签名证书"
        }
    }

    /// 支持平台
    var platform: String {
        if name.contains("iPhone") || name.contains("iOS") {
            return "iOS"
        } else if name.contains("Mac") {
            return "macOS"
        } else {
            return "iOS / macOS"
        }
    }
}
