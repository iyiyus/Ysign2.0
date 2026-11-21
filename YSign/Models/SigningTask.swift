import Foundation

/// 签名任务模型
/// 代表一次完整的 IPA 重签名操作，包含输入参数、当前状态和日志记录
struct SigningTask: Identifiable {

    /// 任务唯一标识
    let id: UUID

    /// 待签名的 IPA 文件
    let ipaFile: IPAFile

    /// 用于签名的证书
    let certificate: CertificateInfo

    /// 签名选项（Bundle ID 修改、插件移除、dylib 注入等）
    let options: SigningOptions

    /// 当前任务状态
    var status: Status

    /// 签名进度（0.0 ~ 1.0），用于驱动进度条 UI
    var progress: Double

    /// 任务执行日志，按时间顺序记录每一步操作
    var logs: [LogEntry]

    /// 任务开始时间
    let startTime: Date

    /// 任务结束时间（完成或失败时设置）
    var endTime: Date?

    /// 签名后的 IPA 输出路径
    var outputURL: URL?

    /// 任务状态枚举，对应签名流水线的各个阶段
    enum Status: String {
        case queued = "等待中"        // 在队列中排队
        case extracting = "解压中"    // 正在解压 IPA
        case signing = "签名中"       // 正在对二进制和框架签名
        case packaging = "打包中"     // 正在重新打包为 IPA
        case installing = "安装中"    // 正在安装到设备
        case completed = "完成"       // 签名成功
        case failed = "失败"          // 签名失败

        /// 对应的 SF Symbol 图标名
        var icon: String {
            switch self {
            case .queued: return "clock"
            case .extracting: return "doc.zipper"
            case .signing: return "signature"
            case .packaging: return "shippingbox"
            case .installing: return "arrow.down.app"
            case .completed: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            }
        }
    }

    /// 单条日志记录
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date    // 日志产生的时间戳
        let message: String    // 日志内容
        let level: Level       // 日志等级

        /// 日志等级，用于 UI 中显示不同颜色
        enum Level {
            case info      // 普通信息（灰色）
            case warning   // 警告（黄色）
            case error     // 错误（红色）
            case success   // 成功（绿色）
        }
    }

    /// 计算任务耗时（秒），任务未完成时返回 nil
    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    /// 格式化的耗时字符串（如 "3.2秒"）
    var durationFormatted: String {
        guard let d = duration else { return "..." }
        return String(format: "%.1f秒", d)
    }
}

/// 签名选项配置
/// 控制签名过程中的各种行为，如修改 Bundle ID、移除插件、注入动态库等
struct SigningOptions: Hashable {

    // MARK: - 基本选项

    /// 新的 Bundle ID（为 nil 时保持原始值不变）
    var newBundleID: String?

    /// 新的应用显示名称（为 nil 时保持原始值不变）
    var newDisplayName: String?

    /// 新的版本号（为 nil 时保持原始值不变）
    var newVersion: String?

    /// 自定义输出文件名（为 nil 时使用默认 原名_signed.ipa）
    var outputFileName: String?

    // MARK: - 移除选项

    /// 是否移除应用内的 PlugIns 目录（通知扩展等），默认移除以避免签名问题
    var removePlugins: Bool = true

    /// 是否移除 Watch App 目录，默认移除
    var removeWatchApp: Bool = true

    /// 要从 .app/Frameworks 中移除的已有库名称列表
    var frameworksToRemove: [String] = []

    // MARK: - 动态库注入

    /// 需要注入的 dylib 文件列表
    var injectDylibs: [URL] = []

    /// dylib 加载路径前缀（@executable_path 或 @rpath）
    var dylibLoadPathPrefix: String = "@executable_path"

    /// dylib 在 .app 内的子目录（"Frameworks/" 或 "/"）
    var dylibSubDirectory: String = "Frameworks/"

    // MARK: - 签名选项

    /// 自定义 entitlements XML 字符串（为 nil 时从描述文件自动提取）
    var customEntitlements: String?

    /// 是否强制重签（忽略已有签名直接覆盖）
    var forceSign: Bool = false

    /// 仅修改配置不签名
    var configOnly: Bool = false

    /// 签名后移除 embedded.mobileprovision
    var removeEmbeddedProvision: Bool = false

    // MARK: - Info.plist 修改

    /// 修改最低 iOS 版本（为 nil 时不修改）
    var newMinimumOSVersion: String?

    /// 移除设备限制（UISupportedDevices）
    var removeDeviceLimit: Bool = false

    /// 移除 URL Schemes（应用跳转）
    var removeURLSchemes: Bool = false

    /// 开启文件访问（UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace）
    var enableFileAccess: Bool = false

    /// App 多开（给 Bundle ID 添加随机后缀）
    var enableAppMultiOpen: Bool = false

    // MARK: - 图标

    /// 自定义图标数据（PNG），为 nil 时不修改
    var customIconData: Data?

    // MARK: - 压缩

    /// 压缩级别
    var compressionLevel: CompressionLevel = .compatible

    enum CompressionLevel: String, CaseIterable, Hashable {
        case speed = "速度"
        case compatible = "兼容"
        case size = "大小"
    }

    // MARK: - 架构

    /// 精简到指定架构（为 nil 时保留所有架构）
    var thinArchitecture: Architecture?

    /// CPU 架构枚举
    enum Architecture: String, CaseIterable {
        case arm64
        case armv7
    }
}
