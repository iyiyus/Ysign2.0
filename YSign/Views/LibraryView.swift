import SwiftUI
import UniformTypeIdentifiers

/// 资源库页面
///
/// 展示用户导入的所有 IPA 文件，支持：
/// - 网格/列表视图切换
/// - 导入新的 IPA 文件
/// - 左滑删除
/// - 点击进入签名流程
struct LibraryView: View {
    @EnvironmentObject var appState: AppState

    /// 搜索关键词（从父视图传入）
    @Binding var searchText: String

    /// 是否显示应用内文件选择器（从父视图传入）
    @Binding var showingImporter: Bool

    /// 是否显示系统「文件」导入器（从父视图传入）
    @Binding var showingFilesImporter: Bool

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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 子视图

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(DS.primarySoft)
                    .frame(width: 96, height: 96)
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(DS.primary)
            }
            .padding(.bottom, 4)

            Text("还没有导入应用")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(DS.text)

            Text("点击 + 按钮导入 IPA 文件\n或者通过「文件」应用分享到 YSign")
                .font(.subheadline)
                .foregroundStyle(DS.textSecondary)
                .multilineTextAlignment(.center)

            IPAImportMenuButton(
                appLibraryPresented: $showingImporter,
                filesPresented: $showingFilesImporter
            ) {
                Label("导入 IPA", systemImage: "plus")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous)
                            .fill(DS.primary)
                    )
            }
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listView: some View {
        List {
            ForEach(filteredApps) { app in
                NavigationLink(value: app) {
                    AppListRow(app: app)
                }
                .buttonStyle(.plain)
                .dsRowCard()
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
        .scrollContentBackground(.hidden)
        .refreshable {
            await appState.refreshLibrary()
        }
    }

    // MARK: - 操作方法

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

            // 三行文字
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("v\(app.version)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DS.primary)
                    Text(app.fileSizeFormatted)
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                }
                .lineLimit(1)

                Text(app.bundleID)
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

// MARK: - 导入方式菜单（应用库 / 资源管理器）

/// IPA 导入辅助：从系统「文件」App 选择的安全作用域 URL 导入资源库
enum IPAImportHelper {

    /// .ipa 对应的 UTType（无注册类型时回退到通用 Data）
    static var ipaContentTypes: [UTType] {
        // 系统没有内置 ipa UTType，文件 App 通常把 ipa 识别为 zip 归档。
        // 必须用宽集合兜底，否则选中 ipa 后「打开」按钮不可点。
        var types: [UTType] = []
        if let dynamic = UTType(filenameExtension: "ipa", conformingTo: .data) {
            types.append(dynamic)
        }
        types.append(contentsOf: [.zip, .archive, .data])
        return types
    }

    /// 从「文件」App 的 URL 导入 IPA（处理安全作用域访问）
    static func importFromFilesURL(_ url: URL, onDone: @escaping () -> Void) {
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let manager = IPALibraryManager()
            do {
                _ = try await manager.importIPA(from: url)
            } catch {
                print("导入失败: \(error.localizedDescription)")
            }
            await MainActor.run { onDone() }
        }
    }
}

/// 导入方式按钮（锚定式菜单）
///
/// 用 `Menu` 而非 `confirmationDialog`：菜单固定在按钮下方展开，
/// 不会像挂在导航栈根视图上的 dialog 那样被系统当成 popover 飘到页面中间。
struct IPAImportMenuButton<LabelContent: View>: View {
    @Binding var appLibraryPresented: Bool
    @Binding var filesPresented: Bool
    @ViewBuilder let label: () -> LabelContent

    var body: some View {
        Menu {
            Button {
                appLibraryPresented = true
            } label: {
                Label("从应用库中导入", systemImage: "internaldrive")
            }
            Button {
                filesPresented = true
            } label: {
                Label("从资源管理器导入", systemImage: "folder")
            }
        } label: {
            label()
        }
    }
}

/// 系统「文件」导入器修饰器（统一挂在应用页根视图，只挂一份）
struct IPAFileImporter: ViewModifier {
    @Binding var isPresented: Bool
    var onImported: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: IPAImportHelper.ipaContentTypes,
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    IPAImportHelper.importFromFilesURL(url) {
                        onImported?()
                    }
                }
            }
    }
}

extension View {
    func ipaFileImporter(isPresented: Binding<Bool>, onImported: (() -> Void)? = nil) -> some View {
        modifier(IPAFileImporter(isPresented: isPresented, onImported: onImported))
    }
}
