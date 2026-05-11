import Foundation

/// 描述文件存储管理器
///
/// 负责描述文件(.mobileprovision)的导入、加载和删除。
/// 存储在 Documents/YSign/Profiles/ 目录下。
///
/// 存储结构：
/// Documents/YSign/Profiles/
/// └── {uuid}.mobileprovision   ← 描述文件原始数据
actor ProvisioningProfileStore {

    /// 描述文件存储目录
    private let storeDirectory: URL

    // MARK: - 初始化

    init() {
        self.storeDirectory = YSInternalStorage.directory("Profiles")
    }

    // MARK: - 公开方法

    /// 加载所有已保存的描述文件
    func loadAll() -> [MobileProvision] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: storeDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var profiles: [MobileProvision] = []
        for file in files where file.pathExtension == "mobileprovision" {
            if let profile = try? MobileProvision.parse(from: file) {
                profiles.append(profile)
            }
        }

        // 按过期时间排序，未过期的在前
        return profiles.sorted { a, b in
            if a.isExpired != b.isExpired { return !a.isExpired }
            return a.expirationDate > b.expirationDate
        }
    }

    /// 导入描述文件
    ///
    /// - Parameter url: .mobileprovision 文件路径
    /// - Returns: 导入后的描述文件信息
    /// - Throws: SigningError.invalidProvisioningProfile
    @discardableResult
    func importProfile(from url: URL) throws -> MobileProvision {
        let data = try Data(contentsOf: url)

        // 验证描述文件是否有效
        let profile = try MobileProvision.parse(from: data, fileURL: url)

        // 用 UUID 作为文件名保存（和旧项目一致）
        let fileName = "\(profile.id.uuidString).mobileprovision"
        let destURL = storeDirectory.appendingPathComponent(fileName)
        try data.write(to: destURL)

        return profile
    }

    /// 删除指定的描述文件
    func delete(id: UUID) throws {
        // 遍历目录查找匹配的文件
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: storeDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "mobileprovision" {
                // 检查文件名是否匹配
                if file.deletingPathExtension().lastPathComponent == id.uuidString {
                    try fm.removeItem(at: file)
                    return
                }
                // 也检查解析后的 profile（如果文件名不是 UUID 格式）
                if let profile = try? MobileProvision.parse(from: file), profile.id == id {
                    try fm.removeItem(at: file)
                    return
                }
            }
        }
    }

    /// 获取指定描述文件的原始数据（签名时需要嵌入到 .app 中）
    func getProfileData(for profile: MobileProvision) throws -> Data {
        let fileName = "\(profile.id.uuidString).mobileprovision"
        let fileURL = storeDirectory.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try Data(contentsOf: fileURL)
        }

        // 尝试用 fileURL
        if FileManager.default.fileExists(atPath: profile.fileURL.path) {
            return try Data(contentsOf: profile.fileURL)
        }

        throw SigningError.invalidProvisioningProfile("描述文件数据未找到")
    }
}
