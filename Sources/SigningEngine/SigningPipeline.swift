import Foundation

/// 进度回调节流器（线程安全）
final class ProgressThrottle: @unchecked Sendable {
    private var lastTime: CFAbsoluteTime = 0
    private let interval: CFAbsoluteTime = 0.15

    func shouldUpdate() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastTime > interval else { return false }
        lastTime = now
        return true
    }
}

/// 签名流水线 —— 编排完整的 IPA 重签名流程
///
/// 将整个签名过程抽象为一条流水线，按序执行以下阶段：
/// 解压 → 预处理 → 签名 → 打包 → 清理
///
/// 使用方式：
/// ```swift
/// let pipeline = SigningPipeline(
///     ipaURL: inputIPA,
///     certificate: cert,
///     options: signingOptions,
///     delegate: self
/// )
/// let outputURL = try await pipeline.execute()
/// ```
///
/// 设计目标：
/// - 每个阶段可独立测试
/// - 支持取消操作（通过 Task cancellation）
/// - 实时报告进度和日志
/// - 失败时自动清理临时文件
actor SigningPipeline {

    // MARK: - 属性

    /// 输入的 IPA 文件路径
    private let ipaURL: URL

    /// 签名用的证书
    private let certificate: CertificateParser.P12Result

    /// 签名选项
    private let options: SigningOptions

    /// 描述文件数据（可选，如果不提供则不嵌入）
    private let provisionData: Data?

    /// 描述文件路径（可选）
    private let provisionURL: URL?

    /// 进度回调（stage, progress）
    private let onProgress: ((String, Double) -> Void)?

    /// 日志回调
    private let onLog: ((String) -> Void)?

    /// 进度更新节流
    private let throttle: ProgressThrottle = ProgressThrottle()

    /// 输出目录（默认为 Documents/YSign/Signed/）
    private let outputDirectory: URL

    // MARK: - 初始化

    /// 创建签名流水线
    ///
    /// - Parameters:
    ///   - ipaURL: 待签名的 IPA 文件路径
    ///   - certificate: 已解析的 P12 证书
    ///   - options: 签名选项（Bundle ID修改、注入等）
    ///   - provisionURL: 描述文件路径（可选）
    ///   - outputDirectory: IPA 输出目录
    ///   - onProgress: 进度回调 (阶段描述, 进度百分比 0~1)
    ///   - onLog: 日志回调
    init(
        ipaURL: URL,
        certificate: CertificateParser.P12Result,
        options: SigningOptions,
        provisionURL: URL? = nil,
        outputDirectory: URL? = nil,
        onProgress: ((String, Double) -> Void)? = nil,
        onLog: ((String) -> Void)? = nil
    ) {
        self.ipaURL = ipaURL
        self.certificate = certificate
        self.options = options
        self.provisionURL = provisionURL
        self.provisionData = nil
        self.onProgress = onProgress
        self.onLog = onLog

        // 默认输出到 Documents/YSign/Signed/
        if let dir = outputDirectory {
            self.outputDirectory = dir
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.outputDirectory = docs.appendingPathComponent("YSign/Signed")
        }
    }

    // MARK: - 执行签名

    /// 执行完整的签名流水线
    ///
    /// 这是主入口方法，按序执行所有签名阶段。
    /// 支持 Swift 的 Task cancellation（在任意阶段可取消）。
    ///
    /// - Returns: 签名后的 IPA 文件路径
    /// - Throws: SigningError（任何阶段失败都会抛出）
    func execute() async throws -> URL {
        let startTime = CFAbsoluteTimeGetCurrent()

        // ===== 阶段1：解压 IPA =====
        log("📦 开始解压 IPA...")
        reportProgress("解压中", 0.0)

        let extracted: IPAHandler.ExtractedIPA
        do {
            let progressCb = onProgress
            let t = throttle
            extracted = try await IPAHandler.extract(ipaURL: ipaURL) { progress in
                guard t.shouldUpdate() else { return }
                progressCb?("解压中", progress * 0.2)
            }
        } catch {
            throw error
        }

        // 检查取消
        try Task.checkCancellation()
        log("✓ 解压完成: \(extracted.appName)")

        // ===== FairPlay 加密检测（未砸壳直接拒绝）=====
        if !options.configOnly {
            let execURL = extracted.appURL.appendingPathComponent(extracted.executableName)
            if MachOParser.isFairPlayEncrypted(url: execURL) {
                log("❌ 检测到 FairPlay 加密（cryptid=1），该 IPA 未砸壳，无法签名")
                throw SigningError.signingFailed("检测到 FairPlay 加密（未砸壳），请使用已砸壳的 IPA")
            }
            log("✓ 无 FairPlay 加密")
        }

        // ===== 阶段2：预处理（修改 Bundle ID、移除插件等）=====
        log("🔧 预处理应用包...")
        reportProgress("预处理", 0.2)

        try await preprocess(extracted: extracted)

        try Task.checkCancellation()
        log("✓ 预处理完成")

        // ===== 阶段3：签名 =====
        if options.configOnly {
            log("⏭️ 仅修改配置，跳过签名")
            reportProgress("跳过签名", 0.8)
        } else {
            log("✍️ 开始代码签名...")
            reportProgress("签名中", 0.4)

            try await sign(extracted: extracted)

            try Task.checkCancellation()
            log("✓ 签名完成")
        }

        // 签名后移除 embedded.mobileprovision
        if options.removeEmbeddedProvision {
            try IPAHandler.removeEmbeddedProvision(appURL: extracted.appURL)
            log("  → 已移除 embedded.mobileprovision")
        }

        // ===== 阶段4：重新打包 =====
        log("📦 重新打包 IPA...")
        reportProgress("打包中", 0.8)

        let outputURL = try await repackage(extracted: extracted)
        log("✓ 打包完成")

        // ===== 阶段5：清理临时文件 =====
        IPAHandler.cleanup(extractedIPA: extracted)

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        log("🎉 全部完成! 耗时: \(String(format: "%.1f", elapsed))秒")
        log("📂 输出: \(outputURL.lastPathComponent)")
        reportProgress("完成", 1.0)

        return outputURL
    }

    // MARK: - 各阶段实现

    /// 阶段2：预处理
    /// 在签名之前修改应用包内容
    private func preprocess(extracted: IPAHandler.ExtractedIPA) async throws {
        let appURL = extracted.appURL

        // 修改 Bundle ID
        var finalBundleID = extracted.bundleID
        if let newBundleID = options.newBundleID, !newBundleID.isEmpty, newBundleID != extracted.bundleID {
            // App 多开：添加随机后缀
            let actualBundleID = options.enableAppMultiOpen
                ? "\(newBundleID).\(UUID().uuidString.prefix(8))"
                : newBundleID
            try IPAHandler.changeBundleID(appURL: appURL, newBundleID: actualBundleID)
            finalBundleID = actualBundleID
            log("  → Bundle ID 修改为: \(actualBundleID)")
        } else if options.enableAppMultiOpen {
            let actualBundleID = "\(extracted.bundleID).\(UUID().uuidString.prefix(8))"
            try IPAHandler.changeBundleID(appURL: appURL, newBundleID: actualBundleID)
            finalBundleID = actualBundleID
            log("  → App 多开 Bundle ID: \(actualBundleID)")
        }

        // 修改显示名称
        if let newName = options.newDisplayName, !newName.isEmpty, newName != extracted.appName {
            try IPAHandler.changeDisplayName(appURL: appURL, newName: newName)
            log("  → 显示名称修改为: \(newName)")
        }

        // 修改版本号
        if let newVersion = options.newVersion, !newVersion.isEmpty {
            try IPAHandler.changeVersion(appURL: appURL, newVersion: newVersion)
            log("  → 版本号修改为: \(newVersion)")
        }

        // 修改最低 iOS 版本
        if let minVer = options.newMinimumOSVersion, !minVer.isEmpty {
            try IPAHandler.changeMinimumOSVersion(appURL: appURL, newVersion: minVer)
            log("  → 最低 iOS 版本修改为: \(minVer)")
        }

        // 移除设备限制
        if options.removeDeviceLimit {
            try IPAHandler.removeDeviceLimit(appURL: appURL)
            log("  → 已移除设备限制")
        }

        // 移除 URL Schemes
        if options.removeURLSchemes {
            try IPAHandler.removeURLSchemes(appURL: appURL)
            log("  → 已移除 URL Schemes")
        }

        // 开启文件访问
        if options.enableFileAccess {
            try IPAHandler.enableFileAccess(appURL: appURL)
            log("  → 已开启文件访问")
        }

        // 替换图标
        if let iconData = options.customIconData {
            try IPAHandler.replaceIcon(appURL: appURL, iconData: iconData)
            log("  → 已替换应用图标")
        }

        // 移除 PlugIns
        if options.removePlugins {
            try IPAHandler.removePlugIns(appURL: appURL)
            log("  → 已移除 PlugIns 目录")
        }

        // 移除 Watch App
        if options.removeWatchApp {
            try IPAHandler.removeWatchApp(appURL: appURL)
            log("  → 已移除 Watch 目录")
        }

        // 移除用户选中的已有库（在整个 .app 内递归查找，覆盖 Frameworks/PlugIns/Watch/嵌套）
        if !options.frameworksToRemove.isEmpty {
            let fm = FileManager.default
            for name in options.frameworksToRemove {
                if let url = findItem(named: name, in: appURL) {
                    try fm.removeItem(at: url)
                    log("  → 已移除库: \(name) (\(url.path.replacingOccurrences(of: appURL.path + "/", with: "")))")
                } else {
                    log("  ⚠️ 未找到库: \(name)")
                }
            }
        }

        // 注入动态库（使用用户选择的路径和目录）
        if !options.injectDylibs.isEmpty {
            let loadPaths = try IPAHandler.copyDylibsToSubdir(
                appURL: appURL,
                dylibURLs: options.injectDylibs,
                subDirectory: options.dylibSubDirectory,
                loadPathPrefix: options.dylibLoadPathPrefix
            )
            let execURL = appURL.appendingPathComponent(extracted.executableName)
            try DylibInjector.injectMultiple(binaryURL: execURL, dylibs: loadPaths)
            log("  → 已注入 \(loadPaths.count) 个动态库")
        }

        // 嵌入描述文件
        if let provURL = provisionURL {
            try IPAHandler.embedProvision(appURL: appURL, provisionURL: provURL)
            log("  → 已嵌入描述文件")
        }

        // 清理签名残留（SC_Info / embedded.provisionprofile，避免 installd 错误码 61）
        IPAHandler.cleanupResiduals(appURL: appURL)
        log("  → 已清理签名残留 (SC_Info/embedded.provisionprofile)")

        // 清除旧签名
        try IPAHandler.removeOldSignature(appURL: appURL)
        log("  → 已清除旧签名")
    }

    /// 阶段3：代码签名
    /// 使用证书对所有二进制文件签名
    private func sign(extracted: IPAHandler.ExtractedIPA) async throws {
        let bundleID = options.newBundleID ?? extracted.bundleID

        // 构建 entitlements 数据
        var entitlementsData: Data?
        if let customEnt = options.customEntitlements {
            entitlementsData = customEnt.data(using: .utf8)
        }
        // TODO: 如果没有自定义 entitlements，可以从描述文件中提取

        // 创建签名器并执行签名
        let progressCb = onProgress
        let logCb = onLog
        let t = throttle
        let signer = CodeSigner(
            certificate: certificate,
            progressHandler: { progress in
                guard t.shouldUpdate() else { return }
                progressCb?("签名中", 0.4 + progress * 0.4)
            },
            logHandler: { msg in
                logCb?(msg)
            }
        )

        try await signer.signApp(
            appURL: extracted.appURL,
            entitlements: entitlementsData,
            bundleID: bundleID
        )
    }

    /// 阶段4：重新打包为 IPA
    private func repackage(extracted: IPAHandler.ExtractedIPA) async throws -> URL {
        // 使用自定义文件名或默认 原名_signed.ipa
        let fileName: String
        if let custom = options.outputFileName, !custom.isEmpty {
            fileName = custom.hasSuffix(".ipa") ? custom : "\(custom).ipa"
        } else {
            let originalName = ipaURL.deletingPathExtension().lastPathComponent
            fileName = "\(originalName)_signed.ipa"
        }
        let outputURL = outputDirectory.appendingPathComponent(fileName)

        let repackProgressCb = onProgress
        let t2 = throttle
        try await IPAHandler.repackage(
            extractedIPA: extracted,
            outputURL: outputURL
        ) { progress in
            guard t2.shouldUpdate() else { return }
            repackProgressCb?("打包中", 0.8 + progress * 0.2)
        }

        return outputURL
    }

    // MARK: - 辅助方法

    /// 输出日志
    private func log(_ message: String) {
        onLog?(message)
    }

    /// 在 app bundle 内递归查找指定名称的文件/目录
    private func findItem(named name: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == name {
                return url
            }
        }
        return nil
    }

    /// 报告进度
    private func reportProgress(_ stage: String, _ value: Double) {
        onProgress?(stage, value)
    }
}
