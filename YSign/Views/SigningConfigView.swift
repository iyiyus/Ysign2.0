import SwiftUI
import PhotosUI

/// 签名配置页面
///
/// 用户选择一个 IPA 后进入此页面，配置签名参数。
/// 默认显示基本设置，点击「更多设置」展开高级选项。
struct SigningConfigView: View {
    @EnvironmentObject var appState: AppState

    /// 当前选择的 IPA 文件
    let app: IPAFile

    /// 退出到应用页的回调
    var popToRoot: (() -> Void)?

    /// 跳转到签名进度页（由父视图通过 NavigationPath 推入，避免 iOS 16 多 destination 冲突 Bug）
    var pushToProgress: ((SigningState) -> Void)?

    // MARK: - 基本设置

    @State private var newDisplayName = ""
    @State private var newBundleID = ""
    @State private var newVersion = ""
    @State private var installAfterSign = false
    @State private var selectedCertificate: CertificateInfo?
    @State private var outputFileName = ""

    // MARK: - 高级设置

    @State private var showAdvanced = false

    /// 修改桌面图标
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var customIconData: Data?

    /// 修改启动图。
    ///
    /// 贴牌 YSign 时，启动图和桌面图标一样重要，
    /// 因此这里单独提供一个图片选择状态。
    @State private var selectedLaunchPhotoItem: PhotosPickerItem?
    @State private var customLaunchImageData: Data?

    /// 移除已有库
    @State private var ipaFrameworks: [String] = []
    @State private var selectedFrameworksToRemove: Set<String> = []
    @State private var showFrameworkPicker = false

    /// 动态库注入
    @State private var dylibLoadPath: DylibLoadPath = .executable
    @State private var dylibDirectory: DylibDirectory = .frameworks
    @State private var injectDylibs: [URL] = []
    @State private var showingDylibPicker = false

    /// 压缩级别
    @State private var compressionLevel: SigningOptions.CompressionLevel = .compatible

    /// 其他开关
    @State private var removeAllPlugins = false
    @State private var removeWatchApps = false
    @State private var changeMinVersion = true
    @State private var removeDeviceLimit = true
    @State private var removeAppJump = false
    @State private var enableFileAccess = false
    @State private var fixWhiteIcon = false
    @State private var autoFixJailbreak = false
    @State private var configOnly = false
    @State private var removeEmbeddedProvision = false
    @State private var enableAppMultiOpen = false

    /// App 多开弹窗
    @State private var showingMultiOpenAlert = false
    @State private var multiOpenStartNumber = "1"
    @State private var multiOpenCount = "1"

    // MARK: - 签名状态

    @StateObject private var signingState = SigningState()
    @State private var showingError = false

    // MARK: - 枚举

    enum DylibLoadPath: String, CaseIterable {
        case executable = "@executable"
        case rpath = "@rpath"
    }

    enum DylibDirectory: String, CaseIterable {
        case root = "/"
        case frameworks = "Frameworks/"
    }

    /// 是否看起来是 YSign 本体。
    ///
    /// 当前“贴牌配置嵌入”只对 YSign 这类会在运行时读取 `BrandConfig.json` 的 App 有意义，
    /// 所以这里通过名称和 Bundle ID 做一个轻量判断。
    private var isLikelyYSignTarget: Bool {
        app.bundleID.localizedCaseInsensitiveContains("ysign") ||
        app.name.localizedCaseInsensitiveContains("ysign")
    }

    // MARK: - Body

    var body: some View {
        Form {
            // 基本设置
            basicSection

            // 证书选择
            certificateSection

            // 打包文件名
            outputFileSection


            // 高级设置（展开后显示）
            if showAdvanced {
                iconSection
                launchImageSection
                removeLibsSection
                dylibInjectionSection
                compressionSection
                otherOptionsSection
            }

            // 按钮区域（始终在最下方）
            actionSection
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedCertificate = appState.certificates.first(where: { $0.hasProfile }) ?? appState.certificates.first

            // 读取默认前缀/后缀
            let prefix = UserDefaults.standard.string(forKey: "defaultNamePrefix") ?? ""
            let suffix = UserDefaults.standard.string(forKey: "defaultNameSuffix") ?? ""
            newDisplayName = prefix + app.name + suffix
            newBundleID = app.bundleID
            newVersion = app.version

            // 如果当前选择的是 YSign 本体，则优先把贴牌配置里的品牌名 / Bundle ID 预填进去。
            // 这样用户拿 YSign 原包来重打时，进入页面就已经是贴牌后的默认值。
            if isLikelyYSignTarget {
                if !appState.brandConfig.appName.isEmpty {
                    newDisplayName = appState.brandConfig.appName
                }
                if !appState.brandConfig.appBundleID.isEmpty {
                    newBundleID = appState.brandConfig.appBundleID
                }
            }

            // 读取默认开关
            removeAllPlugins = UserDefaults.standard.bool(forKey: "defaultRemovePlugins")
            removeWatchApps = UserDefaults.standard.bool(forKey: "defaultRemoveWatch")
            changeMinVersion = UserDefaults.standard.object(forKey: "defaultChangeMinVersion") != nil
                ? UserDefaults.standard.bool(forKey: "defaultChangeMinVersion") : true
            removeDeviceLimit = UserDefaults.standard.object(forKey: "defaultRemoveDeviceLimit") != nil
                ? UserDefaults.standard.bool(forKey: "defaultRemoveDeviceLimit") : true
            removeAppJump = UserDefaults.standard.bool(forKey: "defaultRemoveAppJump")
            enableFileAccess = UserDefaults.standard.bool(forKey: "defaultEnableFileAccess")
            fixWhiteIcon = UserDefaults.standard.bool(forKey: "defaultFixWhiteIcon")
            autoFixJailbreak = UserDefaults.standard.bool(forKey: "defaultAutoFixJailbreak")
            configOnly = UserDefaults.standard.bool(forKey: "defaultConfigOnly")
            removeEmbeddedProvision = UserDefaults.standard.bool(forKey: "defaultRemoveEmbeddedProvision")
            installAfterSign = UserDefaults.standard.bool(forKey: "defaultInstallAfterSign")

            // 读取默认注入路径
            let storedLoadPath = UserDefaults.standard.string(forKey: "defaultDylibLoadPath") ?? "@executable"
            dylibLoadPath = storedLoadPath == "@rpath" ? .rpath : .executable
            let storedDir = UserDefaults.standard.string(forKey: "defaultDylibDirectory") ?? "Frameworks/"
            dylibDirectory = storedDir == "/" ? .root : .frameworks

            // 读取默认压缩级别
            let storedCompression = UserDefaults.standard.string(forKey: "defaultCompressionLevel") ?? "兼容"
            compressionLevel = SigningOptions.CompressionLevel(rawValue: storedCompression) ?? .compatible

            // 生成打包文件名
            outputFileName = generateOutputFileName()
        }
        .alert("签名失败", isPresented: $showingError) {
            Button("确定") {}
        } message: {
            Text(signingState.errorMessage ?? "")
        }
        .alert("多开", isPresented: $showingMultiOpenAlert) {
            TextField("开始序号", text: $multiOpenStartNumber)
                .keyboardType(.numberPad)
            TextField("多开数量", text: $multiOpenCount)
                .keyboardType(.numberPad)
            Button("取消", role: .cancel) {
                enableAppMultiOpen = false
            }
            Button("确定") {
                enableAppMultiOpen = true
            }
        } message: {
            Text("请输入多开序号跟数量")
        }
        .sheet(isPresented: $showingDylibPicker) {
            InAppFilePicker(
                allowedExtensions: ["dylib", "framework", "deb"],
                title: "添加第三方库"
            ) { url in
                injectDylibs.append(url)
            }
        }
    }

    // MARK: - 高级：修改启动图

    private var launchImageSection: some View {
        Section(isLikelyYSignTarget ? "修改启动图（YSign贴牌）" : "修改启动图") {
            HStack {
                Text("启动图")
                Spacer()

                PhotosPicker(selection: $selectedLaunchPhotoItem, matching: .images) {
                    if let launchData = customLaunchImageData, let uiImage = UIImage(data: launchData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 70, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .frame(width: 70, height: 44)
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .onChange(of: selectedLaunchPhotoItem) { newItem in
                    Task {
                        if let data = try? await newItem?.loadTransferable(type: Data.self),
                           let uiImage = UIImage(data: data),
                           let pngData = uiImage.pngData() {
                            customLaunchImageData = pngData
                        }
                    }
                }
            }

            if isLikelyYSignTarget {
                Text("导出 YSign 贴牌包时，这张图片会写入 App 包，并替换 `UILaunchScreen` 使用的启动图。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if customLaunchImageData != nil {
                Button("恢复原始启动图", role: .destructive) {
                    customLaunchImageData = nil
                    selectedLaunchPhotoItem = nil
                }
                .font(.caption)
            }
        }
    }

    // MARK: - 基本设置区域

    private var basicSection: some View {
        Group {
            Section("App 名字") {
                TextField("App 名字", text: $newDisplayName)
            }

            Section("Bundle Identifier") {
                TextField("Bundle Identifier", text: $newBundleID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("版本号") {
                TextField("版本号", text: $newVersion)
                    .textInputAutocapitalization(.never)
            }

            Section("签名后立即安装") {
                Toggle("签名后立即安装", isOn: $installAfterSign)
            }
        }
    }

    // MARK: - 证书选择

    private var certificateSection: some View {
        Section("选择证书") {
            if appState.certificates.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("请先在「证书」页面导入证书")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("证书", selection: $selectedCertificate) {
                    ForEach(appState.certificates) { cert in
                        VStack(alignment: .leading) {
                            Text(cert.name)
                                .font(.body)
                            Text(cert.teamID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(cert as CertificateInfo?)
                    }
                }
                .pickerStyle(.menu)

                if let cert = selectedCertificate {
                    if cert.hasProfile {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text(cert.profileName ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(cert.profileBundleID ?? "")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("未导入描述文件，请先在证书页导入")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 打包文件名

    private var outputFileSection: some View {
        Section("打包文件名") {
            TextField("打包文件名", text: $outputFileName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    // MARK: - 按钮区域

    private var actionSection: some View {
        Section {
            // 立即签名
            Button {
                startSigning()
            } label: {
                HStack {
                    Spacer()
                    if signingState.isSigning {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("签名中...")
                    } else {
                        Image(systemName: "signature")
                        Text("开始签名")
                    }
                    Spacer()
                }
                .font(.headline)
                .padding(.vertical, 4)
            }
            .disabled(!canSign)

            // 更多设置 / 收起设置
            Button {
                withAnimation {
                    showAdvanced.toggle()
                }
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "gearshape")
                    Text(showAdvanced ? "收起设置" : "更多设置")
                    Spacer()
                }
                .font(.headline)
                .foregroundColor(.accentColor)
                .padding(.vertical, 4)
            }

            // 签名成功后显示分享
            if let outputURL = signingState.outputURL {
                ShareLink(item: outputURL) {
                    HStack {
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                        Text("分享已签名 IPA")
                        Spacer()
                    }
                    .font(.headline)
                    .foregroundColor(.green)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var canSign: Bool {
        if signingState.isSigning { return false }
        if configOnly { return true }
        return selectedCertificate != nil && (selectedCertificate?.hasProfile ?? false)
    }

    // MARK: - 高级：修改桌面图标

    private var iconSection: some View {
        Section("修改桌面图标") {
            HStack {
                Text("桌面图标")
                Spacer()

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    if let iconData = customIconData, let uiImage = UIImage(data: iconData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else if let icon = app.icon {
                        Image(uiImage: icon)
                            .resizable()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.quaternary)
                            .frame(width: 44, height: 44)
                            .overlay {
                                Image(systemName: "app.fill")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .onChange(of: selectedPhotoItem) { newItem in
                    Task {
                        if let data = try? await newItem?.loadTransferable(type: Data.self) {
                            // 将图片转为 PNG 格式用于替换图标
                            if let uiImage = UIImage(data: data),
                               let pngData = uiImage.pngData() {
                                customIconData = pngData
                            }
                        }
                    }
                }
            }

            if customIconData != nil {
                Button("恢复原始图标", role: .destructive) {
                    customIconData = nil
                    selectedPhotoItem = nil
                }
                .font(.caption)
            }
        }
    }

    // MARK: - 高级：移除已有库

    private var removeLibsSection: some View {
        Section("移除已有库") {
            Button {
                if ipaFrameworks.isEmpty {
                    ipaFrameworks = IPAHandler.listFrameworksInIPA(ipaURL: app.fileURL)
                }
                showFrameworkPicker = true
            } label: {
                HStack {
                    Text("选择要移除的动态库")
                    Spacer()
                    if !selectedFrameworksToRemove.isEmpty {
                        Text("\(selectedFrameworksToRemove.count) 个")
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundColor(.primary)

            if !selectedFrameworksToRemove.isEmpty {
                ForEach(Array(selectedFrameworksToRemove).sorted(), id: \.self) { name in
                    HStack {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                        Text(name)
                            .font(.subheadline)
                        Spacer()
                        Text(name.hasSuffix(".framework") ? "framework" : "dylib")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedFrameworksToRemove.remove(name)
                    }
                }
            }
        }
        .sheet(isPresented: $showFrameworkPicker) {
            FrameworkPickerView(
                frameworks: ipaFrameworks,
                selected: $selectedFrameworksToRemove
            )
        }
    }

    // MARK: - 高级：动态库注入

    private var dylibInjectionSection: some View {
        Section {
            HStack {
                Text("注入路径")
                Spacer()
                Picker("", selection: $dylibLoadPath) {
                    ForEach(DylibLoadPath.allCases, id: \.self) { path in
                        Text(path.rawValue).tag(path)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            HStack {
                Text("注入目录")
                Spacer()
                Picker("", selection: $dylibDirectory) {
                    ForEach(DylibDirectory.allCases, id: \.self) { dir in
                        Text(dir.rawValue).tag(dir)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            // 已添加的动态库列表
            ForEach(injectDylibs, id: \.absoluteString) { url in
                HStack {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .foregroundColor(.red)
                    Text(url.lastPathComponent)
                        .font(.subheadline)
                    Spacer()
                    Button {
                        injectDylibs.removeAll { $0 == url }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.red)
                    }
                }
            }

            Button {
                showingDylibPicker = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.green)
                    Text("添加第三方库（dylib,framework,deb）")
                        .font(.subheadline)
                }
            }
        } header: {
            Text("动态库注入设置")
        } footer: {
            Text("\(dylibLoadPath.rawValue)_path/\(dylibDirectory.rawValue)xxx.dylib")
                .font(.caption2)
        }
    }

    // MARK: - 高级：压缩级别

    private var compressionSection: some View {
        Section {
            HStack {
                Text("压缩级别")
                Spacer()
                Picker("", selection: $compressionLevel) {
                    ForEach(SigningOptions.CompressionLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        } header: {
            Text("压缩级别设置")
        } footer: {
            switch compressionLevel {
            case .speed:
                Text("压缩速度快，压缩率低，文件较大")
            case .compatible:
                Text("兼容模式，平衡压缩速度和大小")
            case .size:
                Text("压缩率最高，速度较慢，文件较小")
            }
        }
    }

    // MARK: - 高级：其他选项

    private var otherOptionsSection: some View {
        Section("其他") {
            Toggle("移除所有插件 App", isOn: $removeAllPlugins)
            Toggle("移除所有手表 App", isOn: $removeWatchApps)
            Toggle("修改版本限制为：iOS 10.0", isOn: $changeMinVersion)
            Toggle("移除设备限制", isOn: $removeDeviceLimit)
            Toggle("移除应用跳转", isOn: $removeAppJump)
            Toggle("开启文件访问", isOn: $enableFileAccess)
            Toggle("修复白图标", isOn: $fixWhiteIcon)
            Toggle("自动修改越狱依赖", isOn: $autoFixJailbreak)
            Toggle("仅修改配置，不签名", isOn: $configOnly)
            Toggle("签名后移除 embedded.mobileprovision", isOn: $removeEmbeddedProvision)

            Toggle("App 多开", isOn: Binding(
                get: { enableAppMultiOpen },
                set: { newValue in
                    if newValue {
                        showingMultiOpenAlert = true
                    } else {
                        enableAppMultiOpen = false
                    }
                }
            ))
        }
    }

    // MARK: - 签名操作

    private func startSigning() {
        guard let cert = selectedCertificate else { return }

        // 准备签名参数
        var opts = SigningOptions()
        opts.newBundleID = newBundleID != app.bundleID ? newBundleID : nil
        opts.newDisplayName = newDisplayName != app.name ? newDisplayName : nil
        opts.newVersion = newVersion != app.version ? newVersion : nil
        opts.outputFileName = outputFileName
        opts.removePlugins = removeAllPlugins
        opts.removeWatchApp = removeWatchApps
        opts.frameworksToRemove = Array(selectedFrameworksToRemove)
        opts.injectDylibs = injectDylibs
        opts.dylibLoadPathPrefix = dylibLoadPath == .executable ? "@executable_path" : "@rpath"
        opts.dylibSubDirectory = dylibDirectory == .frameworks ? "Frameworks/" : "/"
        opts.configOnly = configOnly
        opts.removeEmbeddedProvision = removeEmbeddedProvision
        opts.newMinimumOSVersion = changeMinVersion ? "10.0" : nil
        opts.removeDeviceLimit = removeDeviceLimit
        opts.removeURLSchemes = removeAppJump
        opts.enableFileAccess = enableFileAccess
        opts.enableAppMultiOpen = enableAppMultiOpen
        opts.customIconData = customIconData ?? fallbackBrandIconData()
        opts.customLaunchImageData = customLaunchImageData ?? fallbackBrandLaunchImageData()

        // 如果当前导出对象是 YSign，本次签名会额外把运行时贴牌配置写进 IPA。
        // 这样生成出来的新壳第一次启动时，就能自动带出品牌公告、默认源、帮助链接等信息。
        if isLikelyYSignTarget {
            opts.embeddedBrandConfigData = appState.brandConfig.exportData
        }

        opts.compressionLevel = SigningOptions.CompressionLevel(rawValue: compressionLevel.rawValue) ?? .compatible

        // 准备初始日志（不立即应用，由 SigningProgressView 进入后再应用）
        let initialLogs = [
            "======= System =======",
            "\(appState.brandConfig.appName) V2.0.0",
            "======= App Info =======",
            "AppName：\(newDisplayName)",
            "BundleId：\(newBundleID)",
            "Version：\(newVersion)",
            "Cert：\(cert.name)",
            "======================="
        ]

        // 仅设置非 @Published 的待执行参数，避免导航期间触发 SwiftUI 重渲染
        signingState.pendingCert = cert
        signingState.pendingOpts = opts
        signingState.pendingIPAURL = app.fileURL
        signingState.pendingIPAFile = app
        signingState.pendingAppState = appState
        signingState.pendingInitialLogs = initialLogs

        // 导航到签名页（实际工作由 SigningProgressView.task 触发）
        pushToProgress?(signingState)
    }

    /// 读取品牌配置中的远程图标，作为手动未选择图片时的兜底值。
    ///
    /// 这样一来，只要 `BrandConfig.json` 里已经配置了贴牌图标地址，
    /// 就算用户没有再次手动选择图片，导出的 YSign 贴牌包也能自动带上品牌图标。
    private func fallbackBrandIconData() -> Data? {
        guard customIconData == nil,
              isLikelyYSignTarget,
              let url = URL(string: appState.brandConfig.appIconURL),
              !appState.brandConfig.appIconURL.isEmpty else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// 读取品牌配置中的远程启动图，作为手动未选择图片时的兜底值。
    private func fallbackBrandLaunchImageData() -> Data? {
        guard customLaunchImageData == nil,
              isLikelyYSignTarget,
              let url = URL(string: appState.brandConfig.appLaunchIconURL),
              !appState.brandConfig.appLaunchIconURL.isEmpty else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// 根据设置中的文件名生成规则生成默认输出文件名
    private func generateOutputFileName() -> String {
        let useName = UserDefaults.standard.object(forKey: "defaultFileNameUseName") != nil
            ? UserDefaults.standard.bool(forKey: "defaultFileNameUseName") : true
        let useVersion = UserDefaults.standard.object(forKey: "defaultFileNameUseVersion") != nil
            ? UserDefaults.standard.bool(forKey: "defaultFileNameUseVersion") : true
        let useBundleID = UserDefaults.standard.bool(forKey: "defaultFileNameUseBundleID")
        let useCert = UserDefaults.standard.bool(forKey: "defaultFileNameUseCert")
        let useTimestamp = UserDefaults.standard.object(forKey: "defaultFileNameUseTimestamp") != nil
            ? UserDefaults.standard.bool(forKey: "defaultFileNameUseTimestamp") : true

        var parts: [String] = []
        if useName { parts.append(app.name) }
        if useVersion { parts.append(app.version) }
        if useBundleID { parts.append(app.bundleID) }
        if useCert, let cert = selectedCertificate { parts.append(cert.name) }
        if useTimestamp { parts.append("\(Int(Date().timeIntervalSince1970))") }

        let name = parts.isEmpty ? app.name : parts.joined(separator: "_")
        return "\(name).ipa"
    }
}

// MARK: - 签名状态 ObservableObject 类

class SigningState: ObservableObject {
    @Published var isSigning = false
    @Published var progress: Double = 0
    @Published var stage = ""
    @Published var logs: [String] = []
    @Published var errorMessage: String?
    @Published var outputURL: URL?

    /// 待执行的签名参数（由 startSigning 准备，由 SigningProgressView 触发）
    var pendingCert: CertificateInfo?
    var pendingOpts: SigningOptions?
    var pendingIPAURL: URL?
    var pendingIPAFile: IPAFile?
    var pendingAppState: AppState?
    var pendingInitialLogs: [String] = []
    private var hasStarted = false

    /// 专用签名线程
    private let signingQueue = DispatchQueue(label: "com.ysign.signing", qos: .userInitiated)

    func reset() {
        isSigning = true
        progress = 0
        stage = ""
        logs = []
        errorMessage = nil
        outputURL = nil
        hasStarted = false
    }

    func addLog(_ message: String) {
        logs.append(message)
    }

    /// 由 SigningProgressView.task 调用，确保导航完成后才开始
    func beginSigningIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true

        // 一次性应用初始状态（单次 SwiftUI 更新批次）
        isSigning = true
        progress = 0
        stage = "准备中"
        logs = pendingInitialLogs
        errorMessage = nil
        outputURL = nil

        guard let cert = pendingCert,
              let opts = pendingOpts,
              let ipaURL = pendingIPAURL else {
            DispatchQueue.main.async {
                self.addLog("❌ 签名参数缺失")
                self.isSigning = false
            }
            return
        }

        let ipaFile = pendingIPAFile
        let appStateRef = pendingAppState

        signingQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                // 1. 解析 P12（直接调用，不经过 actor）
                let identity = try CertificateParser.parseP12(data: cert.p12Data, password: cert.password)

                DispatchQueue.main.async { self.addLog("✓ 证书解析成功") }

                // 2. 创建 pipeline（回调直接派发到主线程）
                let throttle = ProgressThrottle()
                let pipeline = SigningPipeline(
                    ipaURL: ipaURL,
                    certificate: identity,
                    options: opts,
                    outputDirectory: YSInternalStorage.directory("Signed"),
                    onProgress: { [weak self] stage, progress in
                        guard throttle.shouldUpdate() else { return }
                        DispatchQueue.main.async {
                            self?.stage = stage
                            self?.progress = progress
                        }
                    },
                    onLog: { [weak self] message in
                        DispatchQueue.main.async {
                            self?.addLog(message)
                        }
                    }
                )

                // 3. 在当前 GCD 线程中运行 async pipeline
                let semaphore = DispatchSemaphore(value: 0)
                var result: Result<URL, Error>!

                Task.detached(priority: .userInitiated) {
                    do {
                        let url = try await pipeline.execute()
                        result = .success(url)
                    } catch {
                        result = .failure(error)
                    }
                    semaphore.signal()
                }

                semaphore.wait()

                switch result! {
                case .success(let outputURL):
                    DispatchQueue.main.async {
                        self.outputURL = outputURL
                        self.isSigning = false
                        self.addLog("签名成功")
                        self.addLog("打包成功：\(outputURL.lastPathComponent)")
                        self.addLog("=======================")

                        if let ipaFile = ipaFile, let appStateRef = appStateRef {
                            let task = SigningTask(
                                id: UUID(),
                                ipaFile: ipaFile,
                                certificate: cert,
                                options: opts,
                                status: .completed,
                                progress: 1.0,
                                logs: self.logs.map { SigningTask.LogEntry(timestamp: Date(), message: $0, level: .info) },
                                startTime: Date(),
                                endTime: Date(),
                                outputURL: outputURL
                            )
                            appStateRef.signingTasks.append(task)
                        }
                    }
                case .failure(let error):
                    DispatchQueue.main.async {
                        self.addLog("❌ 签名失败：\(error.localizedDescription)")
                        self.errorMessage = error.localizedDescription
                        self.isSigning = false
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.addLog("❌ 证书解析失败：\(error.localizedDescription)")
                    self.errorMessage = error.localizedDescription
                    self.isSigning = false
                }
            }
        }
    }
}

// MARK: - 动态库选择页面

struct FrameworkPickerView: View {
    let frameworks: [String]
    @Binding var selected: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if frameworks.isEmpty {
                    Text("此 IPA 没有已有的动态库")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(frameworks, id: \.self) { name in
                        HStack {
                            Image(systemName: selected.contains(name)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selected.contains(name) ? .red : .gray)
                            Text(name)
                                .font(.subheadline)
                            Spacer()
                            Text(name.hasSuffix(".framework") ? "framework" : "dylib")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selected.contains(name) {
                                selected.remove(name)
                            } else {
                                selected.insert(name)
                            }
                        }
                    }
                }
            }
            .navigationTitle("移除动态库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
