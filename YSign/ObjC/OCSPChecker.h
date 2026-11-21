//
//  OCSPChecker.h
//  YSign
//
//  证书吊销状态检查（OCSP），基于内嵌 OpenSSL 实现。
//  对齐 LCSign 的 OCSPBridge：本地构造 OCSP request 查询 Apple 签发机构。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// OCSP 检查结果
typedef NS_ENUM(NSInteger, OCSPCheckStatus) {
    OCSPCheckStatusValid,        // 有效（OCSP 响应 good）
    OCSPCheckStatusRevoked,      // 已吊销
    OCSPCheckStatusExpired,      // 已过期
    OCSPCheckStatusExpiringSoon, // 即将到期（30 天内）
    OCSPCheckStatusUnknown,      // 无法确认（无 AIA/网络失败/无 issuer）
};

@interface OCSPCheckResult : NSObject
@property (nonatomic, assign) OCSPCheckStatus status;
@property (nonatomic, copy, nullable) NSString *message;
@end

@interface OCSPChecker : NSObject

/// 检查证书吊销状态
/// - Parameters:
///   - leafCertDER: 叶子证书 DER 数据
///   - issuerCertDER: 签发者证书 DER 数据（可为 nil，无 issuer 时仅做本地校验）
///   - completion: 回调（主线程）
+ (void)checkLeafCertDER:(NSData *)leafCertDER
             issuerCertDER:(nullable NSData *)issuerCertDER
                completion:(void (^)(OCSPCheckResult *result))completion;

@end

NS_ASSUME_NONNULL_END
