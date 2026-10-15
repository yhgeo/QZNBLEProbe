//
//  LEDVerifyRunner.h
//  热水器蓝牙 —— 真机自动验证引擎
//
//  用途：把 PROTOCOL.md 里那批"待真机验证"的疑点做成一套可重复执行的自动检查，
//  跑完直接产出一份可粘贴的 Markdown 报告。
//
//  对应文档：
//    §2.3  响应帧功能码是否等于请求功能码（已结案：等于）
//    §9    服务端校验能力五层（L1 签名 / L2 会话绑定 / L3 金额算术 / L5 tac 派生性）
//    §4.2  0x85 帧 42..61 那 20 字节是明文用量还是密文
//
//  ⚠️ 三条铁律（与主流程一致，本引擎不得违反）：
//    1. 绝不自造费率包；2. randomNumber 只用设备给的；3. 失败必须上报
//  读阶段（阶段 A）只发只读指令；写阶段（阶段 B）必须由调用方显式确认。
//

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>

NS_ASSUME_NONNULL_BEGIN

/// 一条检查的结果
@interface LEDVerifyResult : NSObject
@property (nonatomic, copy) NSString *ident;      // 短标识，如 "A1"
@property (nonatomic, copy) NSString *title;      // 人话标题
/// 判定：PASS / FAIL / INFO / SKIP / WARN
@property (nonatomic, copy) NSString *verdict;
@property (nonatomic, copy) NSString *detail;     // 一句话结论（报告里当"结论"列）
@property (nonatomic, copy) NSString *evidence;   // 证据：原始数值，可空
@end

@interface LEDVerifyRunner : NSObject

@property (nonatomic, strong, readonly) NSMutableArray<LEDVerifyResult *> *results;
@property (nonatomic, assign, readonly) BOOL running;

/// `log` 用于实时刷屏；`completion` 在全部跑完后回调，report 即最终 Markdown 文本
- (void)startWithPeripheral:(nullable CBPeripheral *)peripheral
                       log:(void (^)(NSString *line))log
                completion:(void (^)(NSString *report))completion;

/// 阶段 B：把捕获到的 0x85 原文按 0x86 写回设备，核实设备是否有完整性/认证校验。
/// 会让设备从「待采集」回到「空闲」，属写操作，**必须用户先确认**。
- (void)runWriteBackProbeWithLog:(void (^)(NSString *line))log
                      completion:(void (^)(BOOL deviceAcked, BOOL stateCleared, NSString *detail))completion;

/// 上一份报告（Markdown，可直接贴进 PROTOCOL.md）
- (NSString *)markdownReport;

@end

NS_ASSUME_NONNULL_END
