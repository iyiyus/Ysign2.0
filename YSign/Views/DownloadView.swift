import SwiftUI

/// 下载管理页面
///
/// 展示所有下载任务，支持：
/// - 查看下载进度
/// - 从 URL 添加新下载
/// - 暂停/取消下载
/// - 查看存储空间使用情况
/// - 清除已完成的下载记录
struct DownloadView: View {
    @StateObject private var downloadManager = DownloadManager.shared
    @EnvironmentObject var appState: AppState

    /// 是否显示添加 URL 弹窗
    @State private var showingURLInput = false

    /// 用户输入的下载 URL
    @State private var inputURL = ""

    /// 存储空间描述
    @State private var storageInfo = ""

    var body: some View {
        NavigationStack {
            Group {
                if downloadManager.tasks.isEmpty {
                    emptyStateView
                } else {
                    taskListView
                }
            }
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // 清除已完成
                    if downloadManager.tasks.contains(where: { $0.status == .completed || $0.status == .failed }) {
                        Button {
                            downloadManager.clearCompleted()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }

                    // 添加 URL 下载
                    Button {
                        showingURLInput = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingURLInput) {
                URLInputSheetView(url: $inputURL) {
                    startURLDownload()
                }
                .presentationDetents([.height(200)])
            }
            .task {
                storageInfo = await calculateStorage()
            }
        }
    }

    // MARK: - 子视图

    /// 空状态
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("暂无下载任务")
                .font(.title2)
                .fontWeight(.medium)

            Text("在「软件源」中选择应用下载\n或者输入 IPA 下载链接")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showingURLInput = true
            } label: {
                Label("输入链接下载", systemImage: "link")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    /// 下载任务列表
    private var taskListView: some View {
        List {
            // 存储空间信息
            if !storageInfo.isEmpty {
                Section {
                    HStack {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(.secondary)
                        Text("存储空间")
                        Spacer()
                        Text(storageInfo)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 进行中（下载中 + 暂停 + 等待）
            let activeList = downloadManager.tasks.filter {
                $0.status == .downloading || $0.status == .waiting || $0.status == .paused
            }
            if !activeList.isEmpty {
                Section("进行中") {
                    ForEach(activeList) { task in
                        DownloadTaskRow(task: task, onImport: importToLibrary)
                    }
                }
            }

            // 已完成 / 失败
            let completedList = downloadManager.tasks.filter {
                $0.status == .completed || $0.status == .failed
            }
            if !completedList.isEmpty {
                Section("已完成") {
                    ForEach(completedList) { task in
                        DownloadTaskRow(task: task, onImport: importToLibrary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 操作

    /// 从 URL 开始下载
    private func startURLDownload() {
        let url = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        downloadManager.downloadFromURL(url)
        inputURL = ""
    }

    /// 将下载的文件导入到资源库
    private func importToLibrary(fileURL: URL) {
        Task {
            let manager = IPALibraryManager()
            _ = try? await manager.importIPA(from: fileURL)
            await appState.refreshLibrary()
        }
    }

    /// 计算存储空间
    private func calculateStorage() async -> String {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeSpace = attrs[.systemFreeSize] as? Int64 {
            return "可用 \(ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file))"
        }
        return ""
    }
}

// MARK: - 下载任务行

/// 单个下载任务的展示组件
struct DownloadTaskRow: View {
    let task: DownloadTask
    let onImport: ((URL) -> Void)?

    @EnvironmentObject var appState: AppState
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var showActions = false
    @State private var showShare = false

    init(task: DownloadTask, onImport: ((URL) -> Void)? = nil) {
        self.task = task
        self.onImport = onImport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // 状态图标
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.fileName)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if task.status == .downloading {
                            Text("\(Int(task.progress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if task.totalBytes > 0 {
                                Text("\(ByteCountFormatter.string(fromByteCount: task.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: task.totalBytes, countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            Text(task.status.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if task.totalBytes > 0 {
                                Text(ByteCountFormatter.string(fromByteCount: task.totalBytes, countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Spacer()

                // 操作按钮
                HStack(spacing: 16) {
                    if task.status == .downloading {
                        Button { downloadManager.pauseDownload(id: task.id) } label: {
                            Image(systemName: "pause.fill")
                                .font(.subheadline)
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                    } else if task.status == .paused {
                        Button { downloadManager.resumeDownload(id: task.id) } label: {
                            Image(systemName: "play.fill")
                                .font(.subheadline)
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }

                    Button { downloadManager.removeTask(id: task.id) } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // 进度条
            if task.status == .downloading || task.status == .paused || task.status == .waiting {
                ProgressView(value: task.progress)
                    .tint(task.status == .paused ? .orange : .accentColor)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if task.status == .completed || task.status == .failed {
                showActions = true
            }
        }
        .confirmationDialog(task.fileName, isPresented: $showActions, titleVisibility: .visible) {
            if task.status == .completed, let fileURL = task.localFileURL {
                Button("查看文件位置") {
                    openFileLocation(fileURL)
                }
                Button("导入应用库") {
                    onImport?(fileURL)
                }
                Button("分享") {
                    showShare = true
                }
            }
            Button("删除", role: .destructive) {
                if let fileURL = task.localFileURL {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                downloadManager.removeTask(id: task.id)
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showShare) {
            if let fileURL = task.localFileURL {
                ShareSheet(items: [fileURL])
            }
        }
    }

    /// 打开文件所在目录（切换到文件 Tab 并导航到对应文件夹）
    private func openFileLocation(_ url: URL) {
        appState.navigateToFolder = url.deletingLastPathComponent()
        appState.selectedTab = .files
    }

    /// 状态图标
    private var statusIcon: String {
        switch task.status {
        case .downloading: return "arrow.down.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .waiting: return "clock.fill"
        }
    }

    /// 状态颜色
    private var statusColor: Color {
        switch task.status {
        case .downloading: return .blue
        case .completed: return .green
        case .failed: return .red
        case .paused: return .orange
        case .waiting: return .gray
        }
    }
}

// MARK: - 系统分享

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - URL 输入底部弹窗

struct URLInputSheetView: View {
    @Binding var url: String
    let onDownload: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("https://example.com/app.ipa", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .padding(.horizontal)

                Button {
                    onDownload()
                    dismiss()
                } label: {
                    Text("下载")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal)
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("输入下载地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") {
                        url = ""
                        dismiss()
                    }
                }
            }
            .onAppear { isFocused = true }
        }
    }
}
