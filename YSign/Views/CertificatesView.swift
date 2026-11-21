import SwiftUI

/// 证书管理页面
///
/// 证书和描述文件配对管理：
/// - 先导入 P12 证书 → 列表显示"未导入描述文件"
/// - 再导入描述文件 → 与证书关联
/// - 点击证书 → 显示详细信息（名称、组织、过期、设备、权限等）
struct CertificatesView: View {
    @EnvironmentObject var appState: AppState

    // MARK: 导入状态

    /// 导入入口（系统文件选择器）
    @State private var showingFilePicker = false
    @State private var showingFolderPicker = false

    /// 导入进行中
    @State private var importing = false

    /// P12 密码重试（默认密码 "1" 失败后弹框）
    @State private var showingPasswordAlert = false
    @State private var p12PasswordInput = ""
    @State private var pendingRetryP12s: [URL] = []

    /// 批量导入的中间状态（密码框弹出期间暂存）
    @State private var importedP12s: [CertificateImportService.ImportedP12] = []
    @State private var pendingProfiles: [URL] = []
    @State private var importErrors: [String] = []
    /// 默认密码阶段失败的错误（重试成功后丢弃）
    @State private var pendingRetryErrors: [String] = []

    /// 错误 / 成功提示
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var successMessage: String?
    @State private var showingSuccess = false

    var body: some View {
        VStack {
            if appState.certificates.isEmpty {
                emptyStateView
            } else {
                certificateListView
            }
        }
        // 导入文件（P12 / 描述文件 / ZIP）
        .sheet(isPresented: $showingFilePicker) {
            DocumentPickerView(
                contentTypes: [.data, .item],
                onPick: { urls in
                    handleImport(urls)
                },
                onDismiss: { showingFilePicker = false }
            )
        }
        // 导入文件夹（内含 P12 / 描述文件 / ZIP）；asCopy 必须为 false，否则 iOS 断言崩溃
        .sheet(isPresented: $showingFolderPicker) {
            DocumentPickerView(
                contentTypes: [.folder],
                asCopy: false,
                onPick: { urls in
                    handleImport(urls)
                },
                onDismiss: { showingFolderPicker = false }
            )
        }
        // 默认密码导入失败 → 手动输入密码重试
        .alert("输入证书密码", isPresented: $showingPasswordAlert) {
            SecureField("密码", text: $p12PasswordInput)
            Button("重试导入") { retryWithPassword() }
            Button("取消", role: .cancel) { finishImportCancelled() }
        } message: {
            Text("默认密码导入失败，请输入 \(pendingRetryP12s.count) 个证书的保护密码")
        }
        .alert("错误", isPresented: $showingError) {
            Button("确定") {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .alert("成功", isPresented: $showingSuccess) {
            Button("确定") {}
        } message: {
            Text(successMessage ?? "")
        }
        .onAppear {
            Task { await appState.loadCertificates() }
        }
        // 右上角加号：选择导入方式
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                importMenu
            }
        }
    }

    /// 导入入口菜单（导入文件 / 导入文件夹）
    private var importMenu: some View {
        Menu {
            importMenuItems
        } label: {
            Image(systemName: "plus")
        }
        .disabled(importing)
    }

    /// 列表 / 空状态使用的导入按钮（菜单展开导入方式）
    private var importMenuLabel: some View {
        Menu {
            importMenuItems
        } label: {
            Label("导入新证书", systemImage: "plus.circle")
        }
        .disabled(importing)
    }

    @ViewBuilder
    private var importMenuItems: some View {
        Button {
            showingFilePicker = true
        } label: {
            Label("导入文件", systemImage: "doc.badge.plus")
        }

        Button {
            showingFolderPicker = true
        } label: {
            Label("导入文件夹", systemImage: "folder.badge.plus")
        }
    }

    // MARK: - 子视图

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("还没有导入证书")
                .font(.title2)
                .fontWeight(.medium)

            Text("先导入 P12 证书，再导入描述文件\n支持个人证书和企业证书")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Menu {
                Button {
                    showingFilePicker = true
                } label: {
                    Label("导入文件", systemImage: "doc.badge.plus")
                }

                Button {
                    showingFolderPicker = true
                } label: {
                    Label("导入文件夹", systemImage: "folder.badge.plus")
                }
            } label: {
                Label("导入证书", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)

            Text("支持 P12 / 描述文件 / ZIP 压缩包\n文件夹内含证书文件同理")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var certificateListView: some View {
        List {
            ForEach(appState.certificates) { cert in
                NavigationLink {
                    CertificateDetailView(cert: cert)
                        .environmentObject(appState)
                } label: {
                    CertificateRow(cert: cert)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        deleteCertificate(cert)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }

            Section {
                importMenuLabel

                if importing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在导入证书…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 批量导入流程

    /// 入口：收集文件 / 文件夹中的证书，先用默认密码 "1" 导入 P12
    private func handleImport(_ urls: [URL]) {
        guard !importing else { return }
        importing = true
        importErrors = []
        pendingRetryErrors = []
        importedP12s = []
        pendingProfiles = []

        Task {
            let service = CertificateImportService()
            var allP12: [URL] = []
            var allProfiles: [URL] = []

            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let collected = service.collect(from: url)
                allP12 += collected.p12s
                allProfiles += collected.profiles
            }

            guard !allP12.isEmpty || !allProfiles.isEmpty else {
                service.cleanup()
                importing = false
                errorMessage = "所选位置没有找到 P12 证书、描述文件或 ZIP 压缩包"
                showingError = true
                return
            }

            // 第一步：用默认密码导入全部 P12
            let first = await service.importP12s(allP12, password: CertificateImportService.defaultPassword)
            importedP12s = first.imported

            if !first.failed.isEmpty {
                // 默认密码失败 → 暂存状态，弹密码框让用户填写
                pendingRetryP12s = first.failed
                pendingRetryErrors = first.errors
                pendingProfiles = allProfiles
                importing = false
                p12PasswordInput = ""
                showingPasswordAlert = true
                return
            }

            // 无需重试，直接配对描述文件
            await finishImport(service: service, profiles: allProfiles)
        }
    }

    /// 用户输入密码后重试导入失败的 P12
    private func retryWithPassword() {
        let password = p12PasswordInput
        guard !password.isEmpty, !pendingRetryP12s.isEmpty else {
            finishImportCancelled()
            return
        }
        importing = true

        Task {
            let service = CertificateImportService()
            let retry = await service.importP12s(pendingRetryP12s, password: password)
            importedP12s += retry.imported
            // 只保留重试后仍失败的错误
            importErrors = retry.errors
            pendingRetryErrors = []

            let profiles = pendingProfiles
            await finishImport(service: service, profiles: profiles)
        }
    }

    /// 取消密码重试：保留已导入部分，配对描述文件
    private func finishImportCancelled() {
        importing = true
        importErrors = pendingRetryErrors
        pendingRetryErrors = []
        Task {
            await finishImport(service: CertificateImportService(), profiles: pendingProfiles)
        }
    }

    /// 第二步：配对导入描述文件并汇总结果
    private func finishImport(service: CertificateImportService, profiles: [URL]) async {
        let linked = await service.importProfiles(profiles, imported: importedP12s)
        importErrors += linked.errors

        await appState.loadCertificates()
        service.cleanup()

        var summary = ""
        if !importedP12s.isEmpty {
            summary += "已导入 \(importedP12s.count) 个证书"
            if !linked.linked.isEmpty { summary += "、\(linked.linked.count) 个描述文件" }
        } else if !linked.linked.isEmpty {
            summary += "已关联 \(linked.linked.count) 个描述文件"
        }
        if !linked.linked.isEmpty && !importedP12s.isEmpty {
            summary += "\n" + linked.linked.prefix(3).joined(separator: "\n")
        }
        if !importErrors.isEmpty {
            summary += (summary.isEmpty ? "" : "\n") + "失败：\n" + importErrors.prefix(5).joined(separator: "\n")
        }

        importing = false
        pendingRetryP12s = []
        pendingProfiles = []

        if summary.isEmpty {
            errorMessage = "没有可导入的内容"
            showingError = true
        } else if !importedP12s.isEmpty || !linked.linked.isEmpty {
            successMessage = summary
            showingSuccess = true
        } else {
            errorMessage = summary
            showingError = true
        }
    }

    private func deleteCertificate(_ cert: CertificateInfo) {
        Task {
            let store = CertificateStore()
            try? await store.delete(id: cert.id)
            await appState.loadCertificates()
        }
    }
}

// MARK: - 证书列表行

struct CertificateRow: View {
    let cert: CertificateInfo

    var body: some View {
        HStack(spacing: 12) {
            // 状态图标
            Image(systemName: cert.hasProfile ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundColor(statusColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(cert.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if cert.hasProfile {
                    Text(cert.profileBundleID ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("⚠ 未导入描述文件")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Text(cert.displayExpiryStatus)
                    .font(.caption2)
                    .foregroundColor(cert.isExpired ? .red : .green)
            }

            Spacer()

            // 证书类型标签
            Text(cert.certificateType)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1))
                .foregroundColor(.blue)
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        if cert.isExpired { return .red }
        if !cert.hasProfile { return .orange }
        return .green
    }
}

// MARK: - 证书详情页

struct CertificateDetailView: View {
    @EnvironmentObject var appState: AppState
    let cert: CertificateInfo
    @StateObject private var revocation = RevocationService.shared

    @State private var showingProfileImporter = false
    @State private var showingDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var successMessage: String?
    @State private var showingSuccess = false

    /// 实时获取最新证书数据
    private var currentCert: CertificateInfo {
        appState.certificates.first(where: { $0.id == cert.id }) ?? cert
    }

    var body: some View {
        List {
            // 证书基本信息
            Section("证书信息") {
                DetailRow(title: "名称", value: currentCert.name)
                DetailRow(title: "类型", value: currentCert.certificateType)
                DetailRow(title: "组织", value: currentCert.teamName)
                DetailRow(title: "组织单位 (OU)", value: currentCert.organizationalUnit)
                DetailRow(title: "团队 ID", value: currentCert.teamID)
                DetailRow(title: "序列号", value: currentCert.serialNumber)
                DetailRow(title: "支持平台", value: currentCert.platform)
            }

            // 证书状态
            Section {
                HStack {
                    Text("状态")
                        .foregroundStyle(.secondary)
                    Spacer()
                    // 状态即吊销检测结果；检测中/无法确认时回退本地有效期判断
                    if let result = revocation.results[currentCert.id],
                       result.status == .revoked || result.status == .expired ||
                       result.status == .expiringSoon || result.status == .valid {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(result.status == .valid ? .green :
                                      (result.status == .revoked || result.status == .expired) ? .red : .orange)
                                .frame(width: 8, height: 8)
                            Text(result.status.label)
                                .foregroundColor(result.status == .valid ? .green :
                                                 (result.status == .revoked || result.status == .expired) ? .red : .orange)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(currentCert.isExpired ? .red : .green)
                                .frame(width: 8, height: 8)
                            Text(currentCert.displayExpiryStatus)
                                .foregroundColor(currentCert.isExpired ? .red : .green)
                        }
                    }
                }
                DetailRow(title: "生效时间", value: formatDate(currentCert.creationDate))
                DetailRow(title: "过期时间", value: formatDate(currentCert.expirationDate))
            } header: {
                Text("证书状态")
            }

            // 描述文件信息
            Section {
                if currentCert.hasProfile {
                    DetailRow(title: "名称", value: currentCert.profileName ?? "-")
                    DetailRow(title: "Bundle ID", value: currentCert.profileBundleID ?? "-")
                    DetailRow(title: "类型", value: currentCert.profileType ?? "-")
                    if let expDate = currentCert.profileExpirationDate {
                        DetailRow(title: "过期时间", value: formatDate(expDate))
                    }

                    // 更换描述文件
                    Button {
                        showingProfileImporter = true
                    } label: {
                        Label("更换描述文件", systemImage: "arrow.triangle.2.circlepath")
                    }

                    // 移除描述文件
                    Button(role: .destructive) {
                        unlinkProfile()
                    } label: {
                        Label("移除描述文件", systemImage: "trash")
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("未导入描述文件，无法签名")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        showingProfileImporter = true
                    } label: {
                        Label("导入描述文件", systemImage: "plus.circle.fill")
                    }
                }
            } header: {
                Text("描述文件")
            }

            // 支持的设备 UDID
            if let devices = currentCert.provisionedDevices, !devices.isEmpty {
                Section {
                    ForEach(devices, id: \.self) { udid in
                        Text(udid)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("已注册设备 (\(devices.count) 台)")
                } footer: {
                    Text("只有这些 UDID 的设备可以安装签名后的应用")
                }
            } else if currentCert.hasProfile && currentCert.provisionedDevices == nil {
                Section("设备支持") {
                    HStack {
                        Image(systemName: "globe")
                            .foregroundColor(.green)
                        Text("不限设备（企业证书 / App Store）")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 证书权限
            if let keys = currentCert.entitlementKeys, !keys.isEmpty {
                Section {
                    ForEach(keys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(EntitlementLocalizer.name(for: key))
                                .font(.subheadline)
                            Text(key)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("证书权限 (\(keys.count) 项)")
                } footer: {
                    Text("来自描述文件的授权，签名时自动嵌入应用")
                }
            }

            // 删除证书
            Section {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        Label("删除证书", systemImage: "trash")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("证书详情")
        .navigationBarTitleDisplayMode(.inline)
        // 下拉刷新：立即重新检查吊销状态
        .refreshable {
            await revocation.checkAwait(cert: currentCert)
        }
        .onAppear {
            revocation.check(cert: currentCert)
        }
        .sheet(isPresented: $showingProfileImporter) {
            InAppFilePicker(
                allowedExtensions: ["mobileprovision"],
                title: "选择描述文件"
            ) { url in
                importProfile(from: url)
            }
        }
        .alert("确认删除", isPresented: $showingDeleteConfirm) {
            Button("删除", role: .destructive) { deleteCert() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复，确定删除该证书？")
        }
        .alert("错误", isPresented: $showingError) {
            Button("确定") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("成功", isPresented: $showingSuccess) {
            Button("确定") {}
        } message: {
            Text(successMessage ?? "")
        }
    }

    // MARK: - 操作

    private func importProfile(from url: URL) {
        Task {
            do {
                let store = CertificateStore()
                let updated = try await store.linkProfile(certID: cert.id, profileURL: url)
                await appState.loadCertificates()
                successMessage = "描述文件 \"\(updated.profileName ?? "")\" 已关联"
                showingSuccess = true
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private func unlinkProfile() {
        Task {
            let store = CertificateStore()
            try? await store.unlinkProfile(certID: cert.id)
            await appState.loadCertificates()
        }
    }

    private func deleteCert() {
        Task {
            let store = CertificateStore()
            try? await store.delete(id: cert.id)
            await appState.loadCertificates()
        }
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }
}

// MARK: - 详情行

struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Entitlements 中文名称

/// 证书权限 key → 中文名称映射（未收录的 key 原样显示）
enum EntitlementLocalizer {

    static let names: [String: String] = [
        "get-task-allow": "允许调试（Debug）",
        "application-identifier": "应用标识符",
        "com.apple.developer.team-identifier": "团队标识符",
        "keychain-access-groups": "钥匙串访问组",
        "com.apple.security.application-groups": "应用组（App Groups）",
        "com.apple.developer.associated-domains": "关联域名（Universal Links）",
        "aps-environment": "推送通知（APNs）",
        "com.apple.developer.default-data-protection": "数据保护",
        "com.apple.developer.siri": "Siri 支持",
        "com.apple.developer.healthkit": "健康数据（HealthKit）",
        "com.apple.developer.homekit": "家庭自动化（HomeKit）",
        "com.apple.developer.networking.networkextension": "网络扩展（VPN/代理）",
        "com.apple.developer.networking.vpn.api": "个人 VPN",
        "com.apple.developer.networking.wildcard": "网络通配符",
        "com.apple.developer.networking.multicast": "本地网络多播",
        "com.apple.developer.carplay": "CarPlay 支持",
        "com.apple.external-accessory.wireless-configuration": "无线配件配置",
        "com.apple.developer.external-accessory": "外部配件框架",
        "com.apple.developer.pass-type-identifiers": "卡券（Pass）标识符",
        "com.apple.developer.in-app-payments": "Apple Pay 支付",
        "com.apple.developer.payment-pass": "Apple Pay 卡片",
        "com.apple.developer.game-center": "游戏中心",
        "com.apple.developer.icloud-services": "iCloud 服务",
        "com.apple.developer.icloud-container-identifiers": "iCloud 容器",
        "com.apple.developer.ubiquity-kvstore-identifier": "iCloud 键值存储",
        "com.apple.developer.icloud-container-development": "iCloud 开发容器",
        "com.apple.developer.usernotifications.time-sensitive": "时效性通知",
        "com.apple.developer.usernotifications.communication": "通信类通知",
        "com.apple.developer.kernel.extended-virtual-addressing": "扩展虚拟寻址",
        "com.apple.developer.kernel.increased-memory-limit": "增加内存上限",
        "com.apple.developer.device-information.user-assigned-device-name": "读取设备名称",
        "com.apple.developer.location.push": "定位推送",
        "com.apple.developer.nfc.readonly": "NFC 读取",
        "com.apple.developer.nfc.readwrite": "NFC 读写",
        "com.apple.developer.family-controls": "家庭控制（屏幕使用时间）",
        "com.apple.developer.group-session": "SharePlay 群组会话",
        "com.apple.developer.web-browser": "网页浏览器",
        "com.apple.developer.authentication-services.autofill-credential-provider": "密码自动填充",
        "com.apple.developer.shared-with-you": "共享协作（Shared with You）",
        "com.apple.developer.contacts.notes": "通讯录备注",
        "com.apple.developer.classkit": "ClassKit 教育框架",
        "com.apple.developer.system-extension.install": "系统扩展安装",
        "com.apple.developer.driverkit": "DriverKit 驱动",
        "com.apple.developer.applesignin": "通过 Apple 登录",
        "com.apple.developer.applesignin-custom": "Apple 登录（自定义配置）",
    ]

    /// 取权限的中文名称；未收录的返回原始 key
    static func name(for key: String) -> String {
        names[key] ?? key
    }
}
