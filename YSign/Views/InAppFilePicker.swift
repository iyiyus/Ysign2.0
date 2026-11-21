import SwiftUI

/// 应用内文件选择器
///
/// 从应用的 Documents/YSign/ 目录中选择文件
/// 支持按扩展名过滤，递归扫描子目录
struct InAppFilePicker: View {
    /// 允许的文件扩展名（小写），如 ["ipa"], ["p12", "pfx"]
    let allowedExtensions: [String]

    /// 标题
    let title: String

    /// 选择回调
    let onPick: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var files: [PickerFileItem] = []
    @State private var isLoading = true

    struct PickerFileItem: Identifiable {
        let url: URL
        let name: String
        let size: Int64
        let date: Date
        var id: URL { url }

        var sizeFormatted: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }

        var icon: String {
            switch url.pathExtension.lowercased() {
            case "ipa": return "app.gift.fill"
            case "p12", "pfx": return "lock.shield.fill"
            case "mobileprovision": return "checkmark.seal.fill"
            case "dylib": return "puzzlepiece.extension.fill"
            case "zip": return "doc.zipper"
            default: return "doc.fill"
            }
        }

        var iconColor: Color {
            switch url.pathExtension.lowercased() {
            case "ipa": return .purple
            case "p12", "pfx": return .orange
            case "mobileprovision": return .green
            default: return .gray
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("扫描文件...")
                } else if files.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.questionmark")
                            .font(.system(size: 50))
                            .foregroundStyle(.secondary)
                        Text("未找到可用文件")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("请先通过 WiFi 传输或「文件」应用\n将文件导入到 YSign 文件目录")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(files) { file in
                            Button {
                                onPick(file.url)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: file.icon)
                                        .font(.title3)
                                        .foregroundColor(file.iconColor)
                                        .frame(width: 30)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text(file.sizeFormatted)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .task { scanFiles() }
        }
    }

    private func scanFiles() {
        isLoading = true
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let ysignDir = docs.appendingPathComponent("YSign")

        var result: [PickerFileItem] = []

        if let enumerator = FileManager.default.enumerator(
            at: ysignDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard allowedExtensions.contains(ext) else { continue }

                let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                result.append(PickerFileItem(
                    url: fileURL,
                    name: fileURL.lastPathComponent,
                    size: Int64(attrs?.fileSize ?? 0),
                    date: attrs?.contentModificationDate ?? Date()
                ))
            }
        }

        result.sort { $0.date > $1.date }
        files = result
        isLoading = false
    }
}
