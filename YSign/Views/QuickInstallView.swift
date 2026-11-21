import SwiftUI
import UIKit

// MARK: - 外部分享的 IPA 数据

/// 从应用外分享/打开进入的 IPA
///
/// 文件只保存在临时工作目录（`tmp/YSignQuickInstall/`），**不属于应用库**。
/// 只有用户点「导入工作区」时才会通过 IPALibraryManager 复制进资源库。
struct SharedIPAItem: Identifiable {
    let id = UUID()

    /// 原始文件名（展示用）
    let fileName: String

    /// 应用名称
    let name: String

    /// Bundle ID
    let bundleID: String

    /// 版本号
    let version: String

    /// 构建号
    let buildNumber: String

    /// 文件大小（字节）
    let fileSize: Int64

    /// 应用图标
    let icon: UIImage?

    /// 临时副本路径（不在应用库内）
    let fileURL: URL

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var versionDisplay: String {
        buildNumber.isEmpty ? version : "\(version) (\(buildNumber))"
    }
}

// MARK: - 快捷安装协调器

/// 处理外部分享 IPA 的接收、信息解析与三个操作
///
/// 关键约定：
/// - 「签名并安装」「直接安装」只使用临时副本，绝不写入应用库（ipaLibrary）
/// - 只有「导入工作区」会把 IPA 复制进资源库并刷新列表
final class QuickInstallCoordinator: ObservableObject {

    static let shared = QuickInstallCoordinator()

    /// 当前待确认的分享 IPA（非 nil 时展示确认页）
    @Published var item: SharedIPAItem?

    /// 是否正在处理（签名 / 安装 / 导入）
    @Published var isWorking = false

    /// 处理完成（展示结果）
    @Published var isFinished = false
    @Published var resultMessage: String?
    @Published var resultIsError = false

    /// 接收/解析失败时展示的全局错误（此时没有确认页可显示）
    @Published var incomingError: String?

    /// 签名进度
    @Published var stage = ""
    @Published var progress: Double = 0
    @Published var logs: [String] = []

    /// 临时工作目录
    private let workDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("YSignQuickInstall", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// 正在运行的签名任务（支持取消）
    private var pipelineTask: Task<Void, Never>?

    // MARK: - 接收外部文件

    /// 处理系统传入的 file:// URL（「文件」App 分享 / 用 YSign 打开）
    func handleIncomingFile(_ url: URL) {
        guard url.pathExtension.lowercased() == "ipa" else { return }

        let scoped = url.startAccessingSecurityScopedResource()
        let sourceURL = url

        DispatchQueue.global(qos: .userInitiated).async {
            // 安全作用域访问只在这个复制周期内保持
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

            let fm = FileManager.default
            do {
                // 清理上一次的临时副本（保留当前正在处理的即可）
                if let old = try? fm.contentsOfDirectory(at: self.workDirectory, includingPropertiesForKeys: nil) {
                    old.forEach { try? fm.removeItem(at: $0) }
                }

                // 复制到临时工作目录：不写入应用库
                let dest = self.workDirectory.appendingPathComponent("\(UUID().uuidString).ipa")
                try fm.copyItem(at: sourceURL, to: dest)

                let info = try IPAHandler.quickInfo(ipaURL: dest)
                let attrs = try? fm.attributesOfItem(atPath: dest.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let icon = info.icon.flatMap { UIImage(data: $0) }

                let item = SharedIPAItem(
                    fileName: sourceURL.lastPathComponent,
                    name: info.name,
                    bundleID: info.bundleID,
                    version: info.version,
                    buildNumber: info.buildNumber,
                    fileSize: size,
                    icon: icon,
                    fileURL: dest
                )

                DispatchQueue.main.async { self.present(item) }
            } catch {
                DispatchQueue.main.async {
                    self.presentFailure("无法读取 IPA：\(error.localizedDescription)")
                }
            }
        }
    }

    private func present(_ item: SharedIPAItem) {
        guard !isWorking else { return }
        self.item = item
        isFinished = false
        resultMessage = nil
        resultIsError = false
        logs = []
        stage = ""
        progress = 0
    }

    /// 解析失败时也要给出反馈（不展示确认页）
    private func presentFailure(_ message: String) {
        guard !isWorking else { return }
        item = nil
        isFinished = false
        resultMessage = nil
        incomingError = message
    }

    // MARK: - 操作一：导入工作区（唯一会写入应用库的动作）

    @MainActor
    func importToWorkspace(appState: AppState) {
        guard let item else { return }
        isWorking = true
        let url = item.fileURL

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try IPALibraryManager().importIPA(from: url)
                Task { @MainActor in
                    await appState.refreshLibrary()
                    self.complete(message: "已导入工作区，可在「应用 → 未签名」中找到")
                }
            } catch {
                DispatchQueue.main.async {
                    self.complete(message: "导入失败：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 操作二：签名并安装（不导入应用库）

    @MainActor
    func signAndInstall(appState: AppState) {
        guard let item else { return }

        guard let cert = appState.certificates.first(where: { $0.hasProfile })
                ?? appState.certificates.first else {
            complete(message: "请先导入签名证书与描述文件")
            return
        }

        isWorking = true
        isFinished = false
        resultMessage = nil
        resultIsError = false
        logs = []
        stage = "准备中"
        progress = 0
        appendLog("======= 快捷安装 =======")
        appendLog("AppName：\(item.name)")
        appendLog("BundleId：\(item.bundleID)")
        appendLog("Cert：\(cert.name)")

        BackgroundKeepAlive.shared.start(reason: .signing)

        let opts = makeDefaultOptions(for: item)
        let fileURL = item.fileURL
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let profileURL = cert.profileFileName.map {
            docs.appendingPathComponent("YSign/Certificates/\($0)")
        }

        SigningProcessQueue.submit {
            do {
                let identity = try CertificateParser.parseP12(data: cert.p12Data, password: cert.password)
                DispatchQueue.main.async { self.appendLog("✓ 证书解析成功") }

                let pipeline = SigningPipeline(
                    ipaURL: fileURL,
                    certificate: identity,
                    options: opts,
                    provisionURL: profileURL,
                    onProgress: { stage, value in
                        DispatchQueue.main.async {
                            self.stage = stage
                            self.progress = value
                        }
                    },
                    onLog: { message in
                        DispatchQueue.main.async { self.appendLog(message) }
                    }
                )

                let semaphore = DispatchSemaphore(value: 0)
                var result: Result<URL, Error>!
                let task = Task.detached(priority: .userInitiated) {
                    do {
                        result = .success(try await pipeline.execute())
                    } catch {
                        result = .failure(error)
                    }
                    semaphore.signal()
                }
                DispatchQueue.main.async { self.pipelineTask = task }
                semaphore.wait()

                switch result! {
                case .success(let outputURL):
                    Task { @MainActor in
                        self.onSigned(outputURL: outputURL, item: item)
                    }
                case .failure(let error):
                    Task { @MainActor in self.onSignFailed(error) }
                }
            } catch {
                Task { @MainActor in self.onSignFailed(error) }
            }
        }
    }

    /// 签名完成后自动触发安装
    @MainActor
    private func onSigned(outputURL: URL, item: SharedIPAItem) {
        BackgroundKeepAlive.shared.stop(reason: .signing)
        appendLog("✓ 签名完成：\(outputURL.lastPathComponent)")
        appendLog("开始安装...")
        stage = "安装中"

        BackgroundKeepAlive.shared.start(reason: .installing)
        IPAInstaller.install(
            ipaURL: outputURL,
            appName: item.name,
            bundleID: item.bundleID,
            version: item.version,
            onEvent: { event in
                switch event {
                case .serverReady:
                    DispatchQueue.main.async { self.appendLog("等待设备拉取安装包") }
                case .deviceFetching:
                    DispatchQueue.main.async { self.appendLog("✓ 设备已开始拉取 IPA，请在系统弹窗中确认") }
                }
            }
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.complete(message: "已触发系统安装，请在弹窗中确认")
                case .failed(let msg):
                    self.complete(message: "安装失败：\(msg)")
                }
                // 给系统安装弹窗留缓冲时间后释放保活
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    BackgroundKeepAlive.shared.stop(reason: .installing)
                }
            }
        }
    }

    @MainActor
    private func onSignFailed(_ error: Error) {
        BackgroundKeepAlive.shared.stop(reason: .signing)
        appendLog("❌ 签名失败：\(error.localizedDescription)")
        complete(message: "签名失败：\(error.localizedDescription)")
    }

    // MARK: - 操作三：直接安装（不签名、不导入应用库）

    @MainActor
    func directInstall() {
        guard let item else { return }
        isWorking = true
        isFinished = false
        resultMessage = nil
        resultIsError = false
        logs = ["======= 直接安装 =======", "File：\(item.fileName)"]
        stage = "安装中"

        BackgroundKeepAlive.shared.start(reason: .installing)
        IPAInstaller.install(
            ipaURL: item.fileURL,
            appName: item.name,
            bundleID: item.bundleID,
            version: item.version,
            onEvent: { event in
                switch event {
                case .serverReady:
                    DispatchQueue.main.async { self.appendLog("等待设备拉取安装包") }
                case .deviceFetching:
                    DispatchQueue.main.async { self.appendLog("✓ 设备已开始拉取 IPA，请在系统弹窗中确认") }
                }
            }
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.complete(message: "已触发系统安装，请在弹窗中确认")
                case .failed(let msg):
                    self.complete(message: "安装失败：\(msg)")
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    BackgroundKeepAlive.shared.stop(reason: .installing)
                }
            }
        }
    }

    // MARK: - 通用

    /// 取消正在进行的签名
    func cancelWork() {
        pipelineTask?.cancel()
        appendLog("⏹ 用户请求取消")
    }

    /// 关闭确认页（临时副本保留到下次分享时清理，避免安装器读取期间被删）
    func dismiss() {
        pipelineTask?.cancel()
        item = nil
        isWorking = false
        isFinished = false
        resultMessage = nil
        resultIsError = false
        logs = []
        stage = ""
        progress = 0
    }

    private func complete(message: String) {
        isWorking = false
        isFinished = true
        resultMessage = message
        resultIsError = message.contains("失败") || message.contains("无法") || message.contains("请先")
        progress = 1
    }

    private func appendLog(_ message: String) {
        logs.append(message)
        if logs.count > 500 { logs.removeFirst(logs.count - 250) }
    }

    /// 使用设置页的默认签名选项，快捷安装不进入配置页
    private func makeDefaultOptions(for item: SharedIPAItem) -> SigningOptions {
        var opts = SigningOptions()
        let ud = UserDefaults.standard
        opts.removePlugins = ud.bool(forKey: "defaultRemovePlugins")
        opts.removeWatchApp = ud.bool(forKey: "defaultRemoveWatch")
        opts.removeDeviceLimit = ud.object(forKey: "defaultRemoveDeviceLimit") != nil
            ? ud.bool(forKey: "defaultRemoveDeviceLimit") : true
        opts.newMinimumOSVersion = (ud.object(forKey: "defaultChangeMinVersion") != nil
            ? ud.bool(forKey: "defaultChangeMinVersion") : true) ? "10.0" : nil
        opts.removeURLSchemes = ud.bool(forKey: "defaultRemoveAppJump")
        opts.enableFileAccess = ud.bool(forKey: "defaultEnableFileAccess")
        opts.removeEmbeddedProvision = ud.bool(forKey: "defaultRemoveEmbeddedProvision")
        opts.compressionLevel = SigningOptions.CompressionLevel(
            rawValue: ud.string(forKey: "defaultCompressionLevel") ?? "兼容"
        ) ?? .compatible
        opts.outputFileName = "\(item.name)_快捷安装.ipa"
        return opts
    }
}

// MARK: - 快捷安装确认页（项目设计系统风格）

struct QuickInstallView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var coordinator: QuickInstallCoordinator
    let item: SharedIPAItem

    @State private var entitlementsText: String?
    @State private var isLoadingEntitlements = true

    /// 默认签名证书（优先选带描述文件的）
    private var defaultCertificate: CertificateInfo? {
        appState.certificates.first(where: { $0.hasProfile }) ?? appState.certificates.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    headerCard
                    appInfoCard
                    entitlementsCard
                    profileCard

                    if coordinator.isWorking || !coordinator.logs.isEmpty {
                        logCard
                    }
                }
                .padding(DS.paddingScreen)
                .padding(.bottom, 24)
            }
            .background(DS.background.ignoresSafeArea())
            .navigationTitle("快捷安装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        coordinator.dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(DS.textTertiary)
                    }
                    .disabled(coordinator.isWorking)
                }
            }
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
            .task {
                await loadEntitlements()
            }
        }
    }

    // MARK: - 卡片

    /// 应用头部：图标 / 名称 / Bundle ID / 状态徽章
    private var headerCard: some View {
        HStack(spacing: 14) {
            if let icon = item.icon {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: 66, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous)
                    .fill(DS.primarySoft)
                    .frame(width: 66, height: 66)
                    .overlay {
                        Image(systemName: "app.fill")
                            .font(.title)
                            .foregroundStyle(DS.primary)
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)

                Text(item.bundleID)
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    QuickBadge(text: "未签名", color: DS.warning)
                    QuickBadge(text: item.versionDisplay, color: DS.primary)
                }
            }
            Spacer(minLength: 0)
        }
        .dsCard(padding: 14)
    }

    /// 应用信息
    private var appInfoCard: some View {
        DSSectionCard(title: "应用信息") {
            QuickInfoRow(icon: "app.badge", title: "Bundle ID", value: item.bundleID)
            DSDivider()
            QuickInfoRow(icon: "number", title: "版本", value: item.versionDisplay)
            DSDivider()
            QuickInfoRow(icon: "externaldrive", title: "大小", value: item.sizeFormatted)
            DSDivider()
            QuickInfoRow(icon: "doc", title: "文件名", value: item.fileName)
        }
    }

    /// 原包权限
    private var entitlementsCard: some View {
        DSSectionCard(
            title: "原包权限",
            footer: "签名时以当前证书描述文件的能力为准"
        ) {
            HStack(alignment: .top, spacing: 12) {
                DSIconBadge(systemName: "gearshape.2", color: DS.primary, size: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text("权限 / 能力")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(DS.text)
                    if isLoadingEntitlements {
                        Text("正在读取主程序 entitlements...")
                            .font(.caption)
                            .foregroundStyle(DS.textTertiary)
                    } else if let text = entitlementsText, !text.isEmpty {
                        Text(entitlementSummary(text))
                            .font(.caption)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(3)
                    } else {
                        Text("主程序未读取到 entitlements；签名时将使用当前证书描述文件能力。")
                            .font(.caption)
                            .foregroundStyle(DS.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    /// 签名描述文件
    private var profileCard: some View {
        DSSectionCard(title: "签名描述文件") {
            if let cert = defaultCertificate {
                QuickInfoRow(icon: "person.badge.key", title: "证书", value: cert.name)
                DSDivider()
                QuickInfoRow(icon: "doc.badge.gearshape", title: "描述文件", value: cert.profileName ?? "未导入")
                DSDivider()
                QuickInfoRow(icon: "building.2", title: "Team ID", value: cert.teamID)
                DSDivider()
                QuickInfoRow(icon: "calendar", title: "过期时间", value: cert.expirationDate.formatted(date: .abbreviated, time: .omitted))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DS.warning)
                    Text("未导入签名证书，「签名并安装」不可用")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    /// 处理日志
    private var logCard: some View {
        DSSectionCard(title: "处理进度") {
            VStack(alignment: .leading, spacing: 6) {
                if coordinator.isWorking {
                    HStack {
                        Text(coordinator.stage)
                            .font(.caption)
                            .foregroundStyle(DS.textSecondary)
                        Spacer()
                        Text("\(Int(coordinator.progress * 100))%")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(DS.primary)
                    }
                    ProgressView(value: coordinator.progress)
                        .tint(DS.primary)
                }
                ForEach(Array(coordinator.logs.suffix(12).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - 底部操作区

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: 10) {
            if coordinator.isWorking {
                Button {
                    coordinator.cancelWork()
                } label: {
                    Label("取消签名", systemImage: "stop.circle")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(DS.destructive)
                }
                .buttonStyle(.plain)
            } else if coordinator.isFinished {
                Text(coordinator.resultMessage ?? "")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(coordinator.resultIsError ? DS.destructive : DS.success)
                    .multilineTextAlignment(.center)
                Button {
                    coordinator.dismiss()
                } label: {
                    Text("完成")
                }
                .buttonStyle(DSPrimaryButtonStyle())
            } else {
                HStack(spacing: 12) {
                    Button {
                        coordinator.dismiss()
                    } label: {
                        Text("取消")
                    }
                    .buttonStyle(DSSecondaryButtonStyle())

                    Button {
                        coordinator.importToWorkspace(appState: appState)
                    } label: {
                        Text("导入工作区")
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                }

                Button {
                    coordinator.signAndInstall(appState: appState)
                } label: {
                    Label("签名并安装", systemImage: "hammer.fill")
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .disabled(defaultCertificate == nil)

                Button {
                    coordinator.directInstall()
                } label: {
                    Label("直接安装", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(DSSecondaryButtonStyle())
            }
        }
        .padding(.horizontal, DS.paddingScreen)
        .padding(.vertical, 12)
        .background(DS.card.ignoresSafeArea(edges: .bottom))
    }

    // MARK: - 辅助

    private func loadEntitlements() async {
        defer { isLoadingEntitlements = false }
        entitlementsText = try? await IPAHandler.extractEntitlementsFromIPA(ipaURL: item.fileURL)
    }

    private func entitlementSummary(_ text: String) -> String {
        // entitlements 多为 plist/XML 文本，提取键名做摘要展示
        let keys = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("<key>") }
            .map { $0.replacingOccurrences(of: "<key>", with: "").replacingOccurrences(of: "</key>", with: "") }
        if keys.isEmpty { return "已读取到主程序 entitlements" }
        let preview = keys.prefix(4).joined(separator: "、")
        return "已读取 \(keys.count) 项权限：\(preview)\(keys.count > 4 ? " 等" : "")"
    }
}

// MARK: - 小型组件

private struct QuickInfoRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(DS.textTertiary)
                .frame(width: 18)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(DS.textSecondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(DS.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct QuickBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .lineLimit(1)
    }
}
