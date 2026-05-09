import SwiftUI

/// 资源库页面
///
/// 展示用户导入的所有 IPA 文件，支持：
/// - 网格/列表视图切换
/// - 导入新的 IPA 文件（根据贴牌方配置的导入权限）
/// - 左滑删除
/// - 点击进入签名流程
struct LibraryView: View {
    @EnvironmentObject var appState: AppState

    /// 搜索关键词（从父视图传入）
    @Binding var searchText: String

    /// 是否显示文件导入器（从父视图传入）
    @Binding var showingImporter: Bool

    /// 根据搜索关键词过滤后的 IPA 列表
    private var filteredApps: [IPAFile] {
        if searchText.isEmpty {
            return appState.ipaLibrary
        }
        return appState.ipaLibrary.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            if appState.ipaLibrary.isEmpty {
                emptyStateView
            } else {
                listView
                    .refreshable {
                        await appState.refreshLibrary()
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingImporter) {
            InAppFilePicker(
                allowedExtensions: ["ipa"],
                title: "选择 IPA 文件"
            ) { url in
                handleImportURL(url)
            }
        }
    }

    // MARK: - 子视图

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("还没有导入应用")
                .font(.title2)
                .fontWeight(.medium)

            Text("点击右上角 + 按钮导入 IPA 文件\n或者通过「文件」应用分享到 \(appState.brandConfig.appName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // 贴牌方可以通过 `import_permissions` 关闭导入能力。
            // 这样某些仅作为分发入口的品牌壳，就不会向最终用户暴露手动导入功能。
            if appState.brandConfig.importPermissions {
                Button {
                    showingImporter = true
                } label: {
                    Label("导入 IPA", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            } else {
                Text("当前品牌配置已关闭导入权限")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
    }

    private var listView: some View {
        List {
            ForEach(filteredApps) { app in
                NavigationLink(value: app) {
                    AppListRow(app: app)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        deleteApp(app)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - 操作方法

    private func handleImportURL(_ url: URL) {
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

    private func deleteApp(_ app: IPAFile) {
        Task {
            let manager = IPALibraryManager()
            try? await manager.delete(id: app.id)
            await appState.refreshLibrary()
        }
    }
}

// MARK: - 列表行组件

/// 仿参考图布局：图标 + 三行文字（名称、版本|大小|bundleID、文件名）
struct AppListRow: View {
    let app: IPAFile

    var body: some View {
        HStack(spacing: 12) {
            // 应用图标
            if let icon = app.icon {
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

            // 三行文字
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text("V\(app.version) | \(app.fileSizeFormatted) | \(app.bundleID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(app.fileURL.lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}
