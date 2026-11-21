import Foundation

/// 全局串行签名队列（对齐 LCSign 的 ProcessQueue）
///
/// - 串行执行：同一时间只有一个签名任务占用 CPU/IO，避免多任务并发导致内存压力
/// - 可后台运行：任务运行在独立 GCD 队列，配合 BackgroundKeepAlive 可在后台继续
/// - 日志缓冲：各任务共享一条队列，日志由各 SigningState 自行环形缓冲
enum SigningProcessQueue {

    /// 全局唯一的串行签名队列
    static let queue = DispatchQueue(label: "com.ysign.process", qos: .userInitiated)

    /// 队列中等待执行的任务数（通过 barrier 保证读取一致性）
    static var pendingCount: Int {
        queue.sync { _pendingCount }
    }

    private static var _pendingCount = 0

    /// 提交一个签名任务到全局队列
    static func submit(work: @escaping () -> Void) {
        queue.sync { _pendingCount += 1 }
        queue.async {
            work()
            queue.sync { _pendingCount = max(0, _pendingCount - 1) }
        }
    }
}
