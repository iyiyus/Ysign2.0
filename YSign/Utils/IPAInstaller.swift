import Foundation
import UIKit
import Network

/// IPA 安装器
///
/// 安装方式（与旧项目一致）：
/// 1. TrollStore：本地 HTTP 服务 IPA → apple-magnifier:// URL Scheme 安装
/// 2. itms-services：本地 HTTP 服务 IPA → 远程 HTTPS 服务器生成 manifest.plist → 系统弹窗安装
class IPAInstaller: NSObject {

    static let shared = IPAInstaller()

    /// 安装结果
    enum InstallResult {
        case success
        case failed(String)
    }

    private var httpServer: SimpleHTTPServer?
    private let port: UInt16 = 9800

    /// 安装 IPA 到设备
    /// - Parameters:
    ///   - ipaURL: 签名后的 IPA 文件路径
    ///   - appName: App 名称
    ///   - bundleID: Bundle ID
    ///   - version: 版本号
    ///   - completion: 回调
    static func install(
        ipaURL: URL,
        appName: String? = nil,
        bundleID: String? = nil,
        version: String? = nil,
        completion: @escaping (InstallResult) -> Void
    ) {
        shared.installIPA(
            ipaURL: ipaURL,
            appName: appName ?? ipaURL.deletingPathExtension().lastPathComponent,
            bundleID: bundleID ?? "com.unknown.app",
            version: version ?? "1.0",
            completion: completion
        )
    }

    private func installIPA(
        ipaURL: URL,
        appName: String,
        bundleID: String,
        version: String,
        completion: @escaping (InstallResult) -> Void
    ) {
        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            completion(.failed("IPA 文件不存在"))
            return
        }

        guard let ipaData = try? Data(contentsOf: ipaURL, options: .mappedIfSafe) else {
            completion(.failed("无法读取 IPA 文件"))
            return
        }

        // 停止之前的服务器
        httpServer?.stop()
        httpServer = nil

        let server = SimpleHTTPServer(port: port)

        // 注册 IPA 下载路由
        server.addRoute("/app.ipa") {
            return HTTPResponse(
                statusCode: 200,
                contentType: "application/octet-stream",
                body: ipaData
            )
        }

        do {
            try server.start()
            self.httpServer = server
        } catch {
            completion(.failed("启动安装服务器失败：\(error.localizedDescription)"))
            return
        }

        let useTrollStore = UserDefaults.standard.bool(forKey: "trollStoreEnable")

        if useTrollStore {
            // TrollStore 模式
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let trollURL = URL(string: "apple-magnifier://install?url=http://127.0.0.1:\(self.port)/app.ipa")!
                UIApplication.shared.open(trollURL, options: [:]) { success in
                    if !success {
                        completion(.failed("无法打开 TrollStore，请确认已安装并开启 URL Scheme"))
                    } else {
                        completion(.success)
                    }
                }
            }
        } else {
            // itms-services 模式
            // 本地服务器提供 IPA，远程 HTTPS plist.php 生成 manifest
            let localIP = SimpleHTTPServer.getLocalIPAddress()
            let localIPAURL = "http://\(localIP):\(port)/app.ipa"

            print("[IPAInstaller] 本地 IP: \(localIP), IPA URL: \(localIPAURL)")

            // 获取服务器列表
            let servers = IPAInstallServerStore.loadServers()
            let activeServers = servers.filter { $0.isEnabled }

            if activeServers.isEmpty {
                completion(.failed("未配置安装服务器，请在「设置 → IPA 安装服务器」中添加"))
                return
            }

            print("[IPAInstaller] 可用服务器: \(activeServers.map { $0.url })")

            // 构建加密参数: bundleName,iconURL,bundleID,ipaURL → base64 → 字符替换
            // 注意：appName 中的逗号会破坏 plist.php 的解析，需要移除
            let safeAppName = appName.replacingOccurrences(of: ",", with: " ")
            let brandIconURL = BrandConfig.loadFromBundle().appIconURL
            let paramStr = "\(safeAppName),\(brandIconURL),\(bundleID),\(localIPAURL)"
            let encryptedParam = Self.encryptParam(paramStr)

            print("[IPAInstaller] 明文参数: \(paramStr)")
            print("[IPAInstaller] 加密参数: \(encryptedParam)")

            // 尝试第一个可用的服务器
            self.tryInstallWithServers(
                servers: activeServers,
                index: 0,
                encryptedParam: encryptedParam,
                completion: completion
            )
        }
    }

    /// 按顺序尝试服务器，失败自动切换下一个
    private func tryInstallWithServers(
        servers: [IPAInstallServer],
        index: Int,
        encryptedParam: String,
        completion: @escaping (InstallResult) -> Void
    ) {
        guard index < servers.count else {
            completion(.failed("所有安装服务器均不可用"))
            return
        }

        let server = servers[index]
        let plistURL = "\(server.url)?\(encryptedParam)"

        print("[IPAInstaller] 尝试服务器[\(index)]: \(server.url)")
        print("[IPAInstaller] plist URL: \(plistURL)")

        guard let testURL = URL(string: plistURL) else {
            print("[IPAInstaller] URL 无效，跳过")
            tryInstallWithServers(servers: servers, index: index + 1, encryptedParam: encryptedParam, completion: completion)
            return
        }

        var request = URLRequest(url: testURL)
        request.timeoutInterval = 8

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("[IPAInstaller] 服务器 \(server.url) 请求失败: \(error.localizedDescription)")
                self?.tryInstallWithServers(servers: servers, index: index + 1, encryptedParam: encryptedParam, completion: completion)
                return
            }

            let httpResp = response as? HTTPURLResponse
            let statusCode = httpResp?.statusCode ?? 0
            print("[IPAInstaller] 服务器响应状态: \(statusCode)")

            if let data = data, let body = String(data: data, encoding: .utf8) {
                print("[IPAInstaller] 服务器响应内容(前500字符): \(String(body.prefix(500)))")
            }

            guard statusCode == 200 else {
                print("[IPAInstaller] 服务器返回非200，尝试下一个")
                self?.tryInstallWithServers(servers: servers, index: index + 1, encryptedParam: encryptedParam, completion: completion)
                return
            }

            // 服务器可用，构建 itms-services 链接
            let installString = "itms-services://?action=download-manifest&url=\(plistURL)"
            print("[IPAInstaller] itms-services URL: \(installString)")

            guard let installURL = URL(string: installString) else {
                DispatchQueue.main.async {
                    completion(.failed("生成安装链接失败"))
                }
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UIApplication.shared.open(installURL, options: [:]) { success in
                    print("[IPAInstaller] open URL result: \(success)")
                    if !success {
                        completion(.failed("系统未能打开安装链接"))
                    }
                }
            }
        }.resume()
    }

    /// 加密参数：base64 编码后替换特殊字符（与 plist.php 解密逻辑对应）
    static func encryptParam(_ raw: String) -> String {
        let base64 = Data(raw.utf8).base64EncodedString()
        return base64
            .replacingOccurrences(of: "=", with: "mangotool")
            .replacingOccurrences(of: "/", with: "mangosign")
            .replacingOccurrences(of: "+", with: "qq1603175")
    }

    /// 测试服务器延迟（ms），用于设置页面展示。
    ///
    /// 这里不会真的触发安装，只是构造一个最小测试请求，
    /// 用来判断该 `plist.php` 服务是否在线，以及大致响应速度。
    static func testServerLatency(url: String) async -> (ok: Bool, latencyMs: Int) {
        let testParam = encryptParam("Test,,com.test.app,http://127.0.0.1/test.ipa")
        let fullURL = "\(url)?\(testParam)"
        guard let requestURL = URL(string: fullURL) else {
            return (false, 0)
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 10

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let end = CFAbsoluteTimeGetCurrent()
            let ms = Int((end - start) * 1000)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                return (true, ms)
            }
            return (false, ms)
        } catch {
            return (false, 0)
        }
    }
 }

 // MARK: - IPA 安装服务器模型与存储

 /// 单个安装服务器模型。
 ///
 /// 对应一个可用的 `plist.php` 服务地址，
 /// 在 itms-services 安装模式下会按顺序尝试这些服务器。
 struct IPAInstallServer: Identifiable, Codable, Equatable {
     /// 行级唯一标识，用于列表渲染和测速结果映射。
     var id = UUID()

     /// 服务器 URL。
     /// 一般形如：`https://example.com/plist.php`
     var url: String

     /// 是否启用该服务器。
     /// 被关闭的服务器不会参与自动安装尝试。
     var isEnabled: Bool = true
 }

 /// 安装服务器存储器。
 ///
 /// 这里继续使用 `UserDefaults`，因为：
 /// - 数据量很小
 /// - 读取频率低
 /// - 启动时需要立即拿到结果
 class IPAInstallServerStore {
     private static let key = "ipaInstallServers"

     /// 读取本地已保存的安装服务器列表。
     static func loadServers() -> [IPAInstallServer] {
         guard let data = UserDefaults.standard.data(forKey: key),
               let servers = try? JSONDecoder().decode([IPAInstallServer].self, from: data) else {
             return []
         }
         return servers
     }

     /// 保存安装服务器列表。
     static func saveServers(_ servers: [IPAInstallServer]) {
         if let data = try? JSONEncoder().encode(servers) {
             UserDefaults.standard.set(data, forKey: key)
         }
     }

     /// 根据贴牌配置补充默认安装服务器。
     ///
     /// 策略和默认软件源一致：只在本地完全为空时写入，
     /// 这样不会覆盖用户手动维护过的服务器顺序与启用状态。
     static func seedDefaults(from urls: [String]) {
         let normalized = urls
             .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
             .filter { !$0.isEmpty }

         guard !normalized.isEmpty else { return }
         guard loadServers().isEmpty else { return }

         saveServers(normalized.map { IPAInstallServer(url: $0, isEnabled: true) })
     }

     /// 按品牌配置覆盖更新安装服务器列表。
     ///
     /// 当启用了在线贴牌配置后，远端下发的安装服务器应当视为当前品牌的权威列表，
     /// 因此这里直接覆盖本地保存值，以确保服务器增删改能立即体现在安装流程中。
     static func applyManagedServers(from urls: [String]) {
         let normalized = urls
             .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
             .filter { !$0.isEmpty }

         saveServers(normalized.map { IPAInstallServer(url: $0, isEnabled: true) })
     }
 }

 // MARK: - 轻量 HTTP 服务器

 /// HTTP 响应对象。
 ///
 /// 用于把本地生成的 IPA 数据包装成一个最小可用的 HTTP 响应。
 struct HTTPResponse {
     let statusCode: Int
     let contentType: String
     let body: Data
 }

 /// 基于 NWListener 的轻量 HTTP 服务器。
 ///
 /// 当前主要用途只有一个：
 /// 把本机生成好的 IPA 暂时暴露成一个局域网 URL，供安装服务器生成 manifest 使用。
 class SimpleHTTPServer {
     /// 监听端口。
     private let port: UInt16

     /// 底层网络监听器。
     private var listener: NWListener?

     /// 路由表。
     /// 键是路径，例如 `/app.ipa`；值是返回响应的闭包。
     private var routes: [String: () -> HTTPResponse] = [:]

     /// 当前活跃连接。
     /// 在 stop 时统一取消，避免资源泄漏。
     private var connections: [NWConnection] = []

     init(port: UInt16) {
         self.port = port
     }

     /// 注册一个静态路由。
     func addRoute(_ path: String, handler: @escaping () -> HTTPResponse) {
         routes[path] = handler
     }

     /// 启动监听。
     func start() throws {
         let params = NWParameters.tcp
         params.allowLocalEndpointReuse = true
         listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
         listener?.newConnectionHandler = { [weak self] connection in
             self?.handleConnection(connection)
         }
         listener?.start(queue: .global(qos: .userInitiated))
     }

     /// 停止服务器并清理连接。
     func stop() {
         listener?.cancel()
         listener = nil
         for conn in connections {
             conn.cancel()
         }
         connections.removeAll()
     }

     /// 处理单个入站连接。
     private func handleConnection(_ connection: NWConnection) {
         connections.append(connection)
         connection.start(queue: .global(qos: .userInitiated))

         connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
             guard let self = self, let data = data, error == nil else {
                 connection.cancel()
                 return
             }

             let request = String(data: data, encoding: .utf8) ?? ""
             let path = self.parseRequestPath(request)

             if let handler = self.routes[path] {
                 let response = handler()
                 self.sendResponse(connection: connection, response: response)
             } else {
                 let notFound = HTTPResponse(
                     statusCode: 404,
                     contentType: "text/plain",
                     body: "Not Found".data(using: .utf8)!
                 )
                 self.sendResponse(connection: connection, response: notFound)
             }
         }
     }

     /// 从原始 HTTP 请求报文中解析路径。
     private func parseRequestPath(_ request: String) -> String {
         let lines = request.components(separatedBy: "\r\n")
         guard let firstLine = lines.first else { return "/" }
         let parts = firstLine.components(separatedBy: " ")
         guard parts.count >= 2 else { return "/" }
         let fullPath = parts[1]
         return fullPath.components(separatedBy: "?").first ?? fullPath
     }

     /// 获取本机 WiFi IP 地址。
     ///
     /// 当前优先读取 `en0`，这对大多数 iPhone / iPad 的 Wi‑Fi 场景是成立的。
     static func getLocalIPAddress() -> String {
         var address = "127.0.0.1"
         var ifaddr: UnsafeMutablePointer<ifaddrs>?
         if getifaddrs(&ifaddr) == 0 {
             var ptr = ifaddr
             while ptr != nil {
                 defer { ptr = ptr?.pointee.ifa_next }
                 guard let interface = ptr?.pointee else { continue }
                 let addrFamily = interface.ifa_addr.pointee.sa_family
                 if addrFamily == UInt8(AF_INET) {
                     let name = String(cString: interface.ifa_name)
                     if name == "en0" {
                         var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                         getnameinfo(
                             interface.ifa_addr,
                             socklen_t(interface.ifa_addr.pointee.sa_len),
                             &hostname,
                             socklen_t(hostname.count),
                             nil,
                             socklen_t(0),
                             NI_NUMERICHOST
                         )
                         address = String(cString: hostname)
                     }
                 }
             }
             freeifaddrs(ifaddr)
         }
         return address
     }

     /// 发送 HTTP 响应。
     private func sendResponse(connection: NWConnection, response: HTTPResponse) {
         var header = "HTTP/1.1 \(response.statusCode) OK\r\n"
         header += "Content-Type: \(response.contentType)\r\n"
         header += "Content-Length: \(response.body.count)\r\n"
         header += "Connection: close\r\n"
         header += "\r\n"

         var responseData = header.data(using: .utf8)!
         responseData.append(response.body)

         connection.send(content: responseData, completion: .contentProcessed { _ in
             connection.cancel()
         })
     }
 }
