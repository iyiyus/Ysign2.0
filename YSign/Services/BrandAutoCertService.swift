import Foundation

/// 品牌自动证书服务
///
/// 首次启动时，根据证书站嵌入的域名和本机 UDID，
/// 自动从证书站 POST /api/signtool/getcertificate 拉取 p12 + 描述文件。
///
/// 每台设备只会成功导入一次（按 UDID 标记）。
enum BrandAutoCertService {

    private static let flagKey = "brandAutoCertImportedUDID"

    /// 执行一次自动拉取。
    ///
    /// - Parameters:
    ///   - host: 证书站域名
    ///   - udid: 本机 UDID
    ///   - store: 证书存储
    /// - Returns: 是否成功导入
    @discardableResult
    static func runOnce(host: String, udid: String, store: CertificateStore) async -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let udid = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !udid.isEmpty else {
            print("[BrandAutoCert] 跳过: host=\(host.isEmpty ? "空" : host), udid=\(udid.isEmpty ? "空" : "有")")
            return false
        }

        // 已经为该 UDID 拉过 => 跳过
        if UserDefaults.standard.string(forKey: flagKey) == udid {
            print("[BrandAutoCert] 已导入过, 跳过")
            return false
        }

        // 调 /api/signtool/getcertificate
        guard let payload = await fetchCertificate(host: host, udid: udid) else {
            return false
        }

        // 导入
        do {
            let imported = try await importCertificate(payload: payload, store: store)
            if imported {
                UserDefaults.standard.set(udid, forKey: flagKey)
                print("[BrandAutoCert] 证书导入成功")
            }
            return imported
        } catch {
            print("[BrandAutoCert] 导入失败: \(error)")
            return false
        }
    }

    /// 重置标记，允许下次重新拉取（用于调试或换 UDID 场景）
    static func resetFlag() {
        UserDefaults.standard.removeObject(forKey: flagKey)
    }

    private struct CertPayload {
        let p12Data: Data
        let profileData: Data
        let password: String
    }

    /// POST /api/signtool/getcertificate  (udid=xxx)
    private static func fetchCertificate(host: String, udid: String) async -> CertPayload? {
        let urlString = "https://\(host)/api/signtool/getcertificate"
        guard let url = URL(string: urlString) else {
            print("[BrandAutoCert] URL 无效: \(urlString)")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "udid=" + percentEncode(udid)
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                print("[BrandAutoCert] HTTP 错误")
                return nil
            }

            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = obj["code"] as? Int, code == 0,
                  let payload = obj["data"] as? [String: Any] else {
                // 尝试解析错误信息
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("[BrandAutoCert] 服务端返回: \(obj)")
                }
                return nil
            }

            let p12B64 = (payload["p12"] as? String) ?? ""
            let mpB64 = (payload["mobileprovision"] as? String) ?? ""
            let password = (payload["p12_password"] as? String) ?? "1"

            guard let p12Data = Data(base64Encoded: p12B64), !p12Data.isEmpty else {
                print("[BrandAutoCert] p12 base64 解码失败")
                return nil
            }
            guard let mpData = Data(base64Encoded: mpB64), !mpData.isEmpty else {
                print("[BrandAutoCert] mobileprovision base64 解码失败")
                return nil
            }

            return CertPayload(p12Data: p12Data, profileData: mpData, password: password)
        } catch {
            print("[BrandAutoCert] 网络请求失败: \(error)")
            return nil
        }
    }

    /// 落盘并走 CertificateStore 标准导入流程
    private static func importCertificate(payload: CertPayload, store: CertificateStore) async throws -> Bool {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("brand_auto_cert_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let p12URL = tmp.appendingPathComponent("cert.p12")
        let mpURL  = tmp.appendingPathComponent("cert.mobileprovision")
        try payload.p12Data.write(to: p12URL)
        try payload.profileData.write(to: mpURL)

        let cert = try await store.importP12(from: p12URL, password: payload.password)
        _ = try await store.linkProfile(certID: cert.id, profileURL: mpURL)
        return true
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
