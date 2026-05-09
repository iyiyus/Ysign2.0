import SwiftUI

/// 源内应用列表页面
///
/// 展示某个软件源下的所有可下载应用，支持：
/// - 分类筛选（默认、最新、应用、游戏、影音、工具、插件）
/// - 搜索应用
/// - 点击下载
struct SourceAppsView: View {
    @EnvironmentObject var appState: AppState

    /// 当前源
    let source: AppSource

    /// 搜索关键词
    @State private var searchText = ""

    /// 当前选中的分类
    @State private var selectedCategory = "全部"

    /// 所有分类
    private let categories = ["全部", "最新", "应用", "游戏", "影音", "工具", "插件"]

    /// 过滤后的应用列表
    private var filteredApps: [AppModel] {
        var apps = source.apps

        // 按分类过滤
        if selectedCategory != "全部" && selectedCategory != "最新" {
            apps = apps.filter { $0.type == selectedCategory }
        }

        // 按最新排序
        if selectedCategory == "最新" {
            apps = apps.sorted { $0.versionDate > $1.versionDate }
        } else {
            // 按权重排序
            apps = apps.sorted { $0.weigh > $1.weigh }
        }

        // 搜索过滤
        if !searchText.isEmpty {
            apps = apps.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }

        return apps
    }

    var body: some View {
        VStack(spacing: 0) {
            // 分类标签栏
            categoryBar

            // 应用列表
            List {
                ForEach(filteredApps) { app in
                    AppRow(app: app)
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索应用")
    }

    // MARK: - 子视图

    /// 分类标签栏
    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(categories, id: \.self) { category in
                    Button {
                        withAnimation { selectedCategory = category }
                    } label: {
                        Text(category)
                            .font(.subheadline)
                            .fontWeight(selectedCategory == category ? .semibold : .regular)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(selectedCategory == category ? Color.accentColor : Color.clear)
                            )
                            .foregroundColor(selectedCategory == category ? .white : .primary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

// MARK: - 应用行组件

/// 软件源中单个应用的展示行
struct AppRow: View {
    let app: AppModel
    @ObservedObject private var downloadManager = DownloadManager.shared

    /// 当前下载任务（如果正在下载）
    private var activeTask: DownloadTask? {
        downloadManager.tasks.first { $0.url == app.downloadURL && ($0.status == .downloading || $0.status == .waiting) }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                // 应用图标
                CachedAsyncImage(url: app.iconURL)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                // 应用信息
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("v\(app.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !app.size.isEmpty {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(app.size)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                // 下载按钮 / 进度百分比
                if let task = activeTask {
                    Text("\(Int(task.progress * 100))%")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.accentColor)
                        .frame(width: 50)
                } else {
                    Button {
                        startDownload()
                    } label: {
                        Text("获取")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .frame(width: 60)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }

            // 下载进度条
            if let task = activeTask {
                ProgressView(value: task.progress)
                    .tint(.accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    private func startDownload() {
        downloadManager.addDownload(
            url: app.downloadURL,
            fileName: app.fileName,
            sourceName: app.sourceName
        )
    }
}

// MARK: - 图标组件（支持 HTTP URL）

/// 支持 HTTP 的图片加载（AsyncImage 对 HTTP 可能失败）
struct CachedAsyncImage: View {
    let url: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if failed {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "app.fill")
                            .foregroundStyle(.secondary)
                    }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .overlay { ProgressView() }
                    .task { await loadImage() }
            }
        }
    }

    private func loadImage() async {
        guard let requestURL = URL(string: url) else { failed = true; return }
        do {
            let (data, _) = try await URLSession.shared.data(from: requestURL)
            if let uiImage = UIImage(data: data) {
                image = uiImage
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}
