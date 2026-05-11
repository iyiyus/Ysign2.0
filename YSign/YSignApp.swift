import SwiftUI

/// YSign 应用入口
///
/// 负责：
/// - 创建全局状态管理 AppState
/// - 处理 URL Scheme 回调（接收 UDID 等）
/// - 处理外部文件打开（IPA、P12）
@main
struct YSignApp: App {
    @StateObject private var appState = AppState()

    /// 外观模式（0=跟随系统，1=浅色，2=深色）
    @AppStorage("appearanceMode") private var appearanceMode = 0

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(resolvedColorScheme)
                .onOpenURL { url in
                    handleOpenURL(url)
                }
        }
    }

    /// 根据 appearanceMode 解析为 SwiftUI ColorScheme
    private var resolvedColorScheme: ColorScheme? {
        switch appearanceMode {
        case 1:  return .light
        case 2:  return .dark
        default: return nil    // 跟随系统
        }
    }

    /// 处理外部 URL Scheme 回调
    ///
    /// 支持的格式（与旧版 freesign:// 对应）：
    /// - ysign://?udid=XXXXXXXX  → 保存设备 UDID
    /// - ysign://?deviceUDID=XX  → 兼容旧格式
    /// - ysign://?UDID=XX        → 兼容大写格式
    private func handleOpenURL(_ url: URL) {
        guard url.scheme == "ysign" else { return }

        // 解析 URL 参数
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems {
            for item in queryItems {
                // 兼容多种参数名：udid / deviceUDID / UDID
                let key = item.name.lowercased()
                if key == "udid" || key == "deviceudid" {
                    if let value = item.value, !value.isEmpty {
                        // 保存 UDID 到 UserDefaults
                        UserDefaults.standard.set(value, forKey: "deviceUDID")
                        print("[YSign] 成功接收 UDID 回调: \(value)")

                        // 触觉反馈
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        return
                    }
                }
            }
        }
    }
}
