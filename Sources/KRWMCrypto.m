//
//  KRWMCrypto.m
//  热水器蓝牙 —— 加密 / 签名 / 编解码
//

#import "KRWMCrypto.h"
#import <CommonCrypto/CommonCrypto.h>

// CC_MD5 自 iOS 13 起被标记弃用，但服务端算法就是 MD5，没有替代品。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/// 外层固定密钥。**自带 `&key=` 前缀**——这不是笔误，是算法的一部分。
static NSString * const kOuterKey = @"&key=sign-kailu-855c74a88b8b494187c99b08b8c9a744";

/// 设备域 AES-128 密钥（结算写回 clData 用）
static NSString * const kAesKey = @"20210118klcx@002";

@implementation KRWMCrypto

#pragma mark - 摘要

+ (NSString *)md5Hex:(NSString *)input {
    if (input == nil) return @"";
    // 用 data 而不是 [input UTF8String]：后者遇到内嵌 \0 会截断
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) return @"";

    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *out = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [out appendFormat:@"%02x", digest[i]];
    }
    return out;
}

+ (NSString *)encryptPassword:(NSString *)rawPassword {
    NSString *md5 = [self md5Hex:rawPassword ?: @""];
    if (md5.length >= 10) {
        return [[md5 substringFromIndex:md5.length - 10] uppercaseString];
    }
    return [md5 uppercaseString];
}

+ (NSString *)smsSecretForPhone:(NSString *)phone {
    if (phone.length != 11) return nil;
    // 前 3 位 + 后 4 位 + "klcx"
    NSString *raw = [NSString stringWithFormat:@"%@%@klcx",
                     [phone substringToIndex:3],
                     [phone substringFromIndex:7]];
    return [self md5Hex:raw];
}

#pragma mark - 签名

+ (NSString *)rawFromParams:(NSDictionary<NSString *, NSString *> *)params {
    NSArray<NSString *> *keys = [[params allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *raw = [NSMutableString string];
    for (NSString *key in keys) {
        NSString *value = params[key];
        if (value == nil) continue;   // value 为 nil → 连 key 一起跳过
        [raw appendString:key];
        [raw appendString:value];
    }
    return raw;
}

+ (NSString *)signRaw:(NSString *)raw sessionKey:(NSString *)sessionKey {
    if (sessionKey.length == 0) return nil;

    NSString *inner = [self md5Hex:[raw stringByAppendingFormat:@"&key=%@", sessionKey]];
    return [self md5Hex:[inner stringByAppendingString:kOuterKey]];
}

#pragma mark - 设备域 AES

+ (nullable NSData *)aesECBDecrypt:(NSData *)cipher {
    if (cipher.length == 0 || cipher.length % kCCBlockSizeAES128 != 0) return nil;

    size_t outLength = 0;
    NSMutableData *out = [NSMutableData dataWithLength:cipher.length + kCCBlockSizeAES128];

    // 不加 kCCOptionPKCS7Padding：对齐 native 的 AES/ECB/NoPadding，去填充自己来
    CCCryptorStatus status = CCCrypt(kCCDecrypt,
                                     kCCAlgorithmAES,
                                     kCCOptionECBMode,
                                     kAesKey.UTF8String,
                                     kCCKeySizeAES128,
                                     NULL,
                                     cipher.bytes, cipher.length,
                                     out.mutableBytes, out.length,
                                     &outLength);
    if (status != kCCSuccess) return nil;

    out.length = outLength;
    return out;
}

/// 去填充 + 转文本（对齐 native 语义）：
/// 末字节 last ∈ 1..n 时校验末尾 last 个字节是否全等于 last（PKCS#7），
/// 不满足返回空串；last == 0 或 > n 视为无填充。最后按 C 字符串截断（到第一个 0x00）。
+ (nullable NSString *)stripPaddingToText:(NSData *)data {
    NSUInteger n = data.length;
    if (n == 0) return @"";

    const unsigned char *b = data.bytes;
    NSUInteger effective = n;

    unsigned char last = b[n - 1];
    if (last >= 1 && last <= n) {
        NSUInteger start = n - last;
        for (NSUInteger i = start; i < n; i++) {
            if (b[i] != last) return @"";   // 填充不合法 → 按 native 行为判为失败
        }
        effective = start;
    }

    NSUInteger end = effective;
    for (NSUInteger i = 0; i < effective; i++) {
        if (b[i] == 0) { end = i; break; }
    }

    NSString *text = [[NSString alloc] initWithBytes:b length:end encoding:NSUTF8StringEncoding];
    return text ?: @"";
}

+ (NSString *)decryptClData:(NSString *)base64Cipher {
    if (base64Cipher.length == 0) return nil;

    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:base64Cipher
                                                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (decoded.length == 0) return nil;

    NSData *plain = [self aesECBDecrypt:decoded];
    if (plain == nil) return nil;

    NSString *text = [self stripPaddingToText:plain];
    return text.length > 0 ? text : nil;
}

#pragma mark - Hex

+ (NSString *)hexFromData:(NSData *)data {
    if (data.length == 0) return @"";
    const unsigned char *b = data.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [out appendFormat:@"%02x", b[i]];
    }
    return out;
}

+ (nullable NSData *)dataFromHex:(NSString *)hex {
    if (hex == nil) return nil;
    // 去掉可能存在的分隔符
    NSMutableString *clean = [NSMutableString stringWithCapacity:hex.length];
    for (NSUInteger i = 0; i < hex.length; i++) {
        unichar c = [hex characterAtIndex:i];
        BOOL isHex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (isHex) [clean appendFormat:@"%C", c];
    }
    if (clean.length == 0 || clean.length % 2 != 0) return nil;

    NSUInteger n = clean.length / 2;
    NSMutableData *out = [NSMutableData dataWithLength:n];
    unsigned char *dst = out.mutableBytes;

    for (NSUInteger i = 0; i < n; i++) {
        unsigned int byte = 0;
        NSString *pair = [clean substringWithRange:NSMakeRange(i * 2, 2)];
        if (sscanf([pair UTF8String], "%x", &byte) != 1) return nil;
        dst[i] = (unsigned char)(byte & 0xFF);
    }
    return out;
}

@end

#pragma clang diagnostic pop
