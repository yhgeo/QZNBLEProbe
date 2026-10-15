//
//  LEDVerifyRunner.m
//  热水器蓝牙 —— 真机自动验证引擎（实现）
//

#import "LEDVerifyRunner.h"
#import "KRWMCrypto.h"
#import "KRWMClient.h"
#import <QZNOSDK/KRWaterMeterKit.h>

#pragma mark - 结果对象

@implementation LEDVerifyResult
@end

#pragma mark - 常量

static const uint8_t kHead  = 0x60;
static const uint8_t kFlag  = 0x80;
static const uint8_t kTail  = 0x16;
static const uint8_t kWireB = 0x23;   // '#'
static const uint8_t kWireE = 0x0A;   // '\n'

static NSString * const V_PASS = @"PASS";
static NSString * const V_FAIL = @"FAIL";
static NSString * const V_WARN = @"WARN";
static NSString * const V_INFO = @"INFO";
static NSString * const V_SKIP = @"SKIP";

/// 记录探针用到的功能码
static const unsigned int kCmdState   = 0x23;
static const unsigned int kCmdRate    = 0x21;
static const unsigned int kCmdCollect = 0x85;
static const unsigned int kCmdWriteBk = 0x86;

#pragma mark - 出站帧来源

/// 直接从 SDK 自己的日志里捞"我发出去的帧"。
///
/// 为什么不用 method swizzling：SDK 的 `startLog=YES` 会把每条出站帧按
/// `-writeData--[<NSData>]<HEX文本>` 打进 `KRWMCore.AllLogString`（探针页已打开），
/// 读日志是**纯只读**操作，不改 SDK 行为、不需要 objc runtime、也不会因为
/// 分类没被 `-ObjC` 链接进来而失效。
///
/// 找最近一条指定功能码的出站帧；找不到返回 nil。
static NSString *LEDTakeWireFrame(unsigned int expectFunCode) {
    NSString *log = [KRWMCore sharedCore].AllLogString;
    if (log.length == 0) return nil;

    NSRange marker = [log rangeOfString:@"-writeData--[" options:NSBackwardsSearch];
    if (marker.location == NSNotFound) return nil;

    NSUInteger start = NSMaxRange(marker);
    NSRange close = [log rangeOfString:@"]" options:0 range:NSMakeRange(start, log.length - start)];
    if (close.location == NSNotFound) return nil;

    NSRange rest = NSMakeRange(NSMaxRange(close), log.length - NSMaxRange(close));
    NSRange eol = [log rangeOfString:@"\n" options:0 range:rest];
    NSUInteger textLen = (eol.location == NSNotFound) ? rest.length : (eol.location - rest.location);
    NSString *text = [log substringWithRange:NSMakeRange(rest.location, textLen)];

    NSRange hash = [text rangeOfString:@"#"];
    if (hash.location == NSNotFound) return nil;
    text = [text substringFromIndex:hash.location];

    // 校验一下确实是我们要的那条指令：解开 HEX 看第 5 字节（功能码）
    NSRange nl = [text rangeOfString:@"\n"];
    NSString *oneLine = (nl.location == NSNotFound) ? text : [text substringToIndex:nl.location];
    NSString *hex = [oneLine stringByTrimmingCharactersInSet:
                     [NSCharacterSet characterSetWithCharactersInString:@"#\r\n "]];
    NSData *bin = [KRWMCrypto dataFromHex:hex];
    if (bin.length < 6) return nil;
    if (((const uint8_t *)bin.bytes)[4] != expectFunCode) return nil;

    return oneLine;
}

#pragma mark - 小工具

static uint32_t LEDU32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

/// 香农熵（bit/byte，0~8）。用来判断一段字节像"结构化字段"还是"随机密文/摘要"。
static double LEDEntropy(NSData *data) {
    if (data.length == 0) return 0.0;
    NSUInteger counts[256] = {0};
    const uint8_t *b = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) counts[b[i]]++;
    double e = 0.0;
    for (int i = 0; i < 256; i++) {
        if (counts[i] == 0) continue;
        double p = (double)counts[i] / (double)data.length;
        e -= p * log2(p);
    }
    return e;
}

static NSData *LEDSub(NSData *d, NSUInteger loc, NSUInteger len) {
    if (loc + len > d.length) return [NSData data];
    return [d subdataWithRange:NSMakeRange(loc, len)];
}

/// 在一批"同一偏移的字节"上看有几个不同取值
static NSUInteger LEDDistinctAtOffset(NSArray<NSData *> *samples, NSUInteger off, NSUInteger len) {
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSData *s in samples) {
        if (off + len > s.length) continue;
        [seen addObject:[KRWMCrypto hexFromData:LEDSub(s, off, len)]];
    }
    return seen.count;
}

/// 从已有结果里取出 B3.1 的结论（报告里做三方比对用）
static NSString *LEDUploadAmountFromResults(NSArray<LEDVerifyResult *> *results) {
    for (LEDVerifyResult *r in results) {
        if ([r.ident isEqualToString:@"B3.1"] && r.detail.length) return r.detail;
    }
    return nil;
}

/// 把 §5.2 的字段表逐项抠出来（大端 + BCD 时间）
///
/// ⚠️ 42..61 的**宽度按设备实测**（PROTOCOL.md §16.3）：`flowRate` / `useTime`
/// 是 2 字节，**不能**照抄 iOS SDK 反汇编里的 4 字节偏移——SDK 那套是
/// `pluseNum` 当 8 字节，读真机 62 字节帧时会串位。
static NSDictionary *LEDParseConsumption(NSData *payload) {
    if (payload.length < 42) return nil;
    const uint8_t *p = payload.bytes;

    // timeId 是 BCD：每字节两位十进制
    NSMutableString *timeId = [NSMutableString string];
    for (NSUInteger i = 1; i <= 6; i++) [timeId appendFormat:@"%02x", p[i]];

    NSData *tail = (payload.length > 42) ? LEDSub(payload, 42, payload.length - 42) : [NSData data];

    NSMutableDictionary *d = [@{
        @"timeId":       timeId,
        @"productId":    @(LEDU32(p + 7)),
        @"deviceId":     @(LEDU32(p + 11)),
        @"accountId":    @(LEDU32(p + 15)),
        @"accountType":  @(p[19]),
        @"useCount":     @(LEDU32(p + 20)),
        @"ykMoney":      @(LEDU32(p + 24)),      // 预扣，厘
        @"consumeMone":  @(LEDU32(p + 28)),      // 消费，厘
        @"rate":         @(LEDU32(p + 32)),
        @"mac":          [KRWMCrypto hexFromData:LEDSub(payload, 36, 6)],
        @"tail":         tail ?: [NSData data],
        @"length":       @(payload.length),
    } mutableCopy];

    // 尾部字段（仅当确实是 62 字节那种完整帧时才有意义）
    if (payload.length >= 62) {
        uint16_t flow = (uint16_t)((p[46] << 8) | p[47]);
        uint16_t use  = (uint16_t)((p[48] << 8) | p[49]);
        d[@"pluseNum"]  = @(LEDU32(p + 42));
        d[@"flowRate"]  = @(flow);   // mL/6s
        d[@"useTime"]   = @(use);    // 秒
        d[@"pauseCnt"]  = @(p[50]);
        d[@"tac"]       = [KRWMCrypto hexFromData:LEDSub(payload, 59, 3)];
    }
    return d;
}

/// 一个响应帧的"体检"结果
static NSDictionary *LEDInspectFrame(NSString *orig, unsigned int expectFunCode) {
    if (orig.length < 10) return nil;
    NSString *hex = nil;
    if ([orig hasPrefix:@"#"]) {
        hex = [orig substringWithRange:NSMakeRange(1, orig.length - 2)];
    } else {
        hex = orig;
    }
    hex = [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSData *bin = [KRWMCrypto dataFromHex:hex];
    if (bin.length < 8) return nil;

    const uint8_t *b = bin.bytes;
    if (b[0] != kHead) return nil;

    NSUInteger declaredLen = ((NSUInteger)b[1] << 8) | b[2];
    NSUInteger recvControl  = b[3];
    NSUInteger recvFunCode  = b[4];
    if (declaredLen < 3) return nil;
    NSUInteger expectTotal  = declaredLen + 5;

    // CRC 自算：Σ data + control + funCode
    NSUInteger calcCrc = recvControl + recvFunCode;
    for (NSUInteger i = 6; i + 2 < bin.length; i++) calcCrc += b[i];
    calcCrc &= 0xFF;
    NSUInteger recvCrc = b[bin.length - 2];

    NSData *payload = LEDSub(bin, 6, declaredLen - 3);

    return @{
        @"control":      @(recvControl),
        @"funCode":      @(recvFunCode),
        @"sameAsReq":    @(recvFunCode == expectFunCode),
        @"declaredLen":  @(declaredLen),
        @"actualLen":    @(bin.length),
        @"lenOK":        @(expectTotal == bin.length),
        @"crcCalc":      @(calcCrc),
        @"crcRecv":      @(recvCrc),
        @"crcOK":        @(calcCrc == recvCrc),
        @"tailByte":     @(b[bin.length - 1]),
        @"tailOK":       @(b[bin.length - 1] == kTail),
        @"payload":      payload ?: [NSData data],
        @"raw":          orig ?: @"",
    };
}

#pragma mark - 主类私有接口

/// `addResult:` / `log:` 必须在 `LEDSelfTestAgainstRealSample` **之前**声明——
/// 那个静态函数要用它们；不声明就会报
/// `no visible @interface ... declares the selector`（首版构建就是栽在这）。
/// 其余属性留在下面那个扩展里，两个扩展会合并成同一个类扩展。
@interface LEDVerifyRunner (PrivateAPI)
- (void)log:(NSString *)line;
- (void)addResult:(NSString *)ident
            title:(NSString *)title
          verdict:(NSString *)verdict
           detail:(NSString *)detail
         evidence:(NSString *)evidence;
- (void)recordWriteBackResult:(NSString *)detail
                      verdict:(NSString *)verdict
                     evidence:(NSString *)evidence;
@end

/// 用真机实测样本做一次离线自检：确认字段偏移没写错。
///
/// 样本来自探针真机日志（PROTOCOL.md §16.2），字段值已知，可当回归用例。
/// 硬编码的是**公开的协议样本**，不含任何账号凭据。
static void LEDSelfTestAgainstRealSample(LEDVerifyRunner *runner) {
    static NSString * const kRealPayload =
        @"802610151807390000037b00000e1d00006105020000000200000bb8"
         "000002a40000001ac47f0edbd142000000fe014901cf01000000000000a86e0fdf82";
    NSData *payload = [KRWMCrypto dataFromHex:kRealPayload];
    NSDictionary *f = LEDParseConsumption(payload);

    NSMutableArray<NSString *> *bad = [NSMutableArray array];
    void (^expect)(NSString *, id) = ^(NSString *key, id want) {
        id got = f[key];
        if (![got isEqual:want]) [bad addObject:[NSString stringWithFormat:@"%@=%@ 期望 %@", key, got, want]];
    };
    expect(@"length", @(62));
    expect(@"timeId", @"261015180739");
    expect(@"productId", @(891));
    expect(@"deviceId", @(3613));
    expect(@"accountId", @(24837));
    expect(@"accountType", @(2));
    expect(@"useCount", @(2));
    expect(@"ykMoney", @(3000));
    expect(@"consumeMone", @(676));
    expect(@"rate", @(26));
    expect(@"mac", @"c47f0edbd142");
    expect(@"pluseNum", @(254));
    expect(@"flowRate", @(329));
    expect(@"useTime", @(463));
    expect(@"pauseCnt", @(1));
    expect(@"tac", @"0fdf82");

    // 顺带核对 CRC 公式（§14.2）：crc = (Σpayload + control + funCode) & 0xFF
    NSUInteger sum = 0;
    const uint8_t *b = payload.bytes;
    for (NSUInteger i = 0; i < payload.length; i++) sum += b[i];
    NSUInteger crc = (sum + 0x81 + 0x85) & 0xFF;
    if (crc != 0x9D) [bad addObject:[NSString stringWithFormat:@"CRC 复算=0x%02X 期望 0x9D", (unsigned) crc]];
    if (payload.length + 3 != 0x41) [bad addObject:@"长度字段应为 0x0041"];

    [runner addResult:@"A9.1"
                title:@"离线回归：用真机实测样本验证字段偏移"
              verdict:bad.count == 0 ? V_PASS : V_FAIL
               detail:bad.count == 0
                      ? @"16 个字段 + CRC + 长度字段全部命中（样本见 PROTOCOL.md §16.2）"
                      : [NSString stringWithFormat:@"%lu 项不符：%@", (unsigned long)bad.count,
                         [bad componentsJoinedByString:@"; "]]
             evidence:[NSString stringWithFormat:@"payload(%luB)=%@", (unsigned long)payload.length,
                       [KRWMCrypto hexFromData:payload]]];
}

#pragma mark - 主类

@interface LEDVerifyRunner ()
@property (nonatomic, strong) NSMutableArray<LEDVerifyResult *> *results;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) CBPeripheral *peripheral;

@property (nonatomic, copy) void (^logBlock)(NSString *line);
@property (nonatomic, copy) void (^doneBlock)(NSString *report);

/// 阶段 A 采集到的素材
@property (nonatomic, strong) NSMutableArray<NSData *> *collectSamples;   // 0x85 payload 样本
@property (nonatomic, strong) NSMutableArray<NSString *> *collectWire;    // 对应出站帧
@property (nonatomic, strong) NSDictionary *lastState;                    // 状态帧字段
@property (nonatomic, strong) NSData *lastWire86;                         // 最近一次 0x86 出站帧
@property (nonatomic, copy)   NSString *lastXfHexLower;
@property (nonatomic, copy)   NSString *lastOrderNo;
@property (nonatomic, copy)   NSString *lastSnCode;
@property (nonatomic, assign) NSInteger probeSeed;
@property (nonatomic, assign) BOOL didTailCompare;
@property (nonatomic, strong) NSString *markdown;
@end

@implementation LEDVerifyRunner

- (instancetype)init {
    if ((self = [super init])) {
        _results = [NSMutableArray array];
        _collectSamples = [NSMutableArray array];
        _collectWire = [NSMutableArray array];
        _probeSeed = (NSInteger)([NSDate date].timeIntervalSince1970);
    }
    return self;
}

#pragma mark - 生命周期

- (void)startWithPeripheral:(CBPeripheral *)peripheral
                        log:(void (^)(NSString *))log
                 completion:(void (^)(NSString *))completion {
    if (self.running) {
        if (log) log(@"⚠️ 上一轮自检还没跑完");
        return;
    }
    self.running = YES;
    self.peripheral = peripheral;
    self.logBlock = log;
    self.doneBlock = completion;
    self.didTailCompare = NO;
    [self.results removeAllObjects];
    [self.collectSamples removeAllObjects];
    [self.collectWire removeAllObjects];
    self.lastXfHexLower = nil;
    self.lastOrderNo = nil;

    [self log:@"========== 自动验证开始 =========="];
    [self log:@"只读优先：先跑阶段 A（不会开阀、不会关阀）"];
    [self section:@"A9 离线自检（不碰设备）"];
    LEDSelfTestAgainstRealSample(self);   // 先证明偏移表没写错，再去读真机
    [self section:@"A1 读设备状态（0x23）"];
    [self stepA1_State];
}

- (void)log:(NSString *)line {
    if (self.logBlock) self.logBlock(line ?: @"");
}

- (void)section:(NSString *)title {
    if (title.length) [self log:[NSString stringWithFormat:@"\n--- %@ ---", title]];
}

- (void)addResult:(NSString *)ident
            title:(NSString *)title
          verdict:(NSString *)verdict
           detail:(NSString *)detail
         evidence:(NSString *)evidence {
    LEDVerifyResult *r = [[LEDVerifyResult alloc] init];
    r.ident = ident;
    r.title = title;
    r.verdict = verdict;
    r.detail = detail ?: @"";
    r.evidence = evidence ?: @"";
    [self.results addObject:r];
    [self log:[NSString stringWithFormat:@"[%@] %@  %@\n      %@%@",
               verdict, ident, title, r.detail,
               r.evidence.length ? [NSString stringWithFormat:@"\n      证据: %@", r.evidence] : @""]];
}

- (void)finishAll {
    self.running = NO;
    self.markdown = [self buildReport];
    [self log:@"\n========== 自动验证结束 =========="];
    [self log:[NSString stringWithFormat:@"共 %lu 条结论，点「复制报告」取走 Markdown",
               (unsigned long)self.results.count]];
    if (self.doneBlock) self.doneBlock(self.markdown);
}

#pragma mark - 阶段 A：只读巡检

/// A1 读状态：拿 deviceId / accountId / random / mac，后续步骤都要用
- (void)stepA1_State {
    [self section:@"A1 读设备状态（0x23）"];
    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krGetStateOfDevice:^(KRSyncType t, NSData *d, NSString *orig) {
        NSDictionary *insp = LEDInspectFrame(orig, kCmdState);
        if (insp) {
            // 出站帧从 SDK 自己的日志里捞（纯只读，见 LEDTakeWireFrame 的说明）
            NSString *sent = LEDTakeWireFrame(kCmdState);
            [ws addResult:@"A0.1" title:@"出站帧与响应帧结构自洽（长度/CRC/结束码）"
                  verdict:([insp[@"lenOK"] boolValue] && [insp[@"crcOK"] boolValue]
                           && [insp[@"tailOK"] boolValue]) ? V_PASS : V_FAIL
                   detail:[NSString stringWithFormat:@"响应 control=0x%02X funCode=0x%02X len=%@/%@ crc=0x%02X/0x%02X；出站帧%@",
                           [insp[@"control"] unsignedIntValue], [insp[@"funCode"] unsignedIntValue],
                           insp[@"declaredLen"], insp[@"actualLen"],
                           [insp[@"crcCalc"] unsignedIntValue], [insp[@"crcRecv"] unsignedIntValue],
                           sent.length ? @"已抓到" : @"没抓到（SDK 日志里没找到）"]
                 evidence:[NSString stringWithFormat:@"出站: %@\n响应: %@",
                           sent ?: @"(未捕获)", insp[@"raw"]]];

            // 关键疑点：响应功能码 == 请求功能码？
            [ws addResult:@"A0.2" title:@"响应功能码 == 请求功能码（0x23）"
                  verdict:[insp[@"sameAsReq"] boolValue] ? V_PASS : V_FAIL
                   detail:[NSString stringWithFormat:@"请求 0x%02X，响应 0x%02X",
                           kCmdState, [insp[@"funCode"] unsignedIntValue]]
                 evidence:nil];
        }
        if (d.length >= 31) {
            const uint8_t *p = d.bytes;
            NSUInteger off = (p[0] == kHead && d.length >= 14) ? 6 : 0;
            const uint8_t *q = d.bytes + off;
            ws.lastState = @{
                @"deviceId":  @(LEDU32(q + 5)),
                @"accountId": @(LEDU32(q + 9)),
                @"mac":       [KRWMCrypto hexFromData:LEDSub(d, off + 13, 6)],
                @"protocol":  [NSString stringWithFormat:@"%02X", q[19]],
                @"random":    [KRWMCrypto hexFromData:LEDSub(d, off + 24, 4)],
                @"state":     @(q[28]),
                @"devType":   @(q[29]),
                @"a1":        @(q[30]),
            };
            ws.lastSnCode = ws.lastState[@"mac"];
            [ws addResult:@"A1.1" title:@"设备状态帧解析"
                  verdict:V_INFO
                   detail:[NSString stringWithFormat:@"state=%@ deviceId=%@ random=%@ mac=%@ protocol=%@",
                           ws.lastState[@"state"], ws.lastState[@"deviceId"],
                           ws.lastState[@"random"], ws.lastState[@"mac"], ws.lastState[@"protocol"]]
                 evidence:[KRWMCrypto hexFromData:d]];
        } else {
            [ws addResult:@"A1.1" title:@"设备状态帧解析" verdict:V_FAIL
                   detail:[NSString stringWithFormat:@"payload 只有 %lu 字节（需 ≥31）", (unsigned long)d.length]
                 evidence:nil];
        }
    } result:^(KRSyncType t, KRSyncResponseState s) {
        if (s != KRSyncResponseStateSuccess) {
            [ws addResult:@"A1.0" title:@"读设备状态" verdict:V_FAIL
                   detail:[NSString stringWithFormat:@"同步状态 %ld", (long)s] evidence:nil];
        }
        [ws stepA2_Collect:1];
    }];
}

/// A2 采集消费数据：拿 1 个样本，然后看设备能不能再给（用于多帧比对）
- (void)stepA2_Collect:(NSInteger)round {
    if (round == 1) [self section:@"A2 采集消费数据（0x85）"];
    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krGetConsumptionDetails:^(KRSyncType t, NSData *d, NSString *orig) {
        NSDictionary *insp = LEDInspectFrame(orig, kCmdCollect);
        NSString *sent = LEDTakeWireFrame(kCmdCollect);
        if (round == 1) {
            [ws addResult:@"A2.0.1" title:@"出站 0x85 帧"
                  verdict:sent.length ? V_PASS : V_WARN
                   detail:sent.length ? @"SDK 日志里抓到了 0x85 出站帧" : @"没抓到出站帧（SDK 日志可能被清空过）"
                 evidence:sent ?: @"-"];
        }
        if (insp) {
            [ws addResult:[NSString stringWithFormat:@"A2.%ld.0", (long)round]
                    title:@"0x85 响应功能码 == 请求功能码"
                  verdict:[insp[@"sameAsReq"] boolValue] ? V_PASS : V_FAIL
                   detail:[NSString stringWithFormat:@"请求 0x%02X，响应 0x%02X（看雪帖猜 0xFB）",
                           kCmdCollect, [insp[@"funCode"] unsignedIntValue]]
                 evidence:insp[@"raw"]];

            NSData *payload = insp[@"payload"];
            if (payload.length >= 42) {
                [ws.collectSamples addObject:payload];
                [ws.collectWire addObject:sent ?: @""];
                NSDictionary *f = LEDParseConsumption(payload);
                [ws addResult:[NSString stringWithFormat:@"A2.%ld.1", (long)round]
                        title:@"0x85 明文区字段解析"
                      verdict:V_INFO
                       detail:[NSString stringWithFormat:@"rate=%@厘 ykMoney=%@厘 consumeMone=%@厘 accountId=%@ mac=%@",
                               f[@"rate"], f[@"ykMoney"], f[@"consumeMone"], f[@"accountId"], f[@"mac"]]
                     evidence:[NSString stringWithFormat:@"payload(%luB) %@",
                               (unsigned long)payload.length, [KRWMCrypto hexFromData:payload]]];

                NSData *tail = f[@"tail"];
                [ws addResult:[NSString stringWithFormat:@"A2.%ld.2", (long)round]
                        title:@"42..61 那 20 字节的性质（明文用量 vs 密文/摘要）"
                      verdict:V_INFO
                       detail:[NSString stringWithFormat:@"长度 %lu 字节，香农熵 %.2f bit/byte（随机≈4.3，结构化字段通常<3）",
                               (unsigned long)tail.length, LEDEntropy(tail)]
                     evidence:[KRWMCrypto hexFromData:tail]];
            } else {
                [ws addResult:[NSString stringWithFormat:@"A2.%ld.1", (long)round]
                        title:@"0x85 样本可用性" verdict:V_SKIP
                       detail:[NSString stringWithFormat:@"payload 只有 %lu 字节，设备当前无待结算记录",
                               (unsigned long)payload.length] evidence:nil];
            }
        }

        // 最多再多要 2 帧，凑 3 个样本做纵向比对；失败就算了
        if (round < 3 && ws.collectSamples.count == (NSUInteger)round) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [ws stepA2_Collect:round + 1]; });
            return;
        }
        [ws stepA3_TailComparison];
    } result:^(KRSyncType t, KRSyncResponseState s) {
        if (s != KRSyncResponseStateSuccess && ws.collectSamples.count == 0) {
            [ws addResult:@"A2.0" title:@"采集消费数据" verdict:V_SKIP
                   detail:[NSString stringWithFormat:@"读不到（同步状态 %ld）——设备可能空闲无记录", (long)s]
                 evidence:nil];
        }
        if (round >= 3) [ws stepA3_TailComparison];
    }];
}

/// A3 多帧比对：把"随用量变化的字段"和"固定不变的字段"分开，判断尾部是计数器还是摘要/密文
- (void)stepA3_TailComparison {
    // 0x85 的 dataCallback 与 result 回调都会走到这一步，去重
    if (self.didTailCompare) return;
    self.didTailCompare = YES;

    [self section:@"A3 多帧纵向比对（判断尾部字段性质）"];
    NSArray<NSData *> *samples = self.collectSamples;

    if (samples.count < 2) {
        [self addResult:@"A3.0" title:@"多帧比对" verdict:V_SKIP
                 detail:[NSString stringWithFormat:@"只有 %lu 个样本，至少需要 2 个（设备侧无更多记录）",
                         (unsigned long)samples.count]
               evidence:nil];
        [self stepA4_Analyze];
        return;
    }

    // 逐位置看取值是否恒定
    NSUInteger len = samples.firstObject.length;
    NSMutableString *volatileMap = [NSMutableString string];
    NSMutableString *stableMap = [NSMutableString string];
    NSUInteger volatileCount = 0;
    for (NSUInteger off = 42; off < len; off++) {
        NSUInteger d = LEDDistinctAtOffset(samples, off, 1);
        if (d > 1) {
            volatileCount++;
            [volatileMap appendFormat:@"%lu(%lu) ", (unsigned long)off, (unsigned long)d];
        } else {
            [stableMap appendFormat:@"%lu ", (unsigned long)off];
        }
    }

    // 金额 + 尾部一起列出来，好肉眼判断"改金额会不会连动尾部"
    NSMutableString *dump = [NSMutableString string];
    for (NSUInteger i = 0; i < samples.count; i++) {
        NSDictionary *f = LEDParseConsumption(samples[i]);
        [dump appendFormat:@"#%lu consumeMone=%@ rate=%@ tail=%@\n",
         (unsigned long)(i + 1), f[@"consumeMone"], f[@"rate"], [KRWMCrypto hexFromData:f[@"tail"]]];
    }

    [self addResult:@"A3.1" title:@"尾部字节的变动位点分布"
          verdict:V_INFO
           detail:[NSString stringWithFormat:@"42..%lu 共 %lu 字节，其中 %lu 字节在不同帧间取值不同；恒定字节：%@",
                   (unsigned long)(len - 1), (unsigned long)(len - 42), (unsigned long)volatileCount,
                   stableMap.length > 40 ? [stableMap substringToIndex:40] : stableMap]
         evidence:dump];
    [self stepA4_Analyze];
}

/// A4 把 A3 的原始结论整理成"是不是密文"的判定
- (void)stepA4_Analyze {
    if (self.collectSamples.count < 2) {
        [self finishOrContinue];
        return;
    }
    NSData *t1 = self.collectSamples[0];
    NSData *t2 = self.collectSamples[1];
    NSData *tail1 = (t1.length > 42) ? LEDSub(t1, 42, t1.length - 42) : [NSData data];
    NSData *tail2 = (t2.length > 42) ? LEDSub(t2, 42, t2.length - 42) : [NSData data];

    double e1 = LEDEntropy(tail1);
    BOOL sameAmount = [[LEDParseConsumption(t1) objectForKey:@"consumeMone"]
                       isEqual:[LEDParseConsumption(t2) objectForKey:@"consumeMone"]];
    NSUInteger tailDiff = 0;
    for (NSUInteger i = 0; i < MIN(tail1.length, tail2.length); i++) {
        if (((const uint8_t *)tail1.bytes)[i] != ((const uint8_t *)tail2.bytes)[i]) tailDiff++;
    }

    NSString *verdict = V_INFO;
    NSString *detail = nil;
    if (sameAmount && tailDiff == 0) {
        detail = @"两帧金额相同、尾部也完全相同 → 尾部不含随机量或计数器";
    } else if (sameAmount && tailDiff > 0) {
        detail = [NSString stringWithFormat:@"两帧金额相同但尾部有 %lu 字节不同 → 尾部含计数器/时间戳，不是纯粹的金额摘要",
                  (unsigned long)tailDiff];
    } else {
        detail = [NSString stringWithFormat:@"两帧金额不同，尾部 %lu/%lu 字节随之变化，熵 %.2f→%.2f bit/byte",
                  (unsigned long)tailDiff, (unsigned long)tail1.length, e1, LEDEntropy(tail2)];
    }
    [self addResult:@"A4.1" title:@"尾部是否可当「金额的完整性指纹」" verdict:verdict
             detail:detail
           evidence:[NSString stringWithFormat:@"tail#1=%@\ntail#2=%@",
                     [KRWMCrypto hexFromData:tail1], [KRWMCrypto hexFromData:tail2]]];
    [self finishOrContinue];
}

#pragma mark - 阶段 A 的服务端部分

- (void)finishOrContinue {
    KRWMClient *c = [KRWMClient shared];
    if (!c.loggedIn) {
        [self addResult:@"B0.0" title:@"服务端检查" verdict:V_SKIP
                 detail:@"当前无登录态（loginCode/projectId 缺失），跳过 B 阶段全部接口实验"
               evidence:nil];
        [self finishAll];
        return;
    }
    if (self.collectSamples.count == 0) {
        [self addResult:@"B0.0" title:@"服务端检查" verdict:V_SKIP
                 detail:@"没有采集到 0x85 样本，无法做上传类实验" evidence:nil];
        [self finishAll];
        return;
    }
    [self stepB1_RandomProbe];
}

/// B1：拿一个"服务端绝对没发过"的 randomNumber 去上传，看服务端是否按自己的会话库校验
- (void)stepB1_RandomProbe {
    [self section:@"B1 会话绑定（L2）：用不存在的 randomNumber 上传"];
    self.probeSeed += 1;
    NSMutableString *fake = [NSMutableString string];
    uint32_t v = (uint32_t)(self.probeSeed * 2654435761u);
    for (int i = 0; i < 4; i++) [fake appendFormat:@"%02x", (v >> (8 * i)) & 0xFF];

    // 故意构造一个长度对、内容无意义的 xfData，避免拿真实数据去撞
    NSMutableData *blob = [NSMutableData dataWithLength:62];
    uint8_t *bp = blob.mutableBytes;
    bp[0] = 0x80;
    for (NSUInteger i = 1; i < blob.length; i++) bp[i] = (uint8_t)((i * 37 + (NSUInteger)self.probeSeed) & 0xFF);
    NSString *blobHex = [[KRWMCrypto hexFromData:blob] lowercaseString];

    __weak typeof(self) ws = self;
    [self log:[NSString stringWithFormat:@"→ upload(randomNumber=%@, xfData=自造 %luB)",
               fake, (unsigned long)blob.length]];
    [[KRWMClient shared] uploadXfDataVerbatim:blobHex
                                 protocolType:self.lastState[@"protocol"] ?: @""
                                 randomNumber:fake
                                   completion:^(BOOL success, NSInteger code, NSDictionary *data, NSString *message) {
        NSString *verdict = V_INFO;
        NSString *detail = nil;
        if (code == 226) {
            verdict = V_PASS;
            detail = @"服务端回 226「加密校验失败」→ 它确实在对 randomNumber 做会话/密文校验，不照单全收";
        } else if (code == 170) {
            verdict = V_PASS;
            detail = @"服务端回 170「签名错误」→ 但签名是我们自算的，说明它按收到的字段重算签名（严格）";
        } else if (code == 0) {
            verdict = V_WARN;
            detail = @"服务端接受了自造 xfData（code=0）→ 它没有对帧原文件认证校验，只用服务端自己的账本";
        } else {
            detail = [NSString stringWithFormat:@"服务端回 code=%ld %@", (long)code, message ?: @""];
        }
        [ws addResult:@"B1.1" title:@"服务端是否按会话校验 randomNumber" verdict:verdict
               detail:detail
             evidence:[NSString stringWithFormat:@"request randomNumber=%@ xfData=%luB\nresponse success=%d code=%ld message=%@\ndata=%@",
                       fake, (unsigned long)blob.length, success, (long)code, message ?: @"-",
                       data ? [data description] : @"nil"]];
        [ws stepB2_SignatureStrictness];
    }];
}

/// B2：拿真实样本试"大写 xfData"，验证服务端是不是严格重算签名
- (void)stepB2_SignatureStrictness {
    [self section:@"B2 签名严格性（L1）：故意送大写 xfData"];
    NSData *sample = self.collectSamples.firstObject;
    NSString *upper = [[KRWMCrypto hexFromData:sample] uppercaseString];
    self.lastXfHexLower = [[KRWMCrypto hexFromData:sample] lowercaseString];

    __weak typeof(self) ws = self;
    [[KRWMClient shared] uploadXfDataVerbatim:upper
                                 protocolType:self.lastState[@"protocol"] ?: @""
                                 randomNumber:self.lastState[@"random"] ?: @""
                                   completion:^(BOOL success, NSInteger code, NSDictionary *data, NSString *message) {
        NSString *verdict = V_INFO;
        NSString *detail = nil;
        if (code == 170) {
            verdict = V_PASS;
            detail = @"大写被拒（170）→ 服务端逐字重算签名，只保证「字段与签名原文一致」，不是防篡改";
        } else if (code == 0) {
            verdict = V_WARN;
            detail = @"大写也被接受（code=0）→ 服务端对 xfData 大小写不敏感，或按规范化后的值重算";
        } else {
            detail = [NSString stringWithFormat:@"code=%ld %@", (long)code, message ?: @""];
        }
        [ws addResult:@"B2.1" title:@"服务端对 xfData 大小写的严格性" verdict:verdict
               detail:detail
             evidence:[NSString stringWithFormat:@"大写长度=%lu code=%ld message=%@",
                       (unsigned long)upper.length, (long)code, message ?: @"-"]];
        [ws stepB3_AmountCrossCheck:data];
    }];
}

/// B3：三方金额比对 + 金额算术核对
- (void)stepB3_AmountCrossCheck:(NSDictionary *)uploadData {
    [self section:@"B3 金额交叉核对（L3）：上传响应 vs 订单查询 vs 账单列表"];

    id upMoney = uploadData[@"upMoney"] ?: uploadData[@"consumeMoney"];
    [self log:[NSString stringWithFormat:@"upload 响应金额字段: %@",
               upMoney ? [upMoney description] : @"(无)  —— 大概率因为 B2 已把这一单上传过"]];
    if (upMoney) {
        [self addResult:@"B3.1" title:@"upload 响应里的服务端金额" verdict:V_INFO
                 detail:[NSString stringWithFormat:@"upMoney=%@", upMoney] evidence:[uploadData description]];
    } else {
        [self addResult:@"B3.1" title:@"upload 响应里的服务端金额" verdict:V_SKIP
                 detail:@"响应里没有 upMoney/consumeMoney 字段（本单可能已在 B1/B2 被上传或拒收）"
               evidence:[uploadData description] ?: @"nil"];
    }

    // 本地算术：服务端 L3 若存在，就该是 费率 × 用量 ≈ 已扣金额
    NSDictionary *f = LEDParseConsumption(self.collectSamples.firstObject);
    uint32_t rate = [f[@"rate"] unsignedIntValue];
    uint32_t consumed = [f[@"consumeMone"] unsignedIntValue];
    uint32_t pre = [f[@"ykMoney"] unsignedIntValue];
    NSString *arith = [NSString stringWithFormat:@"rate=%@ 厘/单位, consumeMone=%@ 厘, ykMoney=%@ 厘",
                       f[@"rate"], f[@"consumeMone"], f[@"ykMoney"]];
    if (rate == 0 || consumed == 0) {
        [self addResult:@"B3.2" title:@"金额算术自洽性（rate × 用量 = 金额）" verdict:V_SKIP
                 detail:[NSString stringWithFormat:@"样本里 rate 或金额为 0，做不了乘法核对。%@", arith]
               evidence:nil];
    } else {
        // 不同计费方式(chargeMethod=0x11 水控计量)下用量与金额的换算系数未知，
        // 这里只给出可核对的关系式，不做"要么通过要么失败"的强判定。
        [self addResult:@"B3.2" title:@"金额算术自洽性（rate × 用量 = 金额）" verdict:V_INFO
                 detail:[NSString stringWithFormat:@"%@；预扣 %u 厘 ≥ 消费 %u 厘 → %@。服务端能拿到的独立量只有 rate 和预扣额，乘法核对的代价极低",
                         arith, pre, consumed, (pre >= consumed) ? @"成立" : @"不成立（异常）"]
               evidence:[NSString stringWithFormat:@"tail/用量字段=%@", [KRWMCrypto hexFromData:f[@"tail"]]]];
    }

    // 订单维度：拿 consumeOrder/result/query 的独立金额
    NSString *orderNo = self.lastOrderNo;
    if (orderNo.length == 0) {
        [self addResult:@"B3.3" title:@"订单查询的独立金额" verdict:V_SKIP
                 detail:@"没有 orderNo（rateOrder 没返回，或本轮没走过开阀），跳过 consumeOrder/result/query"
               evidence:nil];
        [self stepB4_BillCrossCheck];
        return;
    }
    __weak typeof(self) ws = self;
    [[KRWMClient shared] queryOrderResult:orderNo snCode:self.lastSnCode ?: @""
                              completion:^(BOOL success, NSInteger code, NSDictionary *data, NSString *message) {
        [ws addResult:@"B3.3" title:@"订单查询的独立金额" verdict:success ? V_INFO : V_WARN
               detail:[NSString stringWithFormat:@"errorCode=%ld %@", (long)code, message ?: @""]
             evidence:data ? [data description] : @"nil"];
        [ws stepB4_BillCrossCheck];
    }];
}

/// B4：账单列表里同笔金额
- (void)stepB4_BillCrossCheck {
    [self section:@"B4 账单列表（第三方独立口径）"];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM";
    NSString *month = [fmt stringFromDate:[NSDate date]];

    __weak typeof(self) ws = self;
    [[KRWMClient shared] loadBillsForMonth:month completion:^(BOOL ok, NSArray *list, NSString *message) {
        if (!ok || list.count == 0) {
            [ws addResult:@"B4.1" title:@"账单列表" verdict:V_SKIP
                   detail:[NSString stringWithFormat:@"取不到（%@）", message ?: @"空"] evidence:nil];
            [ws finishAll];
            return;
        }
        NSDictionary *first = list.firstObject;
        NSDictionary *dto = [first[@"consumeBillDTO"] isKindOfClass:[NSDictionary class]]
                            ? first[@"consumeBillDTO"] : first;
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (NSUInteger i = 0; i < MIN(list.count, (NSUInteger)5); i++) {
            NSDictionary *it = list[i];
            NSDictionary *d = [it[@"consumeBillDTO"] isKindOfClass:[NSDictionary class]]
                              ? it[@"consumeBillDTO"] : it;
            [lines addObject:[NSString stringWithFormat:@"%@  %@元  %@",
                              d[@"consumeDate"] ?: @"?", d[@"consumeMoney"] ?: @"?", d[@"snCode"] ?: d[@"deviceId"] ?: @""]];
        }
        [ws addResult:@"B4.1" title:@"账单列表里的金额" verdict:V_INFO
               detail:[NSString stringWithFormat:@"最近 %lu 笔（本月 %@）", (unsigned long)MIN(list.count, (NSUInteger)5), month]
             evidence:[lines componentsJoinedByString:@"\n"]];
        [ws addResult:@"B4.2" title:@"金额三方是否恒等（upload / 订单查询 / 账单）" verdict:V_INFO
               detail:[NSString stringWithFormat:@"upload=%@，账单最近一笔=%@ —— 若两者不等且能对上设备帧，说明金额只有一个权威来源（服务端）",
                       LEDUploadAmountFromResults(ws.results) ?: @"(无)", dto[@"consumeMoney"] ?: @"?"]
             evidence:nil];
        [ws finishAll];
    }];
}

#pragma mark - 阶段 B：写操作（需用户显式确认）

- (void)runWriteBackProbeWithLog:(void (^)(NSString *))log
                      completion:(void (^)(BOOL, BOOL, NSString *))completion {
    self.logBlock = log;
    NSData *sample = self.collectSamples.firstObject;
    if (sample.length == 0) {
        if (completion) completion(NO, NO, @"没有 0x85 样本可回传");
        return;
    }
    [self log:@"B5：把采集到的 0x85 原文按 0x86 原样回传设备（写操作）"];
    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krClearConsumptionDetails:sample
        dataCallback:^(KRSyncType t, NSData *d, NSString *orig) {
            [ws log:[NSString stringWithFormat:@"0x86 响应 payload: %@", [KRWMCrypto hexFromData:d]]];
        } result:^(KRSyncType t, KRSyncResponseState s) {
            // 注意：SDK 的 `KRSyncResponseStateSuccess` 是「写命令已确认」，
            // 设备对 payload 本身是否买账要看随后的 state 复查。
            BOOL acked = (s == KRSyncResponseStateSuccess);
            [ws log:[NSString stringWithFormat:@"0x86 同步状态: %ld", (long)s]];
            // 紧接着读一次状态：state 还是 3/6 就说明记录没被清（设备侧有完整性校验）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[KRWMCore sharedCore] krGetStateOfDevice:^(KRSyncType t2, NSData *d2, NSString *orig2) {
                    NSUInteger off = (d2.length >= 14 && ((const uint8_t *)d2.bytes)[0] == kHead) ? 6 : 0;
                    uint8_t st = (d2.length > off + 28) ? ((const uint8_t *)d2.bytes)[off + 28] : 0xFF;
                    BOOL cleared = (st == 0);
                    NSString *detail = [NSString stringWithFormat:
                        @"回传 xfData 后设备 ACK=%@，state=%u（0 空闲 / 3 待采集）→ %@",
                        acked ? @"是" : @"否", st,
                        cleared ? @"设备接受了回传并清空（说明设备不校验 payload，谁来都给清）"
                                : @"设备回了 ACK 但没清记录 → 它校验的是数据本身，而不是「有没有发 0x86」。"
                                  @"原始 0x85 数据不是合法的 0x86 payload（正解是服务端 clData 解密后那段）"];
                    [ws recordWriteBackResult:detail verdict:(cleared ? V_WARN : V_PASS) evidence:orig2];
                    if (completion) completion(acked, cleared, detail);
                } result:^(KRSyncType t2, KRSyncResponseState s2) {
                    NSString *detail = [NSString stringWithFormat:
                        @"写回命令 ACK=%@，但复查状态没读到（同步状态 %ld）——"
                        @"结论未定，可再跑一次自动验证", acked ? @"是" : @"否", (long)s2];
                    [ws recordWriteBackResult:detail verdict:V_SKIP evidence:nil];
                    if (completion) completion(acked, NO, detail);
                }];
            });
        }];
}

/// B5 结果的唯一写入口。
///
/// 之前这里有两条添加路径，导致报告里出现**两条 B5.1**（一条 INFO、一条 SKIP），
/// 而且 `markdownReport` 用的是旧的 `self.markdown`，会把新结果吞掉。
/// 现在统一走这里，并**同时刷新** `markdown`，保证复制到的一定是最新报告。
- (void)recordWriteBackResult:(NSString *)detail
                      verdict:(NSString *)verdict
                     evidence:(NSString *)evidence {
    for (NSInteger i = (NSInteger)self.results.count - 1; i >= 0; i--) {
        if ([self.results[(NSUInteger)i].ident isEqualToString:@"B5.1"]) {
            [self.results removeObjectAtIndex:(NSUInteger)i];
        }
    }
    [self addResult:@"B5.1"
              title:@"把 0x85 原文当 0x86 回传，设备是否买账"
            verdict:verdict
             detail:detail
           evidence:evidence];
    self.markdown = [self buildReport];
}

#pragma mark - 报告

/// 报告永远即时重建，避免"复制到旧报告"（B5 之前就踩过这个坑）
- (NSString *)markdownReport {
    return [self buildReport];
}

- (NSString *)buildReport {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";

    NSMutableString *s = [NSMutableString string];
    [s appendString:@"### 自动验证报告（真机）\n\n"];
    [s appendFormat:@"- 时间：%@\n", [fmt stringFromDate:[NSDate date]]];
    [s appendFormat:@"- 设备：%@  %@\n",
     self.peripheral.name ?: @"(无名)",
     [self.peripheral formattedMacAddress] ?: @"(无 MAC)"];
    if (self.lastState) {
        [s appendFormat:@"- 状态帧：state=%@ deviceId=%@ random=%@ protocol=%@ mac=%@\n",
         self.lastState[@"state"], self.lastState[@"deviceId"], self.lastState[@"random"],
         self.lastState[@"protocol"], self.lastState[@"mac"]];
    }
    [s appendFormat:@"- 0x85 样本数：%lu\n\n", (unsigned long)self.collectSamples.count];

    [s appendString:@"| 项 | 结论 | 判定 | 证据 |\n|---|---|---|---|\n"];
    for (LEDVerifyResult *r in self.results) {
        NSString *ev = [r.evidence stringByReplacingOccurrencesOfString:@"\n" withString:@"<br>"];
        NSString *dt = [r.detail stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        if (dt.length > 240) dt = [[dt substringToIndex:240] stringByAppendingString:@"…"];
        if (ev.length > 400) ev = [[ev substringToIndex:400] stringByAppendingString:@"…"];
        [s appendFormat:@"| %@ %@ | %@ | %@ | %@ |\n", r.ident, r.title, dt, r.verdict,
         ev.length ? ev : @"-"];
    }

    [s appendString:@"\n#### 原始样本\n\n"];
    for (NSUInteger i = 0; i < self.collectSamples.count; i++) {
        [s appendFormat:@"- 0x85 #%lu payload：`%@`\n", (unsigned long)(i + 1),
         [KRWMCrypto hexFromData:self.collectSamples[i]]];
    }
    if (self.collectSamples.count == 0) [s appendString:@"- （无）\n"];

    return s;
}

@end
