#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OpenSSLP12Info : NSObject

@property (nonatomic, copy) NSString *commonName;
@property (nonatomic, copy) NSString *organization;
@property (nonatomic, copy) NSString *organizationalUnit;
@property (nonatomic, copy) NSString *country;
@property (nonatomic, copy) NSString *userID;
@property (nonatomic, copy) NSString *serialNumber;
@property (nonatomic, assign) long long notBefore;
@property (nonatomic, assign) long long notAfter;

/// DER-encoded private key (PKCS#8)
@property (nonatomic, strong, nullable) NSData *privateKeyData;
/// DER-encoded certificate
@property (nonatomic, strong, nullable) NSData *certificateData;

@end

@interface OpenSSLP12Parser : NSObject

/// 解析 P12 数据，返回证书信息。失败时 error 非空。
+ (nullable OpenSSLP12Info *)parseP12Data:(NSData *)data
                                 password:(NSString *)password
                                    error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
