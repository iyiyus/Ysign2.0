import Foundation
import UIKit

/// IPA 文件模型
/// 代表一个已导入到本地资源库中的 IPA 安装包，包含从 Info.plist 解析出的元数据
struct IPAFile: Identifiable, Hashable {

    /// 唯一标识符，用于列表渲染和持久化存储
    let id: UUID

    /// 应用显示名称（从 CFBundleDisplayName 或 CFBundleName 读取）
    let name: String

    /// 应用 Bundle Identifier（如 com.example.app）
    let bundleID: String

    /// 应用版本号（CFBundleShortVersionString，如 1.0.0）
    let version: String

    /// 应用构建号（CFBundleVersion，如 100）
    let buildNumber: String

    /// 最低支持的 iOS 系统版本（MinimumOSVersion）
    let minimumOSVersion: String

    /// IPA 文件大小（字节）
    let fileSize: Int64

    /// 应用图标（从 IPA 中提取的最大尺寸图标）
    let icon: UIImage?

    /// IPA 文件在本地磁盘的路径
    let fileURL: URL

    /// 导入到资源库的时间，用于排序
    let importDate: Date

    /// 格式化后的文件大小字符串（如 "12.3 MB"）
    var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    // MARK: - Hashable 实现（仅基于 id 判等，避免 UIImage 无法 hash 的问题）

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: IPAFile, rhs: IPAFile) -> Bool {
        lhs.id == rhs.id
    }
}
