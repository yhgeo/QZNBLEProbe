//
//  KRWMClient.h
//  热水器蓝牙 —— 服务端接口客户端
//
//  对应 v3-api.china-qzxy.cn 的「蓝牙水表通道」四个接口 + 登录 + 设备台账查询。
//  与官方 Android 客户端、开源项目 linyu 的实现逐字段对齐。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 统一回调
/// @param ok      是否成功
/// @param data    服务端返回的 `data` 字段（无数据时为 nil）
/// @param message 失败原因 / 服务端提示
typedef void (^KRWMResponseHandler)(BOOL ok, NSDictionary * _Nullable data, NSString *message);

/// 列表型接口的回调（账单列表的 data 是数组，不是字典）
typedef void (^KRWMListHandler)(BOOL ok, NSArray * _Nullable list, NSString *message);

/// 带原始 `errorCode` 的回调。自动验证要用它区分 170 / 226 / 0，普通业务回调拿不到码。
typedef void (^KRWMCodeHandler)(BOOL success, NSInteger errorCode,
                                NSDictionary * _Nullable data, NSString *message);

@interface KRWMClient : NSObject

+ (instancetype)shared;

#pragma mark - 会话

@property (nonatomic, copy, readonly) NSString *loginCode;
@property (nonatomic, copy, readonly) NSString *userId;
@property (nonatomic, copy, readonly) NSString *accountId;
@property (nonatomic, copy, readonly) NSString *projectId;
@property (nonatomic, copy, readonly) NSString *telephone;

/// 是否已有可用登录态（loginCode + projectId 都在）
@property (nonatomic, readonly) BOOL loggedIn;

/// 从本地恢复登录态，返回是否恢复成功
- (BOOL)restoreSession;

/// 清除登录态
- (void)clearSession;

#pragma mark - 接口

/// 账密登录。密码明文传入，内部按官方算法加密（MD5 后 10 位大写）
- (void)loginWithPhone:(NSString *)phone
              password:(NSString *)rawPassword
            completion:(KRWMResponseHandler)completion;

/// 发送短信验证码。`secret` 由手机号本地算出，不需要抓包
- (void)sendSmsCodeToPhone:(NSString *)phone
                completion:(KRWMResponseHandler)completion;

/// 短信验证码登录。**没注册过的手机号会自动注册**，所以同时当注册用
- (void)loginWithPhone:(NSString *)phone
               smsCode:(NSString *)smsCode
            completion:(KRWMResponseHandler)completion;

/// 按 MAC 查设备台账。内部会自动尝试「原样」与「清掉首字节最高两位」两种写法，
/// 拿到 deviceId / bigTypeId / smallTypeId / snCode 等开阀必需字段
- (void)deviceInfoForMac:(NSString *)macAddress
              completion:(KRWMResponseHandler)completion;

/// 下费率（开阀第一步）。downData 是**必须原样写进设备**的费率包
- (void)requestRateOrderWithDeviceId:(NSString *)deviceId
                          macAddress:(NSString *)macAddress
                             macType:(NSString *)macType
                           bigTypeId:(NSString *)bigTypeId
                         smallTypeId:(NSString *)smallTypeId
                        protocolType:(NSString *)protocolType
                        randomNumber:(NSString *)randomNumber
                          completion:(KRWMResponseHandler)completion;

/// 上传消费数据（结算）。xfData 内部会转小写——服务端对大小写敏感，写错会报 170
- (void)uploadXfData:(NSString *)xfData
        protocolType:(NSString *)protocolType
        randomNumber:(NSString *)randomNumber
          completion:(KRWMResponseHandler)completion;

/// 上报失败订单。蓝牙通道没有服务端兜底，开阀后没能正常结算时必须调用
- (void)reportFailWithConsumeDate:(NSString *)consumeDate
                       completion:(KRWMResponseHandler)completion;

#pragma mark - 钱包 / 账单

/// 账户余额（`GET /account/wallet`）
/// 返回 `data`：`accountRealMoney` 实际余额、`accountGivenMoney` 赠送金额
- (void)loadWalletWithCompletion:(KRWMResponseHandler)completion;

/// 水费账单列表（`GET /order/query/account/bill/list`）
///
/// @param month 形如 `2026-10`；传 nil 取服务端默认（本月）
/// @return 数组元素为 `{"consumeBillDTO": {...}}`
- (void)loadBillsForMonth:(nullable NSString *)month
               completion:(KRWMListHandler)completion;

#pragma mark - 自动验证专用（原样透传、不改写字段）

/// 上传消费数据，但**原样**发送 `xfData`（不做小写归一）。
///
/// 用途：验证服务端到底是"按收到的 xfData 重算签名"还是"只校验签名自洽"——
/// 故意送大写即可触发 170。**这是唯一的区别**，其余字段与 `uploadXfData:` 完全一致。
- (void)uploadXfDataVerbatim:(NSString *)xfData
                protocolType:(NSString *)protocolType
                randomNumber:(NSString *)randomNumber
                  completion:(KRWMCodeHandler)completion;

/// 查询某笔订单的服务端结算结果（`POST /order/consumeOrder/result/query`）。
/// 用来与上传响应、账单列表做三方金额比对。
- (void)queryOrderResult:(NSString *)orderNo
                 snCode:(NSString *)snCode
             completion:(KRWMCodeHandler)completion;

#pragma mark - MAC 换算

/// 规范化：12 位 hex、无分隔、大写。不是 MAC 时返回 nil
+ (nullable NSString *)normalizeMac:(NSString *)mac;

/// 台账 MAC → 蓝牙连接地址（首字节最高两位置 1，无分隔大写）
+ (NSString *)connectAddressFor:(NSString *)ledgerMac;

/// 广播地址 → 台账 MAC（清掉首字节最高两位，小写无分隔）；本来就是公开地址时返回 nil
+ (nullable NSString *)publicAddressOf:(NSString *)broadcastMac;

/// 查台账时依次尝试的候选（第一个永远是原样）
+ (NSArray<NSString *> *)lookupVariantsFor:(NSString *)mac;

@end

NS_ASSUME_NONNULL_END
