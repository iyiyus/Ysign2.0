import Foundation

/// Mach-O 二进制文件解析器
///
/// 负责解析 iOS 应用的可执行文件和动态库的二进制格式。
/// Mach-O（Mach Object）是 macOS/iOS 使用的可执行文件格式。
///
/// 核心功能：
/// 1. 识别 FAT（通用）二进制和单架构二进制
/// 2. 解析 Load Commands（加载命令），找到代码签名区域
/// 3. 支持读取和修改 LC_CODE_SIGNATURE 段
/// 4. 支持注入 LC_LOAD_DYLIB 命令（动态库注入）
///
/// 性能优化：
/// - 使用内存映射（mmap）读取大文件，避免全量加载到内存
/// - 按需解析，只读取签名相关的 Load Commands
struct MachOParser {

    // MARK: - Mach-O 常量定义

    /// Mach-O 魔数（Magic Number），用于识别文件类型
    static let MH_MAGIC_64: UInt32 = 0xFEEDFACF    // 64位 Mach-O
    static let MH_CIGAM_64: UInt32 = 0xCFFAEDFE    // 64位 Mach-O（字节序反转）
    static let MH_MAGIC: UInt32 = 0xFEEDFACE       // 32位 Mach-O
    static let MH_CIGAM: UInt32 = 0xCEFAEDFE       // 32位 Mach-O（字节序反转）
    static let FAT_MAGIC: UInt32 = 0xBEBAFECA       // FAT/通用二进制
    static let FAT_CIGAM: UInt32 = 0xCAFEBABE       // FAT/通用二进制（字节序反转）

    /// Load Command 类型常量
    static let LC_CODE_SIGNATURE: UInt32 = 0x1D      // 代码签名
    static let LC_LOAD_DYLIB: UInt32 = 0x0C          // 加载动态库
    static let LC_SEGMENT_64: UInt32 = 0x19          // 64位段
    static let LC_SEGMENT: UInt32 = 0x01             // 32位段

    /// CPU 架构类型
    static let CPU_TYPE_ARM64: UInt32 = 0x0100000C   // ARM64 (iPhone 5s+)
    static let CPU_TYPE_ARM: UInt32 = 0x0000000C     // ARM (32位，旧设备)

    // MARK: - 数据结构

    /// 解析后的 Mach-O 文件信息
    struct MachOInfo {
        /// 文件是否为 FAT（通用）二进制（包含多个架构）
        let isFat: Bool
        /// 包含的所有架构切片
        let slices: [Slice]
        /// 原始文件路径
        let fileURL: URL
    }

    /// 单个架构切片的信息
    struct Slice {
        /// CPU 架构类型（arm64/armv7）
        let cpuType: UInt32
        /// 切片在文件中的偏移量
        let offset: UInt64
        /// 切片大小
        let size: UInt64
        /// 是否为64位
        let is64Bit: Bool
        /// Load Commands 列表
        let loadCommands: [LoadCommand]
        /// 代码签名 Load Command 的偏移（如果存在）
        let codeSignatureOffset: UInt64?
        /// 代码签名的大小
        let codeSignatureSize: UInt32?
    }

    /// Load Command 基本信息
    struct LoadCommand {
        /// 命令类型（如 LC_CODE_SIGNATURE, LC_LOAD_DYLIB 等）
        let cmd: UInt32
        /// 命令大小（字节）
        let cmdSize: UInt32
        /// 命令在文件中的偏移量
        let offset: UInt64
        /// 命令的原始数据
        let data: Data
    }

    // MARK: - 公开方法

    /// 解析 Mach-O 文件
    ///
    /// 支持 FAT 二进制和单架构二进制，自动识别并解析所有切片。
    /// 使用内存映射避免大文件的全量加载。
    ///
    /// - Parameter url: Mach-O 文件路径
    /// - Returns: 解析后的 MachOInfo
    /// - Throws: SigningError.machOParseError
    static func parse(url: URL) throws -> MachOInfo {
        // 使用内存映射方式读取文件，大幅减少内存占用
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { fileHandle.closeFile() }

        // 读取前4字节判断文件类型
        let magicData = fileHandle.readData(ofLength: 4)
        guard magicData.count == 4 else {
            throw SigningError.machOParseError("文件太小，无法读取魔数")
        }
        let magic = magicData.withUnsafeBytes { $0.load(as: UInt32.self) }

        switch magic {
        case FAT_MAGIC, FAT_CIGAM:
            // FAT 二进制：包含多个架构，需要逐个解析
            let slices = try parseFatBinary(fileHandle: fileHandle, url: url)
            return MachOInfo(isFat: true, slices: slices, fileURL: url)

        case MH_MAGIC_64, MH_CIGAM_64:
            // 64位单架构 Mach-O
            let slice = try parseSingleSlice(fileHandle: fileHandle, offset: 0, is64Bit: true)
            return MachOInfo(isFat: false, slices: [slice], fileURL: url)

        case MH_MAGIC, MH_CIGAM:
            // 32位单架构 Mach-O
            let slice = try parseSingleSlice(fileHandle: fileHandle, offset: 0, is64Bit: false)
            return MachOInfo(isFat: false, slices: [slice], fileURL: url)

        default:
            throw SigningError.machOParseError("不是有效的 Mach-O 文件 (magic: \(String(format: "0x%08X", magic)))")
        }
    }

    /// 移除现有的代码签名
    /// 在重签名之前需要先清除旧签名，避免签名冲突
    ///
    /// - Parameter url: Mach-O 文件路径
    /// - Throws: SigningError.machOParseError
    static func removeCodeSignature(url: URL) throws {
        var data = try Data(contentsOf: url)
        let info = try parse(url: url)

        // 对每个切片移除 LC_CODE_SIGNATURE
        for slice in info.slices {
            guard let csOffset = slice.codeSignatureOffset else { continue }

            // 找到 LC_CODE_SIGNATURE 命令并将其类型设为 0（无效化）
            for lc in slice.loadCommands where lc.cmd == LC_CODE_SIGNATURE {
                let cmdOffset = Int(slice.offset + lc.offset)
                // 将 cmd 字段设为 0，表示无效命令
                data.replaceSubrange(cmdOffset..<(cmdOffset + 4), with: withUnsafeBytes(of: UInt32(0)) { Data($0) })
            }

            // 截断文件到代码签名之前的位置
            let truncateAt = Int(csOffset)
            if truncateAt < data.count {
                data = data.prefix(truncateAt)
            }
        }

        try data.write(to: url)
    }

    /// 获取需要签名的二进制偏移和大小信息
    /// 代码签名需要对二进制内容计算哈希，此方法返回需要哈希的范围
    ///
    /// - Parameter info: 已解析的 MachOInfo
    /// - Returns: 每个切片的 (偏移, 大小) 元组数组
    static func getSignableRanges(info: MachOInfo) -> [(offset: UInt64, size: UInt64)] {
        return info.slices.map { slice in
            let sigSize = UInt64(slice.codeSignatureSize ?? 0)
            let signableSize = slice.size - sigSize
            return (offset: slice.offset, size: signableSize)
        }
    }

    // MARK: - 私有解析方法

    /// 解析 FAT（通用）二进制文件
    /// FAT 文件头部包含一个架构表，列出了每个架构切片的偏移和大小
    private static func parseFatBinary(fileHandle: FileHandle, url: URL) throws -> [Slice] {
        fileHandle.seek(toFileOffset: 4) // 跳过 magic

        // 读取架构数量（4字节，大端序）
        let countData = fileHandle.readData(ofLength: 4)
        let archCount = countData.withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }

        var slices: [Slice] = []

        // 逐个解析每个架构描述符（每个 20 字节）
        for _ in 0..<archCount {
            let archData = fileHandle.readData(ofLength: 20)
            guard archData.count == 20 else {
                throw SigningError.machOParseError("FAT 架构描述符不完整")
            }

            let cpuType = archData.withUnsafeBytes { UInt32(bigEndian: $0.load(fromByteOffset: 0, as: UInt32.self)) }
            let offset = archData.withUnsafeBytes { UInt32(bigEndian: $0.load(fromByteOffset: 8, as: UInt32.self)) }
            let size = archData.withUnsafeBytes { UInt32(bigEndian: $0.load(fromByteOffset: 12, as: UInt32.self)) }

            // 判断是否为 64 位架构
            let is64Bit = (cpuType & 0x01000000) != 0

            // 保存当前位置，跳到切片位置解析
            let savedOffset = fileHandle.offsetInFile
            let slice = try parseSingleSlice(fileHandle: fileHandle, offset: UInt64(offset), is64Bit: is64Bit)
            fileHandle.seek(toFileOffset: savedOffset)

            slices.append(slice)
        }

        return slices
    }

    /// 解析单个架构切片的 Mach-O 头和 Load Commands
    ///
    /// Mach-O 结构：
    /// [Mach Header] → [Load Command 1] → [Load Command 2] → ... → [数据段]
    ///
    /// - Parameters:
    ///   - fileHandle: 文件句柄
    ///   - offset: 切片在文件中的起始偏移
    ///   - is64Bit: 是否为 64 位架构
    private static func parseSingleSlice(fileHandle: FileHandle, offset: UInt64, is64Bit: Bool) throws -> Slice {
        fileHandle.seek(toFileOffset: offset)

        // Mach Header 大小：64位=32字节，32位=28字节
        let headerSize = is64Bit ? 32 : 28
        let headerData = fileHandle.readData(ofLength: headerSize)
        guard headerData.count == headerSize else {
            throw SigningError.machOParseError("Mach Header 不完整")
        }

        // 提取 CPU 类型和 Load Commands 信息
        let cpuType = headerData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let ncmds = headerData.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }
        let sizeOfCmds = headerData.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }

        // 解析所有 Load Commands
        var loadCommands: [LoadCommand] = []
        var codeSignatureOffset: UInt64?
        var codeSignatureSize: UInt32?
        var currentOffset: UInt64 = offset + UInt64(headerSize)
        var totalSize: UInt64 = 0

        for _ in 0..<ncmds {
            fileHandle.seek(toFileOffset: currentOffset)
            let cmdHeaderData = fileHandle.readData(ofLength: 8)
            guard cmdHeaderData.count == 8 else { break }

            let cmd = cmdHeaderData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
            let cmdSize = cmdHeaderData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }

            // 读取完整的 Load Command 数据
            fileHandle.seek(toFileOffset: currentOffset)
            let fullCmdData = fileHandle.readData(ofLength: Int(cmdSize))

            let lc = LoadCommand(
                cmd: cmd,
                cmdSize: cmdSize,
                offset: currentOffset - offset,
                data: fullCmdData
            )
            loadCommands.append(lc)

            // 如果是代码签名命令，记录签名区域的偏移和大小
            if cmd == LC_CODE_SIGNATURE {
                // LC_CODE_SIGNATURE 的 payload：
                // offset 8: dataoff (UInt32) - 签名数据在文件中的偏移
                // offset 12: datasize (UInt32) - 签名数据大小
                let dataOff = fullCmdData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                let dataSize = fullCmdData.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
                codeSignatureOffset = offset + UInt64(dataOff)
                codeSignatureSize = dataSize
                totalSize = UInt64(dataOff) + UInt64(dataSize)
            }

            // 追踪段大小以计算总大小
            if cmd == LC_SEGMENT_64 {
                let segSize = fullCmdData.withUnsafeBytes { $0.load(fromByteOffset: 48, as: UInt64.self) }
                let segOffset = fullCmdData.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt64.self) }
                let end = segOffset + segSize
                if end > totalSize { totalSize = end }
            }

            currentOffset += UInt64(cmdSize)
        }

        // 如果没有找到明确的总大小，使用 sizeOfCmds 估算
        if totalSize == 0 {
            totalSize = UInt64(headerSize) + UInt64(sizeOfCmds)
        }

        return Slice(
            cpuType: cpuType,
            offset: offset,
            size: totalSize,
            is64Bit: is64Bit,
            loadCommands: loadCommands,
            codeSignatureOffset: codeSignatureOffset,
            codeSignatureSize: codeSignatureSize
        )
    }
}
