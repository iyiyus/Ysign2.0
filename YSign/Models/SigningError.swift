import Foundation

/// 签名流程中可能出现的所有错误类型
/// 遵循 LocalizedError 协议，可直接用于 UI 展示错误信息
enum SigningError: LocalizedError {

    /// IPA 文件无效（格式损坏、找不到 .app 目录等）
    case invalidIPA(String)

    /// 证书无效（密码错误、格式损坏、已过期等）
    case invalidCertificate(String)

    /// 描述文件无效（无法解析、Bundle ID 不匹配等）
    case invalidProvisioningProfile(String)

    /// 代码签名过程失败（哈希计算错误、签名数据生成失败等）
    case signingFailed(String)

    /// Mach-O 二进制文件解析失败（不支持的格式、FAT header 异常等）
    case machOParseError(String)

    /// ZIP 压缩/解压失败
    case zipError(String)

    /// 指定的文件或目录不存在
    case fileNotFound(String)

    /// Entitlements 权限配置错误（XML 格式错误等）
    case entitlementError(String)

    /// Dylib 动态库注入失败（LC_LOAD_DYLIB 写入失败等）
    case injectionFailed(String)

    /// 用户主动取消操作
    case cancelled

    /// 提供给用户看的本地化错误描述
    var errorDescription: String? {
        switch self {
        case .invalidIPA(let msg): return "IPA 错误: \(msg)"
        case .invalidCertificate(let msg): return "证书错误: \(msg)"
        case .invalidProvisioningProfile(let msg): return "描述文件错误: \(msg)"
        case .signingFailed(let msg): return "签名失败: \(msg)"
        case .machOParseError(let msg): return "Mach-O 解析错误: \(msg)"
        case .zipError(let msg): return "压缩错误: \(msg)"
        case .fileNotFound(let msg): return "文件未找到: \(msg)"
        case .entitlementError(let msg): return "权限错误: \(msg)"
        case .injectionFailed(let msg): return "注入失败: \(msg)"
        case .cancelled: return "操作已取消"
        }
    }
}
