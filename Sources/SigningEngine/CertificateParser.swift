import Foundation
import Security

/// 证书解析器 —— 使用 OpenSSL 解析 P12 元数据 + Security.framework 提取签名身份
///
/// 核心职责：
/// 1. 使用 OpenSSL 解析 PKCS#12 (.p12) 文件，提取证书元数据（兼容所有加密格式）
/// 2. 使用 Security.framework 提取 SecIdentity/SecKey（用于代码签名）
/// 3. OpenSSL 兼容性远优于 SecPKCS12Import，支持所有 OpenSSL 版本生成的 P12
struct CertificateParser {

    /// P12 解析结果
    struct P12Result {
        /// SecIdentity（可能为空，签名时按需获取）
        let identity: SecIdentity?
        /// SecCertificate（可能为空）
        let certificate: SecCertificate?
        /// 私钥（可能为空）
        let privateKey: SecKey?
        /// 证书通用名称（如 "iPhone Distribution: Company (TEAMID)"）
        let commonName: String
        /// 组织名称
        let organizationName: String
        /// 团队 ID（10位，如 "A1B2C3D4E5"）
        let teamID: String
        /// 证书序列号
        let serialNumber: String
        /// 证书生效时间
        let notBefore: Date
        /// 证书过期时间
        let notAfter: Date
    }

    /// 解析 PKCS#12 (.p12) 文件
    ///
    /// 策略：先用 OpenSSL 解析元数据（兼容所有格式），再用 SecPKCS12Import 获取签名身份
    ///
    /// - Parameters:
    ///   - data: P12 文件的原始二进制数据
    ///   - password: P12 文件的保护密码
    /// - Returns: 包含证书元数据和可选签名身份的结果
    /// - Throws: SigningError.invalidCertificate
    static func parseP12(data: Data, password: String) throws -> P12Result {
        // ========== 第一步：用 OpenSSL 解析 P12 元数据 ==========
        let info: OpenSSLP12Info
        do {
            info = try OpenSSLP12Parser.parseP12Data(data, password: password)
        } catch {
            throw SigningError.invalidCertificate(error.localizedDescription)
        }

        // 从 OpenSSL 解析结果提取信息
        let cn = info.commonName
        let org = info.organization
        let serial = info.serialNumber
        let notBefore = Date(timeIntervalSince1970: TimeInterval(info.notBefore))
        let notAfter = Date(timeIntervalSince1970: TimeInterval(info.notAfter))

        // 提取 Team ID：优先 OU，备选从 CN 正则提取
        var teamID = info.organizationalUnit
        if teamID.isEmpty {
            let regex = try? NSRegularExpression(pattern: #"\(([A-Z0-9]{10})\)"#)
            if let match = regex?.firstMatch(in: cn, range: NSRange(cn.startIndex..., in: cn)),
               let range = Range(match.range(at: 1), in: cn) {
                teamID = String(cn[range])
            }
        }

        // ========== 第二步：用 SecPKCS12Import 获取签名身份 ==========
        var identity: SecIdentity?
        var certificate: SecCertificate?
        var privateKey: SecKey?

        let secResult = trySecImport(data: data, password: password)
        if let item = secResult {
            if let ref = item[kSecImportItemIdentity as String] {
                identity = (ref as! SecIdentity)

                var cert: SecCertificate?
                SecIdentityCopyCertificate(identity!, &cert)
                certificate = cert

                var key: SecKey?
                SecIdentityCopyPrivateKey(identity!, &key)
                privateKey = key
            }
        }

        // ========== 第三步：SecPKCS12Import 失败时，用 OpenSSL 导出的 DER 数据创建 SecKey ==========
        if privateKey == nil, let keyDER = info.privateKeyData as Data? {
            // 尝试 RSA
            let rsaAttrs: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            ]
            var error: Unmanaged<CFError>?
            if let key = SecKeyCreateWithData(keyDER as CFData, rsaAttrs as CFDictionary, &error) {
                privateKey = key
            } else {
                // 尝试 EC
                let ecAttrs: [String: Any] = [
                    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                ]
                if let key = SecKeyCreateWithData(keyDER as CFData, ecAttrs as CFDictionary, nil) {
                    privateKey = key
                }
            }
        }

        if certificate == nil, let certDER = info.certificateData as Data? {
            certificate = SecCertificateCreateWithData(nil, certDER as CFData)
        }

        return P12Result(
            identity: identity,
            certificate: certificate,
            privateKey: privateKey,
            commonName: cn,
            organizationName: org,
            teamID: teamID,
            serialNumber: serial,
            notBefore: notBefore,
            notAfter: notAfter
        )
    }

    /// 验证证书是否适用于代码签名
    static func validateForCodeSigning(_ result: P12Result) -> Bool {
        guard let certificate = result.certificate,
              let publicKey = SecCertificateCopyKey(certificate) else {
            return false
        }
        guard let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any] else {
            return false
        }
        let keyType = attributes[kSecAttrKeyType as String] as? String
        return keyType == (kSecAttrKeyTypeRSA as String) || keyType == (kSecAttrKeyTypeECSECPrimeRandom as String)
    }

    // MARK: - 私有方法

    /// 尝试用 SecPKCS12Import 导入（多种密码组合）
    private static func trySecImport(data: Data, password: String) -> [String: Any]? {
        let passwords: [String] = password.isEmpty ? [password] : [password, ""]
        for pwd in passwords {
            var result: CFArray?
            let options: [String: Any] = [kSecImportExportPassphrase as String: pwd]
            let status = SecPKCS12Import(data as CFData, options as CFDictionary, &result)
            if status == errSecSuccess,
               let items = result as? [[String: Any]],
               let first = items.first {
                return first
            }
        }
        return nil
    }
}
