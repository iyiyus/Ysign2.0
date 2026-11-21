import Foundation
import ZIPFoundation

/// IPA 处理器 —— 负责 IPA 文件的解压、修改和重新打包
///
/// IPA 文件本质上是一个 ZIP 压缩包，内部结构为：
/// ```
/// Payload/
/// └── AppName.app/
///     ├── Info.plist
///     ├── AppName (可执行文件)
///     ├── embedded.mobileprovision
///     ├── _CodeSignature/
///     │   └── CodeResources
///     ├── Frameworks/
///     │   ├── SomeFramework.framework/
///     │   └── injected.dylib
///     └── ... (其他资源文件)
/// ```
///
/// 性能优化策略：
/// - 使用流式解压，避免一次性加载整个 IPA 到内存
/// - 并行解压多个文件
/// - 重新打包时使用无压缩模式加速（对于已压缩的资源如图片）
struct IPAHandler {

    // MARK: - 签名前置校验与残留清理

    /// 检测 IPA 主程序是否带 FairPlay 加密（未砸壳）
    ///
    /// 流程：解压到临时目录 → 检查主二进制 cryptid → 清理临时目录
    ///
    /// - Parameter ipaURL: IPA 文件路径
    /// - Returns: 是否加密（解析失败时返回 false，不阻塞签名流程）
    static func isFairPlayProtected(ipaURL: URL) async -> Bool {
        guard let extracted = try? await extract(ipaURL: ipaURL) else { return false }
        defer { cleanup(extractedIPA: extracted) }
        let execURL = extracted.appURL.appendingPathComponent(extracted.executableName)
        return MachOParser.isFairPlayEncrypted(url: execURL)
    }

    /// 清理签名残留文件（避免 installd 校验错误码 61）
    ///
    /// - SC_Info/ — FairPlay 加密解密密钥目录，残留会导致 sinf 校验失败
    /// - embedded.provisionprofile — 旧的开发环境描述文件
    static func cleanupResiduals(appURL: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: appURL.appendingPathComponent("SC_Info"))
        try? fm.removeItem(at: appURL.appendingPathComponent("embedded.provisionprofile"))
    }

    /// 从 IPA 中提取主程序的原包 entitlements
    ///
    /// 流程：解压到临时目录 → 解析主二进制的代码签名 SuperBlob → 清理临时目录
    ///
    /// - Parameter ipaURL: IPA 文件路径
    /// - Returns: entitlements XML 字符串（无签名时返回 nil）
    static func extractEntitlementsFromIPA(ipaURL: URL) async throws -> String? {
        let extracted = try await extract(ipaURL: ipaURL)
        defer { cleanup(extractedIPA: extracted) }
        let execURL = extracted.appURL.appendingPathComponent(extracted.executableName)
        return try MachOParser.extractEntitlements(url: execURL)
    }

    // MARK: - IPA 操作结果

    /// 解压后的 IPA 信息
    struct ExtractedIPA {
        /// 解压后的临时目录路径
        let workDirectory: URL
        /// .app 目录路径（Payload/xxx.app）
        let appURL: URL
        /// 应用名称
        let appName: String
        /// Info.plist 内容
        let infoPlist: [String: Any]
        /// 原始 Bundle ID
        let bundleID: String
        /// 原始可执行文件名
        let executableName: String
    }

    // MARK: - 解压

    /// 解压 IPA 文件到临时目录
    ///
    /// 流程：
    /// 1. 创建唯一的临时工作目录
    /// 2. 解压 ZIP 内容
    /// 3. 定位 Payload 下的 .app 目录
    /// 4. 解析 Info.plist 获取应用元数据
    ///
    /// - Parameters:
    ///   - ipaURL: IPA 文件路径
    ///   - progressHandler: 解压进度回调
    /// - Returns: 解压后的 IPA 信息
    /// - Throws: SigningError.invalidIPA / SigningError.zipError
    static func extract(
        ipaURL: URL,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> ExtractedIPA {
        // 创建唯一的临时工作目录
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("YSign_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 解压 IPA（ZIP 格式）到工作目录
        do {
            try FileManager.default.unzipItem(at: ipaURL, to: workDir)
        } catch {
            throw SigningError.zipError("解压 IPA 失败: \(error.localizedDescription)")
        }

        // 定位 Payload 目录
        let payloadDir = workDir.appendingPathComponent("Payload")
        guard FileManager.default.fileExists(atPath: payloadDir.path) else {
            throw SigningError.invalidIPA("IPA 中找不到 Payload 目录")
        }

        // 查找 .app 目录
        let contents = try FileManager.default.contentsOfDirectory(
            at: payloadDir, includingPropertiesForKeys: nil
        )
        guard let appDir = contents.first(where: { $0.pathExtension == "app" }) else {
            throw SigningError.invalidIPA("Payload 中找不到 .app 目录")
        }

        // 解析 Info.plist
        let infoPlistURL = appDir.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: infoPlistURL.path) else {
            throw SigningError.invalidIPA(".app 中找不到 Info.plist")
        }

        let plistData = try Data(contentsOf: infoPlistURL)
        guard let plist = try PropertyListSerialization.propertyList(
            from: plistData, format: nil
        ) as? [String: Any] else {
            throw SigningError.invalidIPA("Info.plist 格式错误")
        }

        // 提取基本信息
        let bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        let execName = plist["CFBundleExecutable"] as? String ?? ""
        let appName = plist["CFBundleDisplayName"] as? String
            ?? plist["CFBundleName"] as? String
            ?? appDir.deletingPathExtension().lastPathComponent

        guard !execName.isEmpty else {
            throw SigningError.invalidIPA("Info.plist 中缺少 CFBundleExecutable")
        }

        return ExtractedIPA(
            workDirectory: workDir,
            appURL: appDir,
            appName: appName,
            infoPlist: plist,
            bundleID: bundleID,
            executableName: execName
        )
    }

    // MARK: - 重新打包

    /// 将修改后的 .app 重新打包为 IPA
    ///
    /// - Parameters:
    ///   - extractedIPA: 解压后的 IPA 信息（包含工作目录）
    ///   - outputURL: 输出 IPA 的文件路径
    ///   - progressHandler: 打包进度回调
    /// - Throws: SigningError.zipError
    static func repackage(
        extractedIPA: ExtractedIPA,
        outputURL: URL,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        // 确保输出目录存在
        let outputDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // 如果输出文件已存在则删除
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // 将工作目录压缩为 ZIP（即 IPA）
        do {
            try FileManager.default.zipItem(
                at: extractedIPA.workDirectory,
                to: outputURL,
                shouldKeepParent: false
            )
        } catch {
            throw SigningError.zipError("重新打包 IPA 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - .app 包修改操作

    /// 修改应用的 Bundle ID
    ///
    /// 修改 Info.plist 中的 CFBundleIdentifier 字段。
    /// 注意：如果应用包含扩展（PlugIns），也需要相应修改扩展的 Bundle ID。
    ///
    /// - Parameters:
    ///   - appURL: .app 目录路径
    ///   - newBundleID: 新的 Bundle ID
    static func changeBundleID(appURL: URL, newBundleID: String) throws {
        let infoPlistURL = appURL.appendingPathComponent("Info.plist")
        var plist = try readPlist(from: infoPlistURL)

        // 修改主应用的 Bundle ID
        plist["CFBundleIdentifier"] = newBundleID
        try writePlist(plist, to: infoPlistURL)
    }

    /// 修改应用的显示名称
    ///
    /// - Parameters:
    ///   - appURL: .app 目录路径
    ///   - newName: 新的显示名称
    static func changeDisplayName(appURL: URL, newName: String) throws {
        let infoPlistURL = appURL.appendingPathComponent("Info.plist")
        var plist = try readPlist(from: infoPlistURL)

        plist["CFBundleDisplayName"] = newName
        plist["CFBundleName"] = newName
        try writePlist(plist, to: infoPlistURL)
    }

    /// 嵌入描述文件（embedded.mobileprovision）
    ///
    /// 将 .mobileprovision 文件复制到 .app 目录下并命名为 embedded.mobileprovision。
    /// 这是 iOS 签名的必要步骤。
    ///
    /// - Parameters:
    ///   - appURL: .app 目录路径
    ///   - provisionURL: 描述文件路径
    static func embedProvision(appURL: URL, provisionURL: URL) throws {
        let destURL = appURL.appendingPathComponent("embedded.mobileprovision")

        // 如果已存在则先删除
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }

        try FileManager.default.copyItem(at: provisionURL, to: destURL)
    }

    /// 移除应用中的 PlugIns 目录（通知扩展、键盘扩展等）
    ///
    /// 重签名时通常需要移除扩展，因为扩展需要单独的描述文件和 Bundle ID。
    /// 如果不移除，签名后应用可能无法安装或运行。
    ///
    /// - Parameter appURL: .app 目录路径
    static func removePlugIns(appURL: URL) throws {
        let plugInsDir = appURL.appendingPathComponent("PlugIns")
        if FileManager.default.fileExists(atPath: plugInsDir.path) {
            try FileManager.default.removeItem(at: plugInsDir)
        }
    }

    /// 移除 Watch App 目录
    ///
    /// - Parameter appURL: .app 目录路径
    static func removeWatchApp(appURL: URL) throws {
        let watchDir = appURL.appendingPathComponent("Watch")
        if FileManager.default.fileExists(atPath: watchDir.path) {
            try FileManager.default.removeItem(at: watchDir)
        }
    }

    /// 移除旧的代码签名目录
    /// 在重新签名之前需要清除旧签名，否则新签名会与旧签名冲突
    ///
    /// - Parameter appURL: .app 目录路径
    static func removeOldSignature(appURL: URL) throws {
        let codeSignDir = appURL.appendingPathComponent("_CodeSignature")
        if FileManager.default.fileExists(atPath: codeSignDir.path) {
            try FileManager.default.removeItem(at: codeSignDir)
        }
    }

    /// 拷贝 dylib 文件到应用的 Frameworks 目录
    /// 注入 dylib 前需要先将文件拷贝到应用包内
    ///
    /// - Parameters:
    ///   - appURL: .app 目录路径
    ///   - dylibURLs: dylib 文件路径列表
    /// - Returns: 注入后的相对路径列表（用于 LC_LOAD_DYLIB）
    @discardableResult
    static func copyDylibs(appURL: URL, dylibURLs: [URL]) throws -> [String] {
        let frameworksDir = appURL.appendingPathComponent("Frameworks")
        try FileManager.default.createDirectory(at: frameworksDir, withIntermediateDirectories: true)

        var loadPaths: [String] = []

        for dylibURL in dylibURLs {
            let fileName = dylibURL.lastPathComponent
            let destURL = frameworksDir.appendingPathComponent(fileName)

            // 如果已存在则覆盖
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: dylibURL, to: destURL)

            // 生成加载路径（相对于可执行文件）
            loadPaths.append("@executable_path/Frameworks/\(fileName)")
        }

        return loadPaths
    }

    /// 修改应用的版本号
    static func changeVersion(appURL: URL, newVersion: String) throws {
        let infoPlistURL = appURL.appendingPathComponent("Info.plist")
        var plist = try readPlist(from: infoPlistURL)
        plist["CFBundleShortVersionString"] = newVersion
        plist["CFBundleVersion"] = newVersion
        try writePlist(plist, to: infoPlistURL)
    }

    /// 修改最低 iOS 系统版本
    static func changeMinimumOSVersion(appURL: URL, newVersion: String) throws {
        let infoPlistURL = appURL.appendingPathComponent("Info.plist")
        var plist = try readPlist(from: infoPlistURL)
        plist["MinimumOSVersion"] = newVersion
        try writePlist(plist, to: infoPlistURL)
    }

    /// 移除设备限制（UISupportedDevices）
    static func removeDeviceLimit(appURL: URL) throws {
        let infoPlistURL = appURL.appendingPathComponent("Info.plist")
        var plist = try readPlist(from: infoPlistURL)
        plist.removeValue(forKey: "UISupportedDevices")
        try writePlist(plist, to: infoPlistURL)
    }

    /// 移除 URL Schemes（防止应用跳转）
    static func removeURLSchemes(appURL: URL) throws {
        let infoPlistURL = appURL.appendingPathComponent("Info.plist")
        var plist = try readPlist(from: infoPlistURL)
        plist.removeValue(forKey: "CFBundleURLTypes")
        try writePlist(plist, to: infoPlistURL)
    }

    /// 开启文件访问（iTunes 文件共享 + 文件 App 访问）
    static func enableFileAccess(appURL: URL) throws {
        let infoPlistURL = appURL.appendingPathComponent("Info.plist")
        var plist = try readPlist(from: infoPlistURL)
        plist["UIFileSharingEnabled"] = true
        plist["LSSupportsOpeningDocumentsInPlace"] = true
        try writePlist(plist, to: infoPlistURL)
    }

    /// 替换应用图标
    static func replaceIcon(appURL: URL, iconData: Data) throws {
        let infoPlistURL = appURL.appendingPathComponent("Info.plist")
        let plist = try readPlist(from: infoPlistURL)

        // 收集所有图标文件名
        var iconFileNames: [String] = []

        let icons = plist["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        if let names = primary?["CFBundleIconFiles"] as? [String] {
            iconFileNames.append(contentsOf: names)
        }

        let iPadIcons = plist["CFBundleIcons~ipad"] as? [String: Any]
        let iPadPrimary = iPadIcons?["CFBundlePrimaryIcon"] as? [String: Any]
        if let names = iPadPrimary?["CFBundleIconFiles"] as? [String] {
            iconFileNames.append(contentsOf: names)
        }

        // 回退通用名称
        if iconFileNames.isEmpty {
            iconFileNames = ["AppIcon60x60", "AppIcon76x76", "AppIcon"]
        }

        // 遍历 .app 目录，替换所有匹配的图标文件
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: appURL, includingPropertiesForKeys: nil)
        for fileURL in contents {
            let name = fileURL.deletingPathExtension().lastPathComponent
            // 去掉 @2x/@3x 后缀匹配
            let baseName = name.replacingOccurrences(of: "@2x", with: "")
                               .replacingOccurrences(of: "@3x", with: "")
                               .replacingOccurrences(of: "~ipad", with: "")
            if iconFileNames.contains(baseName) && fileURL.pathExtension == "png" {
                try iconData.write(to: fileURL)
            }
        }
    }

    /// 移除 embedded.mobileprovision
    static func removeEmbeddedProvision(appURL: URL) throws {
        let provURL = appURL.appendingPathComponent("embedded.mobileprovision")
        if FileManager.default.fileExists(atPath: provURL.path) {
            try FileManager.default.removeItem(at: provURL)
        }
    }

    /// 列出 .app/Frameworks 目录中的所有动态库
    static func listFrameworks(appURL: URL) -> [URL] {
        let frameworksDir = appURL.appendingPathComponent("Frameworks")
        guard FileManager.default.fileExists(atPath: frameworksDir.path) else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: frameworksDir, includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter {
            $0.pathExtension == "dylib" || $0.pathExtension == "framework"
        }
    }

    /// 移除指定的已有动态库
    static func removeFrameworks(appURL: URL, frameworkURLs: [URL]) throws {
        for url in frameworkURLs {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// 拷贝 dylib 到指定子目录（支持自定义目录）
    @discardableResult
    static func copyDylibsToSubdir(appURL: URL, dylibURLs: [URL], subDirectory: String, loadPathPrefix: String) throws -> [String] {
        let targetDir: URL
        if subDirectory == "/" {
            targetDir = appURL
        } else {
            targetDir = appURL.appendingPathComponent(subDirectory)
        }
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        var loadPaths: [String] = []
        for dylibURL in dylibURLs {
            let fileName = dylibURL.lastPathComponent
            let destURL = targetDir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: dylibURL, to: destURL)

            let path: String
            if subDirectory == "/" {
                path = "\(loadPathPrefix)/\(fileName)"
            } else {
                path = "\(loadPathPrefix)/\(subDirectory)\(fileName)"
            }
            loadPaths.append(path)
        }
        return loadPaths
    }

    /// 从 IPA（ZIP）中列出 .app/Frameworks 下的动态库和框架名称（不解压）
    static func listFrameworksInIPA(ipaURL: URL) -> [String] {
        guard let archive = Archive(url: ipaURL, accessMode: .read) else { return [] }
        var names = Set<String>()
        for entry in archive {
            let path = entry.path
            // 任意 .app 包内的 .dylib / .framework（含 Frameworks/、PlugIns/、Watch/、嵌套）
            guard path.contains(".app/") else { continue }
            let fileName = String(path.split(separator: "/").last ?? "")
            if fileName.hasSuffix(".dylib") {
                names.insert(fileName)
            } else if fileName.hasSuffix(".framework") {
                names.insert(fileName)
            }
        }
        return names.sorted()
    }

    // MARK: - IPA 信息提取（不解压）

    /// 快速读取 IPA 信息（不完全解压）
    /// 只从 ZIP 中提取 Info.plist 和图标，用于库列表展示
    ///
    /// - Parameter ipaURL: IPA 文件路径
    /// - Returns: 应用的基本元数据
    static func quickInfo(ipaURL: URL) throws -> (name: String, bundleID: String, version: String, buildNumber: String, icon: Data?) {
        guard let archive = Archive(url: ipaURL, accessMode: .read) else {
            throw SigningError.invalidIPA("无法打开 IPA 文件")
        }

        // 在 ZIP 中查找 Info.plist
        var infoPlistData: Data?
        for entry in archive {
            if entry.path.hasSuffix(".app/Info.plist") && entry.path.hasPrefix("Payload/") {
                var data = Data()
                _ = try archive.extract(entry) { chunk in
                    data.append(chunk)
                }
                infoPlistData = data
                break
            }
        }

        guard let plistData = infoPlistData,
              let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw SigningError.invalidIPA("无法读取 IPA 中的 Info.plist")
        }

        let name = plist["CFBundleDisplayName"] as? String
            ?? plist["CFBundleName"] as? String ?? "Unknown"
        let bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        let version = plist["CFBundleShortVersionString"] as? String ?? ""
        let buildNumber = plist["CFBundleVersion"] as? String ?? ""

        // 尝试提取图标（可选）
        var iconData: Data?

        // 收集所有可能的图标名称
        var iconNames: [String] = []
        let iconFiles = (plist["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        if let names = iconFiles?["CFBundleIconFiles"] as? [String] {
            iconNames.append(contentsOf: names)
        }
        // iPad 图标
        let iPadIcons = (plist["CFBundleIcons~ipad"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        if let names = iPadIcons?["CFBundleIconFiles"] as? [String] {
            iconNames.append(contentsOf: names)
        }
        // 通用回退名称
        iconNames.append(contentsOf: ["AppIcon60x60", "AppIcon76x76", "AppIcon"])

        // 找到 .app 目录前缀
        let appPrefix = archive.first { $0.path.hasSuffix(".app/Info.plist") }?
            .path.replacingOccurrences(of: "Info.plist", with: "") ?? "Payload/"

        // 按优先级从大到小搜索（@3x > @2x > 无后缀）
        let suffixes = ["@3x.png", "@2x.png", ".png", "@3x~ipad.png", "@2x~ipad.png"]
        outer: for iconName in iconNames.reversed() {
            for suffix in suffixes {
                let targetPath = appPrefix + iconName + suffix
                for entry in archive {
                    if entry.path == targetPath || entry.path.hasSuffix("/" + iconName + suffix) {
                        var data = Data()
                        _ = try? archive.extract(entry) { chunk in
                            data.append(chunk)
                        }
                        if !data.isEmpty {
                            iconData = data
                            break outer
                        }
                    }
                }
            }
        }

        // 最后兜底：模糊匹配任何包含 AppIcon 的 png
        if iconData == nil {
            var bestEntry: Entry?
            var bestSize: UInt64 = 0
            for entry in archive {
                let p = entry.path.lowercased()
                if p.contains("appicon") && p.hasSuffix(".png") && !p.contains("contents.json") {
                    if entry.uncompressedSize > bestSize {
                        bestSize = entry.uncompressedSize
                        bestEntry = entry
                    }
                }
            }
            if let entry = bestEntry {
                var data = Data()
                _ = try? archive.extract(entry) { chunk in data.append(chunk) }
                if !data.isEmpty { iconData = data }
            }
        }

        return (name: name, bundleID: bundleID, version: version, buildNumber: buildNumber, icon: iconData)
    }

    // MARK: - 清理

    /// 清理临时工作目录
    /// 签名完成后调用，释放磁盘空间
    ///
    /// - Parameter extractedIPA: 解压后的 IPA 信息
    static func cleanup(extractedIPA: ExtractedIPA) {
        try? FileManager.default.removeItem(at: extractedIPA.workDirectory)
    }

    // MARK: - 私有辅助方法

    /// 读取 plist 文件并返回字典
    private static func readPlist(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, format: nil
        ) as? [String: Any] else {
            throw SigningError.invalidIPA("无法解析 plist: \(url.lastPathComponent)")
        }
        return plist
    }

    /// 将字典写入 plist 文件
    private static func writePlist(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }
}
