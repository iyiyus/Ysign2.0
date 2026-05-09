import SwiftUI

/// 设置页面
///
/// 提供应用的全局配置选项：
/// - 外观设置（深色/浅色模式）
/// - 签名默认选项
/// - 存储管理
/// - 关于信息
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    /// 外观模式选择（0=跟随系统，1=浅色，2=深色）
    @AppStorage("appearanceMode") private var appearanceMode = 0

    /// 是否显示清理缓存确认弹窗
    @State private var showingCleanupAlert = false

    /// 缓存大小文字
    @State private var cacheSize = "计算中..."

    var body: some View {
        NavigationStack {
            Form {
                // 证书与设备
                identitySection

                // 传输
                transferSection

                // 外观设置
                appearanceSection

                // 安装设置
                installSection

                // 签名默认选项
                signingDefaultsSection

                // 存储管理
                storageSection

                // 品牌公告
                if !appState.brandConfig.notice.isEmpty {
                    brandNoticeSection
                }

                // 支持与帮助
                supportSection

                // 关于
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                cacheSize = await calculateCacheSize()
            }
        }
    }

    /// 品牌公告区域。
    ///
    /// 对应 PHP 贴牌配置里的 `notice` 字段，
    /// 让贴牌方可以在 App 内直接展示自己的公告内容。
    private var brandNoticeSection: some View {
        Section {
            Text(appState.brandConfig.notice)
                .font(.subheadline)
                .foregroundStyle(.primary)
        } header: {
            Text("公告")
        }
    }

    // MARK: - 各设置分区

    /// 签名身份区域（对应旧版「签名身份」Section）
    private var identitySection: some View {
        Section {
            // 证书管理 → 跳转到签名 Tab 的证书页
            NavigationLink {
                CertificatesView()
            } label: {
                Label("证书管理", systemImage: "lock.shield")
            }

            // 设备 UDID
            NavigationLink {
                DeviceUDIDView()
            } label: {
                Label("设备 UDID", systemImage: "iphone")
            }
        } header: {
            Text("签名身份")
        }
    }

    /// 传输区域（对应旧版「传输」Section）
    private var transferSection: some View {
        Section {
            NavigationLink {
                WiFiTransferView()
            } label: {
                Label("WiFi 文件传输", systemImage: "wifi")
            }
        } header: {
            Text("传输")
        } footer: {
            Text("通过局域网在电脑和设备之间传输文件")
        }
    }

    /// 外观设置区域
    private var appearanceSection: some View {
        Section {
            Picker("外观模式", selection: $appearanceMode) {
                Text("跟随系统").tag(0)
                Text("浅色模式").tag(1)
                Text("深色模式").tag(2)
            }
        } header: {
            Text("外观")
        } footer: {
            Text("设置应用的显示主题")
        }
    }

    /// 安装设置区域
    private var installSection: some View {
        Section {
            NavigationLink {
                IPAInstallServerView()
            } label: {
                Label("IPA 安装服务器", systemImage: "server.rack")
            }
        } header: {
            Text("IPA 安装")
        } footer: {
            Text("配置 plist.php 安装服务器，支持多个地址自动切换")
        }
    }

    /// 签名默认选项区域
    private var signingDefaultsSection: some View {
        Section {
            NavigationLink {
                SigningDefaultsView()
            } label: {
                Label("签名默认配置", systemImage: "signature")
            }
        } header: {
            Text("签名默认选项")
        } footer: {
            Text("配置签名任务的默认参数，新建签名时将使用这些值")
        }
    }

    /// 存储管理区域
    private var storageSection: some View {
        Section {
            HStack {
                Text("缓存大小")
                Spacer()
                Text(cacheSize)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                showingCleanupAlert = true
            } label: {
                Text("清除所有缓存")
            }
            .alert("确认清除?", isPresented: $showingCleanupAlert) {
                Button("清除", role: .destructive) {
                    clearCache()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除所有临时文件和已签名的 IPA 文件。已导入的 IPA 和证书不受影响。")
            }
        } header: {
            Text("存储")
        }
    }

    /// 支持与帮助区域（对应旧版「偏好与支持」）
    private var supportSection: some View {
        Section {
            // 使用教程
            if let tutorialURL = URL(string: appState.brandConfig.tutorialURL), !appState.brandConfig.tutorialURL.isEmpty {
                Link(destination: tutorialURL) {
                    HStack {
                        Label("使用教程", systemImage: "book")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundColor(.primary)
            }

            // 联系我们
            if let contactURL = URL(string: appState.brandConfig.contactURL), !appState.brandConfig.contactURL.isEmpty {
                Link(destination: contactURL) {
                    HStack {
                        Label("联系我们", systemImage: "bubble.left")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundColor(.primary)
            }

            // 购买链接
            if let buyURL = URL(string: appState.brandConfig.buyURL), !appState.brandConfig.buyURL.isEmpty {
                Link(destination: buyURL) {
                    HStack {
                        Label("购买链接", systemImage: "cart")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundColor(.primary)
            }

            // QQ 群 / 社群
            if !appState.brandConfig.group.isEmpty {
                HStack {
                    Label("社群", systemImage: "person.3")
                    Spacer()
                    Text(appState.brandConfig.group)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 服务及隐私协议
            Link(destination: URL(string: "https://www.julyedu.com/agreement/priv")!) {
                HStack {
                    Label("服务及隐私协议", systemImage: "doc.text")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundColor(.primary)
        } header: {
            Text("支持与帮助")
        }
    }

    /// 关于区域
    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text("2.0.0")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("构建号")
                Spacer()
                Text("1")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("引擎")
                Spacer()
                Text("Swift Native (CryptoKit)")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("关于 \(appState.brandConfig.appName)")
        } footer: {
            Text("纯 Swift 实现的 iOS 应用签名工具\n使用 Apple Security.framework + CryptoKit 原生签名引擎")
        }
    }

    // MARK: - 操作方法

    /// 计算缓存目录的总大小
    private func calculateCacheSize() async -> String {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let signedDir = docs.appendingPathComponent("YSign/Signed")
        let tempDir = fm.temporaryDirectory

        var totalSize: Int64 = 0

        // 计算已签名目录大小
        if let enumerator = fm.enumerator(at: signedDir, includingPropertiesForKeys: [.fileSizeKey]) {
            while let url = enumerator.nextObject() as? URL {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                totalSize += Int64(size)
            }
        }

        // 计算临时目录中 YSign 相关文件
        if let contents = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: [.fileSizeKey]) {
            for url in contents where url.lastPathComponent.hasPrefix("YSign_") {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                    while let fileURL = enumerator.nextObject() as? URL {
                        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                        totalSize += Int64(size)
                    }
                }
            }
        }

        return ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    /// 清除缓存
    private func clearCache() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let signedDir = docs.appendingPathComponent("YSign/Signed")

        // 删除已签名 IPA
        try? fm.removeItem(at: signedDir)
        try? fm.createDirectory(at: signedDir, withIntermediateDirectories: true)

        // 删除临时文件
        if let contents = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) {
            for url in contents where url.lastPathComponent.hasPrefix("YSign_") {
                try? fm.removeItem(at: url)
            }
        }

        // 刷新缓存大小
        Task {
            cacheSize = await calculateCacheSize()
        }
    }
}
