import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import ZIPFoundation

/// 文件管理器页面
///
/// 对应旧版的「文件夹」功能，提供：
/// - 浏览 Documents 目录下的所有文件
/// - 文件排序（名称/大小/日期）
/// - 文件操作（删除、移动、分享、预览）
/// - 文件类型识别和图标显示
/// - WiFi 文件传输入口
struct FileManagerView: View {
    @EnvironmentObject var appState: AppState

    /// 当前浏览的目录路径
    let directoryURL: URL

    /// 是否为根目录
    let isRoot: Bool

    /// 文件列表
    @State private var files: [FileItem] = []

    /// 排序方式
    @State private var sortOrder: SortOrder = .name

    /// 是否正在加载
    @State private var isLoading = true

    /// 预览文件的 URL
    @State private var previewURL: URL?

    /// 是否显示预览
    @State private var showingPreview = false

    /// 是否显示删除确认
    @State private var fileToDelete: FileItem?
    @State private var showingDeleteConfirm = false

    /// 搜索关键词
    @State private var searchText = ""

    /// 文件操作相关状态
    @State private var selectedFile: FileItem?
    @State private var showFileActions = false
    @State private var showIPAActions = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showFolderPicker = false
    @State private var folderPickerMode: FolderPickerMode = .copy
    @State private var showShareSheet = false

    /// 是否显示文件导入选择器
    @State private var showDocumentPicker = false

    /// 证书/描述文件操作菜单
    @State private var showCertActions = false
    /// P12 密码输入
    @State private var showPasswordAlert = false
    @State private var p12Password = ""
    /// 十六进制查看器
    @State private var showHexViewer = false
    /// Plist 编辑器
    @State private var showPlistEditor = false
    /// Mach-O 检视器
    @State private var showMachOInspector = false

    /// Toast 提示
    @State private var toastMessage = ""
    @State private var showToast = false

    enum FolderPickerMode { case copy, move }

    /// 应用内部目录名单（不在文件管理器显示）。
    /// 只隐藏证书和描述文件目录，其余保留。
    private static let hiddenInternalFolders: Set<String> = [
        "Certificates",
        "Profiles",
    ]

    /// 需要在根目录直接展示的 YSign 子目录（虚拟提升到一级）
    private static let promotedYSignFolders: [String] = [
        "Downloads",
        "Sources",
    ]

    /// 合并到 AppFolder 虚拟文件夹中展示的子目录
    private static let appFolderSubDirs: [String] = [
        "Library",
        "Signed",
    ]

    /// 排序方式枚举
    enum SortOrder: String, CaseIterable {
        case name = "名称"
        case size = "大小"
        case date = "日期"
    }

    /// 根据搜索和排序过滤后的文件列表
    private var filteredFiles: [FileItem] {
        var result = files

        // 搜索过滤
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }

        // 排序（目录始终在前面）
        result.sort { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            switch sortOrder {
            case .name: return a.name.localizedCompare(b.name) == .orderedAscending
            case .size: return a.fileSize > b.fileSize
            case .date: return a.modifiedDate > b.modifiedDate
            }
        }

        return result
    }

    /// 使用根目录初始化（显示 Documents 根作为一级目录）
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.directoryURL = docs
        self.isRoot = true
    }

    /// 使用指定目录初始化（进入子目录时使用）
    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.isRoot = false
    }

    /// 导航路径（用于跨 Tab 跳转到指定文件夹）
    @State private var navigationPath = NavigationPath()

    var body: some View {
        Group {
            if isRoot {
                NavigationStack(path: $navigationPath) {
                    fileListContent
                        .navigationTitle("文件")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { rootToolbar }
                        .navigationDestination(for: URL.self) { url in
                            FileManagerView(directoryURL: url)
                        }
                }
                .onReceive(appState.$navigateToFolder) { folder in
                    guard let folder else { return }
                    navigationPath = NavigationPath()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        navigationPath.append(folder)
                        appState.navigateToFolder = nil
                    }
                }
            } else {
                fileListContent
                    .navigationTitle(directoryURL.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { loadFiles() }
        .searchable(text: $searchText, prompt: "搜索文件")
        .refreshable { loadFiles() }
        .scrollContentBackground(.hidden)
        .background(DS.background.ignoresSafeArea())
        .tint(DS.primary)
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPickerView(
                onPick: { urls in
                    importFiles(urls)
                },
                onDismiss: {
                    showDocumentPicker = false
                }
            )
        }
        // Toast 提示
        .overlay(alignment: .top) {
            if showToast {
                Text(toastMessage)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { showToast = false }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showToast)
    }

    // MARK: - 子视图

    /// 文件列表内容
    private var fileListContent: some View {
        Group {
            if files.isEmpty && !isLoading {
                DSEmptyState(
                    icon: "folder",
                    title: "文件夹为空",
                    message: "点击右上角 + 导入文件，或使用 WiFi 传输",
                    actionTitle: "导入文件",
                    action: { showDocumentPicker = true }
                )
            } else {
                List {
                    if isRoot { storageSection }

                    ForEach(filteredFiles) { file in
                        fileRow(file)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    fileToDelete = file
                                    showingDeleteConfirm = true
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        // 删除确认
        .overlay {
            if showingDeleteConfirm {
                BottomActionSheet(isPresented: $showingDeleteConfirm, title: fileToDelete?.name) {
                    BottomActionButton(title: "删除", isDestructive: true) {
                        if let file = fileToDelete { deleteFile(file) }
                    }
                }
            }
        }
        // 文件/文件夹通用操作菜单
        .overlay {
            if showFileActions, let file = selectedFile {
                BottomActionSheet(isPresented: $showFileActions, title: file.name) {
                    BottomActionButton(title: "分享") {
                        showShareSheet = true
                    }
                    BottomActionButton(title: "复制到") {
                        folderPickerMode = .copy
                        showFolderPicker = true
                    }
                    BottomActionButton(title: "移动到") {
                        folderPickerMode = .move
                        showFolderPicker = true
                    }
                    BottomActionButton(title: "压缩") {
                        compressFile(file)
                    }
                    if file.url.pathExtension.lowercased() == "plist" {
                        BottomActionButton(title: "Plist 编辑器") {
                            showPlistEditor = true
                        }
                    }
                    if isMachOFile(file) {
                        BottomActionButton(title: "Mach-O 检视器") {
                            showMachOInspector = true
                        }
                    }
                    BottomActionButton(title: "重命名") {
                        renameText = file.name
                        showRenameAlert = true
                    }
                    BottomActionButton(title: "删除", isDestructive: true) {
                        deleteFile(file)
                    }
                }
            }
        }
        // 证书/描述文件操作菜单
        .overlay {
            if showCertActions, let file = selectedFile {
                BottomActionSheet(isPresented: $showCertActions, title: file.name) {
                    BottomActionButton(title: "导入证书库") {
                        if file.url.pathExtension.lowercased() == "p12" || file.url.pathExtension.lowercased() == "pfx" {
                            p12Password = ""
                            showPasswordAlert = true
                        } else {
                            importProvisionToCertStore(file)
                        }
                    }
                    BottomActionButton(title: "查看") {
                        previewURL = file.url
                        showingPreview = true
                    }
                    BottomActionButton(title: "十六进制编辑器") {
                        showHexViewer = true
                    }
                    BottomActionButton(title: "分享") {
                        showShareSheet = true
                    }
                    BottomActionButton(title: "删除", isDestructive: true) {
                        deleteFile(file)
                    }
                }
            }
        }
        // IPA / 压缩包操作菜单
        .overlay {
            if showIPAActions, let file = selectedFile {
                if file.isIPA {
                    BottomActionSheet(isPresented: $showIPAActions, title: file.name) {
                        BottomActionButton(title: "导入应用库") {
                            importToLibrary(file)
                        }
                        BottomActionButton(title: "解压") {
                            unzipFile(file)
                        }
                        BottomActionButton(title: "分享") {
                            showShareSheet = true
                        }
                        BottomActionButton(title: "删除", isDestructive: true) {
                            deleteFile(file)
                        }
                    }
                } else {
                    BottomActionSheet(isPresented: $showIPAActions, title: file.name) {
                        BottomActionButton(title: "解压") {
                            unzipFile(file)
                        }
                        BottomActionButton(title: "分享") {
                            showShareSheet = true
                        }
                        BottomActionButton(title: "删除", isDestructive: true) {
                            deleteFile(file)
                        }
                    }
                }
            }
        }
        // 重命名
        .sheet(isPresented: $showRenameAlert) {
            RenameSheetView(name: $renameText) {
                renameFile()
            }
            .presentationDetents([.height(180)])
        }
        // 分享
        .sheet(isPresented: $showShareSheet) {
            if let file = selectedFile {
                ShareSheet(items: [file.url])
            }
        }
        // P12 密码输入
        .alert("输入 P12 密码", isPresented: $showPasswordAlert) {
            SecureField("密码", text: $p12Password)
            Button("导入") {
                if let file = selectedFile {
                    importP12ToCertStore(file, password: p12Password)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请输入 P12 证书的密码")
        }
        // 十六进制查看器
        .sheet(isPresented: $showHexViewer) {
            if let file = selectedFile {
                HexViewerView(fileURL: file.url)
            }
        }
        // Plist 编辑器
        .sheet(isPresented: $showPlistEditor) {
            if let file = selectedFile {
                PlistEditorView(fileURL: file.url)
            }
        }
        // Mach-O 检视器
        .sheet(isPresented: $showMachOInspector) {
            if let file = selectedFile {
                MachOInspectorView(fileURL: file.url)
            }
        }
        // 文件夹选择器
        .sheet(isPresented: $showFolderPicker) {
            if let file = selectedFile {
                FolderPickerView(
                    sourceFile: file,
                    mode: folderPickerMode,
                    rootURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!,
                    onComplete: {
                        loadFiles()
                        showFolderPicker = false
                    }
                )
            }
        }
    }

    /// 存储空间信息
    private var storageSection: some View {
        Section {
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
               let total = attrs[.systemSize] as? Int64,
               let free = attrs[.systemFreeSize] as? Int64 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        DSIconBadge(systemName: "internaldrive", size: 36)
                        Text("存储空间")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(DS.text)
                        Spacer()
                        Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) 可用")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(DS.textSecondary)
                    }

                    let used = Double(total - free) / Double(total)
                    ProgressView(value: used)
                        .tint(used > 0.9 ? DS.destructive : DS.primary)
                }
            }
        }
    }

    /// 根目录工具栏
    @ToolbarContentBuilder
    private var rootToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 16) {
                Button {
                    showDocumentPicker = true
                } label: {
                    Image(systemName: "plus")
                }
                Menu {
                    Picker("排序", selection: $sortOrder) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
    }

    /// 文件行
    @ViewBuilder
    private func fileRow(_ file: FileItem) -> some View {
        if file.isDirectory {
            NavigationLink(value: file.url) {
                fileRowLabel(file)
            }
        } else if file.isIPA || file.isArchive {
            // IPA / ZIP 等压缩包：点击弹出操作菜单（含解压）
            Button {
                selectedFile = file
                showIPAActions = true
            } label: {
                fileRowLabel(file)
            }
            .foregroundColor(.primary)
        } else if file.isCertFile {
            // P12/mobileprovision 文件：点击弹出证书操作菜单
            Button {
                selectedFile = file
                showCertActions = true
            } label: {
                fileRowLabel(file)
            }
            .foregroundColor(.primary)
        } else {
            // 其他文件：点击预览
            Button {
                previewURL = file.url
                showingPreview = true
            } label: {
                fileRowLabel(file)
            }
            .foregroundColor(.primary)
            .quickLookPreview($previewURL)
        }
    }

    /// 文件行内容（含右侧 ••• 操作按钮）
    private func fileRowLabel(_ file: FileItem) -> some View {
        HStack(spacing: 12) {
            // 文件类型图标（品牌底座）
            DSIconBadge(systemName: file.icon, color: file.iconColor, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if !file.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))
                    } else {
                        Text("\(file.childCount) 项")
                    }
                    Text(file.modifiedDate, style: .date)
                }
                .font(.caption)
                .foregroundStyle(DS.textSecondary)
            }

            Spacer()

            // ••• 操作按钮
            Button {
                selectedFile = file
                showFileActions = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(DS.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 操作

    /// 加载当前目录的文件列表
    private func loadFiles() {
        isLoading = true
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            files = []
            isLoading = false
            return
        }

        // 在根目录：隐藏 YSign 文件夹，但把其中指定子目录提升到一级显示
        let docsRoot = fm.urls(for: .documentDirectory, in: .userDomainMask).first!.standardizedFileURL
        let isAtDocsRoot = directoryURL.standardizedFileURL.path == docsRoot.path

        // 如果在 YSign 内部，隐藏 Certificates / Profiles
        let ysignDir = docsRoot.appendingPathComponent("YSign").standardizedFileURL.path
        let isInYSignDir = directoryURL.standardizedFileURL.path == ysignDir

        var items: [FileItem] = contents.compactMap { url in
            // 根目录隐藏 YSign 文件夹本身
            if isAtDocsRoot && url.lastPathComponent == "YSign" {
                return nil
            }
            // YSign 内部隐藏工作目录
            if isInYSignDir && Self.hiddenInternalFolders.contains(url.lastPathComponent) {
                return nil
            }
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey
            ])
            let isDir = values?.isDirectory ?? false
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.contentModificationDate ?? Date()

            // 计算子项数量（仅目录）
            var childCount = 0
            if isDir {
                childCount = (try? fm.contentsOfDirectory(atPath: url.path))?.count ?? 0
            }

            return FileItem(
                url: url,
                name: url.lastPathComponent,
                isDirectory: isDir,
                fileSize: size,
                modifiedDate: date,
                childCount: childCount
            )
        }

        // 根目录时，把 YSign 下的指定子目录提升到一级显示
        if isAtDocsRoot {
            let ysignURL = docsRoot.appendingPathComponent("YSign")
            for folderName in Self.promotedYSignFolders {
                let folderURL = ysignURL.appendingPathComponent(folderName)
                if fm.fileExists(atPath: folderURL.path) {
                    let childCount = (try? fm.contentsOfDirectory(atPath: folderURL.path))?.count ?? 0
                    let values = try? folderURL.resourceValues(forKeys: [.contentModificationDateKey])
                    let date = values?.contentModificationDate ?? Date()
                    items.append(FileItem(
                        url: folderURL,
                        name: folderName,
                        isDirectory: true,
                        fileSize: 0,
                        modifiedDate: date,
                        childCount: childCount
                    ))
                }
            }

            // 虚拟 AppFolder（包含 Library + Signed）
            let appFolderURL = ysignURL.appendingPathComponent("AppFolder")
            try? fm.createDirectory(at: appFolderURL, withIntermediateDirectories: true)
            let appChildCount = Self.appFolderSubDirs.reduce(0) { count, name in
                let url = ysignURL.appendingPathComponent(name)
                return count + ((try? fm.contentsOfDirectory(atPath: url.path))?.count ?? 0)
            }
            items.append(FileItem(
                url: appFolderURL,
                name: "AppFolder",
                isDirectory: true,
                fileSize: 0,
                modifiedDate: Date(),
                childCount: appChildCount
            ))
        }

        // 进入 AppFolder 时，显示 Library 和 Signed
        let ysignURL2 = docsRoot.appendingPathComponent("YSign")
        let appFolderPath = ysignURL2.appendingPathComponent("AppFolder").standardizedFileURL.path
        if directoryURL.standardizedFileURL.path == appFolderPath {
            items.removeAll()
            for folderName in Self.appFolderSubDirs {
                let folderURL = ysignURL2.appendingPathComponent(folderName)
                if fm.fileExists(atPath: folderURL.path) {
                    let childCount = (try? fm.contentsOfDirectory(atPath: folderURL.path))?.count ?? 0
                    let values = try? folderURL.resourceValues(forKeys: [.contentModificationDateKey])
                    let date = values?.contentModificationDate ?? Date()
                    items.append(FileItem(
                        url: folderURL,
                        name: folderName,
                        isDirectory: true,
                        fileSize: 0,
                        modifiedDate: date,
                        childCount: childCount
                    ))
                }
            }
        }

        files = items
        isLoading = false
    }

    /// 显示 Toast
    private func showToastMessage(_ message: String) {
        toastMessage = message
        withAnimation { showToast = true }
    }

    /// 导入文件到当前目录
    private func importFiles(_ urls: [URL]) {
        let fm = FileManager.default
        // 确保目标目录存在
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var successCount = 0
        for url in urls {
            var dest = directoryURL.appendingPathComponent(url.lastPathComponent)
            do {
                // 如果已存在同名文件，自动重命名
                if fm.fileExists(atPath: dest.path) {
                    let name = url.deletingPathExtension().lastPathComponent
                    let ext = url.pathExtension
                    var counter = 1
                    while fm.fileExists(atPath: dest.path) {
                        let newName = ext.isEmpty ? "\(name)(\(counter))" : "\(name)(\(counter)).\(ext)"
                        dest = directoryURL.appendingPathComponent(newName)
                        counter += 1
                    }
                }
                try fm.copyItem(at: url, to: dest)
                successCount += 1
            } catch {
                print("文件导入失败: \(url.lastPathComponent) - \(error.localizedDescription)")
            }
        }
        loadFiles()
        if successCount > 0 {
            showToastMessage("已导入 \(successCount) 个文件")
        }
    }

    /// 删除文件
    private func deleteFile(_ file: FileItem) {
        try? FileManager.default.removeItem(at: file.url)
        loadFiles()
    }

    /// 重命名文件
    private func renameFile() {
        guard let file = selectedFile, !renameText.isEmpty, renameText != file.name else { return }
        let newURL = file.url.deletingLastPathComponent().appendingPathComponent(renameText)
        try? FileManager.default.moveItem(at: file.url, to: newURL)
        loadFiles()
    }

    /// 压缩文件/文件夹为 zip
    ///
    /// 不能用 NSFileCoordinator(.forUploading)——它只对文件夹打包成 zip，
    /// 对单个文件返回的是原文件本身，会生成「JSON/ipa 原文件改名 .zip」
    /// 的假 zip（解压时报 ArchiveError 13，或 ipa 被解成 Payload 文件夹）。
    /// 改用 ZIPFoundation 的 zipItem 正经打包，文件与目录都支持。
    private func compressFile(_ file: FileItem) {
        Task {
            let zipName = file.name.replacingOccurrences(of: ".\(file.url.pathExtension)", with: "") + ".zip"
            let zipURL = file.url.deletingLastPathComponent().appendingPathComponent(zipName)
            do {
                if FileManager.default.fileExists(atPath: zipURL.path) {
                    try FileManager.default.removeItem(at: zipURL)
                }
                try FileManager.default.zipItem(
                    at: file.url,
                    to: zipURL,
                    shouldKeepParent: true,
                    compressionMethod: .deflate
                )
                showToastMessage("压缩完成")
            } catch {
                showToastMessage("压缩失败: \(error.localizedDescription)")
            }
            loadFiles()
        }
    }

    /// 解压 IPA/ZIP/7z/tar/gz/xz/bz2/deb 文件
    private func unzipFile(_ file: FileItem) {
        let baseName = file.url.deletingPathExtension().lastPathComponent
        let destURL = file.url.deletingLastPathComponent().appendingPathComponent(baseName)

        // 避免重名
        var finalDest = destURL
        var counter = 1
        while FileManager.default.fileExists(atPath: finalDest.path) {
            finalDest = file.url.deletingLastPathComponent().appendingPathComponent("\(baseName)_\(counter)")
            counter += 1
        }

        do {
            try FileManager.default.createDirectory(at: finalDest, withIntermediateDirectories: true)
            let ext = file.url.pathExtension.lowercased()
            if ext == "zip" || ext == "ipa" {
                // ZIP 魔数校验：「JSON 改名 .zip」之类的假 zip 会让
                // unzipItem 报难懂的 ArchiveError 13，提前拦下给明确提示
                let head = (try? Data(contentsOf: file.url, options: [.alwaysMapped]))?.prefix(2)
                guard head == Data("PK".utf8) else {
                    throw CocoaError(
                        .fileReadCorruptFile,
                        userInfo: [NSLocalizedDescriptionKey: "不是有效的 ZIP 文件（文件内容不是 zip 格式）"]
                    )
                }
                // IPA 本质是 ZIP
                try FileManager.default.unzipItem(at: file.url, to: finalDest)
            } else {
                // 7z/tar/gz/xz/bz2/deb 走 ArchiveKit
                _ = try ArchiveKit.extract(archiveURL: file.url, to: finalDest)
            }
            showToastMessage("解压完成")
        } catch {
            // 如果失败清理空目录
            try? FileManager.default.removeItem(at: finalDest)
            showToastMessage("解压失败: \(error.localizedDescription)")
        }
        loadFiles()
    }

    /// 判断文件是否为 Mach-O 二进制（dylib 或无扩展名的可执行文件）
    private func isMachOFile(_ file: FileItem) -> Bool {
        guard !file.isDirectory else { return false }
        let ext = file.url.pathExtension.lowercased()
        if ext == "dylib" || ext == "a" || ext == "so" { return true }
        // 其他文件读魔数判断
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return false }
        defer { handle.closeFile() }
        let magicData = handle.readData(ofLength: 4)
        guard magicData.count == 4 else { return false }
        let magic = magicData.withUnsafeBytes { $0.load(as: UInt32.self) }
        return magic == MachOParser.MH_MAGIC_64 || magic == MachOParser.MH_CIGAM_64
            || magic == MachOParser.MH_MAGIC || magic == MachOParser.MH_CIGAM
            || magic == MachOParser.FAT_MAGIC || magic == MachOParser.FAT_CIGAM
    }

    /// 导入 IPA 到应用库
    private func importToLibrary(_ file: FileItem) {
        Task {
            let manager = IPALibraryManager()
            do {
                _ = try await manager.importIPA(from: file.url)
                await appState.refreshLibrary()
                showToastMessage("已导入应用库: \(file.name)")
            } catch {
                showToastMessage("导入失败: \(error.localizedDescription)")
            }
        }
    }

    /// 导入 P12 到证书库
    private func importP12ToCertStore(_ file: FileItem, password: String) {
        Task {
            let store = CertificateStore()
            do {
                let cert = try await store.importP12(from: file.url, password: password)
                await appState.loadCertificates()
                showToastMessage("证书导入成功: \(cert.name)")
            } catch {
                showToastMessage("证书导入失败: \(error.localizedDescription)")
            }
        }
    }

    /// 导入描述文件（需要先有证书才能关联）
    private func importProvisionToCertStore(_ file: FileItem) {
        Task {
            let store = CertificateStore()
            let certs = await store.loadAll()
            guard let lastCert = certs.last else {
                showToastMessage("请先导入 P12 证书")
                return
            }
            do {
                _ = try await store.linkProfile(certID: lastCert.id, profileURL: file.url)
                await appState.loadCertificates()
                showToastMessage("描述文件导入成功")
            } catch {
                showToastMessage("描述文件导入失败: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 文件项模型

/// 表示文件系统中的一个条目
struct FileItem: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileSize: Int64
    let modifiedDate: Date
    let childCount: Int

    var id: URL { url }

    /// 是否是 IPA 文件
    var isIPA: Bool { url.pathExtension.lowercased() == "ipa" }

    /// 是否是可解压的压缩包（zip/7z/tar/gz/xz/bz2/deb）
    var isArchive: Bool {
        let ext = url.pathExtension.lowercased()
        return ["zip", "7z", "tar", "gz", "tgz", "xz", "bz2", "deb"].contains(ext)
    }

    /// 是否是证书/描述文件
    var isCertFile: Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "p12" || ext == "pfx" || ext == "mobileprovision"
    }

    /// 根据文件扩展名返回对应的 SF Symbol 图标
    var icon: String {
        if isDirectory { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "ipa": return "shippingbox.fill"
        case "p12", "pfx": return "lock.shield.fill"
        case "mobileprovision": return "checkmark.seal.fill"
        case "dylib": return "puzzlepiece.extension.fill"
        case "plist": return "doc.text.fill"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo.fill"
        case "zip": return "doc.zipper"
        case "txt", "md", "log": return "doc.plaintext.fill"
        default: return "doc.fill"
        }
    }

    /// 图标颜色
    var iconColor: Color {
        if isDirectory { return .blue }
        switch url.pathExtension.lowercased() {
        case "ipa": return DS.primary
        case "p12", "pfx": return .orange
        case "mobileprovision": return .green
        case "dylib": return .red
        default: return .gray
        }
    }
}

// MARK: - 文件夹选择器（复制到 / 移动到）

struct FolderPickerView: View {
    let sourceFile: FileItem
    let mode: FileManagerView.FolderPickerMode
    let rootURL: URL
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentURL: URL
    @State private var folders: [URL] = []

    init(sourceFile: FileItem, mode: FileManagerView.FolderPickerMode, rootURL: URL, onComplete: @escaping () -> Void) {
        self.sourceFile = sourceFile
        self.mode = mode
        self.rootURL = rootURL
        self.onComplete = onComplete
        self._currentURL = State(initialValue: rootURL)
    }

    var body: some View {
        NavigationStack {
            List {
                // 选择当前目录
                Button {
                    performAction(to: currentURL)
                } label: {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                        Text(mode == .copy ? "复制到此处" : "移动到此处")
                            .fontWeight(.medium)
                    }
                }

                // 子文件夹列表
                ForEach(folders, id: \.self) { folder in
                    Button {
                        currentURL = folder
                        loadFolders()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.blue)
                            Text(folder.lastPathComponent)
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(mode == .copy ? "复制到" : "移动到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if currentURL != rootURL {
                        Button("返回上级") {
                            currentURL = currentURL.deletingLastPathComponent()
                            loadFolders()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .task { loadFolders() }
        }
    }

    private func loadFolders() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: currentURL, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else {
            folders = []
            return
        }
        folders = contents.filter { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return isDir && url != sourceFile.url
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func performAction(to destFolder: URL) {
        let destURL = destFolder.appendingPathComponent(sourceFile.name)
        let fm = FileManager.default

        // 避免重名
        var finalURL = destURL
        var counter = 1
        while fm.fileExists(atPath: finalURL.path) {
            let ext = sourceFile.url.pathExtension
            let base = sourceFile.url.deletingPathExtension().lastPathComponent
            let newName = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            finalURL = destFolder.appendingPathComponent(newName)
            counter += 1
        }

        do {
            if mode == .copy {
                try fm.copyItem(at: sourceFile.url, to: finalURL)
            } else {
                try fm.moveItem(at: sourceFile.url, to: finalURL)
            }
        } catch {
            print("[FolderPicker] \(mode == .copy ? "复制" : "移动")失败: \(error)")
        }

        onComplete()
        dismiss()
    }
}

// MARK: - 重命名底部弹窗

struct RenameSheetView: View {
    @Binding var name: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("输入新名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .padding(.horizontal)

                Button {
                    onConfirm()
                    dismiss()
                } label: {
                    Text("确定")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()
            }
            .padding(.top, 20)
            .navigationTitle("重命名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { isFocused = true }
        }
    }
}

// MARK: - 底部操作菜单组件（仿 UIAlertController ActionSheet）

struct BottomActionSheet: View {
    @Binding var isPresented: Bool
    let title: String?
    let actions: [ActionItem]

    struct ActionItem: Identifiable {
        let id = UUID()
        let title: String
        let isDestructive: Bool
        let handler: () -> Void
    }

    init(isPresented: Binding<Bool>, title: String?, @ActionBuilder content: () -> [ActionItem]) {
        self._isPresented = isPresented
        self.title = title
        self.actions = content()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 8) {
                Spacer()

                // 操作区
                VStack(spacing: 0) {
                    if let title, !title.isEmpty {
                        Text(title)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 12)
                        Divider()
                    }

                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, item in
                        Button {
                            close()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                item.handler()
                            }
                        } label: {
                            Text(item.title)
                                .font(.body)
                                .foregroundColor(item.isDestructive ? .red : .accentColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        if index < actions.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 8)

                // 取消
                Button {
                    close()
                } label: {
                    Text("取消")
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.2)) { isPresented = false }
    }

    @resultBuilder
    struct ActionBuilder {
        // 以数组为组件类型，支持 if/可选条目
        static func buildExpression(_ item: ActionItem) -> [ActionItem] { [item] }
        static func buildBlock(_ components: [ActionItem]...) -> [ActionItem] {
            components.flatMap { $0 }
        }
        static func buildOptional(_ component: [ActionItem]?) -> [ActionItem] {
            component ?? []
        }
        static func buildEither(first component: [ActionItem]) -> [ActionItem] { component }
        static func buildEither(second component: [ActionItem]) -> [ActionItem] { component }
    }
}

func BottomActionButton(title: String, isDestructive: Bool = false, action: @escaping () -> Void) -> BottomActionSheet.ActionItem {
    BottomActionSheet.ActionItem(title: title, isDestructive: isDestructive, handler: action)
}

// MARK: - UIDocumentPicker 包装（兼容 iOS 16）

struct DocumentPickerView: UIViewControllerRepresentable {
    /// 允许选择的内容类型（默认任意文件；选文件夹时传 [.folder]）
    var contentTypes: [UTType] = [.item, .data, .content]

    /// 是否复制文件到临时目录。iOS 上文件夹选择必须传 false（true 会断言崩溃），
    /// 返回的 URL 需调用方使用安全作用域访问
    var asCopy: Bool = true

    let onPick: ([URL]) -> Void
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: asCopy)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onDismiss: onDismiss)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onDismiss: () -> Void
        init(onPick: @escaping ([URL]) -> Void, onDismiss: @escaping () -> Void) {
            self.onPick = onPick
            self.onDismiss = onDismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
            onDismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss()
        }
    }
}
