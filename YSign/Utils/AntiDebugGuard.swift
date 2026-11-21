import Foundation
import Darwin
import MachO.dyld

/// 反调试 / 反注入守护
///
/// 检测两类威胁：
/// 1. **调试器附着**：`sysctl(KERN_PROC_PID)` 检查进程 `P_TRACED` 标志（Xcode/LLDB 附着即命中）
/// 2. **外部动态库注入**：枚举 dyld 已加载镜像，匹配可疑库名单 + 越狱注入目录路径 + DYLD_INSERT_LIBRARIES
///
/// 命中后置位 `isBlocked`，由 App 根视图以全屏拦截页覆盖，不可关闭。
///
/// 无用户开关，按构建配置恒定：
/// - Release 始终开启
/// - DEBUG 构建关闭（Xcode 调试运行会被 P_TRACED 命中，避免开发自锁；可用 `--antidebug-preview` 预览拦截页）
final class AntiDebugGuard: ObservableObject {

    static let shared = AntiDebugGuard()

    /// 是否显示全屏拦截页
    @Published var isBlocked = false

    /// 最近一次命中结果（供拦截页渲染）
    private(set) var lastResult: CheckResult?

    /// 检查结果
    struct CheckResult {
        let debuggerAttached: Bool
        let injectedLibs: [String]
        let isPreview: Bool

        var shouldBlock: Bool { debuggerAttached || !injectedLibs.isEmpty }

        /// 拦截页展示条目：仅有调试器时展示"Debugger"占位
        var displayLibs: [String] {
            if injectedLibs.isEmpty && debuggerAttached {
                return ["Debugger (调试器附着)"]
            }
            return injectedLibs
        }
    }

    // MARK: - 开关

    /// 当前是否启用检测：Release 恒开，DEBUG 构建关闭
    static var isEnabled: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    // MARK: - 可疑名单

    /// 可疑动态库关键字（小写匹配文件名）
    private static let suspiciousKeywords: [String] = [
        "flexloader", "libflex",                    // Flex 越狱插件加载器
        "substrate", "mobilesubstrate",             // Cydia Substrate
        "substitute", "ellekit", "libhooker",       // 注入框架
        "frida", "gadget", "cycript",               // 动态分析
        "sslkillswitch", "ssl kill",                // SSL Bypass
        "shadow", "abypass", "ts protector",        // 隐藏/反检测
        "tweakinject", "libtweak",
    ]

    /// 越狱注入目录前缀（命中即拦截）
    private static let jailbreakPathPrefixes: [String] = [
        "/library/mobilesubstrate",
        "/usr/lib/tweakinject",
        "/library/tweakinject",
        "/var/jb",
        "/bootstrap",
        "/odyssey",
        "/checkra1n",
        "/etc/apt",
    ]

    /// 合法镜像路径前缀（不参与关键字匹配，避免误报）
    private static let legitPathPrefixes: [String] = [
        "/system/library/",
        "/usr/lib/",
        "/usr/libexec/",
        "/private/var/containers/bundle/",          // 系统框架
        bundlePathPrefix,
        "/applications/xcode",                      // 模拟器：Xcode 内部库
        "/library/developer",                       // 模拟器运行时
        "/system/iosupport/",
    ]

    /// 本 App bundle 路径（自身的资源库合法）
    private static let bundlePathPrefix: String = {
        Bundle.main.bundlePath.lowercased() + "/"
    }()

    // MARK: - 对外入口

    /// 按开关执行检测，命中则触发拦截页
    @discardableResult
    func checkIfEnabled() -> CheckResult? {
        guard Self.isEnabled else { return nil }
        return performCheck()
    }

    /// 无视开关执行检测（命中触发拦截页）
    @discardableResult
    func performCheck() -> CheckResult {
        let debugger = Self.isDebuggerAttached()
        let libs = Self.scanInjectedLibraries()
        let result = CheckResult(debuggerAttached: debugger, injectedLibs: libs, isPreview: false)
        if result.shouldBlock {
            lastResult = result
            DispatchQueue.main.async { [weak self] in
                self?.isBlocked = true
            }
        }
        return result
    }

    /// 设置页预览入口：展示拦截页样例（不可用时从预览退出）
    func showPreview() {
        lastResult = CheckResult(
            debuggerAttached: false,
            injectedLibs: ["FlexLoader.dylib", "libsubstrate.dylib", "FridaGadget.dylib"],
            isPreview: true
        )
        DispatchQueue.main.async { [weak self] in
            self?.isBlocked = true
        }
    }

    /// 关闭拦截（仅预览态允许）
    func dismissPreview() {
        if lastResult?.isPreview == true {
            isBlocked = false
        }
    }

    // MARK: - 调试器检测

    /// sysctl 检查进程是否被调试器附着（P_TRACED）
    static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, 4, &info, &size, nil, 0)
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    // MARK: - 注入检测

    /// 枚举 dyld 镜像，返回拦截的外部动态库文件名列表
    static func scanInjectedLibraries() -> [String] {
        var blocked = Set<String>()
        let imageCount = _dyld_image_count()

        for i in 0..<imageCount {
            guard let cPath = _dyld_get_image_name(i) else { continue }
            let path = String(cString: cPath)
            let lowered = path.lowercased()
            let fileName = (path as NSString).lastPathComponent
            let fileNameLowered = fileName.lowercased()

            // 1. 越狱注入目录：路径前缀命中即拦截
            if jailbreakPathPrefixes.contains(where: { lowered.hasPrefix($0) }) {
                blocked.insert(fileName)
                continue
            }

            // 2. 合法路径白名单内不做关键字匹配（避免系统库/自身资源误报）
            if legitPathPrefixes.contains(where: { lowered.hasPrefix($0) }) {
                continue
            }

            // 3. 非标准路径 + 可疑关键字（如 /var/containers 里的 tweak 注入）
            if suspiciousKeywords.contains(where: { fileNameLowered.contains($0) }) {
                blocked.insert(fileName)
            }
        }

        // 4. DYLD_INSERT_LIBRARIES 环境变量注入
        if let insert = getenv("DYLD_INSERT_LIBRARIES"),
           let value = String(validatingUTF8: insert) {
            for entry in value.split(separator: ":") {
                let name = (String(entry) as NSString).lastPathComponent
                if !name.isEmpty {
                    blocked.insert(name)
                }
            }
        }

        return blocked.sorted()
    }
}
