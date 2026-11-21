import SwiftUI
import UIKit

/// 添加软件源
///
/// 支持两种录入方式：
/// - 输入：粘贴一段文本（每行一个 URL），自动识别其中所有 URL
/// - 剪贴板：读取当前剪贴板内容并识别 URL
///
/// 识别结果可逐个勾选，一次批量添加多个源。
struct AddSourceView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case input = "输入"
        case clipboard = "剪贴板"
        var id: String { rawValue }
    }

    private struct AddResult {
        var added: [String] = []
        var skipped: [String] = []
        var failed: [(url: String, reason: String)] = []

        var summary: String {
            var lines: [String] = []
            if !added.isEmpty { lines.append("成功添加 \(added.count) 个") }
            if !skipped.isEmpty { lines.append("已存在，跳过 \(skipped.count) 个") }
            for item in failed { lines.append("\(item.url)：\(item.reason)") }
            return lines.joined(separator: "\n")
        }
    }

    @State private var mode: Mode = .input
    @State private var inputText = ""
    @State private var clipboardText = ""
    @State private var selectedURLs: Set<String> = []
    @State private var previousURLs: Set<String> = []
    @State private var isAdding = false
    @State private var progressText = ""
    @State private var result: AddResult?
    @State private var showingResult = false

    /// 当前生效的待识别文本
    private var activeText: String {
        mode == .input ? inputText : clipboardText
    }

    /// 从当前文本识别出的 URL（保序去重）
    private var recognizedURLs: [String] {
        Self.extractURLs(from: activeText)
    }

    private var selectedCount: Int {
        recognizedURLs.filter { selectedURLs.contains($0) }.count
    }

    private var allSelected: Bool {
        !recognizedURLs.isEmpty && selectedCount == recognizedURLs.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("支持明文源、appstore 加密源和 ysign 包装源。一段文本里有多个 URL 会自动识别。")
                        .font(.subheadline)
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    DSSegmentedPicker(
                        selection: $mode,
                        options: Mode.allCases,
                        title: { $0.rawValue }
                    )
                    .frame(maxWidth: .infinity)

                    if mode == .input {
                        inputCard
                    } else {
                        clipboardCard
                    }

                    if !progressText.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(progressText)
                                .font(.footnote)
                                .foregroundStyle(DS.textSecondary)
                        }
                    }

                    if !recognizedURLs.isEmpty {
                        recognizedCard

                        Button {
                            Task { await addSelected() }
                        } label: {
                            if isAdding {
                                ProgressView("正在添加…")
                            } else {
                                Text("添加 \(selectedCount) 个软件源")
                            }
                        }
                        .buttonStyle(DSPrimaryButtonStyle())
                        .disabled(selectedCount == 0 || isAdding)
                        .opacity(selectedCount == 0 ? 0.45 : 1)
                        .padding(.top, 4)
                    } else if mode == .input {
                        DSEmptyState(
                            icon: "magnifyingglass",
                            title: "未识别到 URL",
                            message: "在上面输入或粘贴包含 URL 的文本"
                        )
                    }
                }
                .padding(DS.paddingScreen)
                .padding(.bottom, 20)
            }
            .background(DS.background.ignoresSafeArea())
            .navigationTitle("添加软件源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await addSelected() }
                    } label: {
                        if isAdding {
                            ProgressView()
                        } else {
                            Text("添加").fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedCount == 0 || isAdding ? DS.textTertiary : DS.primary)
                    .disabled(selectedCount == 0 || isAdding)
                }
            }
        }
        .task {
            // 剪贴板里有链接时直接切到剪贴板模式，省去手动切换
            if UIPasteboard.general.hasStrings,
               let text = UIPasteboard.general.string,
               !Self.extractURLs(from: text).isEmpty {
                clipboardText = text
                mode = .clipboard
            }
            refreshSelection()
        }
        .task(id: activeText) { refreshSelection() }
        .alert("添加结果", isPresented: $showingResult) {
            Button("确定") {
                if result?.failed.isEmpty == true { dismiss() }
            }
        } message: {
            Text(result?.summary ?? "")
        }
        .interactiveDismissDisabled(isAdding)
    }

    // MARK: - 输入 / 剪贴板

    private var inputCard: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $inputText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 160)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if inputText.isEmpty {
                Text("粘贴或输入 URL，每行一个：\nhttps://...\nhttps://...")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(DS.textTertiary)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .dsCard(padding: 10)
    }

    private var clipboardCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .foregroundStyle(DS.primary)
                Text("当前剪贴板内容")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(DS.text)
                Spacer()
                Button {
                    clipboardText = UIPasteboard.general.string ?? ""
                } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                        .font(.footnote)
                        .foregroundStyle(DS.primary)
                }
            }

            if clipboardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("剪贴板为空，或尚未允许读取剪贴板")
                    .font(.footnote)
                    .foregroundStyle(DS.textSecondary)
            } else {
                Text(clipboardText)
                    .font(.footnote)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dsCard()
    }

    // MARK: - 识别结果

    private var recognizedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("识别到 \(recognizedURLs.count) 个 URL")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(DS.text)
                Spacer()
                Button(allSelected ? "全不选" : "全选") {
                    if allSelected {
                        selectedURLs.removeAll()
                    } else {
                        selectedURLs = Set(recognizedURLs)
                    }
                }
                .font(.footnote)
                .foregroundStyle(DS.primary)
            }

            Divider()

            ForEach(recognizedURLs, id: \.self) { url in
                Button {
                    if selectedURLs.contains(url) {
                        selectedURLs.remove(url)
                    } else {
                        selectedURLs.insert(url)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedURLs.contains(url)
                              ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(selectedURLs.contains(url)
                                             ? DS.primary : DS.textTertiary)
                        Text(url)
                            .font(.footnote)
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .dsCard()
    }

    // MARK: - 逻辑

    /// 文本变化时同步勾选状态：新识别的 URL 默认勾选，已消失的移除
    private func refreshSelection() {
        let urls = Set(recognizedURLs)
        selectedURLs.subtract(previousURLs.subtracting(urls))
        selectedURLs.formUnion(urls.subtracting(previousURLs))
        previousURLs = urls
    }

    /// 批量添加勾选的源（串行，避免同时写源索引文件）
    private func addSelected() async {
        let targets = recognizedURLs.filter { selectedURLs.contains($0) }
        guard !targets.isEmpty, !isAdding else { return }

        isAdding = true
        defer { isAdding = false }

        let store = AppSourceStore()
        let existing = Set(await store.getSourceURLs())
        var addResult = AddResult()

        for (index, url) in targets.enumerated() {
            progressText = "正在添加 \(index + 1)/\(targets.count)：\(url)"

            if existing.contains(url)
                || appState.appSources.contains(where: { $0.sourceURL == url }) {
                addResult.skipped.append(url)
                continue
            }

            do {
                let source = try await store.addSource(url: url)
                await MainActor.run {
                    if !appState.appSources.contains(where: { $0.sourceURL == source.sourceURL }) {
                        appState.appSources.append(source)
                    }
                }
                addResult.added.append(url)
            } catch {
                addResult.failed.append((url, error.localizedDescription))
            }
        }

        progressText = ""
        result = addResult
        if addResult.failed.isEmpty {
            dismiss()
        } else {
            showingResult = true
        }
    }

    /// 从一段文本中提取所有源 URL（支持纯链接和 ysign:// 包装链接里的 url 参数）
    static func extractURLs(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        var found: [String] = []
        var seen = Set<String>()

        func append(_ raw: String) {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 中文及之后的内容一律截断（避免把后面的说明文字当成 URL）
            if let cut = value.firstIndex(where: { ch in
                ch.unicodeScalars.contains { scalar in
                    (0x3400...0x9FFF).contains(scalar.value)
                        || (0x3000...0x303F).contains(scalar.value)
                        || (0xFF00...0xFFEF).contains(scalar.value)
                }
            }) {
                value = String(value[..<cut])
            }
            // 去掉尾部标点
            let trailing = Set(".,;:!?)]}>'\"，。；：！？、】》〉」』")
            while let last = value.last, trailing.contains(last) {
                value.removeLast()
            }
            guard value.lowercased().hasPrefix("http"),
                  URL(string: value) != nil,
                  !seen.contains(value) else { return }
            seen.insert(value)
            found.append(value)
        }

        // 1. 文本中的 http(s) 直链
        let pattern = #"https?://[^\s"'<>()\[\]{}]+"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                append(ns.substring(with: match.range))
            }
        }

        // 2. ysign:// 等包装链接中名为 url 的 query 参数
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let raw = String(token).trimmingCharacters(
                in: CharacterSet(charactersIn: "<>\"'()[]{}")
            )
            guard let components = URLComponents(string: raw),
                  let scheme = components.scheme?.lowercased(),
                  scheme != "http", scheme != "https",
                  let items = components.queryItems else { continue }
            for item in items where item.name.lowercased().contains("url") {
                guard let value = item.value else { continue }
                let decoded = value.removingPercentEncoding ?? value
                append(decoded)
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let ns = decoded as NSString
                    let matches = regex.matches(
                        in: decoded, range: NSRange(location: 0, length: ns.length)
                    )
                    for match in matches {
                        append(ns.substring(with: match.range))
                    }
                }
            }
        }

        return found
    }
}
