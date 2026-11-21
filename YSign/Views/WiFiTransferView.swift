import SwiftUI

/// WiFi 文件传输页面
///
/// 交互对齐参考实现（FreeSign / LCSign）：
/// - 进入页面自动启动本地 HTTP 服务，无需手动点击
/// - 地址高亮展示 + 一键复制
/// - 明确提示传输期间勿锁屏/退出页面
/// - 8080 被占用时自动回退备用端口（8088–8092）
/// - 服务通过 Bonjour 注册为 "YSign"，局域网内可被发现
///
/// 电脑浏览器通过地址访问：上传 / 下载 / 删除文件（保存于文件页）。
struct WiFiTransferView: View {

    /// 服务器是否运行中
    @State private var isRunning = false

    /// 服务器地址（如 http://192.168.1.100:8080）
    @State private var serverAddress = ""

    /// HTTP 服务器实例
    @State private var server: WiFiFileServer?

    /// 错误提示
    @State private var errorMessage = ""

    /// 地址已复制
    @State private var copied = false

    /// 端口尝试顺序（主端口被占用时依次回退）
    private let candidatePorts: [UInt16] = [8080, 8088, 8089, 8090, 8091, 8092]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard

                if isRunning {
                    addressCard
                    hintCard
                    Button(role: .destructive) {
                        stopServer()
                    } label: {
                        Label("停止传输", systemImage: "stop.fill")
                    }
                    .buttonStyle(DSPrimaryButtonStyle(color: DS.destructive))
                } else {
                    descriptionCard
                    Button {
                        startServer()
                    } label: {
                        Label("开启传输", systemImage: "play.fill")
                    }
                    .buttonStyle(DSPrimaryButtonStyle())
                }

                if !errorMessage.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(DS.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dsCard()
                }
            }
            .padding(DS.paddingScreen)
        }
        .background(DS.background.ignoresSafeArea())
        .navigationTitle("WiFi 文件传输")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 进入页面自动开启（对齐参考实现）
            if !isRunning { startServer() }
        }
        .onDisappear {
            // 离开页面自动停止
            if isRunning { stopServer() }
        }
    }

    // MARK: - 区块

    /// 状态卡：图标 + 运行状态
    private var statusCard: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isRunning ? DS.primarySoft : DS.cardMuted)
                    .frame(width: 92, height: 92)
                Image(systemName: "wifi")
                    .font(.system(size: 36, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isRunning ? DS.primary : DS.textTertiary)
            }
            Text(isRunning ? "传输服务运行中" : "传输服务未开启")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(DS.text)
            Text(isRunning ? "电脑浏览器访问下方地址即可互传文件" : "开启后可通过电脑浏览器互传文件")
                .font(.subheadline)
                .foregroundStyle(DS.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .dsCard()
    }

    /// 地址卡：大字地址 + 复制
    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                DSIconBadge(systemName: "desktopcomputer", color: DS.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("在电脑浏览器打开")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.text)
                    Text("电脑与设备需在同一局域网")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                }
                Spacer()
            }

            Text(serverAddress)
                .font(.system(.title3, design: .monospaced, weight: .bold))
                .foregroundStyle(DS.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: DS.cornerM)
                        .fill(DS.primarySoft)
                )

            Button {
                UIPasteboard.general.string = serverAddress
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copied = false
                }
            } label: {
                Label(copied ? "已复制" : "复制地址", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
            }
            .buttonStyle(DSSecondaryButtonStyle())
        }
        .dsCard()
    }

    /// 提示卡
    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("使用提示")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.text)
            hintRow("tray.and.arrow.up", "浏览器选择文件即可上传到本机「文件」页")
            hintRow("tray.and.arrow.down", "点击文件名即可下载到电脑")
            hintRow("lock.display", "传输过程中请勿锁屏或退出本页面")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    /// 未运行时的说明卡
    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("功能说明")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(DS.text)
            hintRow("wifi", "开启后在本机与电脑之间通过 WiFi 互传文件")
            hintRow("safari", "电脑浏览器输入页面显示的局域网地址")
            hintRow("square.and.arrow.up", "上传的文件可在「文件」页查看与管理")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func hintRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(DS.primary)
                .frame(width: 22)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 服务器控制

    /// 启动 HTTP 服务器（端口占用时自动回退）
    private func startServer() {
        guard let ip = getWiFiAddress(), !ip.isEmpty else {
            errorMessage = "未检测到 WiFi 连接，请加入局域网后重试"
            return
        }

        for port in candidatePorts {
            let srv = WiFiFileServer(port: port)
            do {
                try srv.start()
                server = srv
                serverAddress = "http://\(ip):\(port)"
                isRunning = true
                errorMessage = ""
                // 传输服务运行期间保活（防锁屏中断）
                BackgroundKeepAlive.shared.start(reason: .wifiTransfer)
                return
            } catch {
                // 尝试下一个端口
                continue
            }
        }
        errorMessage = "无法启动服务：8080 与备用端口均被占用"
    }

    /// 停止 HTTP 服务器
    private func stopServer() {
        server?.stop()
        server = nil
        isRunning = false
        serverAddress = ""
        BackgroundKeepAlive.shared.stop(reason: .wifiTransfer)
    }

    // MARK: - 网络工具

    /// 获取设备的 WiFi IP 地址
    ///
    /// 注意：ifa_addr 可能为 nil（无地址的网络接口），
    /// 必须安全解包，否则进入页面/启动服务时直接崩溃。
    private func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let start = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = start
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }

            // 跳过没有地址的接口（ifa_addr 为 nil 时强解包会崩溃）
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            // 只查找 en0（WiFi 接口）
            let name = String(cString: current.pointee.ifa_name)
            guard name == "en0" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)
                if !ip.isEmpty { address = ip }
            }
        }

        return address
    }
}
