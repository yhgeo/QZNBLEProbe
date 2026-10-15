//
//  MainViewController.m
//  热水器蓝牙 —— 主流程页
//
//  开阀：连接 → 读状态(0x23) → 查台账 → 下费率(HTTP) → 写费率包(0x21) → 计时
//  结算：关阀(0x22) → 断开重连 → 读状态 → 采集(0x85) → 上传(HTTP) → 解密 → 写回(0x86)
//
//  三条铁律（对齐官方客户端与 linyu）：
//    1. 费率包必须来自服务端，绝不自己造
//    2. randomNumber 必须用设备给的，不能本地生成
//    3. 关阀后没能正常结算的，必须上报失败订单
//

#import "MainViewController.h"
#import "KRWMClient.h"
#import "KRWMCrypto.h"
#import "ProbeViewController.h"
#import "WalletViewController.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <QZNOSDK/KRWaterMeterKit.h>

#pragma mark - 小工具

/// 服务端字段类型不稳（有时 NSString、有时 NSNumber），统一转字符串
static NSString *KRWMStringValue(id obj) {
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    if ([obj isKindOfClass:[NSNumber class]]) return [(NSNumber *)obj stringValue];
    return nil;
}

/// 从 clData 明文里取 `-` 之后那段（要写回设备的 0x86 数据）
static NSData *KRWMWriteBackBytes(NSString *clDataCipher) {
    NSString *plain = [KRWMCrypto decryptClData:clDataCipher];
    if (plain.length == 0) return nil;
    NSRange dash = [plain rangeOfString:@"-"];
    if (dash.location == NSNotFound) return nil;
    NSString *hex = [plain substringFromIndex:dash.location + 1];
    return hex.length ? [KRWMCrypto dataFromHex:hex] : nil;
}

#pragma mark - 设备状态帧（自行按偏移解析，不依赖 SDK 的解析器）

/// 设备状态帧（0x23 响应，实测 48 字节）
///
/// | 偏移 | 长度 | 字段 |
/// |---|---|---|
/// | 1  | 4 | productId |
/// | 5  | 4 | deviceId |
/// | 9  | 4 | accountId |
/// | 13 | 6 | 设备自报的 MAC / snCode |
/// | 19 | 1 | protocolType（2 位大写 hex） |
/// | 24 | 4 | randomNumber |
/// | 28 | 1 | state |
/// | 29 | 1 | devType（macType 第 1 字节） |
/// | 30 | 1 | a1（macType 第 2 字节） |
@interface KRWMDeviceState : NSObject
@property (nonatomic, assign) uint32_t productId;
@property (nonatomic, assign) uint32_t deviceId;
@property (nonatomic, assign) uint32_t accountId;
@property (nonatomic, copy)   NSString *macHex;        // 6 字节 hex（无分隔小写）
@property (nonatomic, copy)   NSString *protocolType;  // 2 位大写 hex，如 "20"
@property (nonatomic, copy)   NSString *randomNumber;  // 8 位 hex
@property (nonatomic, assign) uint8_t state;
@property (nonatomic, assign) uint8_t devType;
@property (nonatomic, assign) uint8_t a1;
@end

@implementation KRWMDeviceState
@end

static uint32_t KRWMReadU32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

/// 解析状态帧。SDK 给的可能是 payload，也可能是完整帧——自动识别。
static KRWMDeviceState *KRWMParseStatePayload(NSData *data) {
    if (data.length < 8) return nil;

    const uint8_t *bytes = data.bytes;
    NSUInteger offset = 0;
    if (bytes[0] == 0x60 && data.length >= 14) {
        offset = 6;   // 完整帧：跳过 60 len len ctrl cmd 00
    }
    if (data.length - offset < 31) return nil;

    const uint8_t *p = bytes + offset;
    KRWMDeviceState *st = [[KRWMDeviceState alloc] init];
    st.productId    = KRWMReadU32(p + 1);
    st.deviceId     = KRWMReadU32(p + 5);
    st.accountId    = KRWMReadU32(p + 9);
    st.macHex       = [KRWMCrypto hexFromData:[data subdataWithRange:NSMakeRange(offset + 13, 6)]];
    st.protocolType = [NSString stringWithFormat:@"%02X", p[19]];
    st.randomNumber = [KRWMCrypto hexFromData:[data subdataWithRange:NSMakeRange(offset + 24, 4)]];
    st.state        = p[28];
    st.devType      = p[29];
    st.a1           = p[30];
    return st;
}

#pragma mark -

@interface MainViewController ()

@property (nonatomic, strong) UILabel *deviceLabel;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UIButton *actionButton;
/// 未连接时显示的「重连上次设备」快捷入口
@property (nonatomic, strong) UIButton *lastDeviceButton;

/// 上次成功连接过的设备（本地记住，省去每次重新扫描挑选）
@property (nonatomic, copy)   NSString *lastDeviceName;
@property (nonatomic, copy)   NSString *lastDeviceIdentifier;
@property (nonatomic, copy)   NSString *lastDeviceMac;
/// 正在「重连上次设备」——扫描时匹配到目标就自动连，不再弹列表
@property (nonatomic, assign) BOOL reconnectingLast;

@property (nonatomic, strong) NSMutableString *log;
@property (nonatomic, strong) NSMutableArray<CBPeripheral *> *found;
@property (nonatomic, strong) CBPeripheral *connected;
/// disconnectHandler 会把 connected 置空，而关阀后还要重连，所以单独留一份
@property (nonatomic, strong) CBPeripheral *lastPeripheral;
@property (nonatomic, assign) BOOL scanning;
@property (nonatomic, assign) BOOL busy;

// 会话
@property (nonatomic, strong) KRWMDeviceState *deviceState;
@property (nonatomic, copy)   NSString *ledgerMac;      // 台账 MAC（无分隔大写）
@property (nonatomic, copy)   NSString *deviceId;       // 服务端 deviceId
@property (nonatomic, copy)   NSString *bigTypeId;
@property (nonatomic, copy)   NSString *smallTypeId;
@property (nonatomic, copy)   NSString *consumeDate;    // 开阀时存下，失败上报要用
@property (nonatomic, copy)   NSString *rateText;
@property (nonatomic, strong) NSData *xfPayload;        // 采集到的消费原始数据
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) NSTimeInterval startedAt;
/// 本轮开阀已尝试补结算的次数，防止「补结算 → 仍非空闲 → 再补结算」死循环
@property (nonatomic, assign) NSInteger settleAttempts;

/// 自动采样（tac）：循环执行「开阀→关水→结算」完整真实交易，积累（记录, tac）样本对。
/// 每一轮都走正规流程并真实计费，不构造、不修改任何协议数据。
@property (nonatomic, assign) BOOL autoSampleActive;      // 采样进行中
@property (nonatomic, assign) NSInteger autoSampleTotal;   // 总轮数
@property (nonatomic, assign) NSInteger autoSampleDone;    // 已完成轮数
@property (nonatomic, assign) NSUInteger autoSampleGeneration; // 递增以作废已排程的自动关水
/// 自动采样期间连续连接失败的次数（连接成功即清零，超限才中止采样）
@property (nonatomic, assign) NSInteger autoReconnectTries;

/// 关阀后重连成功时要接着跑的动作
@property (nonatomic, copy) void (^pendingReconnectBlock)(void);

@end

@implementation MainViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"热水";
    self.log = [NSMutableString string];
    self.found = [NSMutableArray array];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    [self setupUI];
    [self setupSDK];

    NSString *phone = [KRWMClient shared].telephone;
    NSString *masked = phone.length == 11
        ? [phone stringByReplacingCharactersInRange:NSMakeRange(3, 4) withString:@"****"]
        : phone;
    // 左上角「设置」收纳探针与退出登录；右上角常驻「钱包」
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"设置" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(onSettings)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"钱包" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(onWallet)];
    self.navigationItem.prompt = [NSString stringWithFormat:@"已登录 %@", masked];

    [self restoreLastDevice];
    [self refreshActionButton];

    [self log:@"① 点「扫描」→ ② 再点「扫描」结束并选设备 → ③ 点「开始用水」"];
    [self log:@"用完后点「停止用水」，会自动结算。"];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // KRWMCore 是单例，探针页会覆盖它的连接回调；
    // 回到本页必须重新装回自己的，否则「蓝牙已连上但界面没反应」
    [self setupSDK];
    [self refreshActionButton];
}

- (void)dealloc {
    [self.timer invalidate];
}

- (void)setupUI {
    self.deviceLabel = [[UILabel alloc] init];
    self.deviceLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.deviceLabel.numberOfLines = 0;
    self.deviceLabel.text = @"未连接设备";
    self.deviceLabel.textColor = [UIColor secondaryLabelColor];

    self.infoLabel = [[UILabel alloc] init];
    self.infoLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.infoLabel.numberOfLines = 0;
    self.infoLabel.textColor = [UIColor labelColor];
    self.infoLabel.text = @"—";

    self.scanButton = [self makeButton:@"扫描" action:@selector(onScan)];
    self.actionButton = [self makeButton:@"开始用水" action:@selector(onAction)];
    self.actionButton.enabled = NO;

    // 「重连上次设备」——链接样式，未连接且有历史记录时才出现
    self.lastDeviceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.lastDeviceButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.lastDeviceButton.titleLabel.font = [UIFont systemFontOfSize:14];
    self.lastDeviceButton.hidden = YES;
    [self.lastDeviceButton addTarget:self action:@selector(onReconnectLast)
                    forControlEvents:UIControlEventTouchUpInside];

    self.logView = [[UITextView alloc] init];
    self.logView.editable = NO;
    self.logView.selectable = YES;
    self.logView.alwaysBounceVertical = YES;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.layer.cornerRadius = 8;
    self.logView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.scanButton, self.actionButton]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 10;

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.deviceLabel, self.infoLabel, self.lastDeviceButton
    ]];
    header.axis = UILayoutConstraintAxisVertical;
    header.spacing = 6;
    header.alignment = UIStackViewAlignmentFill;

    for (UIView *v in @[header, buttons, self.logView]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:v];
    }

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [header.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [header.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [buttons.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:12],
        [buttons.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [buttons.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [buttons.heightAnchor constraintEqualToConstant:48],

        [self.logView.topAnchor constraintEqualToAnchor:buttons.bottomAnchor constant:12],
        [self.logView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.logView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
    ]];
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.layer.cornerRadius = 10;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - SDK

- (void)setupSDK {
    KRWMCore *core = [KRWMCore sharedCore];
    core.startLog = NO;             // 正式使用关掉 SDK 日志，避免刷屏
    core.timeOutInterval = 8.0;
    core.scanFilterName = nil;

    __weak typeof(self) ws = self;

    core.connectionSuccessfulHandler = ^(CBPeripheral *p) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ws.connected = p;
            ws.lastPeripheral = p;
            ws.reconnectingLast = NO;
            ws.autoReconnectTries = 0;   // 连上了就清零失败计数
            [ws rememberDevice:p];
            [ws updateDeviceLabel];
            // 连接成功后必须刷新主按钮，否则「开始用水」会一直停在禁用状态
            [ws refreshActionButton];
            [ws log:[NSString stringWithFormat:@"✅ 已连接 %@  %@",
                     p.name ?: @"(无名)", [p formattedMacAddress] ?: @"?"]];

            // 关阀后重连：接着跑结算
            void (^next)(void) = ws.pendingReconnectBlock;
            ws.pendingReconnectBlock = nil;
            if (next) next();
        });
    };

    core.connectionFailHandler = ^(CBPeripheral *p) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws log:[NSString stringWithFormat:@"❌ 连接失败：%@", p.name ?: @"(无名)"]];
            // 自动采样模式不轻易放弃：2 秒后自动重连，连续失败 3 次才中止
            if (ws.autoSampleActive && ws.lastPeripheral != nil) {
                ws.autoReconnectTries += 1;
                if (ws.autoReconnectTries > 3) {
                    [ws log:@"🧪 连续连接失败，自动采样中止"];
                    ws.autoSampleActive = NO;
                    ws.busy = NO;
                    [ws refreshActionButton];
                    return;
                }
                [ws log:[NSString stringWithFormat:@"🧪 自动重连（第 %ld 次）…",
                         (long)ws.autoReconnectTries]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (!ws.autoSampleActive || ws.connected != nil) return;
                    [[KRWMCore sharedCore] connectPeripheral:ws.lastPeripheral];
                });
                return;   // 保持 busy，等连接结果
            }
            ws.busy = NO;
            [ws refreshActionButton];
        });
    };

    core.disconnectHandler = ^(CBPeripheral *p) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ws.connected = nil;
            [ws updateDeviceLabel];
            [ws refreshActionButton];
            [ws log:@"⚠️ 连接已断开"];
        });
    };
}

#pragma mark - 上次设备

static NSString * const kPrefLastDeviceName = @"qzn.lastDevice.name";
static NSString * const kPrefLastDeviceId   = @"qzn.lastDevice.identifier";
static NSString * const kPrefLastDeviceMac  = @"qzn.lastDevice.mac";

- (void)rememberDevice:(CBPeripheral *)p {
    self.lastDeviceName = p.name.length ? p.name : @"(无名)";
    self.lastDeviceIdentifier = p.identifier.UUIDString;
    self.lastDeviceMac = [p formattedMacAddress] ?: @"";

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:self.lastDeviceName forKey:kPrefLastDeviceName];
    [d setObject:self.lastDeviceIdentifier forKey:kPrefLastDeviceId];
    [d setObject:self.lastDeviceMac forKey:kPrefLastDeviceMac];
    [d synchronize];
}

- (void)restoreLastDevice {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    self.lastDeviceName = [d stringForKey:kPrefLastDeviceName];
    self.lastDeviceIdentifier = [d stringForKey:kPrefLastDeviceId];
    self.lastDeviceMac = [d stringForKey:kPrefLastDeviceMac];
}

/// 「重连上次设备」入口的标题与可见性
- (void)refreshLastDeviceButton {
    BOOL show = (self.connected == nil) && (self.lastDeviceName.length > 0);
    self.lastDeviceButton.hidden = !show;
    if (show) {
        [self.lastDeviceButton setTitle:[NSString stringWithFormat:@"🔄 重连上次：%@", self.lastDeviceName]
                               forState:UIControlStateNormal];
    }
}

/// 快捷重连：扫描并匹配上次那台设备，扫到就直接连
- (void)onReconnectLast {
    if (self.busy) { [self log:@"⚠️ 正在处理中，请稍候"]; return; }
    if (self.lastDeviceIdentifier.length == 0) { [self log:@"⚠️ 没有可重连的历史设备"]; return; }

    [self log:[NSString stringWithFormat:@"正在寻找上次的设备「%@」…", self.lastDeviceName]];
    self.reconnectingLast = YES;
    [self startScan];
}

#pragma mark - 扫描 / 连接

- (void)onScan {
    if (self.busy) { [self log:@"⚠️ 正在处理中，请稍候"]; return; }
    self.reconnectingLast = NO;      // 手动扫描＝要重新挑设备

    if (self.scanning) {
        [[KRWMCore sharedCore] stopScan];
        self.scanning = NO;
        [self.scanButton setTitle:@"扫描" forState:UIControlStateNormal];
        [self log:[NSString stringWithFormat:@"扫描结束，共发现 %lu 个设备", (unsigned long)self.found.count]];
        [self pickDevice];
        return;
    }
    [self startScan];
}

- (void)startScan {
    KRWMCore *core = [KRWMCore sharedCore];

    [self.found removeAllObjects];
    [self log:@""];
    [self log:@"开始扫描…"];
    self.scanning = YES;
    [self.scanButton setTitle:@"停止" forState:UIControlStateNormal];

    __weak typeof(self) ws = self;
    [core scanForPeripherals:nil retHandler:^(NSArray<CBPeripheral *> *retArray, CBPeripheral *aPeripheral) {
        if (aPeripheral == nil) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([ws.found containsObject:aPeripheral]) return;
            [ws.found addObject:aPeripheral];
            [ws log:[NSString stringWithFormat:@"  [%2lu] %-18@ %@",
                     (unsigned long)ws.found.count,
                     aPeripheral.name ?: @"(无名)",
                     [aPeripheral formattedMacAddress] ?: @""]];

            // 快捷重连模式：扫到目标设备立刻连，不用等用户操作
            if (ws.reconnectingLast &&
                [aPeripheral.identifier.UUIDString isEqualToString:ws.lastDeviceIdentifier]) {
                [core stopScan];
                ws.scanning = NO;
                [ws.scanButton setTitle:@"扫描" forState:UIControlStateNormal];
                [ws log:@"找到上次的设备，正在连接…"];
                [core connectPeripheral:aPeripheral];
            }
        });
    }];
}

- (void)pickDevice {
    if (self.found.count == 0) {
        [self log:@"未发现设备。请确认蓝牙已打开、靠近设备、且设备未被占用。"];
        return;
    }

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"选择热水设备"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    for (CBPeripheral *p in self.found) {
        NSString *title = [NSString stringWithFormat:@"%@  %@", p.name ?: @"(无名)", [p formattedMacAddress] ?: @""];
        [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [ws log:[NSString stringWithFormat:@"正在连接 %@…", p.name ?: @"(无名)"]];
            if (![[KRWMCore sharedCore] connectPeripheral:p]) {
                [ws log:@"⚠️ 连接请求未被接受，请重试"];
                return;
            }
            [ws scheduleConnectTimeout];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:ac animated:YES completion:nil];
}

/// 连接回调迟迟不来时的兜底：若 SDK 自认已连接，就按实际状态恢复界面
- (void)scheduleConnectTimeout {
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (ws.connected != nil) return;

        KRWMCore *core = [KRWMCore sharedCore];
        if ([core isConnected] && core.peripheral != nil) {
            [ws log:@"⚠️ 连接回调未触发，已按实际连接状态恢复"];
            CBPeripheral *p = core.peripheral;
            ws.connected = p;
            ws.lastPeripheral = p;
            ws.reconnectingLast = NO;
            [ws rememberDevice:p];
            [ws updateDeviceLabel];
            [ws refreshActionButton];
            return;
        }
        [ws log:@"⚠️ 连接超时，请重试"];
        ws.busy = NO;
        [ws refreshActionButton];
    });
}

- (void)updateDeviceLabel {
    if (self.connected) {
        self.deviceLabel.text = [NSString stringWithFormat:@"已连接：%@  %@",
                                 self.connected.name ?: @"(无名)",
                                 [self.connected formattedMacAddress] ?: @""];
        self.deviceLabel.textColor = [UIColor systemGreenColor];
    } else {
        self.deviceLabel.text = @"未连接设备";
        self.deviceLabel.textColor = [UIColor secondaryLabelColor];
    }
}

- (void)refreshActionButton {
    BOOL canAct = (self.connected != nil) && !self.busy;
    self.actionButton.enabled = canAct;

    NSString *title;
    UIColor *color;
    if (self.startedAt > 0) {
        title = self.autoSampleActive ? @"结束本轮（采样继续）" : @"停止用水";
        color = [UIColor systemRedColor];
    } else if (self.autoSampleActive) {
        title = @"采样中…";
        color = [UIColor systemGrayColor];
    } else {
        title = @"开始用水";
        color = [UIColor systemBlueColor];
    }

    // 禁用态必须显式置灰：UIButton 的 backgroundColor 不会随 enabled 自动变
    self.actionButton.backgroundColor = canAct ? color : [UIColor systemGrayColor];
    [self.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.actionButton setTitle:title forState:UIControlStateNormal];

    self.scanButton.enabled = !self.busy;
    [self refreshLastDeviceButton];
}

#pragma mark - 主操作

- (void)onAction {
    if (self.busy) { [self log:@"⚠️ 正在处理中，请稍候"]; return; }
    if (!self.connected) { [self log:@"⚠️ 请先扫描并连接设备"]; return; }

    if (self.startedAt > 0) {
        [self confirmStop];
    } else {
        [self startWater];
    }
}

#pragma mark - 开阀

- (void)startWater {
    self.settleAttempts = 0;      // 用户手动发起，重置补结算计数
    [self log:@""];
    [self log:@"========== 开始用水 =========="];
    [self beginOpenFlow];
}

/// 开阀流程主体。与 startWater 分开，是为了让「补结算后自动续跑」复用它而不重置计数
- (void)beginOpenFlow {
    self.busy = YES;
    [self refreshActionButton];
    [self readStateAttempt:1];
}

/// 读设备状态。刚重连上来时设备常常还没准备好，首次无响应属常见——自动退避重试；
/// 若重试期间连接掉了，先重连再试，而不是对着空气盲读
- (void)readStateAttempt:(NSInteger)attempt {
    self.deviceState = nil;
    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krGetStateOfDevice:^(KRSyncType t, NSData *d, NSString *orig) {
        dispatch_async(dispatch_get_main_queue(), ^{ ws.deviceState = KRWMParseStatePayload(d); });
    } result:^(KRSyncType t, KRSyncResponseState s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (s != KRSyncResponseStateSuccess || ws.deviceState == nil) {
                if (attempt < 4) {
                    [ws log:[NSString stringWithFormat:@"第 %ld 次读取状态无响应，稍后重试…", (long)attempt]];
                    if (ws.connected == nil) {
                        [ws log:@"连接已断开，重连后继续…"];
                        [ws reconnectThenRun:^{ [ws readStateAttempt:attempt + 1]; }];
                        return;
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(0.8 * attempt * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        [ws readStateAttempt:attempt + 1];
                    });
                    return;
                }
                [ws fail:@"读取设备状态失败，请靠近设备重试"];
                return;
            }
            [ws onStateRead];
        });
    }];
}

- (void)onStateRead {
    KRWMDeviceState *st = self.deviceState;
    [self log:[NSString stringWithFormat:@"设备状态：state=%u devType=%u a1=%u protocol=%@ random=%@",
               st.state, st.devType, st.a1, st.protocolType, st.randomNumber]];

    if (st.state != 0) {
        if (st.state == 3 || st.state == 6) {
            // 有遗留未结算记录：先补结算，清掉后设备才能开阀
            self.settleAttempts += 1;
            if (self.settleAttempts > 1) {
                [self fail:@"设备仍有未结算的遗留记录，请稍后重试"];
                return;
            }
            [self log:@"设备有未结算的遗留记录，先自动结清…"];
            [self settlePendingWithState:st];
            return;
        }
        [self fail:[NSString stringWithFormat:@"设备当前不可用（state=%u），可能正在被使用", st.state]];
        return;
    }

    [self lookupDeviceInfo];
}

- (void)lookupDeviceInfo {
    // 优先用设备状态帧里自报的 MAC（iOS 拿不到链路地址，官方客户端也走这条路）
    NSString *mac = self.deviceState.macHex;
    if (mac.length != 12) {
        mac = [[self.connected formattedMacAddress] stringByReplacingOccurrencesOfString:@":" withString:@""];
    }
    if (mac.length != 12) {
        [self fail:@"拿不到设备 MAC，无法查询台账"];
        return;
    }

    [self log:[NSString stringWithFormat:@"查询设备台账：%@", mac]];
    __weak typeof(self) ws = self;
    [[KRWMClient shared] deviceInfoForMac:mac completion:^(BOOL ok, NSDictionary *data, NSString *message) {
        if (!ok || data == nil) { [ws fail:message]; return; }

        ws.deviceId    = KRWMStringValue(data[@"deviceId"]);
        ws.bigTypeId   = KRWMStringValue(data[@"bigTypeId"]);
        ws.smallTypeId = KRWMStringValue(data[@"smallTypeId"]);
        NSString *ledger = [[KRWMStringValue(data[@"macAddress"]) ?: @"" stringByReplacingOccurrencesOfString:@":" withString:@""] uppercaseString];
        ws.ledgerMac = (ledger.length == 12) ? ledger : [mac uppercaseString];

        [ws log:[NSString stringWithFormat:@"台账：deviceId=%@ bigType=%@ smallType=%@",
                 ws.deviceId, ws.bigTypeId, ws.smallTypeId]];
        [ws requestRate];
    }];
}

- (void)requestRate {
    KRWMDeviceState *st = self.deviceState;
    // macType = devType 与 a1 两个字节的十六进制拼接
    NSString *macType = [NSString stringWithFormat:@"%02x%02x", st.devType, st.a1];

    [self log:@"向服务端请求费率包…"];
    __weak typeof(self) ws = self;
    [[KRWMClient shared] requestRateOrderWithDeviceId:self.deviceId
                                           macAddress:self.ledgerMac
                                              macType:macType
                                            bigTypeId:self.bigTypeId
                                          smallTypeId:self.smallTypeId
                                         protocolType:st.protocolType
                                         randomNumber:st.randomNumber
                                           completion:^(BOOL ok, NSDictionary *data, NSString *message) {
        if (!ok || data == nil) { [ws fail:message]; return; }

        NSString *downData = KRWMStringValue(data[@"downData"]);
        ws.consumeDate = KRWMStringValue(data[@"consumeDate"]);
        ws.rateText = [NSString stringWithFormat:@"费率 %@ ／ 预扣 %@ 元",
                       KRWMStringValue(data[@"rate"]) ?: @"?",
                       KRWMStringValue(data[@"preDeductMoney"]) ?: @"?"];
        [ws log:[NSString stringWithFormat:@"费率包已下发（%@），写入设备…", ws.rateText]];

        NSData *downBytes = [KRWMCrypto dataFromHex:downData];
        if (downBytes.length == 0) { [ws fail:@"服务端费率数据无效，已停止启动"]; return; }
        [ws writeRatePacket:downBytes];
    }];
}

- (void)writeRatePacket:(NSData *)downBytes {
    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krPublicSendData:downBytes funCode:0x21
        dataCallback:^(KRSyncType t, NSData *d, NSString *orig) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [ws log:[NSString stringWithFormat:@"费率包响应：%@", [KRWMCrypto hexFromData:d]]];
            });
        } result:^(KRSyncType t, KRSyncResponseState s) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (s == KRSyncResponseStateSuccess) {
                    [ws log:@"✅ 设备已开启，开始计时"];
                    ws.busy = NO;
                    ws.startedAt = [NSDate date].timeIntervalSince1970;
                    [ws startTimer];
                    [ws refreshActionButton];
                    // 自动采样模式：本轮开阀后定时自动关水
                    if (ws.autoSampleActive) { [ws scheduleAutoStop]; }
                } else {
                    // 命令发出去了但没确认——不能当失败，费率包可能已经写进去了
                    [ws fail:@"未能确认设备已开启，请确认水流状态后再决定是否重试"];
                }
            });
        }];
}

#pragma mark - 结算

- (void)confirmStop {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"停止用水"
                                                               message:@"将关闭阀门并自动结算本次消费。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"停止" style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *a) { [ws stopWater]; }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)stopWater {
    self.busy = YES;
    [self refreshActionButton];
    [self.timer invalidate];
    self.timer = nil;
    [self log:@""];
    [self log:@"========== 停止用水 =========="];

    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krPublicSendData:[NSData data] funCode:0x22
        dataCallback:^(KRSyncType t, NSData *d, NSString *orig) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [ws log:[NSString stringWithFormat:@"关阀响应：%@", [KRWMCrypto hexFromData:d]]];
            });
        } result:^(KRSyncType t, KRSyncResponseState s) {
            dispatch_async(dispatch_get_main_queue(), ^{
                ws.startedAt = 0;
                [ws refreshActionButton];
                if (s != KRSyncResponseStateSuccess) {
                    [ws log:@"⚠️ 关阀未确认，仍继续尝试结算"];
                }
                [ws settleAfterClose];
            });
        }];
}

/// 关阀后必须**断开重连**再采集：同一连接里「关阀后立刻采集」的数据会被服务端判
/// 226「加密校验失败」（linyu 2026-09-30 实测），重连后采集才能被接受。
- (void)settleAfterClose {
    [self log:@"关阀后重新连接，读取消费数据…"];
    __weak typeof(self) ws = self;
    [self reconnectThenRun:^{
        // 重连后先刷新一次状态：设备在开阀成功时会更新 randomNumber，
        // 拿开阀前的旧随机数上传会被服务端判 226（2026-10-16 实测）
        [ws readStateThenRun:1 block:^{ [ws collectConsumption]; }];
    }];
}

/// 读一次设备状态后回调（带重连与退避重试）。只刷新 deviceState，不走开阀分派。
/// 读不到时也继续（老流程不刷新也能成功），不让结算卡死在这里。
- (void)readStateThenRun:(NSInteger)attempt block:(void (^)(void))block {
    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krGetStateOfDevice:^(KRSyncType t, NSData *d, NSString *orig) {
        dispatch_async(dispatch_get_main_queue(), ^{
            KRWMDeviceState *st = KRWMParseStatePayload(d);
            if (st) {
                ws.deviceState = st;
                [ws log:[NSString stringWithFormat:@"设备状态：state=%u random=%@（结算前已刷新）",
                         st.state, st.randomNumber]];
            }
        });
    } result:^(KRSyncType t, KRSyncResponseState s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (s != KRSyncResponseStateSuccess) {
                if (attempt < 3) {
                    [ws log:[NSString stringWithFormat:@"第 %ld 次刷新状态无响应，稍后重试…", (long)attempt]];
                    if (ws.connected == nil) {
                        [ws reconnectThenRun:^{ [ws readStateThenRun:attempt + 1 block:block]; }];
                        return;
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(0.8 * attempt * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        [ws readStateThenRun:attempt + 1 block:block];
                    });
                    return;
                }
                [ws log:@"⚠️ 刷新状态失败，按原会话参数继续"];
            }
            block();
        });
    }];
}

- (void)reconnectThenRun:(void (^)(void))block {
    CBPeripheral *target = self.lastPeripheral;
    if (target == nil) {
        [self finishWithMessage:@"设备已关闭，但重连失败，下次连接会自动结清"];
        return;
    }
    self.pendingReconnectBlock = block;
    [[KRWMCore sharedCore] disconnect];

    // BLE 栈偶尔还没处理完上一次断开，稍等再连
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[KRWMCore sharedCore] connectPeripheral:target];
    });
}

- (void)collectConsumption {
    [self collectConsumptionAttempt:1];
}

/// 设备刚关阀时消费数据可能还没落盘，首次采集为空属正常——稍等重试一次。
/// ⚠️ 每次采集前必须清空 xfPayload：它只在结算收尾时清，
/// 补结算等路径会留下旧记录——不清的话采集一旦无响应，旧数据会被当新数据上传，
/// 实测导致同一笔记录重复记账（2026-10-16 蓝牙(5).txt 第 22/43 行逐字节相同）。
- (void)collectConsumptionAttempt:(NSInteger)attempt {
    self.xfPayload = nil;
    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krGetConsumptionDetails:^(KRSyncType t, NSData *d, NSString *orig) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (d.length > 0) { ws.xfPayload = d; }
        });
    } result:^(KRSyncType t, KRSyncResponseState s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ws.xfPayload.length == 0) {
                if (attempt < 4) {
                    [ws log:[NSString stringWithFormat:@"第 %ld 次未读到消费数据，稍后重试…", (long)attempt]];
                    if (ws.connected == nil) {
                        [ws log:@"连接已断开，重连后继续…"];
                        [ws reconnectThenRun:^{ [ws collectConsumptionAttempt:attempt + 1]; }];
                        return;
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        [ws collectConsumptionAttempt:attempt + 1];
                    });
                    return;
                }
                [ws log:@"⚠️ 未采集到消费数据"];
                [ws reportFailAndFinish:@"未采集到消费数据"];
                return;
            }
            [ws upload];
        });
    }];
}

- (void)upload {
    [self uploadAttempt:1];
}

/// 上传消费数据。失败时先刷新 randomNumber 再重试一次（226 多为会话参数过期），
/// 仍失败才走失败上报——订单必须收口，否则预扣一直挂着
- (void)uploadAttempt:(NSInteger)attempt {
    // xfData 必须小写（KRWMClient 内部还会再兜一次）
    NSString *xfData = [[KRWMCrypto hexFromData:self.xfPayload] lowercaseString];
    KRWMDeviceState *st = self.deviceState;
    [self log:[NSString stringWithFormat:@"上传消费数据（%lu 字节）…", (unsigned long)self.xfPayload.length]];
    // 完整帧入日志：正常用水即积累（记录, tac）样本对，供本地离线分析 tac 结构
    [self log:[NSString stringWithFormat:@"xfData=%@", xfData]];

    __weak typeof(self) ws = self;
    [[KRWMClient shared] uploadXfData:xfData
                         protocolType:st.protocolType ?: @""
                         randomNumber:st.randomNumber ?: @""
                           completion:^(BOOL ok, NSDictionary *data, NSString *message) {
        if (!ok || data == nil) {
            if (attempt < 2) {
                [ws log:[NSString stringWithFormat:@"⚠️ 上传失败（%@），刷新状态后重试一次…", message]];
                [ws readStateThenRun:1 block:^{ [ws uploadAttempt:attempt + 1]; }];
                return;
            }
            [ws log:[NSString stringWithFormat:@"⚠️ 上传失败：%@", message]];
            [ws reportFailAndFinish:message];
            return;
        }

        NSString *money = KRWMStringValue(data[@"consumeMoney"]) ?: @"?";
        // 服务端此字段单位是厘（26 = 0.026 元）；带小数点的按已是元处理
        NSString *shown = [money containsString:@"."]
            ? money
            : [NSString stringWithFormat:@"%.3f", money.doubleValue / 1000.0];
        [ws log:[NSString stringWithFormat:@"✅ 服务端已记账，本次消费 %@ 元", shown]];

        NSData *backBytes = KRWMWriteBackBytes(KRWMStringValue(data[@"clData"]));
        if (backBytes.length == 0) {
            [ws finishWithMessage:@"结算完成（设备记录未清，下次连接会自动结清）"];
            return;
        }
        [ws writeBack:backBytes];
    }];
}

- (void)writeBack:(NSData *)backBytes {
    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krClearConsumptionDetails:backBytes
        dataCallback:^(KRSyncType t, NSData *d, NSString *orig) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [ws log:[NSString stringWithFormat:@"写回响应：%@", [KRWMCrypto hexFromData:d]]];
            });
        }         result:^(KRSyncType t, KRSyncResponseState s) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // 只有「写回被确认」才算完整成功，才允许自动采样继续下一轮；
                // 若记录未清，下一轮读状态会走补结算分支兜底，但采样在这里先停，
                // 避免在设备状态异常时继续打交易
                [ws finishWithMessage:(s == KRSyncResponseStateSuccess
                                       ? @"✅ 结算完成，设备已恢复空闲"
                                       : @"结算完成（设备记录未清，下次连接会自动结清）")
                         autoContinue:(s == KRSyncResponseStateSuccess)];
            });
        }];
}

/// 遗留数据补结算（设备 state=3/6）
- (void)settlePendingWithState:(KRWMDeviceState *)st {
    self.xfPayload = nil;   // 防残留（见 collectConsumptionAttempt 注释）
    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krGetConsumptionDetails:^(KRSyncType t, NSData *d, NSString *orig) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (d.length > 0) { ws.xfPayload = d; }
        });
    } result:^(KRSyncType t, KRSyncResponseState s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ws.xfPayload.length == 0) {
                [ws fail:@"未能读取遗留消费数据"];
                return;
            }
            NSString *xfData = [[KRWMCrypto hexFromData:ws.xfPayload] lowercaseString];
            [ws log:[NSString stringWithFormat:@"xfData=%@", xfData]];   // 样本积累，见 upload 处注释
            [[KRWMClient shared] uploadXfData:xfData
                                 protocolType:st.protocolType ?: @""
                                 randomNumber:st.randomNumber ?: @""
                                   completion:^(BOOL ok, NSDictionary *data, NSString *message) {
                if (!ok || data == nil) {
                    [ws fail:[NSString stringWithFormat:@"补结算上传失败：%@", message]];
                    return;
                }

                void (^after)(void) = ^{
                    [ws log:@"✅ 遗留账单已结清"];
                    // 补结算后需要一次全新连接，设备才会给出可用的会话参数；
                    // 重连成功后自动接着开阀，用户不必再点一次
                    [ws reconnectThenRun:^{
                        [ws log:@"已重新连接，自动继续开阀…"];
                        [ws beginOpenFlow];
                    }];
                };

                NSData *backBytes = KRWMWriteBackBytes(KRWMStringValue(data[@"clData"]));
                if (backBytes.length == 0) {
                    [ws log:@"⚠️ 服务端未返回写回数据，遗留记录可能未清"];
                    after();
                    return;
                }
                [[KRWMCore sharedCore] krClearConsumptionDetails:backBytes
                    dataCallback:^(KRSyncType t, NSData *d, NSString *orig) {}
                    result:^(KRSyncType t, KRSyncResponseState s) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            // 写回结果要如实记录：8101 只代表命令被确认，不代表记录已清
                            [ws log:(s == KRSyncResponseStateSuccess
                                     ? @"✅ 遗留账单已结清"
                                     : @"⚠️ 遗留记录写回未确认（若未清，下轮会再次补结算）")];
                            after();
                        });
                    }];
            }];
        });
    }];
}

#pragma mark - 失败上报

- (void)reportFailAndFinish:(NSString *)reason {
    if (self.consumeDate.length == 0) {
        [self finishWithMessage:[NSString stringWithFormat:@"结算未完成：%@", reason]];
        return;
    }
    __weak typeof(self) ws = self;
    [[KRWMClient shared] reportFailWithConsumeDate:self.consumeDate completion:^(BOOL ok, NSDictionary *data, NSString *message) {
        [ws finishWithMessage:[NSString stringWithFormat:@"结算未完成：%@（已上报服务端）", reason]];
    }];
}

#pragma mark - 计时

- (void)startTimer {
    [self.timer invalidate];
    __weak typeof(self) ws = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        [ws updateInfoLabel];
    }];
    [self updateInfoLabel];
}

- (void)updateInfoLabel {
    NSString *progress = @"";
    if (self.autoSampleActive) {
        progress = [NSString stringWithFormat:@"🧪 采样 %ld/%ld 轮\n",
                    (long)self.autoSampleDone, (long)self.autoSampleTotal];
    }
    if (self.startedAt <= 0) {
        self.infoLabel.text = [progress stringByAppendingString:
                               (self.rateText.length ? self.rateText : @"—")];
        return;
    }
    NSTimeInterval elapsed = [NSDate date].timeIntervalSince1970 - self.startedAt;
    int minutes = (int)(elapsed / 60);
    int seconds = (int)elapsed % 60;
    self.infoLabel.text = [NSString stringWithFormat:@"%@用水 %02d:%02d\n%@",
                           progress, minutes, seconds, self.rateText ?: @""];
}

#pragma mark - 收尾

- (void)fail:(NSString *)message {
    self.busy = NO;
    self.startedAt = 0;
    [self.timer invalidate];
    self.timer = nil;
    // 任何失败都终止自动采样：宁可少采，不在异常状态下继续打交易
    if (self.autoSampleActive) {
        self.autoSampleActive = NO;
        [self log:@"🧪 自动采样已中止（流程出错）"];
    }
    [self log:[NSString stringWithFormat:@"❌ %@", message]];
    [self refreshActionButton];
    [self updateInfoLabel];
}

- (void)finishWithMessage:(NSString *)message {
    [self finishWithMessage:message autoContinue:NO];
}

/// cont=YES 表示本轮完整成功，允许自动采样继续下一轮
- (void)finishWithMessage:(NSString *)message autoContinue:(BOOL)cont {
    self.busy = NO;
    self.startedAt = 0;
    [self.timer invalidate];
    self.timer = nil;
    self.xfPayload = nil;
    self.consumeDate = nil;
    [self log:message];
    [self refreshActionButton];
    [self updateInfoLabel];

    if (self.autoSampleActive) {
        if (cont) {
            self.autoSampleDone += 1;
            if (self.autoSampleDone >= self.autoSampleTotal) {
                self.autoSampleActive = NO;
                [self log:[NSString stringWithFormat:@"🧪 自动采样完成：共 %ld 轮样本（日志里搜 xfData=）",
                           (long)self.autoSampleTotal]];
            } else {
                [self log:[NSString stringWithFormat:@"🧪 第 %ld/%ld 轮完成，冷却 5 秒后继续…",
                           (long)self.autoSampleDone, (long)self.autoSampleTotal]];
                __weak typeof(self) ws = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (!ws.autoSampleActive) return;
                    [ws startWater];
                });
                return;   // 采样期间保持连接，不释放设备
            }
        } else {
            self.autoSampleActive = NO;
            [self log:@"🧪 自动采样已中止（本轮未完整成功）"];
        }
    }

    // 结算完主动断开：这是公共设备，用完要让给别人连
    if (self.connected) {
        [self log:@"已断开连接，把设备让给其他人使用。"];
        [[KRWMCore sharedCore] disconnect];
    }
}

#pragma mark - 自动采样（tac 样本）

/// 循环执行「开阀→关水→结算」完整真实交易。
/// 边界：每轮都是服务端下单、真实计费、真实出水，只加速"正常使用"的频率，
/// 不构造/修改任何协议数据。开阀时长随机化是为了让记录字段尽量多样——
/// 全是几秒的快开快关，记录几乎相同，离线分析拿不到独立方程。
- (void)onAutoSample {
    if (self.busy) { [self log:@"⚠️ 正在处理中，请稍候"]; return; }
    if (!self.connected) { [self log:@"⚠️ 请先扫描并连接设备"]; return; }
    if (self.startedAt > 0) { [self log:@"⚠️ 请先结束当前用水"]; return; }

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"自动采样"
        message:@"循环执行「开阀→关水→结算」，每轮都是一笔真实计费的完整交易"
                "（开阀时长随机 5-30 秒，约 0.1-0.5 元/轮）。\n\n"
                "建议在没人用水的时段进行；轮数越大越容易被服务端风控注意，请自行权衡。"
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"轮数（1-30）";
        tf.text = @"10";
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"开始" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            NSInteger n = [ac.textFields.firstObject.text integerValue];
            if (n < 1) n = 1;
            if (n > 30) n = 30;
            [ws beginAutoSample:n];
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)beginAutoSample:(NSInteger)n {
    self.autoSampleActive = YES;
    self.autoSampleTotal = n;
    self.autoSampleDone = 0;
    self.autoSampleGeneration += 1;
    [self log:@""];
    [self log:[NSString stringWithFormat:@"🧪 自动采样开始：共 %ld 轮（中途可在「设置」里中止）", (long)n]];
    [self startWater];
}

- (void)cancelAutoSample {
    if (!self.autoSampleActive) return;
    self.autoSampleActive = NO;
    self.autoSampleGeneration += 1;   // 作废已排程的自动关水
    [self log:@"⏹ 自动采样：不再继续后续轮次"];
    if (self.startedAt > 0 && !self.busy) {
        [self log:@"正在关水并结清当前轮…"];
        [self stopWater];
    }
}

/// 开阀成功后定时自动关水（不弹确认框）
- (void)scheduleAutoStop {
    NSUInteger gen = self.autoSampleGeneration;
    NSInteger secs = 5 + arc4random_uniform(26);   // 5-30 秒
    [self log:[NSString stringWithFormat:@"🧪 采样轮：%ld 秒后自动关水（第 %ld/%ld 轮）",
               (long)secs, (long)self.autoSampleDone + 1, (long)self.autoSampleTotal]];
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gen != ws.autoSampleGeneration) return;    // 已被中止
        if (ws.busy || ws.startedAt <= 0) return;      // 用户已手动操作
        [ws stopWater];
    });
}

#pragma mark - 设置 / 钱包入口

- (void)onSettings {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"设置"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    if (self.autoSampleActive) {
        [ac addAction:[UIAlertAction actionWithTitle:@"停止自动采样（结清当前轮）" style:UIAlertActionStyleDestructive
                                              handler:^(UIAlertAction *a) { [ws cancelAutoSample]; }]];
    } else {
        [ac addAction:[UIAlertAction actionWithTitle:@"自动采样（tac 样本）" style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction *a) { [ws onAutoSample]; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"复制全部日志" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) {
            // 优先取落盘文件（带时间戳）；文件不存在再用屏幕日志
            NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *path = [dir stringByAppendingPathComponent:@"runtime_log.txt"];
            NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
            if (content.length == 0) content = ws.log;
            [UIPasteboard generalPasteboard].string = content;
            [ws log:@"📋 日志已复制到剪贴板（含时间戳）"];
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"探针（调试）" style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) { [ws onProbe]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"退出登录" style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *a) { [ws onLogout]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)onProbe {
    [self.navigationController pushViewController:[[ProbeViewController alloc] init] animated:YES];
}

- (void)onWallet {
    [self.navigationController pushViewController:[[WalletViewController alloc] init] animated:YES];
}

#pragma mark - 退出登录

- (void)onLogout {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"退出登录"
                                                               message:@"将清除本机保存的登录态。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [[KRWMClient shared] clearSession];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"KRWMLogoutNotification" object:nil];
        [ws.navigationController popToRootViewControllerAnimated:YES];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 日志

- (void)log:(NSString *)text {
    if (![NSThread isMainThread]) {
        __weak typeof(self) ws = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [ws log:text]; });
        return;
    }
    if (text == nil) text = @"";
    [self.log appendFormat:@"%@\n", text];
    self.logView.text = self.log;
    NSRange bottom = NSMakeRange(self.logView.text.length, 0);
    [self.logView scrollRangeToVisible:bottom];
    [self appendLogToFile:text];
}

/// 每行日志同步追加到 Documents/runtime_log.txt（带时间戳）。
/// 文件在「文件」App 里可直接取走（Info.plist 已开 UIFileSharingEnabled）。
- (void)appendLogToFile:(NSString *)text {
    static NSString *path = nil;
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        path = [dir stringByAppendingPathComponent:@"runtime_log.txt"];
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm:ss";
    });
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [fmt stringFromDate:[NSDate date]], text];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) return;
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh == nil) {
        [data writeToFile:path atomically:YES];   // 首次创建
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:data];
    [fh closeFile];
}

@end
