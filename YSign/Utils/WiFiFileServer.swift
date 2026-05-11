import Foundation
import Network

/// 局域网文件传输 HTTP 服务器
///
/// 用 `Network.framework` 原生 TCP 写的极简 HTTP/1.1 服务器，
/// 不引入任何第三方依赖。
///
/// 功能：
/// - `GET /` 文件列表网页
/// - `GET /files/<name>` 下载文件
/// - `POST /upload` 通过 multipart/form-data 上传文件
///
/// 只服务 Documents 根目录（不含应用内部隐藏目录）。
final class WiFiFileServer {

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.ysign.wifiserver")

    /// 要暴露给用户的根目录（Documents）
    private let rootDirectory: URL

    /// 隐藏的内部目录名（不暴露给 Web 端）
    private let hiddenNames: Set<String> = [
        "YSign", "Certificates", "Profiles", "Library",
        "Sources", "Branding", "Signed",
    ]

    init(port: UInt16 = 8080) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.rootDirectory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)

        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - 连接处理

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    /// 累积读取直到找到 HTTP 头部结束（\r\n\r\n）。
    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, err in
            guard let self = self else { return }
            if let err = err {
                print("[WiFiServer] receive error: \(err)")
                conn.cancel(); return
            }
            var buf = buffer
            if let d = data { buf.append(d) }

            // 找到 header/body 分界
            guard let headerEnd = buf.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else {
                // 尚未完整收到头部，继续读
                if buf.count > 2_000_000 {
                    self.writeSimple(conn, status: "400 Bad Request", body: "Header too large")
                    return
                }
                self.readRequest(conn, buffer: buf)
                return
            }

            let headerData = buf.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerStr = String(data: headerData, encoding: .utf8) else {
                self.writeSimple(conn, status: "400 Bad Request", body: "Invalid header")
                return
            }

            let bodyStart = headerEnd.upperBound
            let body = buf.subdata(in: bodyStart..<buf.count)

            let contentLength = Self.parseHeaderInt(headerStr, "Content-Length") ?? 0
            if body.count < contentLength {
                // 继续读取剩余 body
                self.readBody(conn, header: headerStr, body: body, total: contentLength)
            } else {
                self.route(conn, header: headerStr, body: body)
            }
        }
    }

    private func readBody(_ conn: NWConnection, header: String, body: Data, total: Int) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, err in
            guard let self = self else { return }
            if let err = err {
                print("[WiFiServer] body receive error: \(err)")
                conn.cancel(); return
            }
            var b = body
            if let d = data { b.append(d) }

            if b.count < total {
                self.readBody(conn, header: header, body: b, total: total)
            } else {
                self.route(conn, header: header, body: b)
            }
        }
    }

    // MARK: - 路由

    private func route(_ conn: NWConnection, header: String, body: Data) {
        let firstLine = header.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            writeSimple(conn, status: "400 Bad Request", body: "")
            return
        }
        let method = parts[0]
        let rawPath = parts[1]
        let path = (rawPath.removingPercentEncoding ?? rawPath).components(separatedBy: "?").first ?? "/"

        switch (method, path) {
        case ("GET", "/"):
            handleIndex(conn)
        case ("POST", "/upload"):
            handleUpload(conn, header: header, body: body)
        case ("GET", let p) where p.hasPrefix("/files/"):
            let name = String(p.dropFirst("/files/".count))
            handleDownload(conn, name: name)
        case ("GET", let p) where p.hasPrefix("/delete/"):
            let name = String(p.dropFirst("/delete/".count))
            handleDelete(conn, name: name)
        default:
            writeSimple(conn, status: "404 Not Found", body: "Not Found")
        }
    }

    // MARK: - 处理函数

    private func handleIndex(_ conn: NWConnection) {
        let html = buildIndexHTML()
        writeResponse(conn, status: "200 OK", contentType: "text/html; charset=utf-8", body: html.data(using: .utf8) ?? Data())
    }

    private func handleDownload(_ conn: NWConnection, name: String) {
        let safe = (name.removingPercentEncoding ?? name)
        guard !safe.contains("/"), !safe.contains(".."), !hiddenNames.contains(safe) else {
            writeSimple(conn, status: "403 Forbidden", body: "")
            return
        }
        let url = rootDirectory.appendingPathComponent(safe)
        guard let data = try? Data(contentsOf: url) else {
            writeSimple(conn, status: "404 Not Found", body: "File not found")
            return
        }
        let encoded = Self.rfc5987Encode(safe)
        let extra = "Content-Disposition: attachment; filename*=UTF-8''\(encoded)"
        writeResponse(conn, status: "200 OK", contentType: "application/octet-stream", body: data, extraHeaders: [extra])
    }

    private func handleDelete(_ conn: NWConnection, name: String) {
        let safe = (name.removingPercentEncoding ?? name)
        guard !safe.contains("/"), !safe.contains(".."), !hiddenNames.contains(safe) else {
            writeSimple(conn, status: "403 Forbidden", body: "")
            return
        }
        let url = rootDirectory.appendingPathComponent(safe)
        try? FileManager.default.removeItem(at: url)
        writeRedirect(conn, to: "/")
    }

    private func handleUpload(_ conn: NWConnection, header: String, body: Data) {
        // 解析 boundary
        guard let contentType = Self.parseHeaderString(header, "Content-Type"),
              let range = contentType.range(of: "boundary=") else {
            writeSimple(conn, status: "400 Bad Request", body: "Missing boundary")
            return
        }
        var boundary = String(contentType[range.upperBound...])
        if boundary.hasPrefix("\"") {
            boundary = String(boundary.dropFirst().dropLast())
        }
        let boundaryData = ("--" + boundary).data(using: .utf8)!
        let crlf = Data([0x0d, 0x0a])

        // 按 boundary 拆分
        let parts = Self.split(body, separator: boundaryData)
        for part in parts {
            var p = part
            // 去掉开头 \r\n
            if p.prefix(2) == crlf { p = p.suffix(from: p.startIndex.advanced(by: 2)) }
            // 去掉末尾 \r\n
            if p.suffix(2) == crlf { p = p.prefix(p.count - 2) }
            if p.isEmpty { continue }

            // 找 part header end
            guard let hEnd = p.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else { continue }
            let partHeaderData = p.subdata(in: 0..<hEnd.lowerBound)
            let content = p.subdata(in: hEnd.upperBound..<p.count)
            guard let headerStr = String(data: partHeaderData, encoding: .utf8) else { continue }

            // 提取 filename
            guard let disp = Self.parseHeaderString(headerStr, "Content-Disposition"),
                  let fileName = Self.parseFilename(from: disp), !fileName.isEmpty else {
                continue
            }

            // 拒绝路径穿越和隐藏目录名
            let safeName = fileName.replacingOccurrences(of: "/", with: "_")
            if safeName.contains(".."), hiddenNames.contains(safeName) { continue }

            let dest = rootDirectory.appendingPathComponent(safeName)
            try? content.write(to: dest, options: .atomic)
        }

        writeRedirect(conn, to: "/")
    }

    // MARK: - HTML 构建

    private func buildIndexHTML() -> String {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []

        let visible = items
            .filter { !hiddenNames.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var rows = ""
        for url in visible {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let sizeText = isDir ? "—" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            let encName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            let icon = isDir ? "📁" : "📄"
            let action = isDir
                ? ""
                : "<a href=\"/files/\(encName)\" download>下载</a> · <a href=\"/delete/\(encName)\" onclick=\"return confirm('删除 \(name) ?')\">删除</a>"
            rows += """
                <tr>
                    <td>\(icon) \(Self.escape(name))</td>
                    <td>\(sizeText)</td>
                    <td>\(action)</td>
                </tr>
                """
        }

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>YSign 文件传输</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Arial, sans-serif; background: #f5f5f7; margin: 0; padding: 20px; color: #1d1d1f; }
                .container { max-width: 800px; margin: 0 auto; background: white; border-radius: 12px; padding: 24px; box-shadow: 0 2px 12px rgba(0,0,0,0.05); }
                h1 { margin-top: 0; font-size: 22px; }
                .upload { border: 2px dashed #d2d2d7; border-radius: 10px; padding: 20px; text-align: center; margin-bottom: 20px; }
                .upload input[type=file] { margin: 8px 0; }
                .upload button { background: #0071e3; color: white; border: 0; padding: 10px 24px; border-radius: 8px; font-size: 15px; cursor: pointer; }
                table { width: 100%; border-collapse: collapse; }
                th, td { text-align: left; padding: 10px 8px; border-bottom: 1px solid #f0f0f2; font-size: 14px; }
                th { color: #86868b; font-weight: 500; }
                a { color: #0071e3; text-decoration: none; }
                a:hover { text-decoration: underline; }
                .empty { text-align: center; color: #86868b; padding: 40px; }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>YSign 文件传输</h1>
                <form class="upload" action="/upload" method="POST" enctype="multipart/form-data">
                    <div>选择文件上传到 Documents</div>
                    <input type="file" name="file" required multiple>
                    <br><button type="submit">上传</button>
                </form>
                \(visible.isEmpty
                    ? "<div class=\"empty\">目录为空</div>"
                    : "<table><thead><tr><th>名称</th><th>大小</th><th>操作</th></tr></thead><tbody>\(rows)</tbody></table>"
                )
            </div>
        </body>
        </html>
        """
    }

    // MARK: - HTTP 响应写入

    private func writeResponse(_ conn: NWConnection, status: String, contentType: String, body: Data, extraHeaders: [String] = []) {
        var headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Connection: close",
        ]
        headers.append(contentsOf: extraHeaders)
        let headerStr = headers.joined(separator: "\r\n") + "\r\n\r\n"
        var data = headerStr.data(using: .utf8) ?? Data()
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func writeSimple(_ conn: NWConnection, status: String, body: String) {
        writeResponse(conn, status: status, contentType: "text/plain; charset=utf-8", body: body.data(using: .utf8) ?? Data())
    }

    private func writeRedirect(_ conn: NWConnection, to location: String) {
        let headers = [
            "HTTP/1.1 303 See Other",
            "Location: \(location)",
            "Content-Length: 0",
            "Connection: close",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        conn.send(content: headers.data(using: .utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - 工具

    private static func parseHeaderString(_ header: String, _ name: String) -> String? {
        for line in header.components(separatedBy: "\r\n") {
            let prefix = "\(name):"
            if line.lowercased().hasPrefix(prefix.lowercased()) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func parseHeaderInt(_ header: String, _ name: String) -> Int? {
        guard let v = parseHeaderString(header, name) else { return nil }
        return Int(v)
    }

    private static func parseFilename(from disposition: String) -> String? {
        // filename*=UTF-8''xxx 或 filename="xxx"
        if let r = disposition.range(of: "filename*=") {
            var v = String(disposition[r.upperBound...])
            if let end = v.range(of: ";")?.lowerBound { v = String(v[..<end]) }
            if let r2 = v.range(of: "''") {
                let raw = String(v[r2.upperBound...]).trimmingCharacters(in: .whitespaces)
                return raw.removingPercentEncoding ?? raw
            }
        }
        if let r = disposition.range(of: "filename=") {
            var v = String(disposition[r.upperBound...])
            if let end = v.range(of: ";")?.lowerBound { v = String(v[..<end]) }
            v = v.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") { v = String(v.dropFirst().dropLast()) }
            return v
        }
        return nil
    }

    private static func rfc5987Encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 按二进制分隔符拆分 Data
    private static func split(_ data: Data, separator: Data) -> [Data] {
        var result: [Data] = []
        var start = data.startIndex
        while start < data.endIndex,
              let r = data.range(of: separator, in: start..<data.endIndex) {
            if r.lowerBound > start {
                result.append(data.subdata(in: start..<r.lowerBound))
            }
            start = r.upperBound
        }
        if start < data.endIndex {
            result.append(data.subdata(in: start..<data.endIndex))
        }
        return result
    }
}
