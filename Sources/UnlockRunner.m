//
//  UnlockRunner.m
//  热水器蓝牙 —— 设备卡死解锁（实现）
//

#import "UnlockRunner.h"
#import "KRWMCrypto.h"
#import <QZNOSDK/KRWaterMeterKit.h>

static const uint8_t kHead = 0x60;

static uint32_t KRUR32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

/// 响应帧是 60 … 16 时去掉前 6 字节头，统一按 payload 解析
static NSData *KRUPayload(NSData *d) {
    if (d.length == 0) return nil;
    if (d.length >= 8 && ((const uint8_t *)d.bytes)[0] == kHead) {
        NSUInteger declared = ((NSUInteger)((const uint8_t *)d.bytes)[1] << 8)
                            | ((const uint8_t *)d.bytes)[2];
        if (declared >= 3 && d.length >= 6 + declared - 3) {
            return [d subdataWithRange:NSMakeRange(6, declared - 3)];
        }
    }
    return d;
}

static NSString *KRUErrorName(uint8_t code) {
    switch (code) {
        case 0x01: return @"确认";
        case 0x02: return @"包长度错误";
        case 0x03: return @"未采集消费数据";
        case 0x04: return @"功能码错误";
        case 0x05: return @"数据格式错误";
        case 0x06: return @"校验和错误";
        case 0x07: return @"结束码错误";
        case 0x08: return @"来源错误";
        case 0x09: return @"密钥错误";
        case 0x0A: return @"未知错误(0A)";
        case 0x0B: return @"未知错误(0B)";
        default:   return [NSString stringWithFormat:@"0x%02X", code];
    }
}

@implementation KRUnlockResult
- (instancetype)init {
    if ((self = [super init])) {
        _title = @"";
        _detail = @"";
        _payloadHex = @"";
        _stateBefore = 0xFF;
        _stateAfter = 0xFF;
    }
    return self;
}
@end

@implementation UnlockRunner

+ (NSData *)buildWriteBackPayloadFromXfData:(NSData *)xfData money:(NSNumber *)money {
    if (xfData.length < 62) return nil;
    const uint8_t *p = xfData.bytes;
    NSMutableData *out = [NSMutableData dataWithCapacity:32];
    [out appendBytes:p + 1  length:6];    // timeId
    [out appendBytes:p + 7  length:4];    // productId
    [out appendBytes:p + 11 length:4];    // deviceId
    [out appendBytes:p + 15 length:4];    // accountId
    [out appendBytes:p + 20 length:4];    // useCount
    uint32_t m = money ? money.unsignedIntValue : KRUR32(p + 28);
    uint8_t mb[4] = { (uint8_t)((m >> 24) & 0xFF), (uint8_t)((m >> 16) & 0xFF),
                      (uint8_t)((m >> 8) & 0xFF),  (uint8_t)(m & 0xFF) };
    [out appendBytes:mb length:4];        // consumeMone
    uint8_t sep = 0x00;
    [out appendBytes:&sep length:1];      // 分隔符
    [out appendBytes:p + 57 length:5];    // tac5（必须用设备原值）
    return out;
}

- (void)unlockWithLog:(void (^)(NSString *))log
           completion:(void (^)(KRUnlockResult *))completion {

    KRUnlockResult *res = [KRUnlockResult new];
    void (^finish)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(res); });
    };
    void (^say)(NSString *) = ^(NSString *line) {
        if (log) dispatch_async(dispatch_get_main_queue(), ^{ log(line ?: @""); });
    };

    say(@"========== 解锁设备 ==========");
    say(@"流程：读状态 → 采集 0x85 → 自造 32B → 0x86 → 复查");
    say(@"不走服务端，不产生结算账单");

    KRWMCore *core = [KRWMCore sharedCore];

    // ---- 1 读状态 ----
    [core krGetStateOfDevice:^(KRSyncType t, NSData *d, NSString *orig) {
        NSData *p = KRUPayload(d);
        if (p.length >= 32) {
            const uint8_t *b = p.bytes;
            res.stateBefore = b[28];
            say([NSString stringWithFormat:@"状态帧: state=%u deviceId=%u random=%@",
                 b[28], KRUR32(b + 5), [KRWMCrypto hexFromData:[p subdataWithRange:NSMakeRange(24, 4)]]]);
        }
    } result:^(KRSyncType t, KRSyncResponseState s) {
        if (s != KRSyncResponseStateSuccess || res.stateBefore == 0xFF) {
            res.outcome = KRUnlockOutcomeFailed;
            res.title = @"读不到设备状态";
            res.detail = [NSString stringWithFormat:@"同步状态 %ld，请先连接设备", (long)s];
            say(res.detail);
            finish();
            return;
        }
        if (res.stateBefore == 0) {
            res.outcome = KRUnlockOutcomeIdle;
            res.title = @"设备空闲，无需解锁";
            res.detail = @"state=0";
            say(@"✅ state=0，设备本来就空闲");
            finish();
            return;
        }
        if (res.stateBefore == 1 || res.stateBefore == 2) {
            res.outcome = KRUnlockOutcomeBusy;
            res.title = @"设备正在用水";
            res.detail = [NSString stringWithFormat:@"state=%u（1 有订单 / 2 刷卡中），先关阀再解锁",
                          res.stateBefore];
            say([NSString stringWithFormat:@"⚠️ %@", res.detail]);
            finish();
            return;
        }

        // ---- 2 采集 0x85 ----
        say([NSString stringWithFormat:@"state=%u，采集待结算记录…", res.stateBefore]);
        __block NSData *xfData = nil;
        [core krGetConsumptionDetails:^(KRSyncType t2, NSData *d2, NSString *orig2) {
            NSData *p = KRUPayload(d2);
            if (p.length == 62) {
                xfData = p;
                const uint8_t *b = p.bytes;
                say([NSString stringWithFormat:
                     @"0x85 62B timeId=%@ money=%u厘 rate=%u puluse=%u tac=%@",
                     [KRWMCrypto hexFromData:[p subdataWithRange:NSMakeRange(1, 6)]],
                     KRUR32(b + 28), KRUR32(b + 32), KRUR32(b + 42),
                     [KRWMCrypto hexFromData:[p subdataWithRange:NSMakeRange(57, 5)]]]);
            }
        } result:^(KRSyncType t2, KRSyncResponseState s2) {
            if (s2 != KRSyncResponseStateSuccess || xfData.length != 62) {
                res.outcome = KRUnlockOutcomeNoRecord;
                res.title = @"采不到 62 字节消费帧";
                res.detail = [NSString stringWithFormat:
                              @"同步状态 %ld，记录可能已被他人结算或设备刚关阀还没落盘",
                              (long)s2];
                say([NSString stringWithFormat:@"⚠️ %@", res.detail]);
                finish();
                return;
            }

            // ---- 3 自造 32B ----
            NSData *payload = [UnlockRunner buildWriteBackPayloadFromXfData:xfData money:nil];
            res.payloadHex = [KRWMCrypto hexFromData:payload];
            say([NSString stringWithFormat:@"自造 32B 载荷: %@", res.payloadHex]);
            say(@"（tac 用设备原值，金额用帧原值）");

            // ---- 4 发 0x86 ----
            __block BOOL rejected = NO;
            __block NSString *respText = @"";
            [core krClearConsumptionDetails:payload
                dataCallback:^(KRSyncType t3, NSData *d3, NSString *orig3) {
                    NSData *p = KRUPayload(d3);
                    if (p.length >= 2 && ((const uint8_t *)p.bytes)[0] == 0x81) {
                        uint8_t code = ((const uint8_t *)p.bytes)[1];
                        respText = [NSString stringWithFormat:@"81 %02X %@", code, KRUErrorName(code)];
                        if (code != 0x01) rejected = YES;
                    } else if (p.length > 0) {
                        respText = [KRWMCrypto hexFromData:p];
                    }
                    say([NSString stringWithFormat:@"0x86 响应: %@", respText]);
                } result:^(KRSyncType t3, KRSyncResponseState s3) {
                    if (s3 != KRSyncResponseStateSuccess) {
                        res.outcome = KRUnlockOutcomeFailed;
                        res.title = @"写回超时";
                        res.detail = [NSString stringWithFormat:@"同步状态 %ld", (long)s3];
                        say([NSString stringWithFormat:@"⚠️ %@", res.detail]);
                        finish();
                        return;
                    }

                    // ---- 5 复查状态 ----
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        [core krGetStateOfDevice:^(KRSyncType t4, NSData *d4, NSString *orig4) {
                            NSData *p = KRUPayload(d4);
                            if (p.length >= 32) res.stateAfter = ((const uint8_t *)p.bytes)[28];
                        } result:^(KRSyncType t4, KRSyncResponseState s4) {
                            if (s4 != KRSyncResponseStateSuccess || res.stateAfter == 0xFF) {
                                res.outcome = KRUnlockOutcomeFailed;
                                res.title = @"解锁后读不到状态";
                                res.detail = @"命令已发，结果未确认，可再点一次";
                                say([NSString stringWithFormat:@"⚠️ %@", res.detail]);
                                finish();
                                return;
                            }
                            if (res.stateAfter == 0) {
                                res.outcome = KRUnlockOutcomeCleared;
                                res.title = @"解锁成功";
                                res.detail = [NSString stringWithFormat:@"state %u → 0，设备已可再次开阀",
                                              res.stateBefore];
                                say([NSString stringWithFormat:@"✅ %@", res.detail]);
                                say(@"提醒：服务端那笔订单仍挂着预扣，未结算");
                            } else if (rejected) {
                                res.outcome = KRUnlockOutcomeRejected;
                                res.title = @"载荷被设备拒绝";
                                res.detail = [NSString stringWithFormat:
                                              @"0x86 回 %@，state 仍 %u。tac 与字段必须与帧完全一致",
                                              respText, res.stateAfter];
                                say([NSString stringWithFormat:@"⚠️ %@", res.detail]);
                            } else {
                                res.outcome = KRUnlockOutcomeStillLocked;
                                res.title = @"命令已确认但记录仍在";
                                res.detail = [NSString stringWithFormat:
                                              @"state 仍 %u：设备校验载荷本身，或记录已被他人结算",
                                              res.stateAfter];
                                say([NSString stringWithFormat:@"⚠️ %@", res.detail]);
                            }
                            finish();
                        }];
                    });
                }];
        }];
    }];
}

@end
