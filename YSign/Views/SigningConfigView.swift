import SwiftUI
import PhotosUI

/// 签名配置页面
///
/// 用户选择一个 IPA 后进入此页面，配置签名参数。
/// 亮色卡片式布局：
/// - 顶部应用信息卡（图标 + 名称 + 版本 + 大小）
/// - 分组卡片表单（基本信息 / 证书 / 文件名）
/// - 高级选项折叠区
/// - 底部固定「开始签名」主按钮
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

    /// 移除已有库
    @State private var ipaFrameworks: [String] = []
    @State private var selectedFrameworksToRemove: Set<String> = []
    @State private var showFrameworkPicker = false
    @State private var isLoadingFrameworks = false

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

    // MARK: - Entitlements

    /// 自定义 entitlements 内容（XML，空 = 使用描述文件默认提取）
    @State private var customEntitlementsText = ""
    /// 是否正在读取原包 entitlements
    @State private var isLoadingEntitlements = false
    /// 是否展开编辑器
    @State private var showEntitlementsEditor = false

    // MARK: - 枚举

    enum DylibLoadPath: String, CaseIterable {
        case executable = "@executable"
        case rpath = "@rpath"
    }

    enum DylibDirectory: String, CaseIterable {
        case root = "/"
        case frameworks = "Frameworks/"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // 滚动内容
            ScrollView {
                VStack(spacing: 16) {
                    // 应用信息头卡
                    appHeaderCard

                    // 基本信息
                    DSSectionCard(title: "基本信息") {
                        DSFormTextField(title: "App 名字", text: $newDisplayName)
                        DSDivider()
                        DSFormTextField(title: "Bundle Identifier", text: $newBundleID, mono: true)
                        DSDivider()
                        DSFormTextField(title: "版本号", text: $newVersion)
                        DSDivider()
                        DSToggleRow(title: "签名后立即安装", isOn: $installAfterSign)
                    }

                    // 证书选择
                    certificateSection

                    // 打包文件名
                    DSSectionCard(title: "打包文件名") {
                        DSFormTextField(title: "输出文件名", text: $outputFileName, mono: true)
                    }

                    // Entitlements 权限配置
                    entitlementsSection

                    // 高级设置（展开后显示）
                    if showAdvanced {
                        advancedSections
                    }
                }
                .padding(.horizontal, DS.paddingScreen)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .background(DS.background.ignoresSafeArea())

            // 底部固定操作栏
            bottomActionBar
        }
        .background(DS.background.ignoresSafeArea())
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 签名成功后显示分享
            if signingState.outputURL != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: signingState.outputURL!) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(DS.success)
                    }
                }
            }
        }
        .onAppear {
            selectedCertificate = appState.certificates.first(where: { $0.hasProfile }) ?? appState.certificates.first

            // 读取默认前缀/后缀
            let prefix = UserDefaults.standard.string(forKey: "defaultNamePrefix") ?? ""
            let suffix = UserDefaults.standard.string(forKey: "defaultNameSuffix") ?? ""
            newDisplayName = prefix + app.name + suffix
            newBundleID = app.bundleID
            newVersion = app.version

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
        .task {
            // 进入页面即预加载 IPA 内动态库列表（异步，避免点击时等待）
            await preloadFrameworks()
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

    // MARK: - 应用信息头卡

    private var appHeaderCard: some View {
        HStack(spacing: 14) {
            // 应用图标
            if let icon = app.icon {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous)
                    .fill(DS.primarySoft)
                    .frame(width: 60, height: 60)
                    .overlay {
                        Image(systemName: "app.fill")
                            .font(.title)
                            .foregroundStyle(DS.primary)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)

                Text(app.bundleID)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("v\(app.version)")
                        .font(.system(.caption2, design: .rounded, weight: .bold))
                        .foregroundStyle(DS.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(DS.primarySoft))
                    Text(app.fileSizeFormatted)
                        .font(.caption2)
                        .foregroundStyle(DS.textTertiary)
                }
            }

            Spacer()
        }
        .dsCard(padding: 14)
    }

    // MARK: - 证书选择

    private var certificateSection: some View {
        DSSectionCard(
            title: "选择证书",
            footer: selectedCertificate.map { cert in
                cert.hasProfile ? "描述文件：\(cert.profileName ?? "")" : "未导入描述文件，请先在证书页导入"
            }
        ) {
            if appState.certificates.isEmpty {
                HStack(spacing: 10) {
                    DSIconBadge(systemName: "exclamationmark.triangle.fill", color: DS.warning, size: 34)
                    Text("请先在「证书」页面导入证书")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(DS.textSecondary)
                    Spacer()
                }
                .padding(14)
            } else {
                ForEach(appState.certificates.indices, id: \.self) { index in
                    let cert = appState.certificates[index]
                    certificateRow(cert)
                    if index < appState.certificates.count - 1 {
                        DSDivider()
                    }
                }
            }
        }
    }

    /// 单个证书选择行
    private func certificateRow(_ cert: CertificateInfo) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedCertificate = cert
            }
        } label: {
            HStack(spacing: 12) {
                DSIconBadge(
                    systemName: "lock.shield.fill",
                    color: cert.hasProfile ? DS.primary : DS.warning,
                    size: 38
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(cert.name)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)

                    Text(cert.teamID)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                if selectedCertificate?.id == cert.id {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(DS.primary)
                } else {
                    Image(systemName: "circle")
                        .font(.title3)
                        .foregroundStyle(DS.divider)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 高级设置区域

    @ViewBuilder
    private var advancedSections: some View {
        // 修改桌面图标
        DSSectionCard(title: "修改桌面图标", footer: customIconData != nil ? "已选择自定义图标" : "点击右侧图标更换桌面图标") {
            HStack {
                Text("桌面图标")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(DS.text)
                Spacer()

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    if let iconData = customIconData, let uiImage = UIImage(data: iconData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: DS.cornerS, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.cornerS, style: .continuous)
                                    .strokeBorder(DS.primary.opacity(0.5), lineWidth: 1.5)
                            )
                    } else if let icon = app.icon {
                        Image(uiImage: icon)
                            .resizable()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: DS.cornerS, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: DS.cornerS, style: .continuous)
                            .fill(DS.primarySoft)
                            .frame(width: 48, height: 48)
                            .overlay {
                                Image(systemName: "app.fill")
                                    .foregroundStyle(DS.primary)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if customIconData != nil {
                DSDivider()
                Button {
                    customIconData = nil
                    selectedPhotoItem = nil
                } label: {
                    HStack {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                        Text("恢复原始图标")
                    }
                    .font(.system(.footnote, design: .rounded, weight: .medium))
                    .foregroundStyle(DS.destructive)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }

        // 移除已有库
        DSSectionCard(
            title: "移除已有库",
            footer: ipaFrameworks.isEmpty
                ? (isLoadingFrameworks ? "正在扫描 IPA 内的动态库..." : "此 IPA 未扫描到动态库，点击可重新扫描")
                : "共扫描到 \(ipaFrameworks.count) 个动态库，点击选择要移除的"
        ) {
            Button {
                if ipaFrameworks.isEmpty {
                    Task { await preloadFrameworks(force: true) }
                }
                showFrameworkPicker = true
            } label: {
                HStack {
                    DSIconBadge(systemName: "shippingbox.fill", color: .orange, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("选择要移除的动态库")
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(DS.text)
                        if !ipaFrameworks.isEmpty {
                            Text("已选 \(selectedFrameworksToRemove.count) / \(ipaFrameworks.count)")
                                .font(.caption2)
                                .foregroundStyle(DS.textTertiary)
                        }
                    }
                    Spacer()
                    if isLoadingFrameworks {
                        ProgressView().controlSize(.small)
                    } else if !selectedFrameworksToRemove.isEmpty {
                        DSCountBadge(count: selectedFrameworksToRemove.count)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.textTertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !selectedFrameworksToRemove.isEmpty {
                DSDivider()
                ForEach(Array(selectedFrameworksToRemove).sorted(), id: \.self) { name in
                    HStack(spacing: 10) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(DS.destructive)
                        Text(name)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                        Spacer()
                        Text(name.hasSuffix(".framework") ? "framework" : "dylib")
                            .font(.caption2)
                            .foregroundStyle(DS.textTertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
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
                selected: $selectedFrameworksToRemove,
                onRetry: {
                    Task { await preloadFrameworks(force: true) }
                }
            )
        }

        // 动态库注入
        DSSectionCard(
            title: "动态库注入",
            footer: "注入路径示例：\(dylibLoadPath.rawValue)_path/\(dylibDirectory.rawValue)xxx.dylib"
        ) {
            VStack(spacing: 12) {
                dsSegmentedRow(title: "注入路径", selection: $dylibLoadPath, options: DylibLoadPath.allCases)
                dsSegmentedRow(title: "注入目录", selection: $dylibDirectory, options: DylibDirectory.allCases)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ForEach(injectDylibs, id: \.absoluteString) { url in
                DSDivider()
                HStack(spacing: 10) {
                    DSIconBadge(systemName: "puzzlepiece.extension.fill", color: .indigo, size: 32)
                    Text(url.lastPathComponent)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        injectDylibs.removeAll { $0 == url }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(DS.destructive)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            DSDivider()
            Button {
                showingDylibPicker = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(DS.primary)
                    Text("添加第三方库（dylib, framework, deb）")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(DS.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        // 压缩级别
        DSSectionCard(title: "压缩级别", footer: compressionFooter) {
            HStack {
                Text("压缩模式")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(DS.text)
                Spacer()
                Picker("", selection: $compressionLevel) {
                    ForEach(SigningOptions.CompressionLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .pickerStyle(.menu)
                .tint(DS.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }

        // 其他选项
        DSSectionCard(title: "其他选项") {
            DSToggleRow(title: "移除所有插件 App", isOn: $removeAllPlugins)
            DSDivider()
            DSToggleRow(title: "移除所有手表 App", isOn: $removeWatchApps)
            DSDivider()
            DSToggleRow(title: "修改版本限制为：iOS 10.0", isOn: $changeMinVersion)
            DSDivider()
            DSToggleRow(title: "移除设备限制", isOn: $removeDeviceLimit)
            DSDivider()
            DSToggleRow(title: "移除应用跳转", isOn: $removeAppJump)
            DSDivider()
            DSToggleRow(title: "开启文件访问", isOn: $enableFileAccess)
            DSDivider()
            DSToggleRow(title: "修复白图标", isOn: $fixWhiteIcon)
            DSDivider()
            DSToggleRow(title: "自动修改越狱依赖", isOn: $autoFixJailbreak)
            DSDivider()
            DSToggleRow(title: "仅修改配置，不签名", isOn: $configOnly)
            DSDivider()
            DSToggleRow(title: "签名后移除 embedded.mobileprovision", isOn: $removeEmbeddedProvision)
            DSDivider()
            DSToggleRow(
                title: "App 多开",
                isOn: Binding(
                    get: { enableAppMultiOpen },
                    set: { newValue in
                        if newValue {
                            showingMultiOpenAlert = true
                        } else {
                            enableAppMultiOpen = false
                        }
                    }
                )
            )

            if enableAppMultiOpen {
                DSDivider()
                HStack(spacing: 8) {
                    Text("序号 \(multiOpenStartNumber) 起 · 共 \(multiOpenCount) 个")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(DS.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(DS.primarySoft))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    /// 行内分段选择（用于注入路径/目录）
    private func dsSegmentedRow<T: Hashable & CaseIterable>(
        title: String,
        selection: Binding<T>,
        options: [T]
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(DS.text)
            Spacer()
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text("\(option)").tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .tint(DS.primary)
        }
    }

    // MARK: - Entitlements 区块

    private var entitlementsSection: some View {
        DSSectionCard(
            title: "Entitlements 权限",
            footer: customEntitlementsText.isEmpty
                ? "默认从描述文件自动提取权限；如需自定义可读取原包或手动编辑 XML"
                : "将使用下方自定义 entitlements（仅证书签名时应用）"
        ) {
            HStack(spacing: 12) {
                DSIconBadge(systemName: "key.fill", color: .indigo, size: 34)
                Text(customEntitlementsText.isEmpty ? "未设置自定义权限" : "已设置自定义权限")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(DS.text)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showEntitlementsEditor.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.textTertiary)
                        .rotationEffect(.degrees(showEntitlementsEditor ? 180 : 0))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if showEntitlementsEditor {
                DSDivider()
                HStack(spacing: 12) {
                    Button {
                        loadOriginalEntitlements()
                    } label: {
                        HStack(spacing: 6) {
                            if isLoadingEntitlements {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "doc.text.magnifyingglass")
                            }
                            Text("读取原包")
                        }
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(DS.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingEntitlements)

                    Button {
                        customEntitlementsText = ""
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "eraser")
                            Text("清空")
                        }
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(DS.destructive)
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                TextEditor(text: $customEntitlementsText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 140, maxHeight: 220)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: DS.cornerS, style: .continuous).fill(DS.background))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
    }

    /// 异步预加载 IPA 内动态库列表
    private func preloadFrameworks(force: Bool = false) async {
        if isLoadingFrameworks { return }
        if !force && !ipaFrameworks.isEmpty { return }
        guard FileManager.default.fileExists(atPath: app.fileURL.path) else { return }
        isLoadingFrameworks = true
        let url = app.fileURL
        let result = await Task.detached(priority: .userInitiated) {
            IPAHandler.listFrameworksInIPA(ipaURL: url)
        }.value
        ipaFrameworks = result
        isLoadingFrameworks = false
    }

    /// 解包 IPA 读取主二进制的原包 entitlements
    private func loadOriginalEntitlements() {
        isLoadingEntitlements = true
        Task {
            do {
                let entitlements = try await IPAHandler.extractEntitlementsFromIPA(ipaURL: app.fileURL)
                await MainActor.run {
                    isLoadingEntitlements = false
                    if let entitlements {
                        customEntitlementsText = entitlements
                    } else {
                        customEntitlementsText = """
                        <?xml version="1.0" encoding="UTF-8"?>
                        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                        <plist version="1.0">
                        <dict/>
                        </plist>
                        """
                    }
                }
            } catch {
                await MainActor.run {
                    isLoadingEntitlements = false
                    signingState.addLog("⚠️ 读取原包 entitlements 失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private var compressionFooter: String {
        switch compressionLevel {
        case .speed: return "压缩速度快，压缩率低，文件较大"
        case .compatible: return "兼容模式，平衡压缩速度和大小"
        case .size: return "压缩率最高，速度较慢，文件较小"
        }
    }

    // MARK: - 底部固定操作栏

    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            DSDivider()

            HStack(spacing: 12) {
                // 更多设置 / 收起设置
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        showAdvanced.toggle()
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: showAdvanced ? "slider.horizontal.3" : "slider.horizontal.below.rectangle")
                            .font(.system(.body, weight: .semibold))
                        Text(showAdvanced ? "收起设置" : "更多设置")
                            .font(.system(.caption2, design: .rounded, weight: .medium))
                    }
                    .foregroundStyle(DS.primary)
                    .frame(width: 72, height: 52)
                    .background(RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous).fill(DS.primarySoft))
                }
                .buttonStyle(.plain)

                // 立即签名
                Button {
                    startSigning()
                } label: {
                    HStack(spacing: 8) {
                        if signingState.isSigning {
                            ProgressView()
                                .tint(.white)
                            Text("签名中...")
                        } else {
                            Image(systemName: "signature")
                            Text("开始签名")
                        }
                    }
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(!canSign)
            }
            .padding(.horizontal, DS.paddingScreen)
            .padding(.vertical, 10)
        }
        .background(DS.card.ignoresSafeArea(edges: .bottom))
    }

    private var canSign: Bool {
        if signingState.isSigning { return false }
        if configOnly { return true }
        return selectedCertificate != nil && (selectedCertificate?.hasProfile ?? false)
    }

    // MARK: - 签名操作

    private func startSigning() {
        guard let cert = selectedCertificate else { return }

        // 准备签名参数
        var opts = SigningOptions()

        // 预处理注入库：deb 自动解包提取 dylib（对齐 LCSign 的 DebArArchive）
        var finalDylibs: [URL] = []
        for url in injectDylibs {
            switch url.pathExtension.lowercased() {
            case "deb":
                do {
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("YSDeb_\(UUID().uuidString)")
                    _ = try ArchiveKit.extract(archiveURL: url, to: dest)
                    let dylibs = ArchiveKit.collectDylibs(from: dest)
                    if dylibs.isEmpty {
                        signingState.addLog("⚠️ deb 中未找到 dylib：\(url.lastPathComponent)")
                    } else {
                        finalDylibs.append(contentsOf: dylibs)
                    }
                } catch {
                    signingState.addLog("⚠️ deb 解包失败 \(url.lastPathComponent)：\(error.localizedDescription)")
                }
            default:
                // dylib / framework 二进制等直接注入
                finalDylibs.append(url)
            }
        }
        opts.newBundleID = newBundleID != app.bundleID ? newBundleID : nil
        opts.newDisplayName = newDisplayName != app.name ? newDisplayName : nil
        opts.newVersion = newVersion != app.version ? newVersion : nil
        opts.outputFileName = outputFileName
        opts.removePlugins = removeAllPlugins
        opts.removeWatchApp = removeWatchApps
        opts.frameworksToRemove = Array(selectedFrameworksToRemove)
        opts.injectDylibs = finalDylibs
        opts.dylibLoadPathPrefix = dylibLoadPath == .executable ? "@executable_path" : "@rpath"
        opts.dylibSubDirectory = dylibDirectory == .frameworks ? "Frameworks/" : "/"
        opts.configOnly = configOnly
        opts.removeEmbeddedProvision = removeEmbeddedProvision
        opts.newMinimumOSVersion = changeMinVersion ? "10.0" : nil
        opts.removeDeviceLimit = removeDeviceLimit
        opts.removeURLSchemes = removeAppJump
        opts.enableFileAccess = enableFileAccess
        opts.enableAppMultiOpen = enableAppMultiOpen
        opts.customIconData = customIconData
        opts.customEntitlements = customEntitlementsText.isEmpty ? nil : customEntitlementsText
        opts.compressionLevel = SigningOptions.CompressionLevel(rawValue: compressionLevel.rawValue) ?? .compatible

        // 准备初始日志（不立即应用，由 SigningProgressView 进入后再应用）
        let initialLogs = [
            "======= System =======",
            "YSign V2.0.0",
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

    /// 全局串行签名队列（对齐 LCSign 的 ProcessQueue：多个签名任务按序执行）
    /// 本类的任务也提交到此队列，保证同一时间只有一个签名任务占用 CPU/IO
    private let signingQueue = SigningProcessQueue.queue

    /// 正在运行的 pipeline Task（用于取消）
    private var pipelineTask: Task<Void, Never>?

    /// 日志上限（环形缓冲，防止超长任务撑爆内存）
    private static let maxLogs = 1000

    /// 用户请求取消签名
    func cancelSigning() {
        addLog("⏹ 用户请求取消签名...")
        pipelineTask?.cancel()
    }

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
        // 环形缓冲：超过上限时丢弃最早的一半
        if logs.count > Self.maxLogs {
            logs.removeFirst(logs.count - Self.maxLogs / 2)
        }
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

                // 3. 在当前 GCD 线程中运行 async pipeline（保留 Task 句柄以支持取消）
                let semaphore = DispatchSemaphore(value: 0)
                var result: Result<URL, Error>!

                let task = Task.detached(priority: .userInitiated) {
                    do {
                        let url = try await pipeline.execute()
                        result = .success(url)
                    } catch {
                        result = .failure(error)
                    }
                    semaphore.signal()
                }
                self.pipelineTask = task

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
                        if error is CancellationError {
                            // 用户取消：不弹错误框
                            self.addLog("⏹ 签名已取消")
                            self.isSigning = false
                        } else {
                            self.addLog("❌ 签名失败：\(error.localizedDescription)")
                            self.errorMessage = error.localizedDescription
                            self.isSigning = false
                        }
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
    var onRetry: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    /// 搜索过滤后的列表
    private var filteredFrameworks: [String] {
        searchText.isEmpty ? frameworks : frameworks.filter {
            $0.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if frameworks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 40))
                            .foregroundStyle(DS.textTertiary)
                        Text("此 IPA 没有扫描到动态库")
                            .font(.subheadline)
                            .foregroundStyle(DS.textSecondary)
                        if let onRetry {
                            Button("重新扫描") { onRetry() }
                                .font(.system(.footnote, design: .rounded, weight: .semibold))
                                .foregroundStyle(DS.primary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredFrameworks, id: \.self) { name in
                        HStack {
                            Image(systemName: selected.contains(name)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selected.contains(name) ? DS.destructive : DS.textTertiary)
                            Text(name)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(DS.text)
                            Spacer()
                            Text(name.hasSuffix(".framework") ? "framework" : "dylib")
                                .font(.caption2)
                                .foregroundStyle(DS.textTertiary)
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
            .searchable(text: $searchText, prompt: "搜索动态库")
            .scrollContentBackground(.hidden)
            .background(DS.background.ignoresSafeArea())
            .navigationTitle("移除动态库 (\(frameworks.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selected.isEmpty ? "全选" : "清空") {
                        if selected.isEmpty {
                            selected = Set(frameworks)
                        } else {
                            selected.removeAll()
                        }
                    }
                    .foregroundStyle(DS.primary)
                    .disabled(frameworks.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(DS.primary)
                }
            }
        }
    }
}
