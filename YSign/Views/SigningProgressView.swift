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

    /// 退出到应用页的回调
    var onExit: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // 日志滚动区域
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(signingState.logs.enumerated()), id: \.offset) { index, log in
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                    // 锚点，用于自动滚动到底部
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 签名中：进度条
            if signingState.isSigning {
                VStack(spacing: 6) {
                    ProgressView(value: signingState.progress)
                        .tint(.blue)
                    HStack {
                        Text(signingState.stage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(String(format: "%.1f", signingState.progress * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }

            // 签名完成/失败：底部按钮
            if !signingState.isSigning {
                Divider()
                HStack(spacing: 16) {
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
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .disabled(isInstalling)
                    }

                    Button {
                        onExit?()
                    } label: {
                        Text("退出")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(signingState.errorMessage != nil ? Color.red : Color(.systemGray5))
                            .foregroundColor(signingState.errorMessage != nil ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .background(Color(.systemBackground))
            }
        }
        .navigationTitle("签名")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(signingState.isSigning || isInstalling)
        .toolbar(.hidden, for: .tabBar)
        .task {
            // 等待导航/Liquid Glass 转场动画完全结束后再开始签名
            try? await Task.sleep(nanoseconds: 700_000_000)
            signingState.beginSigningIfNeeded()
        }
        .alert("安装", isPresented: Binding(
            get: { installMessage != nil },
            set: { if !$0 { installMessage = nil } }
        )) {
            Button("确定") { installMessage = nil }
        } message: {
            Text(installMessage ?? "")
        }
    }

    private func installApp() {
        guard let url = signingState.outputURL else { return }
        isInstalling = true
        signingState.addLog("开始安装 \(url.lastPathComponent) ...")
        signingState.addLog("启动本地安装服务器...")

        IPAInstaller.install(
            ipaURL: url,
            appName: app.name,
            bundleID: app.bundleID,
            version: app.version
        ) { result in
            isInstalling = false
            switch result {
            case .success:
                signingState.addLog("已触发系统安装，请在弹窗中确认")
            case .failed(let msg):
                signingState.addLog("⚠️ 安装失败：\(msg)")
                installMessage = msg
            }
        }
    }
}
