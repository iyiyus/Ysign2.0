import SwiftUI

/// Mach-O 检视器（对齐 LCSign 的 MachOKit 检视能力）
///
/// 展示：
/// - 文件格式（FAT/单架构）、架构列表、是否 FairPlay 加密
/// - Load Commands 列表（带人类可读名称）
/// - 依赖的动态库（LC_LOAD_DYLIB 路径）
/// - 原包 entitlements
struct MachOInspectorView: View {
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss

    @State private var errorMessage: String?
    @State private var isFat = false
    @State private var archList: [(name: String, is64Bit: Bool, encrypted: Bool)] = []
    @State private var loadCommands: [(name: String, size: UInt32)] = []
    @State private var dylibs: [String] = []
    @State private var entitlements: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                } else {
                    overviewSection
                    archSection
                    dylibSection
                    loadCommandSection
                    entitlementsSection
                }
            }
            .navigationTitle("Mach-O 检视")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear { parse() }
    }

    // MARK: - 各区块

    private var overviewSection: some View {
        Section("基本信息") {
            InfoRow(title: "文件", value: fileURL.lastPathComponent)
            InfoRow(title: "格式", value: isFat ? "FAT（通用二进制）" : "单架构")
            InfoRow(title: "FairPlay 加密", value: archList.contains { $0.encrypted } ? "是（未砸壳）" : "否")
        }
    }

    private var archSection: some View {
        Section("架构 (\(archList.count))") {
            ForEach(archList.indices, id: \.self) { i in
                InfoRow(
                    title: archList[i].name,
                    value: "\(archList[i].is64Bit ? "64" : "32")位\(archList[i].encrypted ? " · 加密" : "")"
                )
            }
        }
    }

    private var dylibSection: some View {
        Section("依赖动态库 (\(dylibs.count))") {
            if dylibs.isEmpty {
                Text("无 LC_LOAD_DYLIB 依赖")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            ForEach(dylibs, id: \.self) { lib in
                Text(lib)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var loadCommandSection: some View {
        Section("Load Commands (\(loadCommands.count))") {
            ForEach(loadCommands.indices, id: \.self) { i in
                HStack {
                    Text(loadCommands[i].name)
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text("\(loadCommands[i].size)B")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var entitlementsSection: some View {
        if let entitlements {
            Section("Entitlements") {
                Text(entitlements)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
            }
        }
    }

    // MARK: - 解析

    private func parse() {
        do {
            let info = try MachOParser.parse(url: fileURL)
            isFat = info.isFat
            var arches: [(String, Bool, Bool)] = []
            var cmds: [(String, UInt32)] = []
            var libs: [String] = []

            for slice in info.slices {
                let archName = archName(cpuType: slice.cpuType)
                let encrypted = fairPlayEncrypted(slice: slice)
                arches.append((archName, slice.is64Bit, encrypted))

                for lc in slice.loadCommands {
                    cmds.append((Self.loadCommandName(lc.cmd), lc.cmdSize))
                    if lc.cmd == MachOParser.LC_LOAD_DYLIB {
                        if let lib = Self.dylibPath(from: lc.data) {
                            libs.append(lib)
                        }
                    }
                }
            }

            archList = arches
            loadCommands = cmds
            dylibs = libs

            if let ent = try MachOParser.extractEntitlements(url: fileURL) {
                entitlements = ent
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fairPlayEncrypted(slice: MachOParser.Slice) -> Bool {
        let expectedCmd: UInt32 = slice.is64Bit ? MachOParser.LC_ENCRYPTION_INFO_64 : MachOParser.LC_ENCRYPTION_INFO
        for lc in slice.loadCommands where lc.cmd == expectedCmd {
            guard lc.data.count >= 20 else { continue }
            let cryptid = lc.data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
            if cryptid != 0 { return true }
        }
        return false
    }

    private func archName(cpuType: UInt32) -> String {
        switch cpuType {
        case MachOParser.CPU_TYPE_ARM64: return "arm64"
        case MachOParser.CPU_TYPE_ARM: return "armv7/armv7s"
        default: return String(format: "cpu 0x%08X", cpuType)
        }
    }

    // MARK: - 静态辅助

    /// Load Command 人类可读名称
    static func loadCommandName(_ cmd: UInt32) -> String {
        switch cmd {
        case 0x01: return "LC_SEGMENT"
        case 0x0B: return "LC_LOAD_DYLINKER"
        case 0x0C: return "LC_LOAD_DYLIB"
        case 0x0D: return "LC_ID_DYLIB"
        case 0x0E: return "LC_LOAD_WEAK_DYLIB"
        case 0x14: return "LC_LOAD_UPWARD_DYLIB"
        case 0x15: return "LC_VERSION_MIN_MACOSX"
        case 0x16: return "LC_VERSION_MIN_IPHONEOS"
        case 0x18: return "LC_UUID"
        case 0x19: return "LC_SEGMENT_64"
        case 0x1B: return "LC_CODE_SIGNATURE"
        case 0x1C: return "LC_SEGMENT_SPLIT_INFO"
        case 0x21: return "LC_ENCRYPTION_INFO"
        case 0x22: return "LC_DYLD_INFO"
        case 0x23: return "LC_DYLD_INFO_ONLY"
        case 0x25: return "LC_ENCRYPTION_INFO_64"
        case 0x26: return "LC_DYLD_EXPORTS_TRIE"
        case 0x27: return "LC_DYLD_INFO_ONLY_64"
        case 0x28: return "LC_FILESET_ENTRY"
        case 0x29: return "LC_ATOM_INFO"
        case 0x2C: return "LC_DYLD_CHAINED_FIXUPS"
        case 0x2D: return "LC_BUILD_VERSION"
        case 0x2E: return "LC_DYLD_ENVIRONMENT"
        case 0x32: return "LC_LINKER_OPTIMIZATION_HINT"
        case 0x34: return "LC_FUNCTION_STARTS"
        case 0x28 | 0x10000: return "LC_MAIN"
        case 0x1E: return "LC_RPATH"
        case 0x80000018: return "LC_LOAD_WEAK_DYLIB"
        case 0x80000022: return "LC_REEXPORT_DYLIB"
        case 0x80000034: return "LC_LAZY_LOAD_DYLIB"
        default: return String(format: "cmd 0x%X", cmd)
        }
    }

    /// 从 LC_LOAD_DYLIB 数据中提取库路径
    ///
    /// 结构：cmd(4) cmdsize(4) dylib.name.offset(4) timestamp(4) current_version(4) compat_version(4) → [字符串]
    static func dylibPath(from data: Data) -> String? {
        guard data.count > 24 else { return nil }
        let nameOffset = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
        guard Int(nameOffset) < data.count else { return nil }
        let nameData = data.subdata(in: Int(nameOffset)..<data.count)
        // 截断到第一个 NUL
        let bytes = [UInt8](nameData)
        if let zeroIdx = bytes.firstIndex(of: 0) {
            return String(data: Data(bytes[..<zeroIdx]), encoding: .utf8)
        }
        return String(data: nameData, encoding: .utf8)
    }
}

// MARK: - 信息行

private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(.subheadline, design: .monospaced))
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
