import Foundation
import CommonCrypto

/// 证书站嵌入域名读取器
///
/// 证书站 PHP 重签 YSign 时，会把 HTTP_HOST 用 AES-128-CBC + PKCS7 加密，
/// Base64 后写入 Info.plist 的 NSLocationAccuracyAuthorizationDescription 字段。
///
/// 设计目的:
/// - 让 App 运行时能识别"自己来自哪个证书站"
/// - 避免 Info.plist 被简单替换绕过授权
///
/// 密钥/IV 必须与 PHP 侧 (Ipasign.php) 完全一致:
/// - Key: `Ys1gN@SecK3y!789`
/// - IV : `Ys1gN@IvK3y!7890`
enum BrandHost {

    private static let plistKey = "NSLocationAccuracyAuthorizationDescription"
    private static let aesKey   = "Ys1gN@SecK3y!789"
    private static let aesIV    = "Ys1gN@IvK3y!7890"

    /// 解密并返回当前 IPA 绑定的证书站域名。
    ///
    /// 失败场景 (都返回 nil):
    /// - 字段不存在 / 为空
    /// - Base64 非法
    /// - 解密失败
    static func resolveSignedHost() -> String? {
        guard let encrypted = Bundle.main.object(forInfoDictionaryKey: plistKey) as? String,
              !encrypted.isEmpty,
              let cipher = Data(base64Encoded: encrypted),
              let key    = aesKey.data(using: .utf8),
              let iv     = aesIV.data(using: .utf8),
              let plain  = aes128CBCDecrypt(cipher: cipher, key: key, iv: iv),
              let host   = String(data: plain, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
              !host.isEmpty else {
            return nil
        }

        // 只保留常见域名合法字符, 兜底异常数据。
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
        let trimmed = host.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 解密并返回当前 IPA 内嵌的 UDID。
    ///
    /// PHP 端 Ipasign.php 在重签时把 UDID 用同样的 AES 加密后写入
    /// `NSLocationTemporaryUsageDescriptionDictionary` 字段。
    static func resolveEmbeddedUDID() -> String? {
        let udidKey = "NSLocationTemporaryUsageDescriptionDictionary"
        guard let encrypted = Bundle.main.object(forInfoDictionaryKey: udidKey) as? String,
              !encrypted.isEmpty,
              let cipher = Data(base64Encoded: encrypted),
              let key    = aesKey.data(using: .utf8),
              let iv     = aesIV.data(using: .utf8),
              let plain  = aes128CBCDecrypt(cipher: cipher, key: key, iv: iv),
              let udid   = String(data: plain, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
              !udid.isEmpty else {
            return nil
        }

        // UDID 只含字母数字和连字符
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let trimmed = udid.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// AES-128-CBC + PKCS7 解密, 与 PHP `openssl_encrypt(..., OPENSSL_RAW_DATA)` 对齐。
    private static func aes128CBCDecrypt(cipher: Data, key: Data, iv: Data) -> Data? {
        let bufferSize = cipher.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var decryptedCount = 0

        let status = buffer.withUnsafeMutableBytes { bufferPtr -> CCCryptorStatus in
            cipher.withUnsafeBytes { cipherPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            cipherPtr.baseAddress, cipher.count,
                            bufferPtr.baseAddress, bufferSize,
                            &decryptedCount
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        buffer.count = decryptedCount
        return buffer
    }
}
