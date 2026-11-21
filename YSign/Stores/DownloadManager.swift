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

    /// 后台 URLSession（系统级保活：App 退后台/被杀后系统进程继续下载，回来后回调恢复）
    ///
    /// - identifier 固定，App 重启后自动接管未完成的任务
    /// - taskIDMap 持久化到 UserDefaults，保证重启后 delegate 回调能匹配到任务
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.ysign.app.download")
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600 * 6   // 整体 6h 上限（对齐 LCSign）
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: - 初始化

    override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.downloadDirectory = docs.appendingPathComponent("YSign/Downloads")
        try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        super.init()
        loadHistory()
        loadTaskMap()
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
                    if let data {
                        self?.resumeDataMap[id] = data
                        self?.persistResumeData(data, for: id)
                    }
                    if let idx = self?.tasks.firstIndex(where: { $0.id == id }) {
                        self?.tasks[idx].status = .paused
                    }
                    if let key = self?.taskIDMap.first(where: { $0.value == id })?.key {
                        self?.taskIDMap.removeValue(forKey: key)
                        self?.persistTaskMap()
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

        if let resumeData = resumeDataMap[id] ?? loadPersistedResumeData(for: id) {
            // 断点续传（内存或磁盘）
            resumeDataMap[id] = resumeData
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
            persistTaskMap()
        }
        resumeDataMap.removeValue(forKey: id)
        removePersistedResumeData(for: id)
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
            persistTaskMap()
        }
        resumeDataMap.removeValue(forKey: id)
        removePersistedResumeData(for: id)
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
        persistTaskMap()
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
            self.persistTaskMap()
            self.removePersistedResumeData(for: taskID)
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
            self.persistTaskMap()
            self.saveHistory()
        }
    }

    /// 后台会话事件处理完毕回调（App 因后台下载被唤醒后必须调用，否则系统会杀进程）
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            AppDelegate.pendingBackgroundCompletionHandler?()
            AppDelegate.pendingBackgroundCompletionHandler = nil
        }
    }

    // MARK: - taskIDMap 持久化（后台会话跨进程恢复的关键）

    /// taskIDMap 持久化键（URLSessionTask.taskIdentifier → DownloadTask.id）
    private static let taskMapKey = "downloadTaskIDMap"

    /// 保存 taskIDMap（后台会话 App 被杀重启后，delegate 回调依赖此映射）
    private func persistTaskMap() {
        var map: [String: String] = [:]
        for (sessionID, taskID) in taskIDMap {
            map["\(sessionID)"] = taskID.uuidString
        }
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: Self.taskMapKey)
        }
    }

    /// 恢复 taskIDMap
    private func loadTaskMap() {
        guard let data = UserDefaults.standard.data(forKey: Self.taskMapKey),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for (sessionID, taskUUID) in map {
            if let id = UUID(uuidString: taskUUID) {
                taskIDMap[Int(sessionID) ?? 0] = id
            }
        }
    }

    /// 暂停时的 resumeData 落盘（App 被杀后仍可断点续传）
    private func persistResumeData(_ data: Data, for id: UUID) {
        let dir = downloadDirectory.appendingPathComponent(".resume")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(id.uuidString))
    }

    private func loadPersistedResumeData(for id: UUID) -> Data? {
        let url = downloadDirectory.appendingPathComponent(".resume").appendingPathComponent(id.uuidString)
        return try? Data(contentsOf: url)
    }

    private func removePersistedResumeData(for id: UUID) {
        try? FileManager.default.removeItem(
            at: downloadDirectory.appendingPathComponent(".resume").appendingPathComponent(id.uuidString)
        )
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
