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
/// 只服务 Documents 根目录（不含应用内部 YSign 隐藏目录）。
final class WiFiFileServer {

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.ysign.wifiserver")

    /// 要暴露给用户的根目录（Documents）
    private let rootDirectory: URL

    /// 隐藏的内部目录名（不暴露给 Web 端）
    private let hiddenNames: Set<String> = ["YSign"]

    init(port: UInt16 = 8080) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.rootDirectory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)

        // Bonjour 注册，局域网内可发现（对齐 GCDWebUploader 的 bonjourName）
        listener.service = NWListener.Service(name: "YSign", type: "_http._tcp", domain: nil)

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
            // 对端关闭连接（data == nil）时停止，避免无限递归读
            guard let d = data else {
                conn.cancel(); return
            }
            var buf = buffer
            buf.append(d)

            // 找到 header/body 分界
            guard let headerEnd = buf.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else {
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
            guard let d = data else {
                conn.cancel(); return
            }
            var b = body
            b.append(d)

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
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            writeSimple(conn, status: "404 Not Found", body: "File not found")
            return
        }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let encoded = Self.rfc5987Encode(safe)
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/octet-stream",
            "Content-Length: \(fileSize)",
            "Connection: close",
            "Content-Disposition: attachment; filename*=UTF-8''\(encoded)",
        ].joined(separator: "\r\n") + "\r\n\r\n"

        conn.send(content: headers.data(using: .utf8) ?? Data(), completion: .contentProcessed { [weak self] error in
            if error != nil {
                try? handle.close()
                conn.cancel()
                return
            }
            self?.streamFile(conn, handle: handle)
        })
    }

    /// 分块发送文件（避免大 IPA 一次性载入内存导致 OOM）
    private func streamFile(_ conn: NWConnection, handle: FileHandle) {
        let chunk = (try? handle.readData(ofLength: 256 * 1024)) ?? Data()
        guard !chunk.isEmpty else {
            try? handle.close()
            conn.cancel()
            return
        }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil {
                try? handle.close()
                conn.cancel()
                return
            }
            self?.streamFile(conn, handle: handle)
        })
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

        let parts = Self.split(body, separator: boundaryData)
        for part in parts {
            // 每一步都重建为 0-based 的独立 Data：
            // Data 的 removeFirst / 切片不会重置 startIndex，
            // 后续 subdata(in:) 用绝对索引会越界崩溃
            var p = Data(part)
            if p.prefix(2) == crlf { p = Data(p.dropFirst(2)) }
            if p.suffix(2) == crlf { p = Data(p.dropLast(2)) }
            if p.isEmpty { continue }

            guard let hEnd = p.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else { continue }
            let partHeaderData = p.subdata(in: p.startIndex..<hEnd.lowerBound)
            let content = p.subdata(in: hEnd.upperBound..<p.endIndex)
            guard let headerStr = String(data: partHeaderData, encoding: .utf8) else { continue }

            guard let disp = Self.parseHeaderString(headerStr, "Content-Disposition"),
                  let fileName = Self.parseFilename(from: disp), !fileName.isEmpty else {
                continue
            }

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
            let ext = url.pathExtension.uppercased()
            let iconText = isDir ? "DIR" : (ext.isEmpty ? "FILE" : String(ext.prefix(4)))
            let typeText = isDir ? "文件夹" : (ext.isEmpty ? "文件" : ext + " 文件")
            let ops = isDir
                ? ""
                : "<a href=\"/files/\(encName)\" download>下载</a><a class=\"danger\" href=\"/delete/\(encName)\" onclick=\"return confirm('确定删除 \(Self.escape(name)) 吗？')\">删除</a>"
            rows += """
                <tr>
                    <td>
                        <div class="file-name">
                            <div class="file-icon">\(iconText)</div>
                            <div class="file-meta">
                                <div class="file-title">\(Self.escape(name))</div>
                                <div class="file-sub">\(typeText)</div>
                            </div>
                        </div>
                    </td>
                    <td class="size">\(sizeText)</td>
                    <td><span class="status">就绪</span></td>
                    <td class="ops">\(ops)</td>
                </tr>
                """
        }

        let fileList = visible.isEmpty
            ? """
                <tr><td colspan="4" style="padding:0; border-bottom:none;">
                    <div class="empty">
                        <div class="empty-icon">
                            <svg xmlns="http://www.w3.org/2000/svg" width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                                <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"></path>
                            </svg>
                        </div>
                        <div class="empty-title">暂无文件</div>
                        <div class="empty-sub">先上传一个文件试试</div>
                    </div>
                </td></tr>
                """
            : rows

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>YSign 文件传输</title>
            <style>
                :root {
                    --primary: #0F766E;
                    --primary-light: #14B8A6;
                    --primary-soft: #EEF7F6;
                    --primary-glow: rgba(20, 184, 166, 0.35);
                    --bg: #F6F8FA;
                    --card: #FFFFFF;
                    --text: #0F172A;
                    --sub: #475569;
                    --muted: #94A3B8;
                    --line: #E5E7EB;
                    --line-strong: #CBD5E1;
                    --danger: #E11D48;
                    --danger-soft: #FFF1F3;
                    --success: #16A34A;
                    --warning: #F59E0B;
                    --shadow-sm: 0 1px 2px rgba(15, 23, 42, 0.04), 0 1px 3px rgba(15, 23, 42, 0.06);
                    --shadow-md: 0 6px 16px rgba(15, 23, 42, 0.08), 0 2px 6px rgba(15, 23, 42, 0.04);
                    --shadow-lg: 0 24px 48px rgba(15, 23, 42, 0.12), 0 10px 20px rgba(15, 23, 42, 0.06);
                    --radius-sm: 10px;
                    --radius-md: 14px;
                    --radius-lg: 20px;
                }

                @media (prefers-color-scheme: dark) {
                    :root {
                        --primary: #5EEAD4;
                        --primary-light: #99F6E4;
                        --primary-soft: rgba(94, 234, 212, 0.12);
                        --primary-glow: rgba(94, 234, 212, 0.25);
                        --bg: #0B1220;
                        --card: #111A2B;
                        --text: #E6EDF7;
                        --sub: #9FB0C4;
                        --muted: #64748B;
                        --line: #1F2A3C;
                        --line-strong: #334155;
                        --danger: #FF6B8A;
                        --danger-soft: rgba(255, 107, 138, 0.12);
                        --success: #4ADE80;
                        --warning: #FBBF24;
                        --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.4), 0 1px 3px rgba(0, 0, 0, 0.3);
                        --shadow-md: 0 10px 24px rgba(0, 0, 0, 0.35), 0 4px 10px rgba(0, 0, 0, 0.25);
                        --shadow-lg: 0 30px 60px rgba(0, 0, 0, 0.45), 0 12px 24px rgba(0, 0, 0, 0.35);
                    }
                }

                * { box-sizing: border-box; }

                body {
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC",
                                 "Hiragino Sans GB", "Microsoft YaHei", Roboto, Arial, sans-serif;
                    background:
                        radial-gradient(circle at top left, rgba(20, 184, 166, 0.14), transparent 45%),
                        radial-gradient(circle at top right, rgba(59, 130, 246, 0.10), transparent 50%),
                        var(--bg);
                    margin: 0;
                    padding: 48px 20px 80px;
                    color: var(--text);
                    line-height: 1.6;
                    -webkit-font-smoothing: antialiased;
                }

                .container {
                    max-width: 820px;
                    margin: 0 auto;
                }

                /* Header */
                .topbar {
                    display: flex;
                    align-items: center;
                    justify-content: space-between;
                    gap: 16px;
                    margin-bottom: 12px;
                }

                .brand {
                    display: flex;
                    align-items: center;
                    gap: 14px;
                    min-width: 0;
                }

                .logo {
                    width: 44px;
                    height: 44px;
                    border-radius: 14px;
                    background: linear-gradient(135deg, var(--primary), var(--primary-light));
                    color: #fff;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-weight: 800;
                    font-size: 20px;
                    letter-spacing: 0.3px;
                    box-shadow:
                        0 10px 24px var(--primary-glow),
                        0 4px 10px rgba(20, 184, 166, 0.25);
                    position: relative;
                    flex-shrink: 0;
                }

                .logo::after {
                    content: "";
                    position: absolute;
                    inset: -1px;
                    border-radius: 14px;
                    border: 1px solid rgba(255, 255, 255, 0.4);
                    pointer-events: none;
                }

                .brand-text {
                    display: flex;
                    flex-direction: column;
                    line-height: 1.3;
                    min-width: 0;
                }

                h1 {
                    font-size: 22px;
                    margin: 0;
                    letter-spacing: 0.2px;
                }

                .version {
                    font-size: 12px;
                    color: var(--muted);
                    margin-top: 2px;
                }

                .badge {
                    display: inline-flex;
                    align-items: center;
                    gap: 6px;
                    padding: 6px 10px;
                    border-radius: 999px;
                    background: var(--primary-soft);
                    color: var(--primary);
                    font-size: 12px;
                    font-weight: 600;
                    border: 1px solid rgba(20, 184, 166, 0.35);
                }

                .badge-dot {
                    width: 7px;
                    height: 7px;
                    border-radius: 50%;
                    background: var(--primary-light);
                    box-shadow: 0 0 0 3px rgba(20, 184, 166, 0.25);
                }

                .sub {
                    color: var(--sub);
                    font-size: 14px;
                    margin: 10px 0 28px;
                }

                /* Card */
                .card {
                    background: var(--card);
                    border: 1px solid var(--line);
                    border-radius: var(--radius-lg);
                    padding: 28px;
                    margin-bottom: 24px;
                    box-shadow: var(--shadow-md);
                    transition: box-shadow 0.25s ease, transform 0.25s ease;
                }

                .card:hover {
                    box-shadow: var(--shadow-lg);
                    transform: translateY(-1px);
                }

                /* Upload Area */
                .upload {
                    position: relative;
                    border: 2px dashed var(--line-strong);
                    border-radius: var(--radius-lg);
                    text-align: center;
                    padding: 44px 24px;
                    margin-bottom: 24px;
                    background:
                        linear-gradient(180deg, rgba(255,255,255,0), rgba(255,255,255,0)),
                        var(--card);
                    cursor: pointer;
                    transition: border-color 0.25s ease, background 0.25s ease,
                                box-shadow 0.25s ease, transform 0.25s ease;
                    overflow: hidden;
                }

                .upload::before {
                    content: "";
                    position: absolute;
                    inset: 0;
                    background: radial-gradient(circle at center, rgba(20, 184, 166, 0.12), transparent 70%);
                    opacity: 0;
                    transition: opacity 0.3s ease;
                    pointer-events: none;
                }

                .upload:hover {
                    border-color: var(--primary-light);
                    background: var(--primary-soft);
                    box-shadow: 0 20px 40px rgba(20, 184, 166, 0.18), var(--shadow-md);
                    transform: translateY(-3px);
                }

                .upload:hover::before {
                    opacity: 1;
                }

                .upload-header {
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    gap: 12px;
                    margin-bottom: 10px;
                    position: relative;
                    z-index: 1;
                }

                .upload-icon {
                    width: 44px;
                    height: 44px;
                    border-radius: 12px;
                    background: linear-gradient(135deg, var(--primary), var(--primary-light));
                    color: #fff;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    box-shadow: 0 12px 24px rgba(20, 184, 166, 0.35);
                }

                .upload-title {
                    font-size: 17px;
                    font-weight: 700;
                    color: var(--text);
                }

                .upload .tip {
                    font-size: 14px;
                    color: var(--sub);
                    margin-bottom: 18px;
                    position: relative;
                    z-index: 1;
                }

                .upload-actions {
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    gap: 12px;
                    flex-wrap: wrap;
                    position: relative;
                    z-index: 1;
                }

                .btn {
                    background: linear-gradient(135deg, var(--primary), var(--primary-light));
                    color: #fff;
                    border: 0;
                    padding: 12px 28px;
                    border-radius: 12px;
                    font-size: 15px;
                    font-weight: 700;
                    letter-spacing: 0.3px;
                    cursor: pointer;
                    transition: opacity 0.2s ease, transform 0.2s ease, box-shadow 0.2s ease;
                    box-shadow:
                        0 14px 28px rgba(20, 184, 166, 0.35),
                        0 4px 10px rgba(20, 184, 166, 0.25);
                }

                .btn:disabled {
                    opacity: 0.6;
                    cursor: default;
                    transform: none;
                    box-shadow: none;
                }

                .btn:hover:not(:disabled) {
                    opacity: 0.94;
                    transform: translateY(-2px);
                    box-shadow:
                        0 18px 34px rgba(20, 184, 166, 0.42),
                        0 6px 14px rgba(20, 184, 166, 0.3);
                }

                .btn-ghost {
                    background: transparent;
                    color: var(--primary);
                    border: 1px solid var(--line-strong);
                    padding: 11px 22px;
                    border-radius: 12px;
                    font-size: 14px;
                    font-weight: 600;
                    cursor: pointer;
                    transition: background 0.2s ease, border-color 0.2s ease, transform 0.2s ease;
                }

                .btn-ghost:hover {
                    background: var(--primary-soft);
                    border-color: var(--primary-light);
                    transform: translateY(-1px);
                }

                /* Section Title */
                .section-header {
                    display: flex;
                    align-items: center;
                    justify-content: space-between;
                    gap: 12px;
                    margin-bottom: 16px;
                }

                h2 {
                    font-size: 16px;
                    margin: 0;
                    display: flex;
                    align-items: center;
                    gap: 10px;
                    color: var(--text);
                }

                h2::before {
                    content: "";
                    width: 4px;
                    height: 18px;
                    border-radius: 2px;
                    background: linear-gradient(180deg, var(--primary-light), var(--primary));
                }

                .section-count {
                    font-size: 13px;
                    color: var(--muted);
                    font-weight: 500;
                }

                /* Table */
                .table-wrap {
                    border: 1px solid var(--line);
                    border-radius: var(--radius-md);
                    overflow: hidden;
                    box-shadow: var(--shadow-sm);
                }

                table {
                    width: 100%;
                    border-collapse: collapse;
                }

                thead th {
                    text-align: left;
                    padding: 14px 16px;
                    color: var(--muted);
                    font-weight: 600;
                    font-size: 12px;
                    letter-spacing: 0.6px;
                    text-transform: uppercase;
                    background: var(--primary-soft);
                    border-bottom: 1px solid var(--line);
                }

                tbody td {
                    padding: 16px;
                    border-bottom: 1px solid var(--line);
                    font-size: 14px;
                    color: var(--text);
                    word-break: break-all;
                    vertical-align: middle;
                }

                tbody tr:last-child td {
                    border-bottom: none;
                }

                tbody tr {
                    transition: background 0.18s ease;
                }

                tbody tr:hover td {
                    background: var(--primary-soft);
                }

                .file-name {
                    display: flex;
                    align-items: center;
                    gap: 12px;
                    min-width: 0;
                }

                .file-icon {
                    width: 36px;
                    height: 36px;
                    border-radius: 10px;
                    background: linear-gradient(135deg, var(--primary-soft), #fff);
                    border: 1px solid rgba(20, 184, 166, 0.3);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    color: var(--primary);
                    font-weight: 700;
                    font-size: 12px;
                    flex-shrink: 0;
                }

                .file-meta {
                    display: flex;
                    flex-direction: column;
                    min-width: 0;
                }

                .file-title {
                    font-weight: 600;
                    color: var(--text);
                    font-size: 14px;
                    word-break: break-all;
                }

                .file-sub {
                    font-size: 12px;
                    color: var(--muted);
                    margin-top: 2px;
                }

                .size {
                    color: var(--sub);
                    font-weight: 500;
                    white-space: nowrap;
                }

                .ops {
                    white-space: nowrap;
                }

                .ops a {
                    display: inline-block;
                    padding: 7px 12px;
                    border-radius: 8px;
                    font-size: 13px;
                    font-weight: 600;
                    color: var(--primary);
                    text-decoration: none;
                    background: transparent;
                    border: 1px solid transparent;
                    transition: background 0.18s ease, color 0.18s ease, border-color 0.18s ease;
                }

                .ops a:hover {
                    background: var(--primary-soft);
                    border-color: rgba(20, 184, 166, 0.35);
                }

                .ops a.danger {
                    color: var(--danger);
                }

                .ops a.danger:hover {
                    background: var(--danger-soft);
                    border-color: rgba(225, 29, 72, 0.35);
                }

                .status {
                    display: inline-flex;
                    align-items: center;
                    gap: 6px;
                    padding: 4px 10px;
                    border-radius: 999px;
                    font-size: 12px;
                    font-weight: 600;
                    background: rgba(22, 163, 74, 0.12);
                    color: var(--success);
                    border: 1px solid rgba(22, 163, 74, 0.3);
                }

                .status::before {
                    content: "";
                    width: 6px;
                    height: 6px;
                    border-radius: 50%;
                    background: var(--success);
                }

                /* Empty */
                .empty {
                    text-align: center;
                    padding: 48px 20px;
                    color: var(--muted);
                }

                .empty-icon {
                    width: 64px;
                    height: 64px;
                    border-radius: 20px;
                    background: var(--primary-soft);
                    border: 1px dashed rgba(20, 184, 166, 0.4);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    margin: 0 auto 14px;
                    color: var(--primary);
                }

                .empty-title {
                    font-size: 15px;
                    font-weight: 700;
                    color: var(--text);
                    margin-bottom: 4px;
                }

                .empty-sub {
                    font-size: 13px;
                    color: var(--muted);
                }

                /* Footer tip */
                .tip-bar {
                    display: flex;
                    align-items: flex-start;
                    gap: 12px;
                    padding: 16px 18px;
                    border-radius: var(--radius-md);
                    background: var(--primary-soft);
                    border: 1px solid rgba(20, 184, 166, 0.35);
                    color: var(--primary);
                    font-size: 13px;
                }

                .tip-icon {
                    width: 28px;
                    height: 28px;
                    border-radius: 8px;
                    background: rgba(20, 184, 166, 0.18);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-weight: 800;
                    flex-shrink: 0;
                }

                /* Responsive */
                @media (max-width: 640px) {
                    body {
                        padding: 28px 14px 60px;
                    }

                    .card {
                        padding: 20px;
                    }

                    .upload {
                        padding: 34px 16px;
                    }

                    thead th,
                    tbody td {
                        padding: 12px;
                        font-size: 13px;
                    }

                    .ops a {
                        padding: 6px 10px;
                        font-size: 12px;
                    }
                }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="topbar">
                    <div class="brand">
                        <div class="logo">Y</div>
                        <div class="brand-text">
                            <h1>YSign 文件传输</h1>
                            <span class="version">YSign Transfer · 局域网互传</span>
                        </div>
                    </div>
                    <span class="badge"><span class="badge-dot"></span> 设备已连接</span>
                </div>

                <div class="sub">通过局域网与本机互传文件 · 传输过程中请保持设备屏幕常亮</div>

                <form class="upload" id="uploadForm" action="/upload" method="POST" enctype="multipart/form-data">
                    <div class="upload-header">
                        <div class="upload-icon">
                            <svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
                                <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>
                                <polyline points="17 8 12 3 7 8"></polyline>
                                <line x1="12" y1="3" x2="12" y2="15"></line>
                            </svg>
                        </div>
                        <div class="upload-title">上传文件到设备</div>
                    </div>
                    <div class="tip">支持多选文件，通过局域网高速传输</div>
                    <div class="upload-actions">
                        <input type="file" id="fileInput" name="file" required multiple style="display:none">
                        <button type="button" class="btn-ghost" id="selectBtn">选择文件</button>
                        <button type="submit" class="btn" id="uploadBtn">开始上传</button>
                    </div>
                </form>

                <div class="card">
                    <div class="section-header">
                        <h2>设备文件</h2>
                        <span class="section-count" id="fileCount">共 \(visible.count) 个文件</span>
                    </div>

                    <div class="table-wrap">
                        <table>
                            <thead>
                                <tr>
                                    <th style="width:42%">文件名</th>
                                    <th style="width:18%">大小</th>
                                    <th style="width:20%">状态</th>
                                    <th style="width:20%" class="ops">操作</th>
                                </tr>
                            </thead>
                            <tbody id="fileTableBody">
                                \(fileList)
                            </tbody>
                        </table>
                    </div>
                </div>

                <div class="tip-bar">
                    <div class="tip-icon">i</div>
                    <div>
                        建议大文件分批次上传；传输完成后请及时下载并清理设备临时文件。
                    </div>
                </div>
            </div>

            <script>
                const form = document.getElementById('uploadForm');
                const input = document.getElementById('fileInput');
                const selectBtn = document.getElementById('selectBtn');
                const uploadBtn = document.getElementById('uploadBtn');
                const fileCount = document.getElementById('fileCount');

                function updateFileCount(n) {
                    if (fileCount) {
                        fileCount.textContent = '共 ' + n + ' 个文件';
                    }
                }

                selectBtn.addEventListener('click', function (e) {
                    e.stopPropagation();
                    input.click();
                });

                form.addEventListener('click', function (e) {
                    if (e.target === form) {
                        input.click();
                    }
                });

                input.addEventListener('change', function () {
                    if (input.files.length) {
                        uploadBtn.textContent = '上传 ' + input.files.length + ' 个文件';
                        updateFileCount(input.files.length);
                    } else {
                        uploadBtn.textContent = '开始上传';
                        updateFileCount(0);
                    }
                });

                form.addEventListener('submit', function () {
                    uploadBtn.disabled = true;
                    uploadBtn.textContent = '上传中，请稍候…';
                });
            </script>
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
