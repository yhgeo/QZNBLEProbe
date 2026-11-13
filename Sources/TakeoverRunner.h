//
//  TakeoverRunner.h
//  热水器蓝牙 —— 连接抢占 / 强制中断
//
//  水控表是 BLE 单连接外设：同一时刻只允许一个 Central 持有链路。
//  本引擎提供四档中断，按「影响从小到大」排列：
//    1 抢占   —— 连上后保持链路 + 周期 0x23 心跳，期间别人连不上（可随时停）
//    2 踢线   —— connect→短暂保持→disconnect 循环，把已连接方挤掉
//    3 关阀   —— 0x22 关阀 / 0x32 结束交易，中断对方正在进行的用水
//    4 改配   —— 0x88 禁用密钥 / 0x19 清项目 / 0x20 写编号（会让对方后续流程失败）
//
//  ⚠️ 第 3、4 档会改变设备状态，第 4 档默认跑完自动复原（0x88 启用 + 0x20 回原编号）。
//

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KRTakeoverMode) {
    KRTakeoverModeHold = 0,     // 长连接占用
    KRTakeoverModeKick,         // 连接风暴
    KRTakeoverModeValve,        // 关阀 / 结束交易
    KRTakeoverModeConfig,       // 禁用密钥 + 清项目 + 改编号（自动复原）
};

@interface KRTakeoverRunner : NSObject

@property (nonatomic, assign, readonly) BOOL running;

/// 长连接占用：连上后每 interval 秒发一次 0x23，持续 duration 秒（0 = 手动停）
- (void)startHoldWithPeripheral:(CBPeripheral *)peripheral
                       duration:(NSTimeInterval)duration
                       interval:(NSTimeInterval)interval
                            log:(void (^)(NSString *line))log
                     completion:(void (^)(BOOL ok, NSString *detail))completion;

/// 连接风暴：connect → dwell 秒 → disconnect，循环 rounds 次
- (void)startKickWithPeripheral:(CBPeripheral *)peripheral
                         rounds:(NSInteger)rounds
                          dwell:(NSTimeInterval)dwell
                            gap:(NSTimeInterval)gap
                            log:(void (^)(NSString *line))log
                     completion:(void (^)(NSInteger success, NSInteger total))completion;

/// 关阀 / 结束交易 / 0x86 空载荷
- (void)startValveBreakWithLog:(void (^)(NSString *line))log
                    completion:(void (^)(BOOL ok, NSString *detail))completion;

/// 配置层中断：0x88 禁用 keyNo=0 → 0x19 清项目 → 0x20 写无效编号 → 自动复原
- (void)startConfigBreakWithLog:(void (^)(NSString *line))log
                     completion:(void (^)(BOOL ok, NSString *detail))completion;

/// 停止占用 / 停止风暴（下一次循环边界退出）
- (void)stop;

@end

NS_ASSUME_NONNULL_END
