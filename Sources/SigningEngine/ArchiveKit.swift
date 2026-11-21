import Foundation
import SWCompression

/// 归档与压缩包工具 —— 支持 deb / 7z / tar / gz / xz / bz2 解压
///
/// 对齐 LCSign 的解压能力：
/// - deb（AR 归档 → data.tar.xz/gz/bz2 → tar 解包），提取 dylib 用于注入
/// - 7z / tar / gzip / xz / bzip2 压缩包解压到指定目录
struct ArchiveKit {

    // MARK: - 统一入口

    /// 按文件扩展名自动解压归档到目标目录
    ///
    /// - Parameters:
    ///   - archiveURL: 归档文件路径
    ///   - destination: 目标目录（会自动创建）
    /// - Returns: 解出的文件列表
    static func extract(archiveURL: URL, to destination: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        switch archiveURL.pathExtension.lowercased() {
        case "deb":
            return try extractDeb(debURL: archiveURL, to: destination)
        case "7z":
            return try extractSevenZip(sevenZipURL: archiveURL, to: destination)
        case "tar":
            return try extractTar(tarData: try Data(contentsOf: archiveURL), to: destination)
        case "gz":
            return try extractGzip(gzipURL: archiveURL, to: destination)
        case "xz":
            return try extractXz(xzURL: archiveURL, to: destination)
        case "bz2":
            return try extractBzip2(bzip2URL: archiveURL, to: destination)
        default:
            throw SigningError.zipError("不支持的压缩格式: .\(archiveURL.pathExtension)")
        }
    }

    // MARK: - deb 解包

    /// 解包 deb（AR 归档格式）
    ///
    /// deb 内部结构：
    /// ```
    /// debian-binary          — 版本标记
    /// control.tar.{xz,gz}    — 包元数据
    /// data.tar.{xz,gz,bz2}   — 实际文件内容（dylib/framework 所在）
    /// ```
    ///
    /// - Returns: 解出的文件列表
    static func extractDeb(debURL: URL, to destination: URL) throws -> [URL] {
        let data = try Data(contentsOf: debURL)
        let entries = try ArArchiveParser.parse(data: data)

        // 找到 data.tar.*
        guard let dataEntry = entries.first(where: { $0.name.hasPrefix("data.tar") }) else {
            throw SigningError.zipError("deb 中找不到 data.tar.*")
        }

        // 按 tar 的压缩格式解压出 tar 数据
        let tarData: Data
        switch decompressFormat(of: dataEntry.name) {
        case "xz": tarData = try extractXzData(dataEntry.data)
        case "gz": tarData = try extractGzipData(dataEntry.data)
        case "bz2": tarData = try extractBzip2Data(dataEntry.data)
        default: tarData = dataEntry.data
        }

        return try extractTar(tarData: tarData, to: destination)
    }

    /// 从解包后的 deb 目录中收集所有 dylib 文件
    static func collectDylibs(from directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "dylib" }
    }

    // MARK: - 各格式实现

    static func extractSevenZip(sevenZipURL: URL, to destination: URL) throws -> [URL] {
        let data = try Data(contentsOf: sevenZipURL)
        let entries = try SevenZipContainer.open(container: data)
        var results: [URL] = []
        let fm = FileManager.default
        for entry in entries {
            guard let entryData = entry.data else { continue }
            let fileURL = destination.appendingPathComponent(entry.info.name)
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entryData.write(to: fileURL)
            results.append(fileURL)
        }
        return results
    }

    static func extractTar(tarData: Data, to destination: URL) throws -> [URL] {
        let entries = try TarContainer.open(container: tarData)
        var results: [URL] = []
        let fm = FileManager.default
        for entry in entries {
            let fileURL = destination.appendingPathComponent(entry.info.name)
            if entry.info.type == .directory {
                try fm.createDirectory(at: fileURL, withIntermediateDirectories: true)
                continue
            }
            guard let entryData = entry.data else { continue }
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entryData.write(to: fileURL)
            results.append(fileURL)
        }
        return results
    }

    static func extractGzip(gzipURL: URL, to destination: URL) throws -> [URL] {
        let data = try Data(contentsOf: gzipURL)
        let decompressed = try extractGzipData(data)
        // .tar.gz → 解包 tar；.gz → 写出单文件
        return try writeSingleOrTar(decompressed: decompressed, sourceName: gzipURL.lastPathComponent, to: destination)
    }

    static func extractXz(xzURL: URL, to destination: URL) throws -> [URL] {
        let data = try Data(contentsOf: xzURL)
        let decompressed = try extractXzData(data)
        return try writeSingleOrTar(decompressed: decompressed, sourceName: xzURL.lastPathComponent, to: destination)
    }

    static func extractBzip2(bzip2URL: URL, to destination: URL) throws -> [URL] {
        let data = try Data(contentsOf: bzip2URL)
        let decompressed = try extractBzip2Data(data)
        return try writeSingleOrTar(decompressed: decompressed, sourceName: bzip2URL.lastPathComponent, to: destination)
    }

    // MARK: - 底层解压

    static func extractGzipData(_ data: Data) throws -> Data {
        try GzipArchive.unarchive(archive: data)
    }

    static func extractXzData(_ data: Data) throws -> Data {
        try XZArchive.unarchive(archive: data)
    }

    static func extractBzip2Data(_ data: Data) throws -> Data {
        try BZip2.decompress(data: data)
    }

    /// 解压结果可能是 tar（.tar.gz）也可能是单文件（.gz）
    private static func writeSingleOrTar(decompressed: Data, sourceName: String, to destination: URL) throws -> [URL] {
        let baseName = sourceName.replacingOccurrences(of: ".gz", with: "")
            .replacingOccurrences(of: ".xz", with: "")
            .replacingOccurrences(of: ".bz2", with: "")
        if baseName.hasSuffix(".tar") {
            return try extractTar(tarData: decompressed, to: destination)
        }
        let fileURL = destination.appendingPathComponent(baseName)
        try decompressed.write(to: fileURL)
        return [fileURL]
    }

    /// 判断 data.tar.* 的压缩格式
    private static func decompressFormat(of fileName: String) -> String {
        if fileName.hasSuffix(".xz") { return "xz" }
        if fileName.hasSuffix(".gz") { return "gz" }
        if fileName.hasSuffix(".bz2") { return "bz2" }
        return "none"
    }
}

// MARK: - AR 归档解析（deb 基础格式，SWCompression 未提供）

/// AR 归档条目
struct ArArchiveEntry {
    let name: String
    let data: Data
}

/// AR 归档解析器
///
/// AR 格式（Unix ar）：
/// ```
/// "!<arch>\n"                    — 全局魔数（8字节）
/// [文件头 60 字节 + 数据] × n
/// ```
/// 文件头（60 字节）：name(16) mtime(12) uid(6) gid(6) mode(8) size(10) magic("`_\n" 或 "`\n")(2)
struct ArArchiveParser {

    private static let globalMagic = "!<arch>\n"
    private static let headerSize = 60

    /// 解析 AR 归档
    static func parse(data: Data) throws -> [ArArchiveEntry] {
        var entries: [ArArchiveEntry] = []
        var offset = 0

        // 校验全局魔数
        let magicData = data.subdata(in: 0..<globalMagic.count)
        guard String(data: magicData, encoding: .ascii) == globalMagic else {
            throw SigningError.zipError("不是有效的 AR 归档（deb）")
        }
        offset = globalMagic.count

        while offset + headerSize <= data.count {
            let header = String(
                data: data.subdata(in: offset..<(offset + headerSize)),
                encoding: .ascii
            ) ?? ""

            // 文件名：前 16 字节，去掉尾部空格；可能带 `name/` 结尾斜杠（System V 风格）
            var name = String(header.prefix(16)).trimmingCharacters(in: .whitespaces)
            if name.hasSuffix("/") { name.removeLast() }

            // 数据大小：name(16) + mtime(12) + uid(6) + gid(6) + mode(8) = 48 字节后 10 字节
            let sizeStart = header.index(header.startIndex, offsetBy: 48)
            let sizeStr = String(header[sizeStart..<(header.index(sizeStart, offsetBy: 10))])
                .trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeStr), size >= 0 else {
                throw SigningError.zipError("AR 条目头解析失败")
            }

            // 数据起始位置 = 头结束 + 2 字节文件尾魔数 "`\n"
            let dataStart = offset + headerSize + 2
            guard dataStart + size <= data.count else { break }

            if !name.isEmpty {
                entries.append(ArArchiveEntry(name: name, data: data.subdata(in: dataStart..<(dataStart + size))))
            }

            // AR 数据按 2 字节对齐
            offset = dataStart + size + (size % 2)
        }

        return entries
    }
}
