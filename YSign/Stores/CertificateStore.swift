import Foundation

/// 证书存储管理器
///
/// 负责证书（P12 + 描述文件配对）的持久化存储、加载和删除操作。
/// 数据保存在应用沙盒的 Documents/YSign/Certificates/ 目录下。
///
/// 存储结构：
/// Documents/YSign/Certificates/
/// ├── {uuid}.p12                ← P12 原始文件
/// ├── {uuid}.mobileprovision   ← 关联的描述文件
/// └── certificates.json        ← 证书元数据索引
actor CertificateStore {

    /// 证书存储目录
    private let storeDirectory: URL

    /// 元数据索引文件路径
    private let indexFile: URL

    // MARK: - 初始化

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.storeDirectory = docs.appendingPathComponent("YSign/Certificates")
        self.indexFile = storeDirectory.appendingPathComponent("certificates.json")

        // 确保目录存在
        try? FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 公开方法

    /// 加载所有已保存的证书
    func loadAll() -> [CertificateInfo] {
        guard FileManager.default.fileExists(atPath: indexFile.path),
              let data = try? Data(contentsOf: indexFile),
              let certs = try? JSONDecoder().decode([CertificateInfo].self, from: data) else {
            return []
        }
        return certs
    }

    /// 导入一个 P12 证书文件
    @discardableResult
    func importP12(from p12URL: URL, password: String) throws -> CertificateInfo {
        let p12Data = try Data(contentsOf: p12URL)
        let result = try CertificateParser.parseP12(data: p12Data, password: password)

        let certID = UUID()
        let destURL = storeDirectory.appendingPathComponent("\(certID.uuidString).p12")
        try p12Data.write(to: destURL)

        let certInfo = CertificateInfo(
            id: certID,
            name: result.commonName,
            teamName: result.organizationName,
            organizationalUnit: result.teamID,
            teamID: result.teamID,
            serialNumber: result.serialNumber,
            expirationDate: result.notAfter,
            creationDate: result.notBefore,
            p12Data: p12Data,
            password: password
        )

        var certs = loadAll()
        certs.append(certInfo)
        try saveIndex(certs)

        return certInfo
    }

    /// 为指定证书关联描述文件
    @discardableResult
    func linkProfile(certID: UUID, profileURL: URL) throws -> CertificateInfo {
        let profileData = try Data(contentsOf: profileURL)
        let profile = try MobileProvision.parse(from: profileData, fileURL: profileURL)

        // 保存描述文件
        let fileName = "\(certID.uuidString).mobileprovision"
        let destURL = storeDirectory.appendingPathComponent(fileName)
        try profileData.write(to: destURL)

        // 更新索引
        var certs = loadAll()
        guard let idx = certs.firstIndex(where: { $0.id == certID }) else {
            throw SigningError.invalidProvisioningProfile("找不到对应的证书")
        }

        certs[idx].profileName = profile.name
        certs[idx].profileBundleID = profile.bundleIdentifier
        certs[idx].profileType = profile.profileType.rawValue
        certs[idx].profileExpirationDate = profile.expirationDate
        certs[idx].provisionedDevices = profile.provisionedDevices
        certs[idx].entitlementKeys = Array(profile.entitlements.keys).sorted()
        certs[idx].profileFileName = fileName

        try saveIndex(certs)
        return certs[idx]
    }

    /// 移除证书关联的描述文件
    func unlinkProfile(certID: UUID) throws {
        var certs = loadAll()
        guard let idx = certs.firstIndex(where: { $0.id == certID }) else { return }

        // 删除描述文件
        if let fileName = certs[idx].profileFileName {
            let fileURL = storeDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }

        certs[idx].profileName = nil
        certs[idx].profileBundleID = nil
        certs[idx].profileType = nil
        certs[idx].profileExpirationDate = nil
        certs[idx].provisionedDevices = nil
        certs[idx].entitlementKeys = nil
        certs[idx].profileFileName = nil

        try saveIndex(certs)
    }

    /// 删除指定的证书（同时删除关联的描述文件）
    func delete(id: UUID) throws {
        var certs = loadAll()
        if let cert = certs.first(where: { $0.id == id }) {
            // 删除描述文件
            if let fileName = cert.profileFileName {
                let profileURL = storeDirectory.appendingPathComponent(fileName)
                try? FileManager.default.removeItem(at: profileURL)
            }
        }
        certs.removeAll { $0.id == id }

        // 删除 P12 文件
        let p12URL = storeDirectory.appendingPathComponent("\(id.uuidString).p12")
        try? FileManager.default.removeItem(at: p12URL)

        try saveIndex(certs)
    }

    /// 获取指定证书的 P12 解析结果（用于签名）
    func getSigningIdentity(for cert: CertificateInfo) throws -> CertificateParser.P12Result {
        return try CertificateParser.parseP12(data: cert.p12Data, password: cert.password)
    }

    /// 获取指定证书关联的描述文件原始数据（签名时嵌入 .app）
    func getProfileData(for cert: CertificateInfo) throws -> Data {
        guard let fileName = cert.profileFileName else {
            throw SigningError.invalidProvisioningProfile("未导入描述文件")
        }
        let fileURL = storeDirectory.appendingPathComponent(fileName)
        return try Data(contentsOf: fileURL)
    }

    // MARK: - 私有方法

    private func saveIndex(_ certs: [CertificateInfo]) throws {
        let data = try JSONEncoder().encode(certs)
        try data.write(to: indexFile)
    }
}
