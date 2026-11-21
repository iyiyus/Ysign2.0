import SwiftUI

/// 签名任务列表页面
///
/// 展示所有进行中和已完成的签名任务，包括：
/// - 当前正在签名的任务（带进度条）
/// - 历史签名记录
/// - 任务详情和日志查看
struct SigningView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.signingTasks.isEmpty {
                emptyStateView
            } else {
                taskListView
            }
        }
    }

    // MARK: - 子视图

    /// 空状态视图
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "signature")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)

            Text("暂无签名任务")
                .font(.title3)
                .fontWeight(.medium)

            Text("在「资源库」中选择一个应用开始签名")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// 任务列表视图
    private var taskListView: some View {
        List {
            // 进行中的任务
            let activeTasks = appState.signingTasks.filter { $0.status != .completed && $0.status != .failed }
            if !activeTasks.isEmpty {
                Section("进行中") {
                    ForEach(activeTasks) { task in
                        SigningTaskRow(task: task)
                    }
                }
            }

            // 已完成的任务
            let completedTasks = appState.signingTasks.filter { $0.status == .completed || $0.status == .failed }
            if !completedTasks.isEmpty {
                Section("历史记录") {
                    ForEach(completedTasks) { task in
                        SigningTaskRow(task: task)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - 签名任务行组件

/// 单个签名任务的展示行
struct SigningTaskRow: View {
    let task: SigningTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 第一行：应用名 + 状态
            HStack {
                // 状态图标
                Image(systemName: task.status.icon)
                    .foregroundColor(statusColor)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.ipaFile.name)
                        .font(.body)
                        .fontWeight(.medium)

                    Text(task.status.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // 耗时
                if task.status == .completed || task.status == .failed {
                    Text(task.durationFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 进度条（仅在进行中时显示）
            if task.status != .completed && task.status != .failed && task.status != .queued {
                ProgressView(value: task.progress)
                    .tint(statusColor)
            }
        }
        .padding(.vertical, 4)
    }

    /// 根据任务状态返回对应颜色
    private var statusColor: Color {
        switch task.status {
        case .completed: return .green
        case .failed: return .red
        case .queued: return .gray
        default: return .blue
        }
    }
}
