import Foundation
import UIKit

/// IPA 资源库管理器
///
/// 管理用户导入的 IPA 文件集合。提供导入、扫描、删除等操作。
/// IPA 文件统一存储在 Documents/YSign/Library/ 目录下。
///
/// 存储结构：
/// Documents/YSign/Library/
/// ├── {uuid}.ipa          ← IPA 原始文件
/// └── library.json        ← 元数据索引
actor IPALibraryManager {

    /// 资源库存储目录
    private let libraryDirectory: URL

    /// 元数据索引文件路径
    private let indexFile: URL

    // MARK: - 初始化

    init() {
        self.libraryDirectory = YSInternalStorage.directory("Library")
        self.indexFile = libraryDirectory.appendingPathComponent("library.json")
    }

    // MARK: - 公开方法

    /// 扫描资源库，返回所有已导入的 IPA 文件信息
    ///
    /// - Returns: IPA 文件信息数组，按导入时间倒序排列
    func scanLibrary() -> [IPAFile] {
        guard FileManager.default.fileExists(atPath: indexFile.path),
              let data = try? Data(contentsOf: indexFile),
              let items = try? JSONDecoder().decode([IPAFileMetadata].self, from: data) else {
            return []
        }

        // 将持久化元数据转换为 IPAFile 模型
        return items.compactMap { meta in
            let fileURL = libraryDirectory.appendingPathComponent("\(meta.id.uuidString).ipa")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

            // 读取图标（如果缓存存在）
            let iconURL = libraryDirectory.appendingPathComponent("\(meta.id.uuidString).png")
            let icon = UIImage(contentsOfFile: iconURL.path)

            return IPAFile(
                id: meta.id,
                name: meta.name,
                bundleID: meta.bundleID,
                version: meta.version,
                buildNumber: meta.buildNumber,
                minimumOSVersion: meta.minimumOSVersion,
                fileSize: meta.fileSize,
                icon: icon,
                fileURL: fileURL,
                importDate: meta.importDate
            )
        }.sorted { $0.importDate > $1.importDate } // 最近导入的排在前面
    }

    /// 导入 IPA 文件到资源库
    ///
    /// 流程：
    /// 1. 拷贝 IPA 到资源库目录
    /// 2. 快速解析 IPA 获取元数据（不完全解压）
    /// 3. 提取图标缓存
    /// 4. 更新索引文件
    ///
    /// - Parameter sourceURL: IPA 源文件路径
    /// - Returns: 导入后的 IPAFile 信息
    /// - Throws: SigningError.invalidIPA
    func importIPA(from sourceURL: URL) throws -> IPAFile {
        let fileID = UUID()

        // 拷贝 IPA 到资源库
        let destURL = libraryDirectory.appendingPathComponent("\(fileID.uuidString).ipa")
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        // 获取文件大小
        let attributes = try FileManager.default.attributesOfItem(atPath: destURL.path)
        let fileSize = (attributes[.size] as? Int64) ?? 0

        // 快速读取 IPA 元信息（不完全解压，只提取 Info.plist）
        let info = try IPAHandler.quickInfo(ipaURL: destURL)

        // 缓存图标
        var icon: UIImage?
        if let iconData = info.icon {
            icon = UIImage(data: iconData)
            let iconURL = libraryDirectory.appendingPathComponent("\(fileID.uuidString).png")
            try? iconData.write(to: iconURL)
        }

        // 创建元数据
        let metadata = IPAFileMetadata(
            id: fileID,
            name: info.name,
            bundleID: info.bundleID,
            version: info.version,
            buildNumber: "",
            minimumOSVersion: "",
            fileSize: fileSize,
            importDate: Date()
        )

        // 更新索引
        var items = loadIndex()
        items.append(metadata)
        try saveIndex(items)

        return IPAFile(
            id: fileID,
            name: info.name,
            bundleID: info.bundleID,
            version: info.version,
            buildNumber: "",
            minimumOSVersion: "",
            fileSize: fileSize,
            icon: icon,
            fileURL: destURL,
            importDate: Date()
        )
    }

    /// 从资源库中删除指定的 IPA 文件
    ///
    /// - Parameter id: IPA 文件的 UUID
    func delete(id: UUID) throws {
        // 删除 IPA 文件
        let ipaURL = libraryDirectory.appendingPathComponent("\(id.uuidString).ipa")
        try? FileManager.default.removeItem(at: ipaURL)

        // 删除图标缓存
        let iconURL = libraryDirectory.appendingPathComponent("\(id.uuidString).png")
        try? FileManager.default.removeItem(at: iconURL)

        // 更新索引
        var items = loadIndex()
        items.removeAll { $0.id == id }
        try saveIndex(items)
    }

    /// 获取指定 IPA 的文件路径（用于传递给签名流水线）
    ///
    /// - Parameter id: IPA 文件的 UUID
    /// - Returns: 文件 URL
    func getFileURL(for id: UUID) -> URL {
        return libraryDirectory.appendingPathComponent("\(id.uuidString).ipa")
    }

    // MARK: - 私有方法

    /// 从索引文件加载元数据
    private func loadIndex() -> [IPAFileMetadata] {
        guard let data = try? Data(contentsOf: indexFile),
              let items = try? JSONDecoder().decode([IPAFileMetadata].self, from: data) else {
            return []
        }
        return items
    }

    /// 保存元数据到索引文件
    private func saveIndex(_ items: [IPAFileMetadata]) throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: indexFile)
    }
}

// MARK: - 持久化元数据（不含 UIImage，可 Codable）

/// IPA 文件的可序列化元数据
/// 用于 JSON 索引文件的持久化存储
private struct IPAFileMetadata: Codable {
    let id: UUID
    let name: String
    let bundleID: String
    let version: String
    let buildNumber: String
    let minimumOSVersion: String
    let fileSize: Int64
    let importDate: Date
}
