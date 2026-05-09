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
    @State private var navigationPath = NavigationPath()

    enum Section: String, CaseIterable {
        case unsigned = "未签名"
        case signed = "已签名"
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                // 标题
                Text("应用")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                // 标签栏 + 导入按钮
                HStack(spacing: 12) {
                    Picker("", selection: $selectedSection) {
                        ForEach(Section.allCases, id: \.self) { section in
                            Text(section.rawValue).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)

                    // 导入按钮受品牌配置控制。
                    // 当贴牌方关闭导入权限时，这里不再允许用户主动选择 IPA 导入。
                    if appState.brandConfig.importPermissions {
                        Button {
                            showingImporter = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.body.weight(.medium))
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 6)

                // 搜索栏
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                .padding(.bottom, 6)

                // 内容
                switch selectedSection {
                case .unsigned:
                    LibraryView(searchText: $searchText, showingImporter: $showingImporter)
                case .signed:
                    SignedAppsView()
                }
            }
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
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 50))
                        .foregroundStyle(.secondary)
                    Text("暂无已签名应用")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("签名完成后会显示在这里")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        IPAInstaller.install(
            ipaURL: url,
            appName: task.options.newDisplayName ?? task.ipaFile.name,
            bundleID: task.options.newBundleID ?? task.ipaFile.bundleID,
            version: task.options.newVersion ?? task.ipaFile.version
        ) { _ in }
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
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .frame(width: 50, height: 50)
                    .overlay {
                        Image(systemName: "app.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(task.options.newDisplayName ?? task.ipaFile.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text("v\(task.options.newVersion ?? task.ipaFile.version) - 签名时间:\(signTimeString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(task.certificate.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
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
