import SwiftUI
import Combine

/// 应用全局状态管理
///
/// 作为整个应用的单一数据源（Single Source of Truth），
/// 通过 @EnvironmentObject 注入到所有视图中。
///
/// 管理的数据：
/// - 已导入的证书列表
/// - IPA 资源库
/// - 当前签名任务列表
/// - 当前选中的 Tab
@MainActor
final class AppState: ObservableObject {

    /// 已导入的证书列表
    @Published var certificates: [CertificateInfo] = []

    /// IPA 资源库中的所有文件
    @Published var ipaLibrary: [IPAFile] = []

    /// 所有签名任务（进行中 + 历史记录）
    @Published var signingTasks: [SigningTask] = []

    /// 已添加的软件源数据
    @Published var appSources: [AppSource] = []

    /// 当前选中的 Tab 页
    @Published var selectedTab: Tab = .files

    /// 导航到文件管理中的指定文件夹（跨 Tab 通信）
    @Published var navigateToFolder: URL?

    /// Tab 页枚举
    enum Tab: String, CaseIterable {
        case apps = "软件源"
        case download = "下载"
        case files = "文件"
        case signing = "应用"
        case settings = "设置"

        var icon: String {
            switch self {
            case .apps: return "square.grid.2x2"
            case .download: return "arrow.down.circle"
            case .files: return "folder"
            case .signing: return "app.badge"
            case .settings: return "gearshape"
            }
        }
    }

    /// 从磁盘加载所有已保存的证书
    func loadCertificates() async {
        let store = CertificateStore()
        certificates = await store.loadAll()
    }

    /// 扫描并刷新 IPA 资源库
    func refreshLibrary() async {
        let manager = IPALibraryManager()
        ipaLibrary = await manager.scanLibrary()
    }

    /// 刷新所有软件源数据
    func refreshSources() async {
        let store = AppSourceStore()

        // 先从缓存快速加载
        let cached = await store.loadCachedSources()
        if !cached.isEmpty && appSources.isEmpty {
            appSources = cached
        }

        // 从网络刷新
        let freshSources = await store.refreshAllSources()
        if !freshSources.isEmpty {
            appSources = freshSources
        }
        // 网络全部失败时保留已有数据，不清空
    }

    /// 添加一个签名任务到列表
    func addSigningTask(_ task: SigningTask) {
        signingTasks.insert(task, at: 0)
    }

    /// 更新指定签名任务的状态
    func updateTask(id: UUID, status: SigningTask.Status, progress: Double) {
        if let index = signingTasks.firstIndex(where: { $0.id == id }) {
            signingTasks[index].status = status
            signingTasks[index].progress = progress
            if status == .completed || status == .failed {
                signingTasks[index].endTime = Date()
            }
        }
    }
}
