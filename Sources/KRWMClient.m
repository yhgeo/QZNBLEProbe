//
//  KRWMClient.m
//  热水器蓝牙 —— 服务端接口客户端
//

#import "KRWMClient.h"
#import "KRWMCrypto.h"

#pragma mark - 常量

static NSString * const kBaseURL = @"https://v3-api.china-qzxy.cn";

/// 官方 v3 API 固定要求的配置请求头。缺了它结算会报 226「加密校验失败」。
static NSString * const kConfigKeys =
    @"module_list,advertise_type,question_list,service_phone_list,"
     "banner_list_app,activity_list_app,aliCard_popup_config";

static NSString * const kPhoneSystem = @"android";
static NSString * const kVersion     = @"6.5.28";
static NSString * const kXFModel     = @"0";

/// 上传接口把这几码也算成功（服务端历史遗留，不同学校口径不一）
static BOOL KRWMUploadCodeIsOK(NSInteger code) {
    return code == 0 || code == 206 || code == 209;
}

static NSString * const kPrefLoginCode = @"qzn.loginCode";
static NSString * const kPrefUserId    = @"qzn.userId";
static NSString * const kPrefAccountId = @"qzn.accountId";
static NSString * const kPrefProjectId = @"qzn.projectId";
static NSString * const kPrefTelephone = @"qzn.telephone";

#pragma mark - 小工具

/// 服务端字段类型不稳（有时 NSString、有时 NSNumber），统一转字符串
static NSString *KRWMString(id obj) {
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    if ([obj isKindOfClass:[NSNumber class]]) return [(NSNumber *)obj stringValue];
    return nil;
}

/// RFC 3986 非保留字符集，最保险的表单编码
static NSString *KRWMURLEncode(NSString *s) {
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
                   @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    });
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSString *KRWMQueryString(NSDictionary<NSString *, NSString *> *params) {
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    for (NSString *key in params) {
        NSString *value = params[key];
        if (value == nil) continue;
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", KRWMURLEncode(key), KRWMURLEncode(value)]];
    }
    return [pairs componentsJoinedByString:@"&"];
}

#pragma mark -

@implementation KRWMClient

+ (instancetype)shared {
    static KRWMClient *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[KRWMClient alloc] init]; });
    return instance;
}

#pragma mark - 会话

- (NSString *)prefForKey:(NSString *)key {
    return [[NSUserDefaults standardUserDefaults] stringForKey:key] ?: @"";
}

- (void)setPref:(NSString *)value forKey:(NSString *)key {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (value.length > 0) {
        [d setObject:value forKey:key];
    } else {
        [d removeObjectForKey:key];
    }
    [d synchronize];
}

- (NSString *)loginCode { return [self prefForKey:kPrefLoginCode]; }
- (NSString *)userId    { return [self prefForKey:kPrefUserId]; }
- (NSString *)accountId { return [self prefForKey:kPrefAccountId]; }
- (NSString *)projectId { return [self prefForKey:kPrefProjectId]; }
- (NSString *)telephone { return [self prefForKey:kPrefTelephone]; }

- (BOOL)loggedIn {
    return self.loginCode.length > 0 && self.projectId.length > 0 && self.telephone.length > 0;
}

- (BOOL)restoreSession {
    return self.loggedIn;
}

- (void)clearSession {
    for (NSString *key in @[kPrefLoginCode, kPrefUserId, kPrefAccountId, kPrefProjectId, kPrefTelephone]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSDictionary<NSString *, NSString *> *)authFields {
    NSString *tel = self.telephone;
    return @{
        @"loginCode":   self.loginCode,
        @"userId":      self.userId,
        @"accountId":   self.accountId,
        @"projectId":   self.projectId,
        @"telephone":   tel,
        // ⚠️ telPhone 必须也带。绝大多数接口只认 telephone，但个别接口（一卡通余额）
        //    要的是 telPhone，少了它服务端直接回「手机号不能为空」，而且 HTTP 200，
        //    只看状态码完全看不出来。
        @"telPhone":    tel,
        @"phoneSystem": kPhoneSystem,
        @"version":     kVersion
    };
}

#pragma mark - 底层请求

- (void)finish:(KRWMResponseHandler)completion ok:(BOOL)ok data:(NSDictionary *)data message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(ok, data, message ?: @"");
    });
}

- (void)postPath:(NSString *)path
          fields:(NSDictionary<NSString *, NSString *> *)fields
          authed:(BOOL)authed
      completion:(KRWMResponseHandler)completion {

    NSMutableDictionary<NSString *, NSString *> *all = [NSMutableDictionary dictionary];
    if (authed) [all addEntriesFromDictionary:[self authFields]];
    if (fields) [all addEntriesFromDictionary:fields];

    NSURL *url = [NSURL URLWithString:[kBaseURL stringByAppendingString:path]];
    if (url == nil) { [self finish:completion ok:NO data:nil message:@"接口地址无效"]; return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 15.0;
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [KRWMQueryString(all) dataUsingEncoding:NSUTF8StringEncoding];
    [self applyConfigHeaders:req];

    [self send:req completion:completion];
}

- (void)getPath:(NSString *)path
          query:(NSDictionary<NSString *, NSString *> *)query
          authed:(BOOL)authed
      completion:(KRWMResponseHandler)completion {

    NSMutableDictionary<NSString *, NSString *> *all = [NSMutableDictionary dictionary];
    if (query) [all addEntriesFromDictionary:query];
    // GET 的认证参数走 query（与官方客户端一致）
    if (authed) [all addEntriesFromDictionary:[self authFields]];

    NSString *full = [kBaseURL stringByAppendingString:path];
    NSString *qs = KRWMQueryString(all);
    if (qs.length > 0) full = [full stringByAppendingFormat:@"?%@", qs];

    NSURL *url = [NSURL URLWithString:full];
    if (url == nil) { [self finish:completion ok:NO data:nil message:@"接口地址无效"]; return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 15.0;
    [self applyConfigHeaders:req];

    [self send:req completion:completion];
}

- (void)applyConfigHeaders:(NSMutableURLRequest *)req {
    NSString *projectId = self.projectId;
    if (projectId.length > 0 && ![projectId isEqualToString:@"0"]) {
        [req setValue:projectId forHTTPHeaderField:@"Config-Project"];
        [req setValue:kConfigKeys forHTTPHeaderField:@"Config-Keys"];
    }
}

- (void)send:(NSURLRequest *)req completion:(KRWMResponseHandler)completion {
    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
                                        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) {
            [self finish:completion ok:NO data:nil
                 message:[NSString stringWithFormat:@"网络错误：%@", error.localizedDescription]];
            return;
        }
        if (data.length == 0) {
            [self finish:completion ok:NO data:nil message:@"服务端无响应"];
            return;
        }

        NSError *jsonError = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![obj isKindOfClass:[NSDictionary class]]) {
            [self finish:completion ok:NO data:nil message:@"服务端返回格式异常"];
            return;
        }

        NSDictionary *json = (NSDictionary *)obj;
        BOOL success = [json[@"success"] boolValue];
        NSInteger code = [json[@"errorCode"] integerValue];
        NSString *message = KRWMString(json[@"errorMessage"]) ?: KRWMString(json[@"msg"]);
        id dataField = json[@"data"];

        // 有些接口 success=false 但 errorCode=0，以 success 为准；
        // 有些接口 success=true 却带非零 errorCode（上传），由调用方判定，这里只透传。
        if (!success && message.length == 0) {
            message = [NSString stringWithFormat:@"请求失败（errorCode=%ld）", (long)code];
        }

        NSDictionary *dataDict = [dataField isKindOfClass:[NSDictionary class]] ? dataField : nil;
        [self finish:completion ok:success data:dataDict message:message ?: @""];
    }];
    [task resume];
}

#pragma mark - 登录

- (void)loginWithPhone:(NSString *)phone
              password:(NSString *)rawPassword
            completion:(KRWMResponseHandler)completion {

    if (phone.length == 0 || rawPassword.length == 0) {
        [self finish:completion ok:NO data:nil message:@"请填写手机号与密码"];
        return;
    }

    NSDictionary *fields = @{
        @"telephone":   phone,
        @"password":    [KRWMCrypto encryptPassword:rawPassword],
        @"phoneSystem": kPhoneSystem,
        @"type":        @"0",
        @"version":     kVersion
    };

    [self postPath:@"/user/login" fields:fields authed:NO completion:^(BOOL ok, NSDictionary *data, NSString *message) {
        [self applyLoginData:data ok:ok message:message phone:phone completion:completion];
    }];
}

- (void)sendSmsCodeToPhone:(NSString *)phone completion:(KRWMResponseHandler)completion {
    NSString *secret = [KRWMCrypto smsSecretForPhone:phone];
    if (secret == nil) {
        [self finish:completion ok:NO data:nil message:@"请输入 11 位手机号"];
        return;
    }
    // 验证码接口不带登录态，也不参与签名
    [self getPath:@"/user/verification/code/get"
            query:@{@"telephone": phone,
                    @"secret":    secret,
                    @"typeId":    @"3",
                    @"platform":  @"1"}
           authed:NO
       completion:completion];
}

- (void)loginWithPhone:(NSString *)phone
               smsCode:(NSString *)smsCode
            completion:(KRWMResponseHandler)completion {

    if (phone.length != 11) {
        [self finish:completion ok:NO data:nil message:@"请输入 11 位手机号"];
        return;
    }
    if (smsCode.length == 0) {
        [self finish:completion ok:NO data:nil message:@"请输入验证码"];
        return;
    }

    NSDictionary *fields = @{
        @"telephone":   phone,
        @"smsCode":     smsCode,
        @"type":        @"5",
        @"phoneSystem": kPhoneSystem,
        @"version":     kVersion
    };

    // 未注册的手机号会自动注册，所以这个接口同时当注册用
    [self postPath:@"/user/registerAndLogin" fields:fields authed:NO completion:^(BOOL ok, NSDictionary *data, NSString *message) {
        [self applyLoginData:data ok:ok message:message phone:phone completion:completion];
    }];
}

/// `/user/login` 与 `/user/registerAndLogin` 的响应结构相同，统一提取会话并落盘
- (void)applyLoginData:(NSDictionary *)data
                    ok:(BOOL)ok
               message:(NSString *)message
                 phone:(NSString *)phone
            completion:(KRWMResponseHandler)completion {

    if (!ok || data == nil) {
        [self finish:completion ok:NO data:nil message:message.length ? message : @"登录失败"];
        return;
    }

    NSString *loginCode = KRWMString(data[@"loginCode"]);
    NSString *userId    = KRWMString(data[@"userId"]);
    NSDictionary *account = [data[@"userAccount"] isKindOfClass:[NSDictionary class]] ? data[@"userAccount"] : nil;
    NSString *accountId = KRWMString(account[@"accountId"]);
    NSString *projectId = KRWMString(account[@"projectId"]);

    if (loginCode.length == 0 || projectId.length == 0) {
        [self finish:completion ok:NO data:nil message:@"登录成功但缺少会话参数"];
        return;
    }

    [self setPref:loginCode forKey:kPrefLoginCode];
    [self setPref:userId    forKey:kPrefUserId];
    [self setPref:accountId forKey:kPrefAccountId];
    [self setPref:projectId forKey:kPrefProjectId];
    [self setPref:phone     forKey:kPrefTelephone];

    [self finish:completion ok:YES data:data message:@""];
}

#pragma mark - 设备台账

- (void)deviceInfoForMac:(NSString *)macAddress completion:(KRWMResponseHandler)completion {
    NSArray<NSString *> *variants = [KRWMClient lookupVariantsFor:macAddress];
    [self tryDeviceInfoVariants:variants index:0 completion:completion];
}

- (void)tryDeviceInfoVariants:(NSArray<NSString *> *)variants
                        index:(NSUInteger)index
                   completion:(KRWMResponseHandler)completion {

    if (index >= variants.count) {
        [self finish:completion ok:NO data:nil message:@"未查到该设备的台账信息（可能不在本校项目内）"];
        return;
    }

    NSString *mac = variants[index];
    [self getPath:@"/device/info/mac" query:@{@"macAddress": mac} authed:YES
      completion:^(BOOL ok, NSDictionary *data, NSString *message) {
        if (ok && data != nil && data.count > 0) {
            [self finish:completion ok:YES data:data message:@""];
        } else {
            [self tryDeviceInfoVariants:variants index:index + 1 completion:completion];
        }
    }];
}

#pragma mark - 下费率

- (void)requestRateOrderWithDeviceId:(NSString *)deviceId
                          macAddress:(NSString *)macAddress
                             macType:(NSString *)macType
                           bigTypeId:(NSString *)bigTypeId
                         smallTypeId:(NSString *)smallTypeId
                        protocolType:(NSString *)protocolType
                        randomNumber:(NSString *)randomNumber
                          completion:(KRWMResponseHandler)completion {

    NSString *rn = [randomNumber lowercaseString];

    // 参与签名的字段：telephone / deviceId / xfModel / randomNumber（按 key 升序拼接）
    NSString *raw = [KRWMCrypto rawFromParams:@{
        @"deviceId":     deviceId ?: @"",
        @"randomNumber": rn,
        @"telephone":    self.telephone,
        @"xfModel":      kXFModel
    }];
    NSString *signature = [KRWMCrypto signRaw:raw sessionKey:self.loginCode];
    if (signature == nil) {
        [self finish:completion ok:NO data:nil message:@"签名失败，请重新登录"];
        return;
    }

    NSDictionary *fields = @{
        @"deviceId":     deviceId ?: @"",
        @"macAddress":   macAddress ?: @"",
        @"macType":      macType ?: @"",
        @"bigTypeId":    bigTypeId ?: @"0",
        @"smallTypeId":  smallTypeId ?: @"0",
        @"protocolType": protocolType ?: @"",
        @"randomNumber": rn,
        @"xfModel":      kXFModel,
        @"signature":    signature
    };

    [self postPath:@"/order/downRate/bluetooth/rateOrder" fields:fields authed:YES
       completion:^(BOOL ok, NSDictionary *data, NSString *message) {
        if (!ok || data == nil) {
            [self finish:completion ok:NO data:nil message:message.length ? message : @"服务端未下发费率"];
            return;
        }
        NSString *downData = KRWMString(data[@"downData"]);
        if (downData.length == 0) {
            [self finish:completion ok:NO data:nil message:@"服务端费率数据为空，已停止启动"];
            return;
        }
        [self finish:completion ok:YES data:data message:@""];
    }];
}

#pragma mark - 上传结算

- (void)uploadXfData:(NSString *)xfData
        protocolType:(NSString *)protocolType
        randomNumber:(NSString *)randomNumber
          completion:(KRWMResponseHandler)completion {

    // ⚠️ xfData 必须小写：签名用小写、上传字段也必须小写，否则服务端重算签名对不上（170）
    NSString *xf = [xfData lowercaseString];

    NSString *raw = [KRWMCrypto rawFromParams:@{
        @"loginCode": self.loginCode,
        @"telephone": self.telephone,
        @"xfData":    xf
    }];
    NSString *signature = [KRWMCrypto signRaw:raw sessionKey:self.loginCode];
    if (signature == nil) {
        [self finish:completion ok:NO data:nil message:@"签名失败，请重新登录"];
        return;
    }

    NSDictionary *fields = @{
        @"protocolType": protocolType ?: @"",
        @"randomNumber": [randomNumber lowercaseString],
        @"xfData":       xf,
        @"signature":    signature
    };

    // 上传接口的成功判定看 errorCode（不看 success），且 0/206/209 都算成功
    NSMutableDictionary<NSString *, NSString *> *all = [NSMutableDictionary dictionary];
    [all addEntriesFromDictionary:[self authFields]];
    [all addEntriesFromDictionary:fields];

    NSURL *url = [NSURL URLWithString:[kBaseURL stringByAppendingString:@"/order/upload/bluetooth/data"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 20.0;
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [KRWMQueryString(all) dataUsingEncoding:NSUTF8StringEncoding];
    [self applyConfigHeaders:req];

    [self sendRaw:req completion:^(BOOL ok, NSDictionary *json, NSString *message) {
        NSInteger code = [json[@"errorCode"] integerValue];
        NSDictionary *data = [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;

        if (!KRWMUploadCodeIsOK(code) || data == nil) {
            NSString *msg = KRWMString(json[@"errorMessage"]);
            if (code == 170) {
                msg = @"结算签名校验未通过（170），请稍后重试";
            }
            if (msg.length == 0) msg = message.length ? message : @"上传失败";
            [self finish:completion ok:NO data:nil message:msg];
            return;
        }
        [self finish:completion ok:YES data:data message:@""];
    }];
}

#pragma mark - 失败上报

- (void)reportFailWithConsumeDate:(NSString *)consumeDate completion:(KRWMResponseHandler)completion {
    if (consumeDate.length == 0) {
        [self finish:completion ok:NO data:nil message:@"缺少 consumeDate，跳过上报"];
        return;
    }

    NSString *raw = [KRWMCrypto rawFromParams:@{
        @"consumeDate": consumeDate,
        @"loginCode":   self.loginCode,
        @"telephone":   self.telephone
    }];
    NSString *signature = [KRWMCrypto signRaw:raw sessionKey:self.loginCode];
    if (signature == nil) {
        [self finish:completion ok:NO data:nil message:@"签名失败"];
        return;
    }

    NSDictionary *fields = @{
        @"consumeDate": consumeDate,
        @"signature":   signature
    };

    [self postPath:@"/order/upload/bluetooth/fail" fields:fields authed:YES completion:completion];
}

/// 返回完整 JSON（不只是 data 字段），供上传接口判定 errorCode 用
- (void)sendRaw:(NSURLRequest *)req completion:(void (^)(BOOL ok, NSDictionary *json, NSString *message))completion {
    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
                                        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error || data.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, @{}, error.localizedDescription ?: @"服务端无响应");
            });
            return;
        }
        NSError *jsonError = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        NSDictionary *json = [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(YES, json, @"");
        });
    }];
    [task resume];
}

#pragma mark - 钱包 / 账单

- (void)loadWalletWithCompletion:(KRWMResponseHandler)completion {
    [self getPath:@"/account/wallet" query:nil authed:YES completion:completion];
}

- (void)loadBillsForMonth:(NSString *)month completion:(KRWMListHandler)completion {
    NSMutableDictionary<NSString *, NSString *> *all = [NSMutableDictionary dictionary];
    [all addEntriesFromDictionary:[self authFields]];
    if (month.length > 0) all[@"month"] = month;
    all[@"billRequestType"] = @"2";

    NSString *full = [kBaseURL stringByAppendingString:@"/order/query/account/bill/list"];
    NSString *qs = KRWMQueryString(all);
    if (qs.length > 0) full = [full stringByAppendingFormat:@"?%@", qs];

    NSURL *url = [NSURL URLWithString:full];
    if (url == nil) { [self finishList:completion ok:NO list:nil message:@"接口地址无效"]; return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 15.0;
    [self applyConfigHeaders:req];

    [self sendRaw:req completion:^(BOOL ok, NSDictionary *json, NSString *message) {
        BOOL success = [json[@"success"] boolValue];
        id data = json[@"data"];
        NSArray *list = [data isKindOfClass:[NSArray class]] ? data : nil;

        if (!success || list == nil) {
            NSString *msg = KRWMString(json[@"errorMessage"]) ?: message;
            [self finishList:completion ok:NO list:nil
                     message:(msg.length ? msg : @"账单获取失败")];
            return;
        }
        [self finishList:completion ok:YES list:list message:@""];
    }];
}

- (void)finishList:(KRWMListHandler)completion ok:(BOOL)ok list:(NSArray *)list message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(ok, list, message ?: @"");
    });
}

#pragma mark - MAC 换算

+ (NSString *)normalizeMac:(NSString *)mac {
    if (mac.length == 0) return nil;
    NSMutableString *hex = [NSMutableString stringWithCapacity:12];
    for (NSUInteger i = 0; i < mac.length; i++) {
        unichar c = [mac characterAtIndex:i];
        BOOL isHex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (isHex) [hex appendFormat:@"%C", c];
    }
    if (hex.length != 12) return nil;
    return [hex uppercaseString];
}

+ (NSString *)publicAddressOf:(NSString *)broadcastMac {
    NSString *canon = [self normalizeMac:broadcastMac];
    if (canon.length != 12) return nil;

    unsigned int first = 0;
    if (sscanf([[canon substringToIndex:2] UTF8String], "%x", &first) != 1) return nil;
    if ((first & 0xC0) == 0) return nil;   // 本来就是公开地址，推不出台账 MAC

    NSString *newFirst = [NSString stringWithFormat:@"%02X", (first & 0x3F)];
    return [newFirst stringByAppendingString:[canon substringFromIndex:2]];
}

+ (NSString *)connectAddressFor:(NSString *)ledgerMac {
    NSString *canon = [self normalizeMac:ledgerMac];
    if (canon.length != 12) return ledgerMac ?: @"";

    unsigned int first = 0;
    if (sscanf([[canon substringToIndex:2] UTF8String], "%x", &first) != 1) return canon;
    if ((first & 0xC0) != 0) return canon;   // 已经是广播地址，恒等返回

    NSString *newFirst = [NSString stringWithFormat:@"%02X", (first | 0xC0)];
    return [newFirst stringByAppendingString:[canon substringFromIndex:2]];
}

+ (NSArray<NSString *> *)lookupVariantsFor:(NSString *)mac {
    NSString *canon = [self normalizeMac:mac];
    if (canon.length != 12) return @[mac ?: @""];

    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithObject:mac];
    NSString *derived = [self publicAddressOf:canon];
    if (derived.length == 12) {
        NSString *lower = [derived lowercaseString];
        if (![lower isEqualToString:mac]) [out addObject:lower];
    }
    return out;
}

@end
