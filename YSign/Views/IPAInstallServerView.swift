import SwiftUI

/// IPA 安装服务器管理页面
///
/// 用户可添加多个 plist.php 服务器地址，
/// 每条记录旁显示延迟(ms)，安装时自动按顺序尝试。
struct IPAInstallServerView: View {

    @State private var servers: [IPAInstallServer] = []
    @State private var showingAddSheet = false
    @State private var newServerURL = ""
    @State private var serverLatencies: [UUID: ServerStatus] = [:]
    @State private var isTesting = false

    @AppStorage("trollStoreEnable") private var trollStoreEnable = false

    /// 安装方式（本地安装 / 服务器中转，与 IPAInstaller.installMode 对应）
    @AppStorage("ipaInstallMode") private var installMode = IPAInstaller.InstallMode.server.rawValue

    enum ServerStatus {
        case testing
        case ok(Int)      // latency ms
        case failed
    }

    var body: some View {
        List {
            // 安装方式切换
            Section {
                Picker("安装方式", selection: $installMode) {
                    ForEach(IPAInstaller.InstallMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(installModeFooter)
            }

            // TrollStore 开关
            Section {
                Toggle("使用 TrollStore 安装", isOn: $trollStoreEnable)
            } footer: {
                Text("开启后将使用 TrollStore 安装，无需配置安装服务器")
            }

            // 服务器列表
            Section {
                if servers.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "server.rack")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("暂无安装服务器")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("点击右上角 + 添加")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 20)
                        Spacer()
                    }
                } else {
                    ForEach(servers) { server in
                        serverRow(server)
                    }
                    .onDelete(perform: deleteServers)
                    .onMove(perform: moveServers)
                }
            } header: {
                HStack {
                    Text("服务器列表（服务器中转模式使用）")
                    Spacer()
                    if !servers.isEmpty {
                        Button {
                            testAllServers()
                        } label: {
                            if isTesting {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Text("测速")
                                    .font(.caption)
                            }
                        }
                        .disabled(isTesting)
                    }
                }
            } footer: {
                Text("安装时将按顺序尝试服务器，不可用时自动切换下一个。服务器地址为部署了 plist.php 的 HTTPS 地址。")
            }
        }
        .navigationTitle("IPA 安装服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    EditButton()
                    Button {
                        newServerURL = ""
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .alert("添加服务器", isPresented: $showingAddSheet) {
            TextField("https://你的域名/plist.php", text: $newServerURL)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button("添加") {
                addServer()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请输入 plist.php 的 HTTPS 地址")
        }
        .onAppear {
            servers = IPAInstallServerStore.loadServers()
            if !servers.isEmpty {
                testAllServers()
            }
        }
    }

    // MARK: - 安装方式说明

    private var installModeFooter: String {
        if installMode == IPAInstaller.InstallMode.local.rawValue {
            return "本地安装：manifest 由本机生成，本地服务器直接承载 IPA 与 manifest 拉起系统安装，无需配置任何服务器。"
        } else {
            return "服务器中转：由远程 plist.php 服务器生成 manifest，需要在下方配置服务器列表。"
        }
    }

    // MARK: - 服务器行

    private func serverRow(_ server: IPAInstallServer) -> some View {
        HStack {
            // 启用/禁用
            Image(systemName: server.isEnabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(server.isEnabled ? .green : .secondary)
                .onTapGesture {
                    toggleServer(server)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(serverDisplayName(server.url))
                    .font(.subheadline)
                    .lineLimit(1)
                Text(server.url)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            // 延迟显示
            latencyBadge(for: server.id)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func latencyBadge(for id: UUID) -> some View {
        switch serverLatencies[id] {
        case .testing:
            ProgressView()
                .scaleEffect(0.7)
        case .ok(let ms):
            Text("\(ms)ms")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.green)
                .monospacedDigit()
        case .failed:
            Text("无响应")
                .font(.caption)
                .foregroundStyle(.red)
        case .none:
            EmptyView()
        }
    }

    private func serverDisplayName(_ url: String) -> String {
        if let host = URL(string: url)?.host {
            return host
        }
        return url
    }

    // MARK: - 操作

    private func addServer() {
        let trimmed = newServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var url = trimmed
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "https://\(url)"
        }

        let server = IPAInstallServer(url: url)
        servers.append(server)
        save()

        // 立即测速
        Task {
            serverLatencies[server.id] = .testing
            let result = await IPAInstaller.testServerLatency(url: server.url)
            serverLatencies[server.id] = result.ok ? .ok(result.latencyMs) : .failed
        }
    }

    private func deleteServers(at offsets: IndexSet) {
        servers.remove(atOffsets: offsets)
        save()
    }

    private func moveServers(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func toggleServer(_ server: IPAInstallServer) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx].isEnabled.toggle()
            save()
        }
    }

    private func testAllServers() {
        isTesting = true
        Task {
            await withTaskGroup(of: (UUID, Bool, Int).self) { group in
                for server in servers {
                    serverLatencies[server.id] = .testing
                    group.addTask {
                        let result = await IPAInstaller.testServerLatency(url: server.url)
                        return (server.id, result.ok, result.latencyMs)
                    }
                }
                for await (id, ok, ms) in group {
                    serverLatencies[id] = ok ? .ok(ms) : .failed
                }
            }
            isTesting = false
        }
    }

    private func save() {
        IPAInstallServerStore.saveServers(servers)
    }
}
