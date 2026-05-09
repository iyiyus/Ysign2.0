#import "OpenSSLP12Parser.h"
#include <openssl/pkcs12.h>
#include <openssl/x509.h>
#include <openssl/bio.h>
#include <openssl/err.h>

@implementation OpenSSLP12Info
@end

@implementation OpenSSLP12Parser

+ (nullable OpenSSLP12Info *)parseP12Data:(NSData *)data
                                 password:(NSString *)password
                                    error:(NSError **)error {
    if (!data || data.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"OpenSSLP12" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"P12 数据为空"}];
        return nil;
    }

    // 从内存读取 P12
    BIO *bio = BIO_new_mem_buf(data.bytes, (int)data.length);
    if (!bio) {
        if (error) *error = [NSError errorWithDomain:@"OpenSSLP12" code:-2
                                            userInfo:@{NSLocalizedDescriptionKey: @"无法创建 BIO"}];
        return nil;
    }

    PKCS12 *p12 = d2i_PKCS12_bio(bio, NULL);
    BIO_free(bio);

    if (!p12) {
        if (error) *error = [NSError errorWithDomain:@"OpenSSLP12" code:-3
                                            userInfo:@{NSLocalizedDescriptionKey: @"P12 文件格式无效"}];
        return nil;
    }

    EVP_PKEY *pkey = NULL;
    X509 *cert = NULL;
    STACK_OF(X509) *ca = NULL;
    const char *pwd = password ? [password UTF8String] : "";

    int parseResult = PKCS12_parse(p12, pwd, &pkey, &cert, &ca);
    PKCS12_free(p12);

    if (parseResult != 1 || !cert) {
        // 尝试空密码
        if (password.length > 0) {
            bio = BIO_new_mem_buf(data.bytes, (int)data.length);
            p12 = d2i_PKCS12_bio(bio, NULL);
            BIO_free(bio);
            if (p12) {
                parseResult = PKCS12_parse(p12, "", &pkey, &cert, &ca);
                PKCS12_free(p12);
            }
        }

        if (parseResult != 1 || !cert) {
            if (error) *error = [NSError errorWithDomain:@"OpenSSLP12" code:-4
                                                userInfo:@{NSLocalizedDescriptionKey: @"密码错误或证书无法解析"}];
            return nil;
        }
    }

    OpenSSLP12Info *info = [[OpenSSLP12Info alloc] init];

    // 解析 Subject
    X509_NAME *subjectName = X509_get_subject_name(cert);
    if (subjectName) {
        char *subjectStr = X509_NAME_oneline(subjectName, NULL, 0);
        if (subjectStr) {
            NSDictionary *fields = [self parseX509Subject:subjectStr];
            info.commonName = fields[@"CN"] ?: @"";
            info.organization = fields[@"O"] ?: @"";
            info.organizationalUnit = fields[@"OU"] ?: @"";
            info.country = fields[@"C"] ?: @"";
            info.userID = fields[@"UID"] ?: @"";
            OPENSSL_free(subjectStr);
        }
    }

    // 序列号
    ASN1_INTEGER *serial = X509_get_serialNumber(cert);
    if (serial) {
        BIGNUM *bn = ASN1_INTEGER_to_BN(serial, NULL);
        if (bn) {
            char *hex = BN_bn2hex(bn);
            if (hex) {
                info.serialNumber = [NSString stringWithUTF8String:hex];
                OPENSSL_free(hex);
            }
            BN_free(bn);
        }
    }
    if (!info.serialNumber) info.serialNumber = @"";

    // 有效期
    ASN1_TIME *notBefore = X509_get_notBefore(cert);
    ASN1_TIME *notAfter = X509_get_notAfter(cert);

    if (notBefore) {
        info.notBefore = [self timestampFromASN1Time:notBefore];
    }
    if (notAfter) {
        info.notAfter = [self timestampFromASN1Time:notAfter];
    }

    // 导出私钥 DER（PKCS#8 格式）
    if (pkey) {
        unsigned char *pkeyBuf = NULL;
        int pkeyLen = i2d_PrivateKey(pkey, &pkeyBuf);
        if (pkeyLen > 0 && pkeyBuf) {
            info.privateKeyData = [NSData dataWithBytes:pkeyBuf length:pkeyLen];
            OPENSSL_free(pkeyBuf);
        }
    }

    // 导出证书 DER
    if (cert) {
        unsigned char *certBuf = NULL;
        int certLen = i2d_X509(cert, &certBuf);
        if (certLen > 0 && certBuf) {
            info.certificateData = [NSData dataWithBytes:certBuf length:certLen];
            OPENSSL_free(certBuf);
        }
    }

    // 清理
    if (pkey) EVP_PKEY_free(pkey);
    if (cert) X509_free(cert);
    if (ca) sk_X509_pop_free(ca, X509_free);

    return info;
}

+ (NSDictionary *)parseX509Subject:(const char *)subjectData {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    NSString *str = [NSString stringWithUTF8String:subjectData];
    NSArray *parts = [str componentsSeparatedByString:@"/"];
    for (NSString *part in parts) {
        NSArray *kv = [part componentsSeparatedByString:@"="];
        if (kv.count == 2) {
            dict[kv[0]] = kv[1];
        }
    }
    return dict.copy;
}

+ (long long)timestampFromASN1Time:(ASN1_TIME *)asn1Time {
    if (!asn1Time || !asn1Time->data) return 0;

    NSString *timeStr = [NSString stringWithUTF8String:(const char *)asn1Time->data];
    if (timeStr.length < 12) return 0;

    NSString *formatted;
    if (timeStr.length >= 14 && asn1Time->type == V_ASN1_GENERALIZEDTIME) {
        // YYYYMMDDHHMMSSZ
        formatted = [NSString stringWithFormat:@"%@-%@-%@ %@:%@:%@",
                     [timeStr substringWithRange:NSMakeRange(0, 4)],
                     [timeStr substringWithRange:NSMakeRange(4, 2)],
                     [timeStr substringWithRange:NSMakeRange(6, 2)],
                     [timeStr substringWithRange:NSMakeRange(8, 2)],
                     [timeStr substringWithRange:NSMakeRange(10, 2)],
                     [timeStr substringWithRange:NSMakeRange(12, 2)]];
    } else {
        // YYMMDDHHMMSSZ
        formatted = [NSString stringWithFormat:@"20%@-%@-%@ %@:%@:%@",
                     [timeStr substringWithRange:NSMakeRange(0, 2)],
                     [timeStr substringWithRange:NSMakeRange(2, 2)],
                     [timeStr substringWithRange:NSMakeRange(4, 2)],
                     [timeStr substringWithRange:NSMakeRange(6, 2)],
                     [timeStr substringWithRange:NSMakeRange(8, 2)],
                     [timeStr substringWithRange:NSMakeRange(10, 2)]];
    }

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    df.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSDate *date = [df dateFromString:formatted];
    return (long long)[date timeIntervalSince1970];
}

@end
