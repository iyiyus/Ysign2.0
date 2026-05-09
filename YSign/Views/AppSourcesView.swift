import SwiftUI

/// 软件源主页面
///
/// 展示所有源的应用列表，右上角可进入软件源管理页面。
/// 与旧版「应用」Tab 对应。
struct AppSourcesView: View {
    @EnvironmentObject var appState: AppState

    /// 是否正在加载
    @State private var isLoading = false

    /// 所有源的全部应用（按权重排序）
    private var allApps: [AppModel] {
        appState.appSources.flatMap { $0.apps }.sorted { $0.weigh > $1.weigh }
    }

    var body: some View {
        NavigationStack {
            Group {
                if appState.appSources.isEmpty && !isLoading {
                    emptyStateView
                } else if allApps.isEmpty && !isLoading {
                    noAppsView
                } else {
                    appListView
                }
            }
            .navigationTitle("软件源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SourceListView()
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                }
            }
            .refreshable {
                await refreshSources()
            }
            .task {
                if appState.appSources.isEmpty {
                    await refreshSources()
                }
            }
        }
    }

    // MARK: - 子视图

    /// 空状态（没有添加任何源）
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "globe")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("还没有添加软件源")
                .font(.title2)
                .fontWeight(.medium)

            Text("点击右上角进入软件源列表添加")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            NavigationLink {
                SourceListView()
            } label: {
                Label("添加软件源", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    /// 有源但无应用
    private var noAppsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "app.dashed")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
            Text("暂无应用")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("已添加的源暂时没有可用应用")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }

    /// 应用列表
    private var appListView: some View {
        List {
            ForEach(allApps) { app in
                AppRow(app: app)
            }
        }
        .listStyle(.plain)
        .overlay {
            if isLoading && allApps.isEmpty {
                ProgressView("加载中...")
            }
        }
    }

    private func refreshSources() async {
        isLoading = true
        await appState.refreshSources()
        isLoading = false
    }
}

// MARK: - 软件源列表管理页面

/// 软件源管理页面
///
/// 展示已添加的源，右上角 + 号添加新源，左滑删除。
struct SourceListView: View {
    @EnvironmentObject var appState: AppState

    @State private var showingAddSource = false
    @State private var newSourceURL = ""
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var isLoading = false

    var body: some View {
        Group {
            if appState.appSources.isEmpty && !isLoading {
                VStack(spacing: 16) {
                    Image(systemName: "globe")
                        .font(.system(size: 50))
                        .foregroundStyle(.secondary)
                    Text("暂无软件源")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("点击右上角 + 号添加")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            } else {
                List {
                    ForEach(appState.appSources) { source in
                        NavigationLink {
                            SourceAppsView(source: source)
                        } label: {
                            SourceRow(source: source)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                deleteSource(source)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .overlay {
                    if isLoading && appState.appSources.isEmpty {
                        ProgressView("加载中...")
                    }
                }
            }
        }
        .navigationTitle("软件源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if appState.brandConfig.importPermissions {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddSource = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .alert("添加软件源", isPresented: $showingAddSource) {
            TextField("输入源地址", text: $newSourceURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("添加") { addSource() }
            Button("取消", role: .cancel) { newSourceURL = "" }
        } message: {
            Text("请输入软件源的 URL 地址")
        }
        .alert("错误", isPresented: $showingError) {
            Button("确定") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .refreshable {
            isLoading = true
            await appState.refreshSources()
            isLoading = false
        }
    }

    private func addSource() {
        // 贴牌配置可禁止用户手动添加软件源。
        // 即使 UI 已隐藏入口，这里仍做一次兜底判断，避免未来其它入口绕过限制。
        guard appState.brandConfig.importPermissions else { return }

        let url = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }

        isLoading = true
        Task {
            let store = AppSourceStore()
            do {
                let source = try await store.addSource(url: url)
                appState.appSources.append(source)
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
            isLoading = false
            newSourceURL = ""
        }
    }

    private func deleteSource(_ source: AppSource) {
        appState.appSources.removeAll { $0.sourceURL == source.sourceURL }
        Task {
            let store = AppSourceStore()
            try? await store.removeSource(url: source.sourceURL)
        }
    }
}

// MARK: - 源列表行组件

/// 单个软件源的展示行
struct SourceRow: View {
    let source: AppSource

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: source.sourceicon)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "globe")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(source.name.isEmpty ? "未知源" : source.name)
                    .font(.body)
                    .fontWeight(.medium)

                Text(source.sourceURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(source.apps.count) 个应用")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
