import SwiftUI

/// 签名进度页面
///
/// 点击「开始签名」后 push 到此页面，实时显示签名日志。
/// 签名完成后底部显示「安装」和「退出」按钮。
struct SigningProgressView: View {
    @EnvironmentObject var appState: AppState

    let app: IPAFile
    let certificate: CertificateInfo?
    @ObservedObject var signingState: SigningState

    @State private var isInstalling = false
    @State private var installMessage: String?
    @State private var installEventTask: Task<Void, Never>?
    @State private var showInstallTimeout = false
    @State private var lastInstalledIPA: URL?

    /// 退出到应用页的回调
    var onExit: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // 状态卡
            statusCard
                .padding(.horizontal, DS.paddingScreen)
                .padding(.top, 8)

            // 日志滚动区域
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(signingState.logs.enumerated()), id: \.offset) { index, log in
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(DS.text)
                    }
                    // 锚点，用于自动滚动到底部
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.cornerM, style: .continuous)
                    .strokeBorder(DS.divider.opacity(0.7), lineWidth: 1)
            )
            .padding(.horizontal, DS.paddingScreen)
            .padding(.vertical, 12)

            Spacer(minLength: 0)
        }
        .background(DS.background.ignoresSafeArea())

        // 签名完成/失败：底部按钮
        .safeAreaInset(edge: .bottom) {
            if !signingState.isSigning {
                VStack(spacing: 0) {
                    DSDivider()
                    HStack(spacing: 12) {
                        if signingState.outputURL != nil && signingState.errorMessage == nil {
                            Button {
                                installApp()
                            } label: {
                                HStack(spacing: 6) {
                                    if isInstalling {
                                        ProgressView()
                                            .tint(.white)
                                    }
                                    Text(isInstalling ? "安装中..." : "安装")
                                }
                            }
                            .buttonStyle(DSPrimaryButtonStyle(color: DS.success))
                            .disabled(isInstalling)
                        }

                        if signingState.errorMessage != nil {
                            Button {
                                onExit?()
                            } label: {
                                Text("返回")
                            }
                            .buttonStyle(DSPrimaryButtonStyle(color: DS.destructive))
                        } else {
                            Button {
                                onExit?()
                            } label: {
                                Text("退出")
                            }
                            .buttonStyle(DSSecondaryButtonStyle())
                        }
                    }
                    .padding(.horizontal, DS.paddingScreen)
                    .padding(.vertical, 10)
                }
                .background(DS.card.ignoresSafeArea(edges: .bottom))
            } else {
                // 签名中：进度条 + 取消按钮
                VStack(spacing: 0) {
                    DSDivider()
                    VStack(spacing: 8) {
                        HStack {
                            Text(signingState.stage)
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .foregroundStyle(DS.textSecondary)
                            Spacer()
                            Text("\(String(format: "%.1f", signingState.progress * 100))%")
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(DS.primary)
                        }
                        ProgressView(value: signingState.progress)
                            .tint(DS.primary)
                        Button {
                            signingState.cancelSigning()
                        } label: {
                            Label("取消签名", systemImage: "stop.circle")
                                .font(.system(.footnote, design: .rounded, weight: .medium))
                                .foregroundStyle(DS.destructive)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: DS.cornerS, style: .continuous).fill(DS.destructive.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, DS.paddingScreen)
                    .padding(.vertical, 12)
                }
                .background(DS.card.ignoresSafeArea(edges: .bottom))
            }
        }
        .navigationTitle("签名")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(signingState.isSigning || isInstalling)
        .toolbar(.hidden, for: .tabBar)
        .task {
            // 等待导航/Liquid Glass 转场动画完全结束后再开始签名
            try? await Task.sleep(nanoseconds: 700_000_000)
            // 签名开始前开启后台保活（静音音频 + 后台任务双保险）
            if signingState.isSigning {
                BackgroundKeepAlive.shared.start(reason: .signing)
            }
            signingState.beginSigningIfNeeded()
        }
        .onReceive(signingState.$isSigning) { signing in
            // 签名结束（成功或失败）后释放签名保活
            if !signing {
                BackgroundKeepAlive.shared.stop(reason: .signing)
            }
        }
        .alert("安装", isPresented: Binding(
            get: { installMessage != nil },
            set: { if !$0 { installMessage = nil } }
        )) {
            Button("确定") { installMessage = nil }
        } message: {
            Text(installMessage ?? "")
        }
        .alert("未检测到安装确认", isPresented: $showInstallTimeout) {
            Button("重试安装") {
                isInstalling = false
                retryInstall()
            }
            Button("取消", role: .cancel) {
                isInstalling = false
                signingState.addLog("⏹ 90 秒内未检测到设备拉取，已取消追踪")
            }
        } message: {
            Text("超过 90 秒未检测到设备拉取安装包，\n可能已在系统弹窗中点了取消。")
        }
    }

    /// 顶部状态卡（进行中 / 成功 / 失败）
    @ViewBuilder
    private var statusCard: some View {
        let success = signingState.outputURL != nil && signingState.errorMessage == nil && !signingState.isSigning
        let failed = signingState.errorMessage != nil && !signingState.isSigning

        HStack(spacing: 12) {
            DSIconBadge(
                systemName: signingState.isSigning ? "gearshape.2.fill" : (success ? "checkmark.circle.fill" : "xmark.circle.fill"),
                color: signingState.isSigning ? DS.primary : (success ? DS.success : DS.destructive),
                size: 42
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(signingState.isSigning ? "正在签名" : (success ? "签名完成" : "签名失败"))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text(success ? "可以安装或稍后在「已签名」中查看" : (failed ? signingState.errorMessage! : "请勿离开此页面"))
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .dsCard(padding: 12)
    }

    private func installApp() {
        guard let url = signingState.outputURL else { return }
        isInstalling = true
        lastInstalledIPA = url
        // 安装等待确认期间保活（对齐 LCSign 的 installKeepAliveHeld）
        BackgroundKeepAlive.shared.start(reason: .installing)
        signingState.addLog("开始安装 \(url.lastPathComponent) ...")
        signingState.addLog("启动本地安装服务器...")

        // 安装确认追踪（对齐 LCSign 的 InstallActionTracker：>90s 未拉取判定取消）
        installEventTask?.cancel()
        installEventTask = Task { [weak signingState] in
            guard let signingState else { return }
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if isInstalling {
                    showInstallTimeout = true
                }
            }
        }

        IPAInstaller.install(
            ipaURL: url,
            appName: app.name,
            bundleID: app.bundleID,
            version: app.version,
            onEvent: { event in
                switch event {
                case .serverReady:
                    signingState.addLog("等待设备拉取安装包（90 秒内未确认将提示）")
                case .deviceFetching:
                    signingState.addLog("✓ 设备已开始拉取 IPA，请在系统弹窗中确认安装")
                    // 收到拉取事件后取消超时追踪
                    installEventTask?.cancel()
                }
            }
        ) { result in
            isInstalling = false
            switch result {
            case .success:
                signingState.addLog("已触发系统安装，请在弹窗中确认")
            case .failed(let msg):
                signingState.addLog("⚠️ 安装失败：\(msg)")
                installMessage = msg
            }
            // 安装回调结束后延迟释放保活，给系统安装确认弹窗留缓冲时间
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                BackgroundKeepAlive.shared.stop(reason: .installing)
            }
        }
    }

    /// 安装超时后的重试
    private func retryInstall() {
        guard let url = lastInstalledIPA else { return }
        signingState.addLog("↻ 重新发起安装...")
        installApp()
    }
}
