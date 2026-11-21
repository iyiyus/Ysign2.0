import SwiftUI

/// 软件源主页面
///
/// 展示所有源的应用列表，右上角可进入软件源管理页面。
/// 与旧版「应用」Tab 对应。
struct AppSourcesView: View {
    @EnvironmentObject var appState: AppState

    /// 是否正在加载
    @State private var isLoading = false

    /// 添加软件源弹窗状态
    @State private var showingAddSource = false

    /// 所有源的全部应用（按权重排序）
    private var allApps: [AppModel] {
        appState.appSources.flatMap { $0.apps }.sorted { $0.weigh > $1.weigh }
    }

    /// 搜索框文本
    @State private var searchText = ""

    /// 搜索过滤后的应用 (主页用)
    private var searchedApps: [AppModel] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allApps }
        return allApps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.sourceName.localizedCaseInsensitiveContains(trimmed)
        }
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
            .background(DS.background.ignoresSafeArea())
            .navigationTitle("软件源")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索应用 / 软件源")
            .toolbar {
                // 进入软件源列表
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SourceListView()
                    } label: {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(DS.primary)
                    }
                }
                // 直接添加软件源
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddSource = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(DS.primary)
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
            .sheet(isPresented: $showingAddSource) {
                AddSourceView()
            }
        }
    }

    // MARK: - 子视图

    /// 空状态（没有添加任何源）
    private var emptyStateView: some View {
        DSEmptyState(
            icon: "globe",
            title: "还没有添加软件源",
            message: "添加一个软件源，浏览并下载其中的应用",
            actionTitle: "添加软件源",
            actionIcon: "plus.circle.fill",
            action: { showingAddSource = true }
        )
    }

    /// 有源但无应用
    private var noAppsView: some View {
        DSEmptyState(
            icon: "app.dashed",
            title: "暂无应用",
            message: "已添加的源暂时没有可用应用"
        )
    }

    /// 应用列表
    private var appListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(searchedApps) { app in
                    AppRow(app: app)
                        .dsRowCard()
                }
            }
            .padding(.vertical, 6)
        }
        .overlay {
            if isLoading && allApps.isEmpty {
                ProgressView("加载中...")
            } else if !searchText.isEmpty && searchedApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(DS.textTertiary)
                    Text("未找到 \"\(searchText)\"")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(DS.textSecondary)
                }
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
    @State private var isLoading = false

    /// 刚复制了链接的源（用于显示"已复制"反馈）
    @State private var copiedSourceURL: String?

    var body: some View {
        Group {
            if appState.appSources.isEmpty && !isLoading {
                DSEmptyState(
                    icon: "globe",
                    title: "暂无软件源",
                    message: "点击右上角 + 号添加"
                )
            } else {
                List {
                    ForEach(appState.appSources) { source in
                        NavigationLink {
                            SourceAppsView(source: source)
                        } label: {
                            SourceRow(source: source)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteSource(source)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                UIPasteboard.general.string = source.sourceURL
                                copiedSourceURL = source.sourceURL
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .overlay(alignment: .bottom) {
                    if copiedSourceURL != nil {
                        Label("已复制源链接", systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .fontWeight(.medium)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                withAnimation { copiedSourceURL = nil }
                            }
                    }
                }
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddSource = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSource) {
            AddSourceView()
        }
        .refreshable {
            isLoading = true
            await appState.refreshSources()
            isLoading = false
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
            // 源图标: 复用带缓存/UA 兜底的加载组件, 失败显示 globe 占位
            CachedAsyncImage(
                url: source.sourceicon,
                placeholderIcon: "globe",
                baseURL: source.sourceURL
            )
            .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: DS.cornerS, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(source.name.isEmpty ? "未知源" : source.name)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(DS.text)

                Text(source.sourceURL)
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            DSCountBadge(count: source.apps.count)
        }
        .padding(.vertical, 4)
    }
}
