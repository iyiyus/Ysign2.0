import SwiftUI

/// 源内应用列表页面
///
/// 展示某个软件源下的所有可下载应用，支持：
/// - 分类筛选（默认、最新、应用、游戏、影音、工具、插件）
/// - 搜索应用
/// - 点击下载
struct SourceAppsView: View {
    @EnvironmentObject var appState: AppState

    /// 初始注入的源 (用作 fallback / 唯一标识依据)
    let source: AppSource

    /// 搜索关键词
    @State private var searchText = ""

    /// 当前选中的分类
    @State private var selectedCategory = "全部"

    /// 公告是否展开 (默认仅显示 2 行, 点击展开)
    @State private var noticeExpanded = false

    /// 所有分类
    private let categories = ["全部", "最新", "应用", "游戏", "影音", "工具", "插件"]

    /// 实时反映 AppState 中最新的源数据.
    /// 这样在解锁 / 下拉刷新后, 页面会立刻拿到带 downloadURL 的解锁应用,
    /// 而不是停留在初始注入时的快照。
    private var liveSource: AppSource {
        appState.appSources.first(where: { $0.sourceURL == source.sourceURL })
            ?? appState.appSources.first(where: { $0.identifier == source.identifier && !source.identifier.isEmpty })
            ?? source
    }

    /// 过滤后的应用列表
    private var filteredApps: [AppModel] {
        var apps = liveSource.apps

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
            // 公告 (软件源级别): 仅在源声明了 message 时显示
            if !liveSource.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                noticeBar
            }

            // 分类标签栏
            categoryBar

            // 应用列表
            List {
                ForEach(filteredApps) { app in
                    AppRow(app: app, source: liveSource)
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(liveSource.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索应用")
    }

    // MARK: - 子视图

    /// 软件源公告条 (顶部, 可点击展开/收起长文)
    private var noticeBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "megaphone.fill")
                    .font(.caption)
                    .foregroundColor(.accentColor)
                Text("公告")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.accentColor)
                Spacer()
            }
            // 服务端可能返回 \n 转义字符串, FreeSign 会还原成换行;
            // 这里再做一次兜底, 兼容个别源直接传字面 "\n" 的情况。
            Text(formattedNotice)
                .font(.footnote)
                .foregroundColor(.primary)
                .lineLimit(noticeExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation { noticeExpanded.toggle() }
        }
    }

    /// 把可能包含字面 "\n" 的公告还原成真实换行
    private var formattedNotice: String {
        liveSource.message
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "@@@", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
    /// 所属源 (可选). 若不传, 会从 AppState 中按 sourceIdentifier 反查。
    /// 解锁/购买入口需要拿到源级别的 unlockURL / payURL。
    var source: AppSource? = nil

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var downloadManager = DownloadManager.shared

    /// 解锁码输入弹窗状态
    @State private var showingUnlockAlert = false
    @State private var unlockCode = ""

    /// 解锁结果提示
    @State private var showingResultAlert = false
    @State private var resultMessage = ""

    /// 说明是否展开
    @State private var descriptionExpanded = false

    /// 当前解锁请求是否进行中
    @State private var isUnlocking = false

    /// 软件说明: 还原字面 "\n" / "\r\n" 转义后展示
    private var formattedDescription: String {
        app.versionDescription
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 获取所属源 (优先使用显式传入, 否则按 identifier 查找)
    private var resolvedSource: AppSource? {
        if let source { return source }
        return appState.appSources.first { $0.identifier == app.sourceIdentifier }
    }

    /// 当前下载任务（如果正在下载）
    private var activeTask: DownloadTask? {
        downloadManager.tasks.first { $0.url == app.downloadURL && ($0.status == .downloading || $0.status == .waiting) }
    }

    /// 应用大小：源里多为纯字节数（如 "499227034"），转成可读的 MB / GB
    private var formattedSize: String {
        let raw = app.size.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        // 已带单位（如 "210MB"）则原样显示
        guard raw.rangeOfCharacter(from: .letters) == nil,
              let bytes = Double(raw), bytes > 0 else {
            return raw
        }
        let mb = bytes / 1024 / 1024
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        } else if mb >= 1 {
            return String(format: "%.1f MB", mb)
        }
        return String(format: "%.0f KB", bytes / 1024)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                // 应用图标
                CachedAsyncImage(url: app.iconURL, baseURL: resolvedSource?.sourceURL ?? "")
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                // 应用信息
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    // 版本 · 大小（固定一行，不折行）
                    HStack(spacing: 6) {
                        Text("v\(app.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !formattedSize.isEmpty {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(formattedSize)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .lineLimit(1)

                    // 所属软件源：独占一行，避免被版本/按钮挤压截断
                    let sourceName = resolvedSource?.name ?? app.sourceName
                    if !sourceName.isEmpty {
                        Text(sourceName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                .layoutPriority(1)

                Spacer()

                // 下载按钮 / 进度百分比
                if let task = activeTask {
                    Text("\(Int(task.progress * 100))%")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.accentColor)
                        .frame(width: 50)
                } else {
                    actionButton
                }
            }

            // 下载进度条
            if let task = activeTask {
                ProgressView(value: task.progress)
                    .tint(.accentColor)
            }

            // 软件说明（点击展开/收起）
            if !formattedDescription.isEmpty {
                Text(formattedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(descriptionExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            descriptionExpanded.toggle()
                        }
                    }
            }
        }
        .padding(.vertical, 4)
        .alert("来自\(resolvedSource?.name ?? "软件源")的消息", isPresented: $showingUnlockAlert) {
            TextField("请输入解锁码", text: $unlockCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("取消", role: .cancel) { unlockCode = "" }
            Button("获取解锁码") {
                if let payURL = resolvedSource.flatMap({ URL(string: $0.payURL) }) {
                    UIApplication.shared.open(payURL)
                }
                unlockCode = ""
            }
            Button("解锁") {
                performUnlock()
            }
        } message: {
            Text("需要使用解锁码，任意解锁一个即全部解锁")
        }
        .alert("提示", isPresented: $showingResultAlert) {
            Button("好的") {
                // 解锁成功后刷新源, 让带 downloadURL 的应用重新拉下来
                if resultMessage.contains("成功") {
                    Task { await appState.refreshSources() }
                }
            }
        } message: {
            Text(resultMessage)
        }
    }

    /// 主操作按钮: 解锁 / 获取 / 仅展示
    ///
    /// 三种状态:
    /// - `lock=1 && downloadURL=""` && 源里有其他应用已解锁  → 视为源主漏配, 显示"展示"
    /// - `lock=1 && downloadURL=""`                          → 显示"解锁", 点击进入卡密弹窗
    /// - `downloadURL` 非空                                  → 显示"获取", 点击触发下载
    /// - `lock=0 && downloadURL=""`                          → 仅展示项, 显示禁用样式
    @ViewBuilder
    private var actionButton: some View {
        let trimmedDownload = app.downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsUnlock = app.lock && trimmedDownload.isEmpty
        let displayOnly = !app.lock && trimmedDownload.isEmpty

        // 启发式: 同一个源里至少有一个加锁应用已经拿到 downloadURL,
        // 说明该设备的卡密激活有效. 此时还有 lock=1 && downloadURL="" 的应用,
        // 几乎可以断定是源主在后台漏填了下载链接, 不是用户没解锁。
        let sourceAlreadyUnlocked: Bool = {
            guard let s = resolvedSource else { return false }
            return s.apps.contains {
                $0.lock && !$0.downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }()

        if needsUnlock && sourceAlreadyUnlocked {
            // 同源已解锁 -> 这条仍是空, 视为源主未配置
            buttonLabel(text: "展示", color: .secondary)
                .opacity(0.6)
        } else if needsUnlock {
            Button {
                unlockCode = ""
                showingUnlockAlert = true
            } label: {
                buttonLabel(text: "解锁", color: .orange)
            }
            .disabled(isUnlocking)
        } else if displayOnly {
            // 仅展示项, 没有下载入口
            buttonLabel(text: "展示", color: .secondary)
                .opacity(0.6)
        } else {
            Button {
                startDownload()
            } label: {
                buttonLabel(text: "获取", color: .accentColor)
            }
        }
    }

    private func buttonLabel(text: String, color: Color) -> some View {
        Text(text)
            .font(.subheadline)
            .fontWeight(.semibold)
            .frame(width: 60)
            .padding(.vertical, 6)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    private func startDownload() {
        downloadManager.addDownload(
            url: app.downloadURL,
            fileName: app.fileName,
            sourceName: app.sourceName
        )
    }

    /// 调用解锁接口
    private func performUnlock() {
        let code = unlockCode
        unlockCode = ""

        guard let source = resolvedSource else {
            resultMessage = "该软件源不支持解锁"
            showingResultAlert = true
            return
        }

        guard !source.unlockURL.isEmpty else {
            resultMessage = "软件源的解锁地址不正确"
            showingResultAlert = true
            return
        }

        let udid = UserDefaults.standard.string(forKey: "deviceUDID") ?? ""

        isUnlocking = true
        Task {
            let store = AppSourceStore()
            do {
                let result = try await store.unlockSource(
                    unlockURL: source.unlockURL,
                    udid: udid,
                    code: code
                )
                await MainActor.run {
                    isUnlocking = false
                    resultMessage = result.message
                    showingResultAlert = true
                }
            } catch {
                await MainActor.run {
                    isUnlocking = false
                    resultMessage = error.localizedDescription
                    showingResultAlert = true
                }
            }
        }
    }
}

// MARK: - 图标组件（支持 HTTP URL）

/// 支持 HTTP 的图片加载（AsyncImage 对 HTTP 可能失败）
struct CachedAsyncImage: View {
    let url: String
    /// 加载失败时显示的占位图标
    var placeholderIcon: String = "app.fill"
    /// 所属源地址（用于补全 "/uploads/xxx.jpg" 这类相对路径图标）
    var baseURL: String = ""
    @State private var image: UIImage?
    @State private var failed = false

    /// 自定义 URLSession.
    /// 用 `default` 配置 + 自定义 user-agent, 不依赖 `URLSession.shared`,
    /// 避免某些情况下 (低数据模式 / 隐私中继 / WKWebView 共享) HTTP 图标加载失败。
    private static let imageSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024,
            diskPath: "YSignSourceIcons"
        )
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        // 同一图床会并发加载大量图标, 提高每主机连接数, 减少排队超时
        config.httpMaximumConnectionsPerHost = 12
        return URLSession(configuration: config)
    }()

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
                        Image(systemName: placeholderIcon)
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
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { failed = true; return }

        // 构造候选地址：相对路径补全 / http 升级为 https（iOS 上 http 常被 ATS 拦截）
        let candidates = candidateURLs(for: raw)
        guard !candidates.isEmpty else { failed = true; return }

        // 首次失败多为并发排队超时, 稍等后整体重试一次再判定失败
        for attempt in 0..<2 {
            if await attemptLoad(candidates) { return }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        print("[CachedAsyncImage] 加载失败: \(raw)")
        failed = true
    }

    /// 依次尝试候选地址（含浏览器 UA 兜底）
    private func attemptLoad(_ candidates: [URL]) async -> Bool {
        for requestURL in candidates {
            if await tryLoad(requestURL) {
                print("[CachedAsyncImage] 加载成功: \(requestURL)")
                return true
            }

            // 兜底: 有些站会在 user-agent 上做拦截, 给一个常见浏览器 UA 再试
            var request = URLRequest(url: requestURL)
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            if let (data, _) = try? await Self.imageSession.data(for: request),
               let ui = UIImage(data: data) {
                image = ui
                return true
            }
        }
        return false
    }

    /// 生成图片加载候选地址（按优先级）
    private func candidateURLs(for raw: String) -> [URL] {
        var result: [URL] = []

        // 相对路径: "/uploads/xxx.jpg" → 用源地址的 host 补全，优先 https
        if raw.hasPrefix("/"),
           let base = URL(string: baseURL), let host = base.host {
            if let secure = URL(string: "https://\(host)\(raw)") { result.append(secure) }
            let originalScheme = base.scheme ?? "https"
            if let original = URL(string: "\(originalScheme)://\(host)\(raw)"),
               original != result.first { result.append(original) }
            return result
        }

        // 绝对地址（兼容含中文 / 空格的 URL）
        let usable: URL?
        if let direct = URL(string: raw) {
            usable = direct
        } else if let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            usable = URL(string: encoded)
        } else {
            usable = nil
        }
        guard let requestURL = usable else { return result }

        // http 优先尝试 https 版本（同一 host/path），失败再回落原始 http
        if requestURL.scheme?.lowercased() == "http",
           var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            if let secure = components.url { result.append(secure) }
        }
        result.append(requestURL)
        return result
    }

    @discardableResult
    private func tryLoad(_ url: URL) async -> Bool {
        do {
            let (data, _) = try await Self.imageSession.data(from: url)
            if let ui = UIImage(data: data) {
                image = ui
                return true
            }
            // 拿到了数据但解不出图片（多半是缓存了 301/错误页），清掉缓存让重试能重新拉
            if !data.isEmpty {
                Self.imageSession.configuration.urlCache?
                    .removeCachedResponse(for: URLRequest(url: url))
            }
        } catch {
            // 走下一个候选地址
        }
        return false
    }
}
