import Foundation

/// 存储空间深度分析
///
/// 扫描应用容器（Documents / Library / tmp / App Group）中的所有文件，
/// 按用途分类并统计占用，供「存储空间」页面展示与选择性清理。
///
/// 安全约束：
/// - 证书库（YSign/Certificates）与描述文件（YSign/Profiles）完全不参与扫描与清理
/// - 软件源订阅列表（sources.json）属于用户配置，不可清理
/// - 高风险分类（IPA 库、下载文件、偏好设置等）默认不勾选
struct StorageAnalyzer {

    // MARK: - 数据模型

    /// 单个文件条目
    struct StorageFile: Identifiable, Hashable {
        var id: String { url.path }
        let url: URL
        let name: String
        let detail: String
        let size: Int64
    }

    /// 清理风险等级
    enum Risk {
        case safe        // 缓存/临时，可安全清理
        case reacquirable // 可重新获取
        case risky       // 用户数据 / 配置，删除有风险
    }

    /// 清理分类
    struct StorageCategory: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let risk: Risk
        var files: [StorageFile]

        var size: Int64 { files.reduce(0) { $0 + $1.size } }

        var badge: String? {
            switch risk {
            case .reacquirable: return "可重新获取"
            case .risky: return "高风险"
            case .safe: return nil
            }
        }
    }

    /// 位置分布（容器维度）
    struct StorageLocation: Identifiable {
        var id: String { name }
        let name: String
        let size: Int64
    }

    /// 分析报告
    struct StorageReport {
        /// 按占用从大到小排序的分类（已过滤空分类）
        var categories: [StorageCategory]
        var locations: [StorageLocation]
        var totalSize: Int64

        /// 默认勾选的分类（缓存与临时文件）
        static let defaultCategoryID = "cacheTemp"

        func selectedSize(_ selection: Set<String>) -> Int64 {
            categories.reduce(0) { total, category in
                total + category.files
                    .filter { selection.contains($0.id) }
                    .reduce(0) { $0 + $1.size }
            }
        }
    }

    /// 分类定义（顺序即不稳定时的兜底顺序，最终按占用排序）
    private struct CategoryDef {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let risk: Risk
    }

    private static let definitions: [CategoryDef] = [
        CategoryDef(id: "sources", title: "软件源数据", subtitle: "源应用缓存与图标缓存", icon: "globe", risk: .reacquirable),
        CategoryDef(id: "cacheTemp", title: "缓存与临时文件", subtitle: "系统缓存、签名与安装过程的临时数据", icon: "clock.arrow.circlepath", risk: .safe),
        CategoryDef(id: "signed", title: "签名产物", subtitle: "已签名输出的 IPA 文件", icon: "signature", risk: .risky),
        CategoryDef(id: "library", title: "IPA 库", subtitle: "导入的原始 IPA 与图标缓存", icon: "square.stack.3d.up", risk: .risky),
        CategoryDef(id: "userFiles", title: "下载与文件", subtitle: "下载管理器文件与文件页自建目录", icon: "folder", risk: .risky),
        CategoryDef(id: "preferences", title: "偏好与状态数据", subtitle: "应用偏好设置与系统状态", icon: "gearshape", risk: .risky),
        CategoryDef(id: "appGroup", title: "App Group 数据", subtitle: "共享容器中的文件", icon: "square.grid.2x2", risk: .risky),
        CategoryDef(id: "other", title: "其它本软件数据", subtitle: "未归类的散落文件", icon: "doc.text", risk: .risky),
    ]

    /// 位置名称
    private enum LocationKind: String {
        case documents = "Documents"
        case library = "Library"
        case temporary = "临时目录"
        case appGroup = "App Group"
    }

    /// App Group ID（与 YSign.entitlements 一致）
    private static let appGroupID = "group.com.ysign.app"

    // MARK: - 分析

    /// 深度分析报告（建议在后台线程调用）
    static func analyze() -> StorageReport {
        let fm = FileManager.default
        let home = fm.urls(for: .documentDirectory, in: .userDomainMask).first!.deletingLastPathComponent()
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let library = home.appendingPathComponent("Library")
        let temporary = fm.temporaryDirectory
        let appGroup = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)

        var categories: [String: StorageCategory] = [:]
        for def in definitions {
            categories[def.id] = StorageCategory(
                id: def.id, title: def.title, subtitle: def.subtitle,
                icon: def.icon, risk: def.risk, files: []
            )
        }

        var locationSizes: [LocationKind: Int64] = [:]

        let roots: [(LocationKind, URL?)] = [
            (.documents, documents),
            (.library, library),
            (.temporary, temporary),
            (.appGroup, appGroup),
        ]

        for (kind, rootOrNil) in roots {
            guard let root = rootOrNil else { continue }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                guard values?.isDirectory != true else { continue }
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")

                // 敏感数据与用户配置：不参与扫描、不可清理
                if kind == .documents {
                    if relative.hasPrefix("YSign/Certificates/") ||
                        relative.hasPrefix("YSign/Profiles/") ||
                        relative == "YSign/Sources/sources.json" { continue }
                }

                let size = Int64(values?.fileSize ?? 0)
                locationSizes[kind, default: 0] += size

                let categoryID = classify(kind: kind, relative: relative)
                let file = StorageFile(
                    url: url,
                    name: url.lastPathComponent,
                    detail: relative,
                    size: size
                )
                categories[categoryID]?.files.append(file)
            }
        }

        let ordered = definitions.compactMap { categories[$0.id] }
            .filter { !$0.files.isEmpty }
            .map { category -> StorageCategory in
                var c = category
                c.files.sort { $0.size > $1.size }   // 展开后大文件在前
                return c
            }
            .sorted { $0.size > $1.size }             // 分类按占用从大到小

        let kinds: [LocationKind] = [.documents, .library, .temporary, .appGroup]
        let locations: [StorageLocation] = kinds.compactMap { kind in
            guard let size = locationSizes[kind], size > 0 else { return nil }
            return StorageLocation(name: kind.rawValue, size: size)
        }

        return StorageReport(
            categories: ordered,
            locations: locations,
            totalSize: ordered.reduce(0) { $0 + $1.size }
        )
    }

    /// 只统计总占用（设置页列表用）
    static func totalSize() -> Int64 {
        analyze().totalSize
    }

    /// 清理选中的文件，返回实际释放的字节数
    ///
    /// 只删除文件、保留目录结构；删除失败的文件跳过。
    static func cleanup(selection: Set<String>, in report: StorageReport) -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        for category in report.categories {
            for file in category.files where selection.contains(file.id) {
                let size = file.size
                do {
                    try fm.removeItem(at: file.url)
                    freed += size
                } catch {
                    // 正在使用或系统占用的文件跳过
                }
            }
        }
        return freed
    }

    // MARK: - 分类规则

    private static func classify(kind: LocationKind, relative: String) -> String {
        switch kind {
        case .documents:
            if relative.hasPrefix("YSign/Sources/") { return "sources" }
            if relative.hasPrefix("YSign/Signed/") { return "signed" }
            if relative.hasPrefix("YSign/Library/") { return "library" }
            if relative.hasPrefix("YSign/Downloads/") || relative.hasPrefix("Files/") { return "userFiles" }
            return "other"
        case .library:
            if relative.hasPrefix("Caches/") { return "cacheTemp" }
            if relative.hasPrefix("Preferences/") { return "preferences" }
            return "other"
        case .temporary:
            return "cacheTemp"
        case .appGroup:
            return "appGroup"
        }
    }
}

// MARK: - 格式化

extension Int64 {
    /// 存储空间展示用字节数格式（如 23.2 MB）
    var storageSizeString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
