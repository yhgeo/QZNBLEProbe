//
//  UnlockRunner.h
//  热水器蓝牙 —— 设备卡死解锁（跳过服务端结算清记录）
//
//  背景（PROTOCOL.md 附录 E，2026-11-14 真机实测）：
//    设备 state=3/6 表示「有待结算记录」，此时谁都无法开阀。
//    正常解法是 0x85 采集 → 上传服务端 → 解密 clData → 0x86 写回。
//    实测发现 0x86 的 32B 载荷格式与 AES 密钥都是客户端已知的，
//    载荷每个字段都来自设备自己给的 0x85 帧（含 tac），
//    因此可以本地自造载荷直接清记录，不依赖服务端。
//
//  32B 布局（实测）：
//    timeId(6) + productId(4) + deviceId(4) + accountId(4)
//    + useCount(4) + consumeMone(4) + 0x00(1) + tac5(5)
//
//  ⚠️ 定位：这是「解锁工具」，不是「免单工具」。
//    跳过服务端结算不会让账单消失——服务端那笔订单会挂预扣（实测 0.43 元），
//    直到超时释放或走官方结算。省钱的路径不在这里。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KRUnlockOutcome) {
    KRUnlockOutcomeIdle = 0,       // 设备本来就空闲，无需解锁
    KRUnlockOutcomeCleared,        // 解锁成功：state 3/6 → 0
    KRUnlockOutcomeStillLocked,    // 发了 0x86 但状态没变
    KRUnlockOutcomeBusy,           // state=1/2：正在用水，先关阀
    KRUnlockOutcomeNoRecord,       // 采不到 62B 消费帧
    KRUnlockOutcomeRejected,       // 设备回 81 09/81 0A 等，载荷被拒
    KRUnlockOutcomeFailed,         // 通信失败
};

@interface KRUnlockResult : NSObject
@property (nonatomic, assign) KRUnlockOutcome outcome;
@property (nonatomic, copy)   NSString *title;      // 一句话结论
@property (nonatomic, copy)   NSString *detail;     // 细节（字段值、响应码）
@property (nonatomic, copy)   NSString *payloadHex; // 自造的 32B 载荷
@property (nonatomic, assign) uint8_t stateBefore;
@property (nonatomic, assign) uint8_t stateAfter;
@end

@interface UnlockRunner : NSObject

/// 用当前采集到的 0x85 帧自造 32B 写回载荷。
/// @param xfData  62 字节 0x85 payload
/// @param money   覆盖 consumeMone（厘）；传 nil 用帧原值
+ (nullable NSData *)buildWriteBackPayloadFromXfData:(NSData *)xfData
                                              money:(nullable NSNumber *)money;

/// 完整解锁流程：读状态 → 采集 0x85 → 自造载荷 → 0x86 → 复查状态。
/// 只做设备侧动作，不调用任何服务端接口。
- (void)unlockWithLog:(void (^)(NSString *line))log
           completion:(void (^)(KRUnlockResult *result))completion;

@end

NS_ASSUME_NONNULL_END
