import SwiftUI

/// YSign 应用入口
///
/// 负责：
/// - 创建全局状态管理 AppState
/// - 处理 URL Scheme 回调（接收 UDID 等）
/// - 处理外部文件打开（IPA、P12）
/// UIKit AppDelegate 桥接（处理后台 URLSession 唤醒事件）
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// 后台 URLSession 事件处理完毕的系统回调（由 DownloadManager 在 urlSessionDidFinishEvents 中调用）
    static var pendingBackgroundCompletionHandler: (() -> Void)?

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // 系统因后台下载事件唤醒 App 时调用：暂存回调，
        // 等待 DownloadManager 的 delegate 处理完所有事件后再调用
        Self.pendingBackgroundCompletionHandler = completionHandler
    }
}

@main
struct YSignApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @ObservedObject private var antiDebug = AntiDebugGuard.shared
    @ObservedObject private var quickInstall = QuickInstallCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    /// 外观模式（0=跟随系统，1=浅色，2=深色）
    @AppStorage("appearanceMode") private var appearanceMode = 1

    /// 是否已完成首次启动引导（卸载重装后自动重置）
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    /// 启动动画页（冷启动显示一次）
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                .environmentObject(appState)
                .onOpenURL { url in
                    if url.isFileURL {
                        // 从「文件」App 分享 / 用 YSign 打开的 IPA → 快捷安装
                        quickInstall.handleIncomingFile(url)
                    } else {
                        handleOpenURL(url)
                    }
                }
                .onAppear {
                    // 支持命令行预览（调试用）
                    if CommandLine.arguments.contains("--antidebug-preview") {
                        antiDebug.showPreview()
                    }
                    #if DEBUG
                    if CommandLine.arguments.contains("--quick-install-preview") {
                        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                        let sample = docs.appendingPathComponent("LCSign.ipa")
                        if FileManager.default.fileExists(atPath: sample.path) {
                            quickInstall.handleIncomingFile(sample)
                        }
                    }
                    #endif
                    antiDebug.checkIfEnabled()
                }
                .onChange(of: scenePhase) { phase in
                    // 回前台时重新检测
                    if phase == .active {
                        antiDebug.checkIfEnabled()
                        // 证书吊销检查：前台每 30 秒自动执行一次
                        RevocationService.shared.startAutoCheck { appState.certificates }
                    } else {
                        RevocationService.shared.stopAutoCheck()
                    }
                }
                // 反调试拦截页：命中后全屏覆盖，不可关闭
                .fullScreenCover(isPresented: $antiDebug.isBlocked) {
                    AntiDebugBlockView(
                        result: antiDebug.lastResult ?? AntiDebugGuard.CheckResult(
                            debuggerAttached: true,
                            injectedLibs: [],
                            isPreview: false
                        )
                    )
                    .interactiveDismissDisabled()
                }
                // 外部分享 IPA → 快捷安装确认页
                .sheet(item: $quickInstall.item) { item in
                    QuickInstallView(coordinator: quickInstall, item: item)
                        .environmentObject(appState)
                        .interactiveDismissDisabled(quickInstall.isWorking)
                }
                .alert("导入 IPA 失败", isPresented: Binding(
                    get: { quickInstall.incomingError != nil },
                    set: { if !$0 { quickInstall.incomingError = nil } }
                )) {
                    Button("确定") { quickInstall.incomingError = nil }
                } message: {
                    Text(quickInstall.incomingError ?? "")
                }

                // 首次安装启动引导：全屏覆盖主界面，完成后不再出现
                if !hasCompletedOnboarding {
                    OnboardingView()
                        .zIndex(1)
                }

                // 启动动画：字标淡入 + 笔画展开，完成后淡出
                if showSplash {
                    SplashView {
                        showSplash = false
                    }
                    .zIndex(2)
                    .transition(.opacity)
                }
            }
            .preferredColorScheme(resolvedColorScheme)
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
