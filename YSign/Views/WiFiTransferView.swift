import SwiftUI

/// WiFi 文件传输页面
///
/// 对应旧版的 WiFi 文件传输功能。
/// 启动一个本地 HTTP 服务器，让电脑通过浏览器上传/下载文件。
///
/// 技术实现：
/// - 使用 NWListener (Network.framework) 创建 HTTP 服务器
/// - 监听局域网端口，提供简单的文件上传/下载 Web 界面
/// - 文件保存到 Documents 目录
struct WiFiTransferView: View {

    /// 服务器是否运行中
    @State private var isRunning = false

    /// 服务器地址（如 http://192.168.1.100:8080）
    @State private var serverAddress = ""

    /// 设备 IP 地址
    @State private var deviceIP = ""

    /// 服务器端口
    private let serverPort: UInt16 = 8080

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // WiFi 图标
            Image(systemName: "wifi")
                .font(.system(size: 80))
                .foregroundStyle(isRunning ? .blue : .secondary)
                .opacity(isRunning ? 1.0 : 0.5)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isRunning)

            if isRunning {
                // 运行中 —— 显示地址
                VStack(spacing: 12) {
                    Text("WiFi 文件传输已开启")
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text("在电脑浏览器中输入以下地址：")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // 地址（大字、可复制）
                    Text(serverAddress)
                        .font(.system(.title2, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                        .textSelection(.enabled)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.blue.opacity(0.1))
                        )

                    Text("注意：电脑与设备必须在同一局域网下\n传输过程中请勿退出此页面或锁屏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // 停止按钮
                Button(role: .destructive) {
                    stopServer()
                } label: {
                    Label("停止传输", systemImage: "stop.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.horizontal, 40)

            } else {
                // 未运行 —— 显示启动按钮
                VStack(spacing: 12) {
                    Text("WiFi 文件传输")
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text("开启后可通过电脑浏览器上传和下载文件")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    startServer()
                } label: {
                    Label("开启传输", systemImage: "play.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 40)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("WiFi 文件传输")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // 离开页面时停止服务器
            if isRunning { stopServer() }
        }
        .onAppear {
            deviceIP = getWiFiAddress() ?? "未连接 WiFi"
        }
    }

    // MARK: - 服务器控制

    /// 启动 HTTP 服务器
    /// 注意：完整实现需要 GCDWebServer 或自定义 NWListener
    /// 这里展示架构框架，实际集成时需添加 GCDWebServer SPM 包
    private func startServer() {
        let ip = getWiFiAddress() ?? "127.0.0.1"
        serverAddress = "http://\(ip):\(serverPort)"
        isRunning = true
        // TODO: 集成 GCDWebServer 或 Swifter HTTP 服务器
        // let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        // webServer = GCDWebUploader(uploadDirectory: documentsPath.path)
        // webServer.start(withPort: serverPort, bonjourName: "YSign")
    }

    /// 停止 HTTP 服务器
    private func stopServer() {
        isRunning = false
        serverAddress = ""
        // TODO: webServer.stop()
    }

    // MARK: - 网络工具

    /// 获取设备的 WiFi IP 地址
    private func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            let interface = ptr?.pointee

            // 只查找 IPv4 地址
            let addrFamily = interface?.ifa_addr.pointee.sa_family
            guard addrFamily == UInt8(AF_INET) else { continue }

            // 只查找 en0（WiFi 接口）
            let name = String(cString: (interface?.ifa_name)!)
            guard name == "en0" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                interface?.ifa_addr,
                socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                &hostname, socklen_t(hostname.count),
                nil, socklen_t(0),
                NI_NUMERICHOST
            )
            address = String(cString: hostname)
        }

        return address
    }
}
