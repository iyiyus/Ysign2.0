import Foundation
import ZIPFoundation
import CryptoKit

/// 本地备份/还原服务
///
/// 对齐 LCSign 的本地备份还原能力：
/// - 备份内容三组可选：配置 / 工作区 / 文件
/// - **始终排除敏感数据**：证书库（P12）、描述文件、设备 UDID
/// - 导出为 .ysignbackup（ZIP），内层 payload 整体 **AES-GCM 加密**，
///   manifest 记录 SHA256 摘要做**完整性校验**
/// - 可选导出密码（不设密码时使用内置派生密钥，仍加密可校验）
/// - 还原时校验格式版本与内容分组（只接受支持的配置项），合并还原，
///   冲突时跳过已存在文件；危险路径（zip slip）拦截
struct BackupService {

    /// 备份包含的内容类型
    struct Contents: OptionSet {
        let rawValue: Int
        static let configuration = Contents(rawValue: 1 << 0)   // 配置：应用偏好、签名默认、安装与文件服务设置
        static let workspace = Contents(rawValue: 1 << 1)       // 工作区：IPA 库、签名产物、软件源数据
        static let files = Contents(rawValue: 1 << 2)           // 文件：下载文件、文件页自建目录

        static let all: Contents = [.configuration, .workspace, .files]

        /// 备份内记录用的分组名
        var names: [String] {
            var result: [String] = []
            if contains(.configuration) { result.append("Configuration") }
            if contains(.workspace) { result.append("Workspace") }
            if contains(.files) { result.append("Files") }
            return result
        }

        /// 按分组名解析（还原时校验，只接受支持的分组）
        static func from(names: [String]) -> Contents? {
            let map: [String: Contents] = [
                "Configuration": .configuration,
                "Workspace": .workspace,
                "Files": .files,
            ]
            guard !names.isEmpty else { return nil }
            var result: Contents = []
            for name in names {
                guard let flag = map[name] else { return nil }   // 未知分组 → 拒绝
                result.insert(flag)
            }
            return result
        }
    }

    /// 备份清单（写入 backup_manifest.json）
    struct Manifest: Codable {
        let formatVersion: Int
        let appVersion: String
        let createdDate: Date
        let contents: [String]
        /// 明文 payload 的 SHA256（完整性校验）
        let payloadSHA256: String
        /// 是否使用了导出密码
        let requiresPassword: Bool
        /// 密钥派生盐（hex）
        let salt: String
    }

    /// 备份错误
    enum BackupError: LocalizedError {
        case emptySelection
        case invalid(String)
        case unsupportedFormat
        case unsupportedContent
        case passwordRequired
        case incorrectPassword
        case integrityFailed

        var errorDescription: String? {
            switch self {
            case .emptySelection:
                return "请至少选择一项备份内容"
            case .invalid(let reason):
                return "不是有效的 YSign 备份：\(reason)"
            case .unsupportedFormat:
                return "备份格式不受支持（版本过旧或过新）"
            case .unsupportedContent:
                return "备份包含不受支持的内容分组，无法还原"
            case .passwordRequired:
                return "该备份使用了导出密码，请输入密码"
            case .incorrectPassword:
                return "导出密码错误，无法解密备份"
            case .integrityFailed:
                return "备份完整性校验失败，文件可能已损坏"
            }
        }
    }

    /// 备份文件扩展名
    static let backupExtension = "ysignbackup"

    /// 当前备份格式版本
    private static let formatVersion = 2
    /// 未设密码时的默认密钥种子（混淆式加密 + 完整性校验）
    private static let defaultKeySeed = "YSign.Backup.Payload.v2"

    private static let manifestFileName = "backup_manifest.json"
    private static let payloadFileName = "payload.enc"
    private static let innerZipName = "payload.zip"
    private static let settingsFileName = "settings.json"

    /// 导出的偏好设置键（白名单；还原时只接受这些键，排除 UDID/证书等敏感数据）
    private static let settingsKeys = [
        "appearanceMode", "defaultNamePrefix", "defaultNameSuffix",
        "defaultRemovePlugins", "defaultRemoveWatch", "defaultChangeMinVersion",
        "defaultRemoveDeviceLimit", "defaultRemoveAppJump", "defaultEnableFileAccess",
        "defaultFixWhiteIcon", "defaultAutoFixJailbreak", "defaultConfigOnly",
        "defaultRemoveEmbeddedProvision", "defaultInstallAfterSign",
        "defaultDylibLoadPath", "defaultDylibDirectory", "defaultCompressionLevel",
        "defaultFileNameUseName", "defaultFileNameUseVersion", "defaultFileNameUseBundleID",
        "defaultFileNameUseCert", "defaultFileNameUseTimestamp", "trollStoreEnable",
        "ipaInstallServers", "ipaInstallMode", "downloadTaskIDMap",
        "backupIncludeConfig", "backupIncludeWorkspace", "backupIncludeFiles",
    ]

    /// 目录备份映射：(内容分组, 源相对路径, 备份内路径)
    /// 证书库（Certificates）与描述文件（Profiles）永不备份
    private static let directoryMap: [(Contents, String, String)] = [
        (.workspace, "YSign/Library", "Workspace/Library"),
        (.workspace, "YSign/Signed", "Workspace/Signed"),
        (.workspace, "YSign/Sources", "Workspace/Sources"),
        (.files, "YSign/Downloads", "Files/Downloads"),
        (.files, "Files", "Files/UserFiles"),
    ]

    /// 还原目标映射（备份内路径 → 恢复目标相对路径），与 directoryMap 对应
    private static let restoreMap: [(String, String)] = [
        ("Workspace/Library", "YSign/Library"),
        ("Workspace/Signed", "YSign/Signed"),
        ("Workspace/Sources", "YSign/Sources"),
        ("Files/Downloads", "YSign/Downloads"),
        ("Files/UserFiles", "Files"),
    ]

    // MARK: - 导出

    /// 创建备份并导出到指定 URL
    ///
    /// - Parameters:
    ///   - destination: 备份输出路径（.ysignbackup）
    ///   - contents: 包含的内容分组
    ///   - password: 可选导出密码（空则使用内置派生密钥）
    ///   - progress: 进度回调 (0~1)
    static func exportBackup(
        to destination: URL,
        contents: Contents,
        password: String = "",
        progress: ((Double) -> Void)? = nil
    ) throws {
        guard !contents.isEmpty else { throw BackupError.emptySelection }

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!

        let staging = fm.temporaryDirectory.appendingPathComponent("YSBackup_\(UUID().uuidString)")
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }

        // 1. 组装内层目录（明文）
        let innerDir = staging.appendingPathComponent("PayloadFiles")
        try fm.createDirectory(at: innerDir, withIntermediateDirectories: true)

        for (flag, relPath, backupPath) in directoryMap where contents.contains(flag) {
            let src = docs.appendingPathComponent(relPath)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = innerDir.appendingPathComponent(backupPath)
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            try copyDirectoryContents(from: src, to: dst)
        }

        // 2. 偏好设置（白名单键）
        if contents.contains(.configuration) {
            var settings: [String: Any] = [:]
            for key in settingsKeys {
                if let value = UserDefaults.standard.object(forKey: key),
                   let safe = jsonSafe(value) {
                    settings[key] = safe
                }
            }
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
            try data.write(to: innerDir.appendingPathComponent(settingsFileName))
        }

        // 3. 打包内层 ZIP
        let innerZip = staging.appendingPathComponent(innerZipName)
        try createZip(at: innerZip, from: innerDir)
        let innerData = try Data(contentsOf: innerZip)

        // 4. 加密（AES-GCM，自带认证标签 = 完整性校验）
        let salt = randomHex(byteCount: 16)
        let key = deriveKey(password: password, saltHex: salt)
        guard let sealed = try? AES.GCM.seal(innerData, using: key),
              let combined = sealed.combined else {
            throw BackupError.invalid("加密失败")
        }

        // 5. manifest（明文 payload 摘要 + 加密信息）
        let manifest = Manifest(
            formatVersion: formatVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0",
            createdDate: Date(),
            contents: contents.names,
            payloadSHA256: sha256Hex(innerData),
            requiresPassword: !password.isEmpty,
            salt: salt
        )
        let manifestData = try JSONEncoder().encode(manifest)

        // 6. 外层 ZIP：manifest + payload.enc
        let outerDir = staging.appendingPathComponent("Bundle")
        try fm.createDirectory(at: outerDir, withIntermediateDirectories: true)
        try manifestData.write(to: outerDir.appendingPathComponent(manifestFileName))
        try combined.write(to: outerDir.appendingPathComponent(payloadFileName))

        try? fm.removeItem(at: destination)
        try createZip(at: destination, from: outerDir)
        progress?(1.0)
    }

    // MARK: - 还原

    /// 还原结果
    struct RestoreResult {
        let restoredFiles: Int
        let skippedFiles: Int
        let restoredSettings: Int
        let manifest: Manifest?
    }

    /// 从备份还原
    ///
    /// - Parameters:
    ///   - backupURL: 备份文件路径
    ///   - password: 导出密码（备份未设密码时传空）
    ///   - merge: true 合并还原（已存在的文件跳过）；false 覆盖
    static func restoreBackup(
        from backupURL: URL,
        password: String = "",
        merge: Bool = true,
        progress: ((Double) -> Void)? = nil
    ) throws -> RestoreResult {
        let fm = FileManager.default

        let staging = fm.temporaryDirectory.appendingPathComponent("YSRestore_\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        do {
            try fm.unzipItem(at: backupURL, to: staging)
        } catch {
            throw BackupError.invalid("文件无法解压")
        }

        // 1. 校验 manifest
        let manifestURL = staging.appendingPathComponent(manifestFileName)
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw BackupError.invalid("缺少备份清单")
        }
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
            throw BackupError.unsupportedFormat
        }
        guard manifest.formatVersion == formatVersion else {
            throw BackupError.unsupportedFormat
        }
        // 只接受支持的内容分组
        guard Contents.from(names: manifest.contents) != nil else {
            throw BackupError.unsupportedContent
        }

        // 2. 解密 payload（AES-GCM 认证失败 → 密码错误）
        let payloadURL = staging.appendingPathComponent(payloadFileName)
        guard let payload = try? Data(contentsOf: payloadURL) else {
            throw BackupError.invalid("缺少备份数据")
        }
        let key = deriveKey(password: password, saltHex: manifest.salt)
        guard let sealed = try? AES.GCM.SealedBox(combined: payload),
              let innerData = try? AES.GCM.open(sealed, using: key) else {
            if password.isEmpty && manifest.requiresPassword {
                throw BackupError.passwordRequired
            }
            throw BackupError.incorrectPassword
        }

        // 3. 完整性校验（SHA256）
        guard sha256Hex(innerData) == manifest.payloadSHA256 else {
            throw BackupError.integrityFailed
        }

        // 4. 解压内层
        let innerZip = staging.appendingPathComponent(innerZipName)
        try innerData.write(to: innerZip)
        let innerDir = staging.appendingPathComponent("PayloadFiles")
        try fm.unzipItem(at: innerZip, to: innerDir)

        // 5. 还原目录（白名单路径，防 zip slip）
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        var restored = 0
        var skipped = 0

        for (backupPath, targetRel) in restoreMap {
            let src = innerDir.appendingPathComponent(backupPath)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dest = docs.appendingPathComponent(targetRel)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)

            let enumerator = fm.enumerator(at: src, includingPropertiesForKeys: nil)
            while let item = enumerator?.nextObject() as? URL {
                guard !item.hasDirectoryPath else { continue }
                let relative = item.path.replacingOccurrences(of: src.path + "/", with: "")
                guard !relative.contains("..") else { continue }   // zip slip 拦截
                let target = dest.appendingPathComponent(relative)

                if fm.fileExists(atPath: target.path) && merge {
                    skipped += 1
                    continue
                }
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: item, to: target)
                restored += 1
            }
        }

        // 6. 还原偏好设置（只接受白名单键）
        var settingsRestored = 0
        let settingsURL = innerDir.appendingPathComponent(settingsFileName)
        if fm.fileExists(atPath: settingsURL.path),
           let data = try? Data(contentsOf: settingsURL),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in settingsKeys {
                if let value = settings[key], let restored = restoreValue(value) {
                    UserDefaults.standard.set(restored, forKey: key)
                    settingsRestored += 1
                }
            }
        }

        progress?(1.0)
        return RestoreResult(
            restoredFiles: restored,
            skippedFiles: skipped,
            restoredSettings: settingsRestored,
            manifest: manifest
        )
    }

    // MARK: - 辅助

    /// 设置值转 JSON 兼容类型（UserDefaults 里可能存 Data，
    /// JSONSerialization 不支持 Data 会直接抛 ObjC 异常导致进程 abort）
    private static func jsonSafe(_ value: Any) -> Any? {
        if let data = value as? Data {
            return ["__ysign_data_base64": data.base64EncodedString()]
        }
        if value is String || value is NSNumber || value is Bool {
            return value
        }
        if let array = value as? [Any] {
            return array.compactMap { jsonSafe($0) }
        }
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, item) in dict {
                if let safe = jsonSafe(item) { result[key] = safe }
            }
            return result
        }
        if let date = value as? Date {
            return date.timeIntervalSince1970
        }
        return nil
    }

    /// 还原设置值：把 base64 标记还原成 Data
    private static func restoreValue(_ value: Any) -> Any? {
        if let dict = value as? [String: Any],
           let base64 = dict["__ysign_data_base64"] as? String,
           let data = Data(base64Encoded: base64) {
            return data
        }
        return value
    }

    /// 递归复制目录内容
    private static func copyDirectoryContents(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: src, includingPropertiesForKeys: nil) else { return }
        while let item = enumerator.nextObject() as? URL {
            guard !item.hasDirectoryPath else { continue }
            let relative = item.path.replacingOccurrences(of: src.path + "/", with: "")
            guard !relative.contains("..") else { continue }
            let target = dst.appendingPathComponent(relative)
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: item, to: target)
        }
    }

    /// 手动创建 ZIP（逐文件 addEntry，路径完全可控）
    private static func createZip(at destination: URL, from directory: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        let archive = try Archive(url: destination, accessMode: .create)
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            let relative = item.path.replacingOccurrences(of: directory.path + "/", with: "")
            try archive.addEntry(with: relative, fileURL: item, compressionMethod: .deflate)
        }
    }

    /// 密钥派生：设置了密码用密码，否则用内置种子（配合随机盐）
    private static func deriveKey(password: String, saltHex: String) -> SymmetricKey {
        let material = (password.isEmpty ? defaultKeySeed : password) + "." + saltHex
        return SymmetricKey(data: SHA256.hash(data: Data(material.utf8)))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
