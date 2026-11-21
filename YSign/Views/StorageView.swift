import SwiftUI

/// 存储空间页面
///
/// - 深度分析：Documents / Library / tmp / App Group 全部文件按用途分类
/// - 位置分布：各容器占用占比
/// - 清理项目：按占用排序，可展开单独勾选文件；默认只勾选缓存与临时文件
/// - 底部「清理已选」按钮，高风险项目二次确认
struct StorageView: View {

    @State private var report: StorageAnalyzer.StorageReport?
    @State private var isAnalyzing = true

    /// 已勾选的文件 id（文件绝对路径）
    @State private var selection: Set<String> = []
    /// 已展开的分类
    @State private var expanded: Set<String> = []

    @State private var showConfirm = false
    @State private var resultMessage: String?
    @State private var errorMessage: String?

    private var selectedSize: Int64 {
        report?.selectedSize(selection) ?? 0
    }

    private func sizeText(_ bytes: Int64) -> String {
        bytes == 0 ? "0 KB" : bytes.storageSizeString
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(spacing: 18) {
                        if let report {
                            summaryCard(report)
                            locationsCard(report)
                            categoriesCard(report)
                            footerNote
                        } else if isAnalyzing {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("正在分析存储空间...")
                                    .font(.subheadline)
                                    .foregroundStyle(DS.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "externaldrive.badge.questionmark")
                                    .font(.largeTitle)
                                    .foregroundStyle(DS.textTertiary)
                                Text("暂无可分析的数据")
                                    .font(.subheadline)
                                    .foregroundStyle(DS.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                        }
                    }
                    .padding(DS.paddingScreen)
                    .padding(.bottom, 96)
                }
                .background(DS.background.ignoresSafeArea())

                cleanupBar
            }
            .navigationTitle("存储空间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        analyze()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { analyze() }
        }
        .tint(DS.primary)
        .alert("确认清理", isPresented: $showConfirm) {
            Button("清理", role: .destructive) { performCleanup() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .alert("清理完成", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("好") { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
        .alert("错误", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("确定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 汇总卡

    private func summaryCard(_ report: StorageAnalyzer.StorageReport) -> some View {
        let ratio: Double = report.totalSize > 0
            ? min(1, Double(selectedSize) / Double(report.totalSize))
            : 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("YSign 占用")
                        .font(.system(.headline, design: .rounded))
                    Text("本软件文件、缓存、临时数据与共享容器深度分析")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                }
                Spacer()
                Text(report.totalSize.storageSizeString)
                    .font(.system(.title3, design: .rounded, weight: .bold))
            }

            // 占用分段条：深色为已选择可释放部分
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.primarySoft)
                    Capsule()
                        .fill(DS.primary)
                        .frame(width: max(0, geo.size.width * ratio))
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())

            Text("已选择可释放")
                .font(.caption)
                .foregroundStyle(DS.textSecondary)
            Text(sizeText(selectedSize))
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(DS.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    // MARK: - 位置分布

    private func locationsCard(_ report: StorageAnalyzer.StorageReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("位置分布")
                .font(.system(.headline, design: .rounded))
            ForEach(report.locations) { location in
                let ratio: Double = report.totalSize > 0
                    ? min(1, Double(location.size) / Double(report.totalSize))
                    : 0
                VStack(spacing: 5) {
                    HStack {
                        Text(location.name)
                            .font(.subheadline)
                        Spacer()
                        Text(location.size.storageSizeString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.primarySoft.opacity(0.6))
                            Capsule()
                                .fill(DS.primary)
                                .frame(width: max(2, geo.size.width * ratio))
                        }
                    }
                    .frame(height: 6)
                    .clipShape(Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    // MARK: - 清理项目

    private func categoriesCard(_ report: StorageAnalyzer.StorageReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("清理项目")
                .font(.system(.headline, design: .rounded))
            Text("按占用从大到小排序，展开后可单独勾选文件")
                .font(.caption)
                .foregroundStyle(DS.textSecondary)

            Divider()

            ForEach(report.categories) { category in
                categoryRow(category, report: report)
                if expanded.contains(category.id) {
                    ForEach(category.files) { file in
                        fileRow(file)
                    }
                }
                if category.id != report.categories.last?.id {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func categoryRow(
        _ category: StorageAnalyzer.StorageCategory,
        report: StorageAnalyzer.StorageReport
    ) -> some View {
        let state = categorySelectionState(category)
        let percent = report.totalSize > 0
            ? Int(Double(category.size) / Double(report.totalSize) * 100)
            : 0
        return HStack(spacing: 10) {
            Button {
                toggleCategory(category)
            } label: {
                Image(systemName: state == .all ? "checkmark.circle.fill" : state == .some ? "minus.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(state == .none ? DS.textTertiary : DS.primary)
            }
            .buttonStyle(.plain)

            DSIconBadge(systemName: category.icon, color: iconColor(category), size: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(category.title)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .lineLimit(1)
                    if let badge = category.badge {
                        badgeView(badge, risk: category.risk)
                    }
                }
                Text(category.subtitle)
                    .font(.caption2)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(category.size.storageSizeString)
                    .font(.caption)
                    .fontWeight(.medium)
                    .monospacedDigit()
                Text("\(percent)%")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Image(systemName: expanded.contains(category.id) ? "chevron.down" : "chevron.right")
                .font(.caption)
                .foregroundStyle(DS.textTertiary)
                .frame(width: 18, height: 28)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { toggleExpanded(category.id) }
    }

    private func badgeView(_ text: String, risk: StorageAnalyzer.Risk) -> some View {
        let color: Color = risk == .risky ? .red : DS.accent
        return Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private func fileRow(_ file: StorageAnalyzer.StorageFile) -> some View {
        let isSelected = selection.contains(file.id)
        return HStack(spacing: 10) {
            Button {
                toggleFile(file)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? DS.primary : DS.textTertiary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.caption)
                    .lineLimit(1)
                Text(file.detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Text(file.size.storageSizeString)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.leading, 44)
        .padding(.vertical, 4)
    }

    private var footerNote: some View {
        Text("证书库（P12）、描述文件与软件源订阅列表不参与清理。标记为高风险的项目包含用户数据或配置，清理后无法恢复。")
            .font(.caption2)
            .foregroundStyle(DS.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 底部清理栏

    private var cleanupBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                showConfirm = true
            } label: {
                Text("清理已选 \(sizeText(selectedSize))")
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .disabled(selection.isEmpty)
            .padding(.horizontal, DS.paddingScreen)
            .padding(.vertical, 12)
        }
        .background(DS.background.opacity(0.96))
    }

    // MARK: - 选择逻辑

    enum SelectionState { case none, some, all }

    private func categorySelectionState(_ category: StorageAnalyzer.StorageCategory) -> SelectionState {
        guard !category.files.isEmpty else { return .none }
        let count = category.files.filter { selection.contains($0.id) }.count
        if count == 0 { return .none }
        if count == category.files.count { return .all }
        return .some
    }

    private func toggleCategory(_ category: StorageAnalyzer.StorageCategory) {
        if categorySelectionState(category) == .all {
            for file in category.files { selection.remove(file.id) }
        } else {
            for file in category.files { selection.insert(file.id) }
        }
    }

    private func toggleFile(_ file: StorageAnalyzer.StorageFile) {
        if selection.contains(file.id) {
            selection.remove(file.id)
        } else {
            selection.insert(file.id)
        }
    }

    private func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func iconColor(_ category: StorageAnalyzer.StorageCategory) -> Color {
        switch category.risk {
        case .safe: return DS.primary
        case .reacquirable: return .blue
        case .risky: return .orange
        }
    }

    private var confirmMessage: String {
        guard let report else { return "" }
        let risky = report.categories.filter { category in
            category.risk == .risky &&
            category.files.contains { selection.contains($0.id) }
        }
        var message = "将删除 \(selection.count) 个文件，释放 \(selectedSize.storageSizeString)。"
        if !risky.isEmpty {
            message += "\n\n包含高风险数据：\(risky.map(\.title).joined(separator: "、"))，删除后无法恢复。"
        }
        return message
    }

    // MARK: - 操作

    private func analyze() {
        isAnalyzing = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                StorageAnalyzer.analyze()
            }.value
            await MainActor.run {
                report = result
                isAnalyzing = false
                // 默认只勾选缓存与临时文件
                let defaults = result.categories
                    .first { $0.id == StorageAnalyzer.StorageReport.defaultCategoryID }?
                    .files.map(\.id) ?? []
                selection = Set(defaults)
            }
        }
    }

    private func performCleanup() {
        guard let report else { return }
        let target = selection
        Task {
            let freed = await Task.detached(priority: .userInitiated) {
                StorageAnalyzer.cleanup(selection: target, in: report)
            }.value
            await MainActor.run {
                selection = []
                expanded = []
                resultMessage = "已释放 \(sizeText(freed))，清理 \(target.count) 个文件"
                analyze()
            }
        }
    }
}
