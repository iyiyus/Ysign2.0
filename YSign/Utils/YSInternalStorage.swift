import Foundation

/// YSign 内部存储目录工具
///
/// 用途：把应用内部数据（证书、描述文件、品牌缓存、软件源等）放到
/// `Library/Application Support/YSign/` 下，iOS 的"文件"app 不会暴露
/// Library 目录，所以用户看不到这些内部文件。
///
/// 用户可见的数据（导入的 IPA、下载的文件等）仍放在 Documents 下。
enum YSInternalStorage {

    /// 内部数据根目录：`Library/Application Support/YSign/`
    static var root: URL {
        let libSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = libSupport.appendingPathComponent("YSign", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 获取一个内部子目录，不存在则创建。
    static func directory(_ name: String) -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 从旧位置迁移数据到新位置（只在新位置不存在时执行）。
    ///
    /// - Parameters:
    ///   - oldSubpath: 旧的相对路径，相对于 Documents，例如 "YSign/Certificates"
    ///   - newName:    新的子目录名，相对于 `root`，例如 "Certificates"
    static func migrateIfNeeded(oldSubpath: String, newName: String) {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let oldURL = docs.appendingPathComponent(oldSubpath)
        let newURL = root.appendingPathComponent(newName, isDirectory: true)

        guard fm.fileExists(atPath: oldURL.path) else { return }

        // 新目录已有内容则跳过迁移
        if let existing = try? fm.contentsOfDirectory(atPath: newURL.path), !existing.isEmpty {
            return
        }

        try? fm.removeItem(at: newURL)
        try? fm.moveItem(at: oldURL, to: newURL)
    }
}
