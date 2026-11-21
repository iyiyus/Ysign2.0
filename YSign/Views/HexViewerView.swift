import SwiftUI

/// 十六进制查看器
struct HexViewerView: View {
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var hexLines: [HexLine] = []
    @State private var isLoading = true

    /// 每行显示的字节数
    private let bytesPerRow = 16
    /// 最大加载字节数
    private let maxBytes = 16 * 1024

    struct HexLine: Identifiable {
        let id: Int
        let offset: String
        let hex: String
        let ascii: String
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("加载中...")
                } else if hexLines.isEmpty {
                    Text("文件为空")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(hexLines) { line in
                                HStack(spacing: 0) {
                                    Text(line.offset)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 70, alignment: .leading)
                                    Text(line.hex)
                                        .frame(width: 210, alignment: .leading)
                                    Text(line.ascii)
                                        .foregroundStyle(.orange)
                                }
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 1)
                            }
                        }
                    }
                }
            }
            .navigationTitle(fileURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { loadHex() }
        }
    }

    private func loadHex() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: fileURL) else {
                DispatchQueue.main.async {
                    isLoading = false
                }
                return
            }

            let bytes = [UInt8](data.prefix(maxBytes))
            var lines: [HexLine] = []

            for row in stride(from: 0, to: bytes.count, by: bytesPerRow) {
                let end = min(row + bytesPerRow, bytes.count)
                let chunk = bytes[row..<end]

                let offset = String(format: "%08X", row)

                let hex = chunk.map { String(format: "%02X", $0) }
                    .enumerated()
                    .map { $0.offset > 0 && $0.offset % 8 == 0 ? "  \($0.element)" : " \($0.element)" }
                    .joined()

                let ascii = String(chunk.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })

                lines.append(HexLine(id: row, offset: offset, hex: hex, ascii: ascii))
            }

            DispatchQueue.main.async {
                hexLines = lines
                isLoading = false
            }
        }
    }
}
