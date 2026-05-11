import SwiftUI
import CryptoKit

/// 根视图 —— 底部 TabView 导航
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    /// 是否展示公告弹窗.
    @State private var showNoticeAlert = false

    /// 运行时公告文案.
    @State private var noticeMessage = ""

    /// UserDefaults 中记录"已弹过公告"的 key.
    private static let noticeShownKey = "brandNoticeShown_v2"

    var body: some View {
        ZStack {
            tabContent

            // 启动图浮层：只要有缓存或 URL 就立即展示
            if appState.showBrandLaunch {
                BrandLaunchOverlayView(urlString: appState.brandLaunchURL) {
                    appState.showBrandLaunch = false
                }
                .zIndex(1)
            }
        }
        .alert("公告", isPresented: $showNoticeAlert) {
            Button("知道了", role: .cancel) {
                markNoticeShown(noticeMessage)
            }
        } message: {
            Text(noticeMessage)
        }
        .task(id: "init") {
            await appState.performStartup()

            // 公告弹窗
            presentNoticeIfNeeded()
        }
    }

    private var tabContent: some View {
        TabView(selection: $appState.selectedTab) {
            FileManagerView()
                .tabItem {
                    Label(AppState.Tab.files.rawValue, systemImage: AppState.Tab.files.icon)
                }
                .tag(AppState.Tab.files)

            SigningHubView()
                .tabItem {
                    Label(AppState.Tab.signing.rawValue, systemImage: AppState.Tab.signing.icon)
                }
                .tag(AppState.Tab.signing)

            AppSourcesView()
                .tabItem {
                    Label(AppState.Tab.apps.rawValue, systemImage: AppState.Tab.apps.icon)
                }
                .tag(AppState.Tab.apps)

            DownloadView()
                .tabItem {
                    Label(AppState.Tab.download.rawValue, systemImage: AppState.Tab.download.icon)
                }
                .tag(AppState.Tab.download)

            SettingsView()
                .tabItem {
                    Label(AppState.Tab.settings.rawValue, systemImage: AppState.Tab.settings.icon)
                }
                .tag(AppState.Tab.settings)
        }
        .tint(.accentColor)
        .alert("授权校验失败", isPresented: $appState.showingUnauthorizedLicenseAlert) {
            Button("确定") {}
        } message: {
            Text("\(appState.unauthorizedLicenseMessage)\n\n应用将在 10 秒后自动退出。")
        }
    }

    private func presentNoticeIfNeeded() {
        let notice = appState.brandConfig.notice
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notice.isEmpty else { return }

        let currentHash = stableHash(notice)
        let shownHash = UserDefaults.standard.string(forKey: Self.noticeShownKey) ?? ""
        guard shownHash != currentHash else { return }

        noticeMessage = notice
        showNoticeAlert = true
    }

    private func markNoticeShown(_ notice: String) {
        UserDefaults.standard.set(stableHash(notice), forKey: Self.noticeShownKey)
    }

    private func stableHash(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
