import SwiftUI

/// 根视图 —— 底部 TabView 导航
///
/// 旧版 Tab 结构：应用(软件源) → 下载 → 文件 → 签名(证书) → 设置
/// 新版保持相同的 Tab 布局，确保功能一一对应
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            // Tab 1：文件管理
            FileManagerView()
                .tabItem {
                    Label(AppState.Tab.files.rawValue, systemImage: AppState.Tab.files.icon)
                }
                .tag(AppState.Tab.files)

            // Tab 2：应用（签名）
            SigningHubView()
                .tabItem {
                    Label(AppState.Tab.signing.rawValue, systemImage: AppState.Tab.signing.icon)
                }
                .tag(AppState.Tab.signing)

            // Tab 3：软件源
            AppSourcesView()
                .tabItem {
                    Label(AppState.Tab.apps.rawValue, systemImage: AppState.Tab.apps.icon)
                }
                .tag(AppState.Tab.apps)

            // Tab 4：下载管理
            DownloadView()
                .tabItem {
                    Label(AppState.Tab.download.rawValue, systemImage: AppState.Tab.download.icon)
                }
                .tag(AppState.Tab.download)

            // Tab 5：设置
            SettingsView()
                .tabItem {
                    Label(AppState.Tab.settings.rawValue, systemImage: AppState.Tab.settings.icon)
                }
                .tag(AppState.Tab.settings)
        }
        .tint(DS.primary)
        .task {
            await appState.loadCertificates()
            await appState.refreshLibrary()
            await appState.refreshSources()
        }
    }
}
