import Foundation
import ZIPFoundation

/// 证书批量导入服务
///
/// 支持从文件或文件夹批量导入证书：
/// - 文件：P12 / PFX / 描述文件（mobileprovision）/ ZIP 压缩包
/// - 文件夹：递归扫描其中的 P12、描述文件与 ZIP（ZIP 解压后同理，支持嵌套压缩包）
///
/// P12 默认使用密码 "1" 尝试导入，失败的文件由调用方弹出密码框让用户重试。
/// 描述文件按「文件名同名 > Team ID 匹配 > 导入顺序」与证书自动配对。
struct CertificateImportService {

    /// 默认尝试的证书密码
    static let defaultPassword = "1"

    /// 单个 P12 的导入结果（保留来源文件名用于描述文件同名配对）
    struct ImportedP12 {
        let cert: CertificateInfo
        let sourceStem: String
    }

    /// 临时解压根目录
    private var tempRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("YSignCertImport", isDirectory: true)
    }

    // MARK: - 收集

    /// 收集文件 / 文件夹（含 ZIP 解压）中的所有 P12 与描述文件
    func collect(from url: URL) -> (p12s: [URL], profiles: [URL]) {
        let fm = FileManager.default
        let staging = tempRoot.appendingPathComponent("Staging-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var p12s: [URL] = []
        var profiles: [URL] = []
        scan(url: url, depth: 0, staging: staging, p12s: &p12s, profiles: &profiles)
        return (p12s, profiles)
    }

    /// 清理临时解压目录
    func cleanup() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func scan(url: URL, depth: Int, staging: URL, p12s: inout [URL], profiles: inout [URL]) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }

        if isDir.boolValue {
            guard depth < 8,
                  let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                scan(url: child, depth: depth + 1, staging: staging, p12s: &p12s, profiles: &profiles)
            }
            return
        }

        switch url.pathExtension.lowercased() {
        case "p12", "pfx":
            if let local = stage(url, in: staging) { p12s.append(local) }
        case "mobileprovision", "mp":
            if let local = stage(url, in: staging) { profiles.append(local) }
        case "zip":
            guard depth < 8, let local = stage(url, in: staging), let dest = unzip(local) else { return }
            scan(url: dest, depth: depth + 1, staging: staging, p12s: &p12s, profiles: &profiles)
        default:
            break
        }
    }

    /// 复制文件到暂存目录（脱离外部文件的安全作用域），同名文件自动加序号
    private func stage(_ url: URL, in staging: URL) -> URL? {
        let fm = FileManager.default
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var dest = staging.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = staging.appendingPathComponent(ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
            n += 1
        }
        do {
            try fm.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// 解压 ZIP 到临时目录
    private func unzip(_ url: URL) -> URL? {
        let dest = tempRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: url, to: dest)
            return dest
        } catch {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
    }

    // MARK: - 导入 P12

    /// 用指定密码导入一批 P12
    ///
    /// - Returns: 成功导入的证书（含来源文件名）、密码错误等待重试的文件、错误明细
    func importP12s(_ urls: [URL], password: String) async -> (imported: [ImportedP12], failed: [URL], errors: [String]) {
        let store = CertificateStore()
        var imported: [ImportedP12] = []
        var failed: [URL] = []
        var errors: [String] = []

        for url in urls {
            do {
                let cert = try await store.importP12(from: url, password: password)
                imported.append(ImportedP12(
                    cert: cert,
                    sourceStem: url.deletingPathExtension().lastPathComponent
                ))
            } catch {
                failed.append(url)
                errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return (imported, failed, errors)
    }

    // MARK: - 导入描述文件

    /// 将描述文件与证书自动配对导入
    ///
    /// 配对顺序：文件名同名 > Team ID 匹配 > 未配对的第一个证书 > 已有证书库的最后一个。
    func importProfiles(_ urls: [URL], imported: [ImportedP12]) async -> (linked: [String], errors: [String]) {
        let store = CertificateStore()
        var linked: [String] = []
        var errors: [String] = []

        // 兜底候选：已有证书库（纯描述文件导入、无本次新证书时）
        var existing = await store.loadAll()

        for url in urls {
            do {
                let mp = try MobileProvision.parse(from: url)
                let stem = url.deletingPathExtension().lastPathComponent

                // 1. 与本次导入的 P12 同名前缀
                var target = imported.first { $0.sourceStem == stem }?.cert
                // 2. Team ID 匹配
                if target == nil, !mp.teamID.isEmpty {
                    target = imported.first { $0.cert.teamID == mp.teamID }?.cert
                        ?? existing.first { $0.teamID == mp.teamID }
                }
                // 3. 本次导入的第一个证书
                if target == nil {
                    target = imported.first?.cert
                }
                // 4. 兜底：证书库最后一个（沿用原有行为）
                if target == nil {
                    target = existing.last
                }

                guard let certID = target?.id else {
                    errors.append("\(url.lastPathComponent)：请先导入 P12 证书")
                    continue
                }

                let updated = try await store.linkProfile(certID: certID, profileURL: url)
                linked.append("\(updated.profileName ?? "") → \(updated.name)")

                // 更新兜底列表，避免重复配对
                if let idx = existing.firstIndex(where: { $0.id == certID }) {
                    existing[idx] = updated
                }
            } catch {
                errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return (linked, errors)
    }
}
