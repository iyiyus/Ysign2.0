import SwiftUI
import UniformTypeIdentifiers

/// 备份与还原页面
///
/// - 备份内容三组可选：配置 / 工作区 / 文件（选择会记住，下次创建沿用）
/// - 创建并分享备份：生成加密 .ysignbackup 文件并拉起分享
/// - 从文件还原：选择备份文件 → 校验 → 合并还原（可选密码）
struct BackupView: View {
    @EnvironmentObject var appState: AppState

    /// 备份内容选择（持久化：每次创建本地备份都使用这里的选择）
    @AppStorage("backupIncludeConfig") private var includeConfig = true
    @AppStorage("backupIncludeWorkspace") private var includeWorkspace = true
    @AppStorage("backupIncludeFiles") private var includeFiles = true

    /// 可选导出密码（不持久化）
    @State private var exportPassword = ""

    @State private var isWorking = false
    @State private var exportURL: URL?
    @State private var showShare = false
    @State private var showFileImporter = false

    @State private var restoring = false
    @State private var pendingRestoreURL: URL?
    @State private var restorePassword = ""
    @State private var passwordPrompt = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    introCard
                    contentsCard
                    localCard
                }
                .padding(DS.paddingScreen)
            }
            .background(DS.background.ignoresSafeArea())
            .navigationTitle("备份与还原")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(DS.primary)
        .sheet(isPresented: $showShare) {
            if let exportURL {
                ShareLinkSheet(items: [exportURL])
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            restorePicked(url: url)
        }
        .alert("备份已加密", isPresented: $passwordPrompt) {
            SecureField("导出密码", text: $restorePassword)
            Button("还原") {
                if let url = pendingRestoreURL {
                    performRestore(url: url, password: restorePassword)
                }
            }
            Button("取消", role: .cancel) { pendingRestoreURL = nil }
        } message: {
            Text("该备份使用了导出密码，请输入创建备份时设置的密码。")
        }
        .alert("还原完成", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("好") {
                resultMessage = nil
                Task { await appState.refreshLibrary() }
            }
        } message: {
            Text(resultMessage ?? "")
        }
        .alert("错误", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("确定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 卡片

    /// 顶部说明卡
    private var introCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DSIconBadge(systemName: "externaldrive.badge.timemachine", color: DS.primary, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("YSign 数据备份")
                        .font(.system(.headline, design: .rounded))
                    Text("把配置、工作区与文件打包为加密备份，可导出到文件并随时还原。")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                }
            }

            Divider()

            hintRow(icon: "lock.rotation", color: DS.accent,
                    text: "备份数据会加密并进行完整性校验，导入时只接受支持的配置项。")
            hintRow(icon: "key.slash", color: .orange,
                    text: "所有模式都排除设备 UDID、P12、描述文件与证书库；签名证书请在证书页单独管理。")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func hintRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 备份内容选择卡
    private var contentsCard: some View {
        VStack(spacing: 0) {
            contentRow(title: "配置", subtitle: "应用偏好、签名默认与安装服务设置",
                       icon: "slider.horizontal.3", binding: $includeConfig)
            Divider().padding(.leading, 54)
            contentRow(title: "工作区", subtitle: "IPA 库、签名产物与软件源数据",
                       icon: "shippingbox", binding: $includeWorkspace)
            Divider().padding(.leading, 54)
            contentRow(title: "文件", subtitle: "下载文件与文件页中的自建目录",
                       icon: "folder", binding: $includeFiles)

            Divider().padding(.leading, 54)

            HStack(spacing: 12) {
                DSIconBadge(systemName: "key.fill", color: .indigo, size: 30)
                SecureField("导出密码（可选）", text: $exportPassword)
                    .font(.system(.subheadline, design: .rounded))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.vertical, 10)
        }
        .dsCard(padding: 4)
    }

    private func contentRow(title: String, subtitle: String, icon: String, binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            HStack(spacing: 12) {
                DSIconBadge(systemName: icon, color: DS.primary, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(DS.text)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                }
            }
        }
        .tint(DS.primary)
        .padding(.vertical, 8)
    }

    /// 本地备份操作卡
    private var localCard: some View {
        VStack(spacing: 10) {
            Button {
                exportBackup()
            } label: {
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("创建并分享备份")
                    }
                    Text("将备份：\(selectedSummary)")
                        .font(.caption2)
                        .fontWeight(.regular)
                        .opacity(0.85)
                }
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .disabled(isWorking || selectedContents.isEmpty)

            Button {
                showFileImporter = true
            } label: {
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down")
                        Text("从文件还原")
                    }
                    Text("选择由 YSign 创建的 .ysignbackup 文件")
                        .font(.caption2)
                        .fontWeight(.regular)
                        .opacity(0.8)
                }
            }
            .buttonStyle(DSSecondaryButtonStyle())
            .disabled(isWorking || restoring)

            if isWorking || restoring {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(restoring ? "正在还原..." : "正在创建备份...")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                }
            }
        }
        .dsCard()
    }

    // MARK: - 选择摘要

    private var selectedContents: BackupService.Contents {
        var c: BackupService.Contents = []
        if includeConfig { c.insert(.configuration) }
        if includeWorkspace { c.insert(.workspace) }
        if includeFiles { c.insert(.files) }
        return c
    }

    private var selectedSummary: String {
        var names: [String] = []
        if includeConfig { names.append("配置") }
        if includeWorkspace { names.append("工作区") }
        if includeFiles { names.append("文件") }
        return names.isEmpty ? "未选择" : names.joined(separator: "、")
    }

    // MARK: - 操作

    private func exportBackup() {
        isWorking = true
        Task {
            do {
                let fileName = "YSign_备份_\(Date().formatted(.dateTime.year().month().day())).\(BackupService.backupExtension)"
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                let contents = selectedContents
                let password = exportPassword
                try await Task.detached(priority: .userInitiated) {
                    try BackupService.exportBackup(to: dest, contents: contents, password: password)
                }.value
                await MainActor.run {
                    isWorking = false
                    exportURL = dest
                    showShare = true
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = "备份失败: \(error.localizedDescription)"
                }
            }
        }
    }

    /// 从系统文件选择器拿到备份文件（可能是安全作用域 URL）
    private func restorePicked(url: URL) {
        guard url.pathExtension.lowercased() == BackupService.backupExtension else {
            errorMessage = "请选择 .\(BackupService.backupExtension) 备份文件"
            return
        }
        restoring = true
        Task {
            do {
                // 复制到临时目录，避免安全作用域失效
                let local = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).\(BackupService.backupExtension)")
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: url, to: local)

                await MainActor.run {
                    restoring = false
                    pendingRestoreURL = local
                    // 先尝试无密码解密；需要密码时弹输入框
                    performRestore(url: local, password: "")
                }
            } catch {
                await MainActor.run {
                    restoring = false
                    errorMessage = "无法读取备份文件: \(error.localizedDescription)"
                }
            }
        }
    }

    private func performRestore(url: URL, password: String) {
        restoring = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try BackupService.restoreBackup(from: url, password: password)
                }.value
                await MainActor.run {
                    restoring = false
                    pendingRestoreURL = nil
                    restorePassword = ""
                    var msg = "已恢复 \(result.restoredFiles) 个文件"
                    if result.skippedFiles > 0 { msg += "，跳过 \(result.skippedFiles) 个已存在文件" }
                    if result.restoredSettings > 0 { msg += "，恢复 \(result.restoredSettings) 项设置" }
                    if let date = result.manifest?.createdDate {
                        msg += "\n备份创建于 \(date.formatted(date: .abbreviated, time: .shortened))"
                    }
                    resultMessage = msg
                }
            } catch BackupService.BackupError.passwordRequired {
                await MainActor.run {
                    restoring = false
                    passwordPrompt = true
                }
            } catch {
                await MainActor.run {
                    restoring = false
                    pendingRestoreURL = nil
                    restorePassword = ""
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// 分享表包装
struct ShareLinkSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
