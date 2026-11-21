import AVFoundation
import UIKit

/// 后台保活管理器（参考 LCSign 的 BackgroundKeepAlive 实现）
///
/// 原理：循环播放 1 秒静音音频（silence.wav）+ `UIBackgroundModes: audio`，
/// 使 App 在后台期间不会因"无音频活动"被系统挂起；
/// 同时用 `beginBackgroundTask` 申请额外的后台执行时间作双保险。
///
/// 使用场景：
/// - 签名进行中（`keepAliveHeld`）
/// - 本地安装等待确认期间（`installKeepAliveHeld`）
/// - WiFi 传输服务运行中
///
/// 用法：
/// ```swift
/// BackgroundKeepAlive.shared.start(reason: .signing)
/// // ... 完成后
/// BackgroundKeepAlive.shared.stop(reason: .signing)
/// ```
@MainActor
final class BackgroundKeepAlive: ObservableObject {

    static let shared = BackgroundKeepAlive()

    /// 保活用途场景（引用计数式管理，支持多个场景叠加）
    enum Reason: String {
        case signing       // 签名进行中
        case installing    // 本地安装等待确认
        case wifiTransfer  // WiFi 传输服务
    }

    // MARK: - 状态

    /// 是否有签名保活被持有（对应 LCSign 的 keepAliveHeld）
    @Published private(set) var keepAliveHeld = false
    /// 是否有安装保活被持有（对应 LCSign 的 installKeepAliveHeld）
    @Published private(set) var installKeepAliveHeld = false

    /// 当前持有保活的场景集合
    private var heldReasons: Set<Reason> = []

    /// 静音音频播放器（1 秒静音 wav，无限循环）
    private var player: AVAudioPlayer?
    /// 系统后台任务标识（双保险）
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // MARK: - 对外接口

    /// 开始保活（同一场景重复调用无副作用）
    func start(reason: Reason) {
        heldReasons.insert(reason)
        refreshFlags()
        activateAudioSessionIfNeeded()
        startBackgroundTaskIfNeeded()
        startSilentPlaybackIfNeeded()
        print("[BackgroundKeepAlive] start \(reason.rawValue), held: \(heldReasons.map(\.rawValue))")
    }

    /// 停止保活（仅当没有其他场景仍持有时才真正释放）
    func stop(reason: Reason) {
        heldReasons.remove(reason)
        refreshFlags()
        print("[BackgroundKeepAlive] stop \(reason.rawValue), held: \(heldReasons.map(\.rawValue))")

        if heldReasons.isEmpty {
            stopSilentPlayback()
            endBackgroundTaskIfNeeded()
            deactivateAudioSession()
        }
    }

    // MARK: - 私有实现

    private func refreshFlags() {
        keepAliveHeld = heldReasons.contains(.signing)
        installKeepAliveHeld = heldReasons.contains(.installing)
    }

    /// 激活音频会话（playback 类别是后台音频模式生效的前提）
    private func activateAudioSessionIfNeeded() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("[BackgroundKeepAlive] 音频会话激活失败: \(error.localizedDescription)")
        }
    }

    /// 开始循环播放静音音频
    private func startSilentPlaybackIfNeeded() {
        guard player == nil else { return }
        guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else {
            print("[BackgroundKeepAlive] 未找到 silence.wav")
            return
        }
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.numberOfLoops = -1   // 无限循环
            audioPlayer.volume = 0.01        // 静音文件，音量压到最低兜底
            audioPlayer.play()
            player = audioPlayer
        } catch {
            print("[BackgroundKeepAlive] 静音播放失败: \(error.localizedDescription)")
        }
    }

    private func stopSilentPlayback() {
        player?.stop()
        player = nil
    }

    /// 申请系统后台执行时间（双保险：音频被中断时仍有一段缓冲）
    private func startBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "BackgroundKeepAlive") { [weak self] in
            // 到期兜底：立即结束，避免系统强杀
            guard let self else { return }
            Task { @MainActor in
                self.heldReasons.removeAll()
                self.refreshFlags()
                self.stopSilentPlayback()
                self.endBackgroundTaskIfNeeded()
                self.deactivateAudioSession()
            }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
