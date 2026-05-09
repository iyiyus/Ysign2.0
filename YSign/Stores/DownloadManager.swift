import Foundation

/// 下载管理器
///
/// 管理 IPA 文件的下载任务，支持：
/// - 从 URL 下载 IPA 文件
/// - 多任务并发下载
/// - 实时下载进度追踪
/// - 下载完成后自动导入到资源库
///
/// 下载的文件保存在 Documents/YSign/Downloads/ 目录下
class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {

    /// 单例（全局唯一下载管理器）
    @MainActor static let shared = DownloadManager()

    /// 当前所有下载任务（包含进行中和已完成的）
    @MainActor @Published var tasks: [DownloadTask] = []

    /// 下载目录
    let downloadDirectory: URL

    /// URLSessionDownloadTask → 我们的任务 ID 映射
    private var taskIDMap: [Int: UUID] = [:]  // URLSessionTask.taskIdentifier → UUID

    /// 暂停时保存的 resumeData（用于断点续传）
    private var resumeDataMap: [UUID: Data] = [:]

    /// 后台 URLSession（使用 delegate 追踪进度）
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: - 初始化

    override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.downloadDirectory = docs.appendingPathComponent("YSign/Downloads")
        try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        super.init()
        loadHistory()
    }

    // MARK: - 公开方法

    /// 添加一个新的下载任务
    @MainActor @discardableResult
    func addDownload(url: String, fileName: String? = nil, sourceName: String? = nil) -> DownloadTask? {
        guard let downloadURL = URL(string: url) else { return nil }

        // 检查是否已经在下载
        if tasks.contains(where: { $0.url == url && $0.status == .downloading }) {
            return nil
        }

        let name = fileName ?? downloadURL.lastPathComponent

        let task = DownloadTask(
            id: UUID(),
            url: url,
            fileName: name,
            sourceName: sourceName,
            status: .downloading,
            progress: 0,
            totalBytes: 0,
            downloadedBytes: 0,
            startTime: Date(),
            endTime: nil,
            localFileURL: nil
        )

        tasks.insert(task, at: 0)
        startDownload(task: task, url: downloadURL)
        saveHistory()

        return task
    }

    /// 从 URL 字符串快速下载
    @MainActor @discardableResult
    func downloadFromURL(_ urlString: String) -> DownloadTask? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        return addDownload(url: trimmed)
    }

    /// 暂停下载
    @MainActor
    func pauseDownload(id: UUID) {
        guard let sessionTaskID = taskIDMap.first(where: { $0.value == id })?.key else { return }
        session.getAllTasks { [weak self] allTasks in
            guard let downloadTask = allTasks.first(where: { $0.taskIdentifier == sessionTaskID }) as? URLSessionDownloadTask else { return }
            downloadTask.cancel(byProducingResumeData: { data in
                DispatchQueue.main.async {
                    if let data { self?.resumeDataMap[id] = data }
                    if let idx = self?.tasks.firstIndex(where: { $0.id == id }) {
                        self?.tasks[idx].status = .paused
                    }
                    if let key = self?.taskIDMap.first(where: { $0.value == id })?.key {
                        self?.taskIDMap.removeValue(forKey: key)
                    }
                    self?.saveHistory()
                }
            })
        }
    }

    /// 恢复下载
    @MainActor
    func resumeDownload(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .downloading

        if let resumeData = resumeDataMap[id] {
            // 断点续传
            let downloadTask = session.downloadTask(withResumeData: resumeData)
            taskIDMap[downloadTask.taskIdentifier] = id
            resumeDataMap.removeValue(forKey: id)
            downloadTask.resume()
        } else if let url = URL(string: tasks[index].url) {
            // 重新下载
            let downloadTask = session.downloadTask(with: URLRequest(url: url))
            taskIDMap[downloadTask.taskIdentifier] = id
            downloadTask.resume()
        }
        saveHistory()
    }

    /// 取消并删除指定的下载任务
    @MainActor
    func cancelDownload(id: UUID) {
        if let sessionTaskID = taskIDMap.first(where: { $0.value == id })?.key {
            session.getAllTasks { allTasks in
                allTasks.first(where: { $0.taskIdentifier == sessionTaskID })?.cancel()
            }
            taskIDMap.removeValue(forKey: sessionTaskID)
        }
        resumeDataMap.removeValue(forKey: id)
        tasks.removeAll { $0.id == id }
        saveHistory()
    }

    /// 删除任意任务记录（进行中的会先取消）
    @MainActor
    func removeTask(id: UUID) {
        // 如果正在下载，先取消
        if let sessionTaskID = taskIDMap.first(where: { $0.value == id })?.key {
            session.getAllTasks { allTasks in
                allTasks.first(where: { $0.taskIdentifier == sessionTaskID })?.cancel()
            }
            taskIDMap.removeValue(forKey: sessionTaskID)
        }
        resumeDataMap.removeValue(forKey: id)
        tasks.removeAll { $0.id == id }
        saveHistory()
    }

    /// 清除所有已完成的下载记录
    @MainActor
    func clearCompleted() {
        tasks.removeAll { $0.status == .completed || $0.status == .failed }
        saveHistory()
    }

    // MARK: - 私有方法

    /// 开始下载（使用 delegate 追踪进度）
    @MainActor
    private func startDownload(task: DownloadTask, url: URL) {
        let request = URLRequest(url: url)
        let downloadTask = session.downloadTask(with: request)
        taskIDMap[downloadTask.taskIdentifier] = task.id
        downloadTask.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    /// 下载进度回调（实时更新）
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let taskID = taskIDMap[downloadTask.taskIdentifier] else { return }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        let downloaded = totalBytesWritten
        let total = totalBytesExpectedToWrite

        DispatchQueue.main.async { [weak self] in
            guard let self, let index = self.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            self.tasks[index].progress = progress
            self.tasks[index].downloadedBytes = downloaded
            self.tasks[index].totalBytes = total > 0 ? total : 0
        }
    }

    /// 下载完成回调
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let taskID = taskIDMap[downloadTask.taskIdentifier] else { return }

        // 获取文件名（在主线程之前读取）
        var fileName = "unknown.ipa"
        DispatchQueue.main.sync { [weak self] in
            if let index = self?.tasks.firstIndex(where: { $0.id == taskID }) {
                fileName = self?.tasks[index].fileName ?? fileName
            }
        }

        let destURL = downloadDirectory.appendingPathComponent(fileName)
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: location, to: destURL)
        } catch {
            print("[DownloadManager] 移动文件失败: \(error)")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let index = self.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            self.tasks[index].status = .completed
            self.tasks[index].progress = 1.0
            self.tasks[index].endTime = Date()
            self.tasks[index].localFileURL = destURL
            self.taskIDMap.removeValue(forKey: downloadTask.taskIdentifier)
            self.saveHistory()
        }
    }

    /// 下载出错回调
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let taskID = taskIDMap[task.taskIdentifier] else { return }
        print("[DownloadManager] 下载失败: \(error.localizedDescription)")

        DispatchQueue.main.async { [weak self] in
            guard let self, let index = self.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            self.tasks[index].status = .failed
            self.tasks[index].endTime = Date()
            self.taskIDMap.removeValue(forKey: task.taskIdentifier)
            self.saveHistory()
        }
    }

    // MARK: - 持久化

    /// 保存下载历史到磁盘
    @MainActor
    private func saveHistory() {
        let historyFile = downloadDirectory.appendingPathComponent("history.json")
        if let data = try? JSONEncoder().encode(tasks) {
            try? data.write(to: historyFile)
        }
    }

    /// 从磁盘加载下载历史
    private func loadHistory() {
        let historyFile = downloadDirectory.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: historyFile),
           let savedTasks = try? JSONDecoder().decode([DownloadTask].self, from: data) {
            DispatchQueue.main.async { [weak self] in
                self?.tasks = savedTasks.map { task in
                    var t = task
                    if t.status == .downloading || t.status == .waiting {
                        t.status = .paused
                    }
                    return t
                }
            }
        }
    }
}
