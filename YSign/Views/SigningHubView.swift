import SwiftUI

/// 应用页面
///
/// 顶部分段：未签名 / 已签名
/// - 未签名：IPA 资源库（导入、浏览、选择 IPA 进行签名）
/// - 已签名：已完成签名的 IPA 列表
struct SigningHubView: View {
    @EnvironmentObject var appState: AppState

    @State private var selectedSection: Section = .unsigned
    @State private var searchText = ""
    @State private var showingImporter = false
    @State private var showingFilesImporter = false
    @State private var navigationPath = NavigationPath()

    enum Section: String, CaseIterable {
        case unsigned = "未签名"
        case signed = "已签名"
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 12) {
                // 大标题 + 导入按钮
                HStack(alignment: .center) {
                    DSPageHeader(title: "应用", subtitle: "导入 IPA 并完成签名")
                    Spacer()
                    IPAImportMenuButton(
                        appLibraryPresented: $showingImporter,
                        filesPresented: $showingFilesImporter
                    ) {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(DS.primary))
                    }
                }
                .padding(.horizontal, DS.paddingScreen)
                .padding(.top, 8)

                // 分段切换 + 搜索
                VStack(spacing: 10) {
                    DSSegmentedPicker(
                        selection: $selectedSection,
                        options: Section.allCases,
                        title: { $0.rawValue }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    DSSearchField(text: $searchText, placeholder: "搜索应用 / Bundle ID")
                }
                .padding(.horizontal, DS.paddingScreen)

                // 内容
                switch selectedSection {
                case .unsigned:
                    LibraryView(
                        searchText: $searchText,
                        showingImporter: $showingImporter,
                        showingFilesImporter: $showingFilesImporter
                    )
                case .signed:
                    SignedAppsView()
                }
            }
            .background(DS.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: IPAFile.self) { app in
                SigningConfigView(
                    app: app,
                    popToRoot: { navigationPath = NavigationPath() },
                    pushToProgress: { state in
                        navigationPath.append(SigningProgressDestination(state: state, app: app))
                    }
                )
            }
            .navigationDestination(for: SigningProgressDestination.self) { dest in
                SigningProgressView(
                    app: dest.app,
                    certificate: nil,
                    signingState: dest.state,
                    onExit: { navigationPath = NavigationPath() }
                )
            }
            .sheet(isPresented: $showingImporter) {
                InAppFilePicker(
                    allowedExtensions: ["ipa"],
                    title: "选择 IPA 文件"
                ) { url in
                    Task {
                        let manager = IPALibraryManager()
                        do {
                            _ = try await manager.importIPA(from: url)
                        } catch {
                            print("导入失败: \(error.localizedDescription)")
                        }
                        await appState.refreshLibrary()
                    }
                }
            }
            .ipaFileImporter(isPresented: $showingFilesImporter) {
                Task { await appState.refreshLibrary() }
            }
        }
    }
}

/// 签名进度页的导航目标
struct SigningProgressDestination: Hashable {
    let id = UUID()
    let state: SigningState
    let app: IPAFile

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SigningProgressDestination, rhs: SigningProgressDestination) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 已签名应用列表

struct SignedAppsView: View {
    @EnvironmentObject var appState: AppState

    @State private var selectedTask: SigningTask?
    @State private var showingActions = false
    @State private var showingDetail = false

    private var signedTasks: [SigningTask] {
        appState.signingTasks.filter { $0.status == .completed }
    }

    var body: some View {
        Group {
            if signedTasks.isEmpty {
                DSEmptyState(
                    icon: "checkmark.seal",
                    title: "暂无已签名应用",
                    message: "在「未签名」中选择 IPA 完成签名后\n应用会出现在这里"
                )
            } else {
                List {
                    ForEach(signedTasks) { task in
                        Button {
                            selectedTask = task
                            showingActions = true
                        } label: {
                            SignedAppRow(task: task)
                        }
                        .buttonStyle(.plain)
                        .dsRowCard()
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteTask(task)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .confirmationDialog("操作", isPresented: $showingActions, presenting: selectedTask) { task in
            Button("安装") {
                installApp(task)
            }
            Button("详细") {
                selectedTask = task
                showingDetail = true
            }
            Button("分享") {
                shareApp(task)
            }
            Button("查看文件位置") {
                showInFiles(task)
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showingDetail) {
            if let task = selectedTask {
                SignedAppDetailView(task: task)
            }
        }
    }

    private func deleteTask(_ task: SigningTask) {
        // 删除签名后的文件
        if let url = task.outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        appState.signingTasks.removeAll { $0.id == task.id }
    }

    private func installApp(_ task: SigningTask) {
        guard let url = task.outputURL else { return }
        // 安装等待确认期间保活
        BackgroundKeepAlive.shared.start(reason: .installing)
        IPAInstaller.install(
            ipaURL: url,
            appName: task.options.newDisplayName ?? task.ipaFile.name,
            bundleID: task.options.newBundleID ?? task.ipaFile.bundleID,
            version: task.options.newVersion ?? task.ipaFile.version
        ) { _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                BackgroundKeepAlive.shared.stop(reason: .installing)
            }
        }
    }

    private func shareApp(_ task: SigningTask) {
        guard let url = task.outputURL else { return }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }

    private func showInFiles(_ task: SigningTask) {
        guard let url = task.outputURL else { return }
        // 跳转到文件管理 Tab 并导航到文件所在目录
        appState.navigateToFolder = url.deletingLastPathComponent()
        appState.selectedTab = .files
    }
}

// MARK: - 已签名行组件

struct SignedAppRow: View {
    let task: SigningTask

    private var signTimeString: String {
        guard let end = task.endTime else { return "" }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.string(from: end)
    }

    var body: some View {
        HStack(spacing: 12) {
            // 应用图标
            if let icon = task.ipaFile.icon {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: DS.cornerS, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: DS.cornerS, style: .continuous)
                    .fill(DS.primarySoft)
                    .frame(width: 50, height: 50)
                    .overlay {
                        Image(systemName: "app.fill")
                            .font(.title2)
                            .foregroundStyle(DS.primary)
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(task.options.newDisplayName ?? task.ipaFile.name)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)

                Text("v\(task.options.newVersion ?? task.ipaFile.version) · \(task.certificate.name)")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)

                Text(signTimeString)
                    .font(.caption2)
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.textTertiary)
        }
    }
}

// MARK: - 已签名应用详情

struct SignedAppDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let task: SigningTask

    var body: some View {
        NavigationStack {
            List {
                Section("应用信息") {
                    detailRow("名称", task.options.newDisplayName ?? task.ipaFile.name)
                    detailRow("Bundle ID", task.options.newBundleID ?? task.ipaFile.bundleID)
                    detailRow("版本", task.options.newVersion ?? task.ipaFile.version)
                }
                Section("签名信息") {
                    detailRow("证书", task.certificate.name)
                    detailRow("Team ID", task.certificate.teamID)
                    if let profile = task.certificate.profileName {
                        detailRow("描述文件", profile)
                    }
                }
                Section("文件信息") {
                    if let url = task.outputURL {
                        detailRow("文件名", url.lastPathComponent)
                        detailRow("路径", url.path)
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                           let size = attrs[.size] as? Int64 {
                            detailRow("大小", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                    }
                    if let end = task.endTime {
                        detailRow("签名时间", end.formatted(date: .abbreviated, time: .shortened))
                    }
                    detailRow("耗时", task.durationFormatted)
                }
                Section("签名日志") {
                    ForEach(task.logs) { log in
                        Text(log.message)
                            .font(.system(.caption2, design: .monospaced))
                    }
                }
            }
            .navigationTitle("详细信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
