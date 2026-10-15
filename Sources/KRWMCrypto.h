//
//  KRWMCrypto.h
//  热水器蓝牙 —— 加密 / 签名 / 编解码
//
//  所有算法均来自对官方 Android 客户端（趣智校园）与开源项目 linyu 的交叉验证，
//  详见 PROTOCOL.md §6（服务端签名）与 §7.1（设备域 AES）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KRWMCrypto : NSObject

#pragma mark - 摘要

/// MD5 → 32 位小写 hex
+ (NSString *)md5Hex:(NSString *)input;

/// 登录密码：`MD5(明文)` 取**后 10 位**并转大写
+ (NSString *)encryptPassword:(NSString *)rawPassword;

/// 短信验证码接口的 secret：`MD5(手机号前 3 位 + 后 4 位 + "klcx")`（32 位小写）
///
/// 例：13800138000 → "138" + "8000" + "klcx" = "1388000klcx" → MD5
///
/// @return 手机号不是 11 位时返回 nil
+ (nullable NSString *)smsSecretForPhone:(NSString *)phone;

#pragma mark - 签名

/// 按 key 字典序升序拼成签名原文 `key1value1key2value2…`
/// （value 为 nil 时**整个字段跳过**，不是当空串——两者算出的签名不同）
+ (NSString *)rawFromParams:(NSDictionary<NSString *, NSString *> *)params;

/// 凯路请求签名（嵌套 MD5）
///
///     内层 = MD5( raw + "&key=" + sessionKey )
///     签名 = MD5( 内层 + "&key=sign-kailu-855c74a88b8b494187c99b08b8c9a744" )
///
/// @param sessionKey 服务端下发的 loginCode
/// @return 32 位小写 hex；sessionKey 为空时返回 nil
+ (nullable NSString *)signRaw:(NSString *)raw sessionKey:(NSString *)sessionKey;

#pragma mark - 设备域 AES

/// 解密服务端下发的 clData（Base64 → AES-128-ECB → 去填充）
///
/// @return 明文，格式为 `<前缀>-<dataHex>`，取 `-` 之后那段才是要写回设备的 0x86 数据；
///         失败返回 nil
+ (nullable NSString *)decryptClData:(nullable NSString *)base64Cipher;

#pragma mark - Hex

/// 字节 → 小写无分隔 hex
+ (NSString *)hexFromData:(nullable NSData *)data;

/// hex → 字节（大小写均认）；长度为奇数或含非法字符时返回 nil
+ (nullable NSData *)dataFromHex:(nullable NSString *)hex;

@end

NS_ASSUME_NONNULL_END
