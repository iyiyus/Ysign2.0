import Foundation

/// Dylib 动态库注入器
///
/// 负责将 .dylib 动态库注入到 Mach-O 可执行文件中。
/// 原理：向 Mach-O 的 Load Commands 区域插入 LC_LOAD_DYLIB 命令，
/// 使应用启动时自动加载指定的动态库。
///
/// 注入流程：
/// 1. 解析 Mach-O 头部，找到 Load Commands 区域
/// 2. 检查是否有足够的空间插入新命令（利用 __LINKEDIT 前的 padding）
/// 3. 构建 LC_LOAD_DYLIB 结构
/// 4. 写入新命令并更新头部的 ncmds 和 sizeofcmds 字段
///
/// 常见用途：
/// - 注入越狱插件（tweak.dylib）
/// - 注入调试工具
/// - 注入 Substrate/Substitute 框架
struct DylibInjector {

    // MARK: - Load Command 常量

    /// LC_LOAD_DYLIB: 加载动态库命令类型
    private static let LC_LOAD_DYLIB: UInt32 = 0x0C
    /// LC_LOAD_WEAK_DYLIB: 弱加载（库不存在时不崩溃）
    private static let LC_LOAD_WEAK_DYLIB: UInt32 = 0x80000018

    // MARK: - 注入方式枚举

    /// 注入类型
    enum InjectionType {
        /// 强制加载（如果 dylib 不存在，应用会崩溃）
        case load
        /// 弱加载（如果 dylib 不存在，应用正常运行）
        case weakLoad
    }

    // MARK: - 公开方法

    /// 向 Mach-O 文件注入动态库加载命令
    ///
    /// - Parameters:
    ///   - binaryURL: 目标 Mach-O 可执行文件路径
    ///   - dylibPath: dylib 的加载路径（通常为 @executable_path/Frameworks/xxx.dylib）
    ///   - type: 注入类型（强加载/弱加载）
    /// - Throws: SigningError.injectionFailed
    static func inject(
        binaryURL: URL,
        dylibPath: String,
        type: InjectionType = .load
    ) throws {
        var data = try Data(contentsOf: binaryURL)

        // 解析 Mach-O 判断文件类型
        let machO = try MachOParser.parse(url: binaryURL)

        for slice in machO.slices {
            // 构建 LC_LOAD_DYLIB 命令数据
            let loadCommand = buildLoadDylibCommand(path: dylibPath, type: type)

            // 注入到当前切片
            try injectCommand(loadCommand, into: &data, slice: slice)
        }

        // 写回文件
        try data.write(to: binaryURL)
    }

    /// 检查指定的 dylib 是否已经被注入
    ///
    /// - Parameters:
    ///   - binaryURL: Mach-O 文件路径
    ///   - dylibPath: 要检查的 dylib 路径
    /// - Returns: 如果已注入返回 true
    static func isAlreadyInjected(binaryURL: URL, dylibPath: String) throws -> Bool {
        let machO = try MachOParser.parse(url: binaryURL)

        for slice in machO.slices {
            for lc in slice.loadCommands {
                // 检查是否为 dylib 加载命令
                guard lc.cmd == LC_LOAD_DYLIB || lc.cmd == LC_LOAD_WEAK_DYLIB else { continue }

                // LC_LOAD_DYLIB 结构:
                // cmd(4) + cmdsize(4) + name_offset(4) + timestamp(4) + current_version(4) + compat_version(4) + name_string
                guard lc.data.count > 24 else { continue }
                let nameOffset = lc.data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                let nameStart = Int(nameOffset)
                guard nameStart < lc.data.count else { continue }

                // 提取 dylib 路径字符串（null 结尾）
                let nameData = lc.data[nameStart...]
                if let name = String(data: nameData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) {
                    if name == dylibPath {
                        return true
                    }
                }
            }
        }

        return false
    }

    /// 批量注入多个动态库
    ///
    /// - Parameters:
    ///   - binaryURL: 目标可执行文件
    ///   - dylibs: 要注入的 dylib 路径列表
    ///   - type: 注入类型
    /// - Returns: 成功注入的数量
    @discardableResult
    static func injectMultiple(
        binaryURL: URL,
        dylibs: [String],
        type: InjectionType = .load
    ) throws -> Int {
        var injectedCount = 0
        for dylibPath in dylibs {
            // 跳过已注入的
            if try isAlreadyInjected(binaryURL: binaryURL, dylibPath: dylibPath) {
                continue
            }
            try inject(binaryURL: binaryURL, dylibPath: dylibPath, type: type)
            injectedCount += 1
        }
        return injectedCount
    }

    // MARK: - 私有方法

    /// 构建 LC_LOAD_DYLIB 命令的二进制数据
    ///
    /// 命令结构（按字节排列）:
    /// | 偏移 | 大小 | 字段            | 说明                     |
    /// |------|------|-----------------|--------------------------|
    /// | 0    | 4    | cmd             | 命令类型（0x0C）          |
    /// | 4    | 4    | cmdsize         | 命令总大小（8字节对齐）    |
    /// | 8    | 4    | name.offset     | 路径字符串偏移（=24）      |
    /// | 12   | 4    | timestamp       | 时间戳（通常为2）          |
    /// | 16   | 4    | current_version | 当前版本号                 |
    /// | 20   | 4    | compat_version  | 兼容版本号                 |
    /// | 24   | n    | name            | dylib 路径字符串（null结尾）|
    ///
    /// - Parameters:
    ///   - path: dylib 加载路径
    ///   - type: 注入类型
    /// - Returns: 序列化后的 Load Command 数据
    private static func buildLoadDylibCommand(path: String, type: InjectionType) -> Data {
        let pathBytes = Array(path.utf8) + [0] // null 结尾

        // 计算命令总大小（必须 8 字节对齐）
        let nameOffset: UInt32 = 24 // 固定头部大小
        let rawSize = Int(nameOffset) + pathBytes.count
        let alignedSize = (rawSize + 7) & ~7 // 向上对齐到 8 字节

        var command = Data(capacity: alignedSize)

        // 写入命令类型
        let cmdType: UInt32 = (type == .load) ? LC_LOAD_DYLIB : LC_LOAD_WEAK_DYLIB
        command.appendUInt32LE(cmdType)

        // 写入命令大小
        command.appendUInt32LE(UInt32(alignedSize))

        // 写入路径偏移（固定为 24）
        command.appendUInt32LE(nameOffset)

        // 写入时间戳（2 是常用值）
        command.appendUInt32LE(2)

        // 写入版本号（0x00010000 = 1.0.0）
        command.appendUInt32LE(0x00010000) // current_version
        command.appendUInt32LE(0x00010000) // compat_version

        // 写入路径字符串
        command.append(contentsOf: pathBytes)

        // 填充对齐字节
        let padding = alignedSize - rawSize
        if padding > 0 {
            command.append(Data(repeating: 0, count: padding))
        }

        return command
    }

    /// 将 Load Command 注入到 Mach-O 切片中
    ///
    /// 注入原理：
    /// Mach-O 头部后面紧跟 Load Commands 区域，这个区域的大小在链接时就已确定。
    /// 通常在 Load Commands 和第一个段之间有 padding 空间。
    /// 我们利用这个 padding 插入新的 Load Command，然后更新头部的 ncmds 和 sizeofcmds。
    ///
    /// - Parameters:
    ///   - command: 要注入的 Load Command 数据
    ///   - data: 文件数据（会被修改）
    ///   - slice: 目标切片信息
    private static func injectCommand(_ command: Data, into data: inout Data, slice: MachOParser.Slice) throws {
        let sliceStart = Int(slice.offset)
        let headerSize = slice.is64Bit ? 32 : 28

        // 读取当前的 ncmds 和 sizeofcmds
        let ncmdsOffset = sliceStart + 16
        let sizeOfCmdsOffset = sliceStart + 20
        let currentNCmds = data.withUnsafeBytes { $0.load(fromByteOffset: ncmdsOffset, as: UInt32.self) }
        let currentSizeOfCmds = data.withUnsafeBytes { $0.load(fromByteOffset: sizeOfCmdsOffset, as: UInt32.self) }

        // 计算 Load Commands 区域的结束位置
        let lcEnd = sliceStart + headerSize + Int(currentSizeOfCmds)

        // 检查是否有足够的空间（检查结束位置到第一个段之间的空闲空间）
        // 简化实现：检查要写入的位置是否全为 0（padding 区域）
        let insertAt = lcEnd
        let spaceNeeded = command.count
        let checkRange = insertAt..<min(insertAt + spaceNeeded, data.count)

        // 确保不会越界
        guard checkRange.upperBound <= data.count else {
            throw SigningError.injectionFailed("Mach-O 文件没有足够空间注入 Load Command")
        }

        // 检查插入区域是否为空（全0）
        let existingData = data[checkRange]
        let hasSpace = existingData.allSatisfy { $0 == 0 }
        guard hasSpace else {
            throw SigningError.injectionFailed("Load Command 区域没有足够的 padding 空间")
        }

        // 写入新的 Load Command
        data.replaceSubrange(insertAt..<(insertAt + command.count), with: command)

        // 更新 ncmds（+1）
        let newNCmds = currentNCmds + 1
        withUnsafeBytes(of: newNCmds) { bytes in
            data.replaceSubrange(ncmdsOffset..<(ncmdsOffset + 4), with: bytes)
        }

        // 更新 sizeofcmds（+命令大小）
        let newSizeOfCmds = currentSizeOfCmds + UInt32(command.count)
        withUnsafeBytes(of: newSizeOfCmds) { bytes in
            data.replaceSubrange(sizeOfCmdsOffset..<(sizeOfCmdsOffset + 4), with: bytes)
        }
    }
}

// MARK: - Data 扩展（小端序写入）

extension Data {
    /// 追加一个小端序 UInt32 值（Mach-O 使用小端序）
    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(UnsafeBufferPointer(start: &littleEndian, count: 1))
    }
}
