//
//  OCSPChecker.mm
//  YSign
//
//  OCSP 吊销检查实现（OpenSSL）：
//  1. 解析证书，读取 AIA 扩展中的 OCSP responder URL
//  2. 本地校验有效期（过期 / 30 天内到期）
//  3. 用 leaf + issuer 构造 OCSP 请求（OCSP_CERTID），POST 到 responder
//  4. 解析 OCSP 响应的 CertStatus（good / revoked / unknown）
//

#import "OCSPChecker.h"
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/ocsp.h>
#include <openssl/pem.h>
#include <openssl/err.h>

// 内置 Apple WWDR 中间证书（旧版 / G3 / G6），无证书链时用于构造 OCSP CERTID
static NSString * const kWWDRLegacyPEM = @"-----BEGIN CERTIFICATE-----\n"
    @"MIIEIjCCAwqgAwIBAgIIAd68xDltoBAwDQYJKoZIhvcNAQEFBQAwYjELMAkGA1UE\n"
    @"BhMCVVMxEzARBgNVBAoTCkFwcGxlIEluYy4xJjAkBgNVBAsTHUFwcGxlIENlcnRp\n"
    @"ZmljYXRpb24gQXV0aG9yaXR5MRYwFAYDVQQDEw1BcHBsZSBSb290IENBMB4XDTEz\n"
    @"MDIwNzIxNDg0N1oXDTIzMDIwNzIxNDg0N1owgZYxCzAJBgNVBAYTAlVTMRMwEQYD\n"
    @"VQQKDApBcHBsZSBJbmMuMSwwKgYDVQQLDCNBcHBsZSBXb3JsZHdpZGUgRGV2ZWxv\n"
    @"cGVyIFJlbGF0aW9uczFEMEIGA1UEAww7QXBwbGUgV29ybGR3aWRlIERldmVsb3Bl\n"
    @"ciBSZWxhdGlvbnMgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkwggEiMA0GCSqGSIb3\n"
    @"DQEBAQUAA4IBDwAwggEKAoIBAQDKOFSmy1aqyCQ5SOmM7uxfuH8mkbw0U3rOfGOA\n"
    @"YXdkXqUHI7Y5/lAtFVZYcC1+xG7BSoU+L/DehBqhV8mvexj/avoVEkkVCBmsqtsq\n"
    @"Mu2WY2hSFT2Miuy/axiV4AOsAX2XBWfODoWVN2rtCbauZ81RZJ/GXNG8V25nNYB2\n"
    @"NqSHgW44j9grFU57Jdhav06DwY3Sk9UacbVgnJ0zTlX5ElgMhrgWDcHld0WNUEi6\n"
    @"Ky3klIXh6MSdxmilsKP8Z35wugJZS3dCkTm59c3hTO/AO0iMpuUhXf1qarunFjVg\n"
    @"0uat80YpyejDi+l5wGphZxWy8P3laLxiX27Pmd3vG2P+kmWrAgMBAAGjgaYwgaMw\n"
    @"HQYDVR0OBBYEFIgnFwmpthhgi+zruvZHWcVSVKO3MA8GA1UdEwEB/wQFMAMBAf8w\n"
    @"HwYDVR0jBBgwFoAUK9BpR5R2Cf70a40uQKb3R01/CF4wLgYDVR0fBCcwJTAjoCGg\n"
    @"H4YdaHR0cDovL2NybC5hcHBsZS5jb20vcm9vdC5jcmwwDgYDVR0PAQH/BAQDAgGG\n"
    @"MBAGCiqGSIb3Y2QGAgEEAgUAMA0GCSqGSIb3DQEBBQUAA4IBAQBPz+9Zviz1smwv\n"
    @"j+4ThzLoBTWobot9yWkMudkXvHcs1Gfi/ZptOllc34MBvbKuKmFysa/Nw0Uwj6OD\n"
    @"Dc4dR7Txk4qjdJukw5hyhzs+r0ULklS5MruQGFNrCk4QttkdUGwhgAqJTleMa1s8\n"
    @"Pab93vcNIx0LSiaHP7qRkkykGRIZbVf1eliHe2iK5IaMSuviSRSqpd1VAKmuu0sw\n"
    @"ruGgsbwpgOYJd+W+NKIByn/c4grmO7i77LpilfMFY0GCzQ87HUyVpNur+cmV6U/k\n"
    @"TecmmYHpvPm0KdIBembhLoz2IYrF+Hjhga6/05Cdqa3zr/04GpZnMBxRpVzscYqC\n"
    @"tGwPDBUf\n"
    @"-----END CERTIFICATE-----\n";

static NSString * const kWWDRG3PEM = @"-----BEGIN CERTIFICATE-----\n"
    @"MIIEUTCCAzmgAwIBAgIQfK9pCiW3Of57m0R6wXjF7jANBgkqhkiG9w0BAQsFADBi\n"
    @"MQswCQYDVQQGEwJVUzETMBEGA1UEChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBw\n"
    @"bGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkxFjAUBgNVBAMTDUFwcGxlIFJvb3Qg\n"
    @"Q0EwHhcNMjAwMjE5MTgxMzQ3WhcNMzAwMjIwMDAwMDAwWjB1MUQwQgYDVQQDDDtB\n"
    @"cHBsZSBXb3JsZHdpZGUgRGV2ZWxvcGVyIFJlbGF0aW9ucyBDZXJ0aWZpY2F0aW9u\n"
    @"IEF1dGhvcml0eTELMAkGA1UECwwCRzMxEzARBgNVBAoMCkFwcGxlIEluYy4xCzAJ\n"
    @"BgNVBAYTAlVTMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2PWJ/KhZ\n"
    @"C4fHTJEuLVaQ03gdpDDppUjvC0O/LYT7JF1FG+XrWTYSXFRknmxiLbTGl8rMPPbW\n"
    @"BpH85QKmHGq0edVny6zpPwcR4YS8Rx1mjjmi6LRJ7TrS4RBgeo6TjMrA2gzAg9Dj\n"
    @"+ZHWp4zIwXPirkbRYp2SqJBgN31ols2N4Pyb+ni743uvLRfdW/6AWSN1F7gSwe0b\n"
    @"5TTO/iK1nkmw5VW/j4SiPKi6xYaVFuQAyZ8D0MyzOhZ71gVcnetHrg21LYwOaU1A\n"
    @"0EtMOwSejSGxrC5DVDDOwYqGlJhL32oNP/77HK6XF8J4CjDgXx9UO0m3JQAaN4LS\n"
    @"VpelUkl8YDib7wIDAQABo4HvMIHsMBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0j\n"
    @"BBgwFoAUK9BpR5R2Cf70a40uQKb3R01/CF4wRAYIKwYBBQUHAQEEODA2MDQGCCsG\n"
    @"AQUFBzABhihodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLWFwcGxlcm9vdGNh\n"
    @"MC4GA1UdHwQnMCUwI6AhoB+GHWh0dHA6Ly9jcmwuYXBwbGUuY29tL3Jvb3QuY3Js\n"
    @"MB0GA1UdDgQWBBQJ/sAVkPmvZAqSErkmKGMMl+ynsjAOBgNVHQ8BAf8EBAMCAQYw\n"
    @"EAYKKoZIhvdjZAYCAQQCBQAwDQYJKoZIhvcNAQELBQADggEBAK1lE+j24IF3RAJH\n"
    @"Qr5fpTkg6mKp/cWQyXMT1Z6b0KoPjY3L7QHPbChAW8dVJEH4/M/BtSPp3Ozxb8qA\n"
    @"HXfCxGFJJWevD8o5Ja3T43rMMygNDi6hV0Bz+uZcrgZRKe3jhQxPYdwyFot30ETK\n"
    @"XXIDMUacrptAGvr04NM++i+MZp+XxFRZ79JI9AeZSWBZGcfdlNHAwWx/eCHvDOs7\n"
    @"bJmCS1JgOLU5gm3sUjFTvg+RTElJdI+mUcuER04ddSduvfnSXPN/wmwLCTbiZOTC\n"
    @"NwMUGdXqapSqqdv+9poIZ4vvK7iqF0mDr8/LvOnP6pVxsLRFoszlh6oKw0E6eVza\n"
    @"UDSdlTs=\n"
    @"-----END CERTIFICATE-----\n";

static NSString * const kWWDRG6PEM = @"-----BEGIN CERTIFICATE-----\n"
    @"MIIDFjCCApygAwIBAgIUIsGhRwp0c2nvU4YSycafPTjzbNcwCgYIKoZIzj0EAwMw\n"
    @"ZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBD\n"
    @"ZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkG\n"
    @"A1UEBhMCVVMwHhcNMjEwMzE3MjAzNzEwWhcNMzYwMzE5MDAwMDAwWjB1MUQwQgYD\n"
    @"VQQDDDtBcHBsZSBXb3JsZHdpZGUgRGV2ZWxvcGVyIFJlbGF0aW9ucyBDZXJ0aWZp\n"
    @"Y2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzYxEzARBgNVBAoMCkFwcGxlIElu\n"
    @"Yy4xCzAJBgNVBAYTAlVTMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEbsQKC94PrlWm\n"
    @"ZXnXgtxzdVJL8T0SGYngDRGpngn3N6PT8JMEb7FDi4bBmPhCnZ3/sq6PF/cGcKXW\n"
    @"sL5vOteRhyJ45x3ASP7cOB+aao90fcpxSv/EZFbniAbNgZGhIhpIo4H6MIH3MBIG\n"
    @"A1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAUu7DeoVgziJqkipnevr3rr9rL\n"
    @"JKswRgYIKwYBBQUHAQEEOjA4MDYGCCsGAQUFBzABhipodHRwOi8vb2NzcC5hcHBs\n"
    @"ZS5jb20vb2NzcDAzLWFwcGxlcm9vdGNhZzMwNwYDVR0fBDAwLjAsoCqgKIYmaHR0\n"
    @"cDovL2NybC5hcHBsZS5jb20vYXBwbGVyb290Y2FnMy5jcmwwHQYDVR0OBBYEFD8v\n"
    @"lCNR01DJmig97bB85c+lkGKZMA4GA1UdDwEB/wQEAwIBBjAQBgoqhkiG92NkBgIB\n"
    @"BAIFADAKBggqhkjOPQQDAwNoADBlAjBAXhSq5IyKogMCPtw490BaB677CaEGJXuf\n"
    @"QB/EqZGd6CSjiCtOnuMTbXVXmxxcxfkCMQDTSPxarZXvNrkxU3TkUMI33yzvFVVR\n"
    @"T4wxWJC994OsdcZ4+RGNsYDyR5gmdr0nDGg=\n"
    @"-----END CERTIFICATE-----\n";

@implementation OCSPCheckResult
@end

@implementation OCSPChecker

/// 从内置 Apple WWDR 中间证书中匹配叶子证书的签发者
+ (nullable X509 *)bundledIssuerForLeaf:(X509 *)leaf {
    if (!leaf) return NULL;
    NSArray<NSString *> *pems = @[kWWDRLegacyPEM, kWWDRG3PEM, kWWDRG6PEM];
    for (NSString *pem in pems) {
        const char *bytes = pem.UTF8String;
        BIO *bio = BIO_new_mem_buf(bytes, (int)strlen(bytes));
        X509 *candidate = bio ? PEM_read_bio_X509(bio, NULL, NULL, NULL) : NULL;
        if (bio) BIO_free(bio);
        if (!candidate) continue;
        if (X509_check_issued(candidate, leaf) == 1) {
            return candidate;
        }
        X509_free(candidate);
    }
    return NULL;
}


+ (OCSPCheckResult *)resultWithStatus:(OCSPCheckStatus)status message:(NSString *)message {
    OCSPCheckResult *r = [[OCSPCheckResult alloc] init];
    r.status = status;
    r.message = message;
    return r;
}

+ (void)checkLeafCertDER:(NSData *)leafCertDER
             issuerCertDER:(NSData *)issuerCertDER
                completion:(void (^)(OCSPCheckResult *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        OCSPCheckResult *result = [self checkSyncLeaf:leafCertDER issuer:issuerCertDER];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result);
        });
    });
}

+ (OCSPCheckResult *)checkSyncLeaf:(NSData *)leafDER issuer:(NSData *)issuerDER {
    if (leafDER.length == 0) {
        return [self resultWithStatus:OCSPCheckStatusUnknown message:@"证书数据为空"];
    }

    const unsigned char *leafPtr = (const unsigned char *)leafDER.bytes;
    X509 *leaf = d2i_X509(NULL, &leafPtr, leafDER.length);
    if (!leaf) {
        return [self resultWithStatus:OCSPCheckStatusUnknown message:@"证书解析失败"];
    }

    // 1. 本地校验有效期
    ASN1_TIME *notAfter = X509_getm_notAfter(leaf);
    int days = 0, seconds = 0;
    ASN1_TIME_diff(&days, &seconds, NULL, notAfter);
    if (days < 0 || seconds < 0) {
        X509_free(leaf);
        return [self resultWithStatus:OCSPCheckStatusExpired message:@"证书已过期"];
    }
    if (days > 0 && days < 30) {
        X509_free(leaf);
        return [self resultWithStatus:OCSPCheckStatusExpiringSoon
                              message:[NSString stringWithFormat:@"证书将在 %d 天后过期", days]];
    }

    // 2. 读取 AIA 扩展中的 OCSP responder URL
    NSURL *ocspURL = [self ocspURLForCert:leaf];
    if (!ocspURL) {
        X509_free(leaf);
        return [self resultWithStatus:OCSPCheckStatusUnknown message:@"证书无 OCSP 查询地址 (AIA)"];
    }

    // 3. 解析 issuer（无 issuer 无法构造 CERTID；缺省时从内置 Apple WWDR 中间证书匹配）
    X509 *issuer = NULL;
    if (issuerDER.length > 0) {
        const unsigned char *issuerPtr = (const unsigned char *)issuerDER.bytes;
        issuer = d2i_X509(NULL, &issuerPtr, issuerDER.length);
    }
    if (!issuer) {
        issuer = [self bundledIssuerForLeaf:leaf];
    }
    if (!issuer) {
        X509_free(leaf);
        return [self resultWithStatus:OCSPCheckStatusUnknown message:@"缺少签发者证书（内置 WWDR 不匹配），无法在线查询"];
    }

    // 4. 构造 OCSP 请求
    OCSP_REQUEST *req = OCSP_REQUEST_new();
    OCSP_CERTID *cid = OCSP_cert_to_id(EVP_sha1(), leaf, issuer);
    if (!cid || OCSP_request_add0_id(req, cid) == NULL) {
        if (cid) OCSP_CERTID_free(cid);
        OCSP_REQUEST_free(req);
        X509_free(issuer);
        X509_free(leaf);
        return [self resultWithStatus:OCSPCheckStatusUnknown message:@"构造 OCSP 请求失败"];
    }

    int reqLen = i2d_OCSP_REQUEST(req, NULL);
    NSMutableData *reqData = [NSMutableData dataWithLength:(reqLen > 0 ? reqLen : 0)];
    unsigned char *reqPtr = (unsigned char *)reqData.mutableBytes;
    i2d_OCSP_REQUEST(req, &reqPtr);
    OCSP_REQUEST_free(req);
    X509_free(issuer);

    if (reqData.length == 0) {
        X509_free(leaf);
        return [self resultWithStatus:OCSPCheckStatusUnknown message:@"OCSP 请求序列化失败"];
    }

    // 5. POST 到 responder
    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:ocspURL];
    urlRequest.HTTPMethod = @"POST";
    urlRequest.timeoutInterval = 10;
    [urlRequest setValue:@"application/ocsp-request" forHTTPHeaderField:@"Content-Type"];
    urlRequest.HTTPBody = reqData;

    __block OCSPCheckResult *finalResult = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:urlRequest
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error || !data) {
                finalResult = [self resultWithStatus:OCSPCheckStatusUnknown
                                             message:[NSString stringWithFormat:@"OCSP 查询失败: %@",
                                                      error.localizedDescription ?: @"无响应"]];
                dispatch_semaphore_signal(sem);
                return;
            }

            // 6. 解析响应
            const unsigned char *respPtr = (const unsigned char *)data.bytes;
            OCSP_RESPONSE *resp = d2i_OCSP_RESPONSE(NULL, &respPtr, data.length);
            if (!resp) {
                finalResult = [self resultWithStatus:OCSPCheckStatusUnknown message:@"OCSP 响应解析失败"];
                dispatch_semaphore_signal(sem);
                return;
            }

            int respStatus = OCSP_response_status(resp);
            if (respStatus != OCSP_RESPONSE_STATUS_SUCCESSFUL) {
                OCSP_RESPONSE_free(resp);
                finalResult = [self resultWithStatus:OCSPCheckStatusUnknown
                                             message:[NSString stringWithFormat:@"OCSP 响应状态异常: %d", respStatus]];
                dispatch_semaphore_signal(sem);
                return;
            }

            OCSP_BASICRESP *basic = OCSP_response_get1_basic(resp);
            if (!basic) {
                OCSP_RESPONSE_free(resp);
                finalResult = [self resultWithStatus:OCSPCheckStatusUnknown message:@"OCSP 响应缺少 BasicRESP"];
                dispatch_semaphore_signal(sem);
                return;
            }

            int reason = -1;
            ASN1_GENERALIZEDTIME *thisUpd = NULL, *nextUpd = NULL, *revTime = NULL;
            OCSP_SINGLERESP *sresp = OCSP_resp_get0(basic, 0);
            if (!sresp) {
                OCSP_BASICRESP_free(basic);
                OCSP_RESPONSE_free(resp);
                finalResult = [self resultWithStatus:OCSPCheckStatusUnknown message:@"OCSP 响应无 SingleRESP"];
                dispatch_semaphore_signal(sem);
                return;
            }
            int singleStatus = OCSP_single_get0_status(sresp, &reason, &revTime, &thisUpd, &nextUpd);
            switch (singleStatus) {
                case V_OCSP_CERTSTATUS_GOOD:
                    finalResult = [self resultWithStatus:OCSPCheckStatusValid message:@"OCSP 查询通过"];
                    break;
                case V_OCSP_CERTSTATUS_REVOKED:
                    finalResult = [self resultWithStatus:OCSPCheckStatusRevoked message:@"证书已被吊销"];
                    break;
                default:
                    finalResult = [self resultWithStatus:OCSPCheckStatusUnknown message:@"OCSP 状态无法确认"];
                    break;
            }
            (void)reason; (void)revTime; (void)thisUpd; (void)nextUpd;

            OCSP_BASICRESP_free(basic);
            OCSP_RESPONSE_free(resp);
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));

    X509_free(leaf);
    if (!finalResult) {
        finalResult = [self resultWithStatus:OCSPCheckStatusUnknown message:@"OCSP 查询超时"];
    }
    return finalResult;
}

/// 从 AIA 扩展提取 OCSP responder URL
+ (nullable NSURL *)ocspURLForCert:(X509 *)cert {
    STACK_OF(ACCESS_DESCRIPTION) *aia = (STACK_OF(ACCESS_DESCRIPTION) *)
        X509_get_ext_d2i(cert, NID_info_access, NULL, NULL);
    if (!aia) return nil;

    NSURL *result = nil;
    for (int i = 0; i < sk_ACCESS_DESCRIPTION_num(aia); i++) {
        ACCESS_DESCRIPTION *ad = sk_ACCESS_DESCRIPTION_value(aia, i);
        if (OBJ_obj2nid(ad->method) == NID_ad_OCSP && ad->location->type == GEN_URI) {
            ASN1_IA5STRING *uri = ad->location->d.uniformResourceIdentifier;
            if (uri && uri->length > 0) {
                NSString *urlStr = [[NSString alloc] initWithBytes:uri->data
                                                            length:uri->length
                                                          encoding:NSUTF8StringEncoding];
                result = [NSURL URLWithString:urlStr];
                break;
            }
        }
    }
    sk_ACCESS_DESCRIPTION_pop_free(aia, ACCESS_DESCRIPTION_free);
    return result;
}

@end
