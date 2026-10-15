//
//  ProbeViewController.m
//  热水探测 —— QZNOSDK 只读探针
//
//  用途：在真实设备上把原始报文全部捞回来，用于逆向交易/费率报文布局。
//  设计原则：只做「读」操作，不发任何会改变设备状态的指令。
//

#import "ProbeViewController.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <QZNOSDK/KRWaterMeterKit.h>

#pragma mark - 枚举名映射

static NSString *SyncTypeName(KRSyncType t) {
    switch (t) {
        case KRSyncTypeUnknown:                        return @"Unknown";
        case KRSyncTypeClearNumInfo:                   return @"ClearNumInfo";
        case KRSyncTypeReadingNumInfo:                 return @"ReadingNumInfo";
        case KRSyncTypeAssignNumber:                   return @"AssignNumber";
        case KRSyncTypeAssginRate:                     return @"AssignRate";
        case KRSyncTypeEndConsumption:                 return @"EndConsumption";
        case KRSyncTypeGetStateOfDevice:               return @"GetStateOfDevice";
        case KRSyncTypeGetConsumptionDetails:          return @"GetConsumptionDetails";
        case KRSyncTypeClearConsumptionDetails:        return @"ClearConsumptionDetails";
        case KRSyncTypeTransactionRateForDetails:      return @"TransactionRateForDetails";
        case KRSyncTypeEndTransactionMacType:          return @"EndTransaction";
        case KRSyncTypeSetKye1_1:                      return @"SetKey1_1";
        case KRSyncTypeEndWaterTransactionMacType:     return @"EndWaterTransaction";
        case KRSyncTypeElectricTransactionRateForDetails: return @"ElectricTransactionRate";
        case KRSyncTypeClearHeatPumpWaterElectricity:  return @"ClearHeatPumpParam";
        case KRSyncTypeUpDataMQTT:                     return @"UpdateMQTT";
        case KRSyncTypeSetWaterMeter:                  return @"SetWaterMeter";
        case KRSyncTypeSetElectricMeter:               return @"SetElectricMeter";
        case KRSyncTypeGetHeatPumpInfo:                return @"GetHeatPumpInfo";
        case KRSyncTypeDisableKeyNo:                   return @"DisableKeyNo";
        case KRSyncTypeColdWaterMeterGetStateOfDevice: return @"ColdWaterMeterState";
        case KRSyncTypePublicSendData:                 return @"PublicSendData";
        case KRSyncTypeEnd:                            return @"End";
        default:                                       return [NSString stringWithFormat:@"Type(%ld)", (long)t];
    }
}

static NSString *RespStateName(KRSyncResponseState s) {
    switch (s) {
        case KRSyncResponseStateUnKnown:        return @"未知";
        case KRSyncResponseStateUnsupported:    return @"设备不支持蓝牙4.0";
        case KRSyncResponseStateUnauthorized:   return @"蓝牙未授权";
        case KRSyncResponseStateResetting:      return @"蓝牙重置中";
        case KRSyncResponseStateNotConnected:   return @"蓝牙未连接";
        case KRSyncResponseStatePowerOff:       return @"蓝牙已关闭";
        case KRSyncResponseStateDisconnect:     return @"连接已断开";
        case KRSyncResponseStateParameterError: return @"参数错误";
        case KRSyncResponseStateSynchronizing:  return @"正在同步中";
        case KRSyncResponseStateSuccess:        return @"✅ 成功";
        case KRSyncResponseStateCheckSumError:  return @"校验和错误";
        case KRSyncResponseStateTimeOut:        return @"⏱ 超时";
        default:                                return [NSString stringWithFormat:@"State(%ld)", (long)s];
    }
}

#pragma mark -

@interface ProbeViewController ()

@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIButton *scanBtn;
@property (nonatomic, strong) UIButton *probeBtn;
@property (nonatomic, strong) UIButton *cmdBtn;
@property (nonatomic, strong) UIButton *clearBtn;

@property (nonatomic, strong) NSMutableString *log;
@property (nonatomic, strong) NSMutableArray<CBPeripheral *> *found;
@property (nonatomic, strong) CBPeripheral *connected;
@property (nonatomic, strong) NSData *lastXfData;      // 最近一次采集到的消费原始数据
@property (nonatomic, assign) BOOL scanning;
@property (nonatomic, assign) BOOL busy;

// 前置声明，避免「no visible @interface declares the selector」警告
- (void)dumpSDKLog;
- (void)parseState:(NSData *)d;
- (void)parseConsumption:(NSData *)d;
- (void)onClearConsumption;
- (void)doClearConsumption;

@end

@implementation ProbeViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"热水探测";
    self.log = [NSMutableString string];
    self.found = [NSMutableArray array];

    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self setupUI];
    [self setupSDK];

    [self log:@"QZNOSDK 只读探针"];
    [self log:@"------------------------------"];
    [self log:@"本工具只发送「读」类指令，不会改变设备状态。"];
    [self log:@"步骤：① 点「扫描」→ ② 点「停止」选设备 → ③ 点「探测」"];
    [self log:@""];
}

- (void)setupUI {
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = @"未连接";
    self.statusLabel.numberOfLines = 2;
    [self.view addSubview:self.statusLabel];

    self.logView = [[UITextView alloc] init];
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logView.editable = NO;
    self.logView.selectable = YES;
    self.logView.alwaysBounceVertical = YES;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.layer.cornerRadius = 8;
    self.logView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    [self.view addSubview:self.logView];

    self.scanBtn  = [self makeButton:@"扫描" action:@selector(onScan)];
    self.probeBtn = [self makeButton:@"探测" action:@selector(onProbe)];
    self.cmdBtn   = [self makeButton:@"指令" action:@selector(onCustomCommand)];
    self.clearBtn = [self makeButton:@"清消费" action:@selector(onClearConsumption)];

    UIButton *copyBtn  = [self makeButton:@"复制" action:@selector(onCopy)];
    UIButton *resetBtn = [self makeButton:@"清空" action:@selector(onClear)];

    self.probeBtn.enabled = NO;
    self.cmdBtn.enabled = NO;
    self.clearBtn.enabled = NO;

    UIStackView *row1 = [[UIStackView alloc] initWithArrangedSubviews:
                         @[self.scanBtn, self.probeBtn, self.cmdBtn]];
    UIStackView *row2 = [[UIStackView alloc] initWithArrangedSubviews:
                         @[self.clearBtn, copyBtn, resetBtn]];
    for (UIStackView *r in @[row1, row2]) {
        r.translatesAutoresizingMaskIntoConstraints = NO;
        r.axis = UILayoutConstraintAxisHorizontal;
        r.distribution = UIStackViewDistributionFillEqually;
        r.spacing = 8;
        [self.view addSubview:r];
    }

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [self.logView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:8],
        [self.logView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [row1.topAnchor constraintEqualToAnchor:self.logView.bottomAnchor constant:8],
        [row1.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [row1.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [row1.heightAnchor constraintEqualToConstant:40],

        [row2.topAnchor constraintEqualToAnchor:row1.bottomAnchor constant:8],
        [row2.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [row2.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [row2.heightAnchor constraintEqualToConstant:40],
        [row2.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
    ]];
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor tertiarySystemFillColor];
    b.layer.cornerRadius = 8;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - SDK 初始化

- (void)setupSDK {
    KRWMCore *core = [KRWMCore sharedCore];
    core.startLog = YES;              // 打印 SDK 内部日志，便于对照
    core.timeOutInterval = 5.0;       // 单条指令 5 秒超时
    core.scanFilterName = nil;        // 不过滤，扫所有设备

    __weak typeof(self) ws = self;

    core.connectionSuccessfulHandler = ^(CBPeripheral *p) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ws.connected = p;
            [ws setStatus:[NSString stringWithFormat:@"✅ 已连接\n%@  %@",
                           p.name ?: @"(无名)", [p formattedMacAddress] ?: @"?"]
                    color:[UIColor systemGreenColor]];
            [ws log:[NSString stringWithFormat:@"✅ 连接成功: %@  MAC=%@",
                     p.name ?: @"(无名)", [p formattedMacAddress] ?: @"?"]];
            ws.probeBtn.enabled = YES;
            ws.cmdBtn.enabled = YES;
        });
    };

    core.connectionFailHandler = ^(CBPeripheral *p) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws log:[NSString stringWithFormat:@"❌ 连接失败: %@", p.name ?: @"(无名)"]];
            [ws setStatus:@"连接失败" color:[UIColor systemRedColor]];
        });
    };

    core.disconnectHandler = ^(CBPeripheral *p) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ws.connected = nil;
            [ws log:@"⚠️ 连接已断开"];
            [ws setStatus:@"已断开" color:[UIColor systemOrangeColor]];
            ws.probeBtn.enabled = NO;
            ws.cmdBtn.enabled = NO;
        });
    };
}

#pragma mark - 扫描 / 连接

- (void)onScan {
    KRWMCore *core = [KRWMCore sharedCore];

    if (self.scanning) {
        [core stopScan];
        self.scanning = NO;
        [self.scanBtn setTitle:@"扫描" forState:UIControlStateNormal];
        [self log:[NSString stringWithFormat:@"扫描结束，共发现 %lu 个设备", (unsigned long)self.found.count]];
        [self pickDevice];
        return;
    }

    [self.found removeAllObjects];
    [self log:@""];
    [self log:@"开始扫描周边蓝牙设备..."];
    [self setStatus:@"扫描中..." color:[UIColor systemBlueColor]];
    self.scanning = YES;
    [self.scanBtn setTitle:@"停止" forState:UIControlStateNormal];

    __weak typeof(self) ws = self;
    [core scanForPeripherals:nil retHandler:^(NSArray<CBPeripheral *> *retArray, CBPeripheral *aPeripheral) {
        if (!aPeripheral) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([ws.found containsObject:aPeripheral]) return;
            [ws.found addObject:aPeripheral];
            NSString *mac = [aPeripheral formattedMacAddress];
            [ws log:[NSString stringWithFormat:@"  [%2lu] %-18@ RSSI=%-5ld MAC=%@",
                     (unsigned long)ws.found.count,
                     aPeripheral.name ?: @"(无名)",
                     (long)aPeripheral.RSSI.integerValue,
                     mac ?: @"(无)"]];
        });
    }];
}

- (void)pickDevice {
    if (self.found.count == 0) {
        [self log:@"未发现任何设备。请确认：① 蓝牙已打开 ② 靠近设备 ③ 设备未被其他手机占用"];
        [self setStatus:@"未发现设备" color:[UIColor systemRedColor]];
        return;
    }

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"选择要连接的设备"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    for (CBPeripheral *p in self.found) {
        NSString *title = [NSString stringWithFormat:@"%@  %@", p.name ?: @"(无名)", [p formattedMacAddress] ?: @""];
        [ac addAction:[UIAlertAction actionWithTitle:title
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            [ws log:[NSString stringWithFormat:@"正在连接 %@ ...", p.name ?: @"(无名)"]];
            [ws setStatus:@"连接中..." color:[UIColor systemBlueColor]];
            [[KRWMCore sharedCore] connectPeripheral:p];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 兜底
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 只读探测（四步串行）

- (void)onProbe {
    if (self.busy) { [self log:@"⚠️ 上一次探测还没结束"]; return; }
    if (!self.connected) { [self log:@"⚠️ 请先连接设备"]; return; }

    self.busy = YES;
    self.probeBtn.enabled = NO;
    [self log:@""];
    [self log:@"========== 开始只读探测 =========="];
    [self step1_DeviceState];
}

- (void)step1_DeviceState {
    [self log:@""];
    [self log:@"[1/4] 读取设备状态 krGetStateOfDevice"];
    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krGetStateOfDevice:^(KRSyncType t, NSData *d, NSString *orig) {
        dispatch_async(dispatch_get_main_queue(), ^{ [ws dumpRaw:@"设备状态" data:d original:orig]; });
    } result:^(KRSyncType t, KRSyncResponseState s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws log:[NSString stringWithFormat:@"    → 结果: %@", RespStateName(s)]];
            [ws step2_Consumption];
        });
    }];
}

- (void)step2_Consumption {
    [self log:@""];
    [self log:@"[2/4] 读取消费详情 krGetConsumptionDetails"];
    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krGetConsumptionDetails:^(KRSyncType t, NSData *d, NSString *orig) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws dumpRaw:@"消费详情" data:d original:orig];
            [ws parseConsumption:d];
        });
    } result:^(KRSyncType t, KRSyncResponseState s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws log:[NSString stringWithFormat:@"    → 结果: %@", RespStateName(s)]];
            [ws step3_ColdWater];
        });
    }];
}

- (void)step3_ColdWater {
    [self log:@""];
    [self log:@"[3/4] 读取冷水表信息 krColdWaterMeterGetStateOfDevice"];
    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krColdWaterMeterGetStateOfDevice:^(KRSyncType t, NSData *d, NSString *orig) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws dumpRaw:@"冷水表" data:d original:orig];
            [ws parseState:d];
        });
    } result:^(KRSyncType t, KRSyncResponseState s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ws log:[NSString stringWithFormat:@"    → 结果: %@", RespStateName(s)]];
            [ws step4_DeviceType];
        });
    }];
}

- (void)step4_DeviceType {
    [self log:@""];
    [self log:@"[4/4] 读取设备类型 krReadingDeviceDataType (读模式)"];
    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krReadingDeviceDataType:@(0) MAXType:@(0) MINType:@(0)
        dataCallback:^(KRSyncType t, NSData *d, NSString *orig) {
            dispatch_async(dispatch_get_main_queue(), ^{ [ws dumpRaw:@"设备类型" data:d original:orig]; });
        } result:^(KRSyncType t, KRSyncResponseState s) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [ws log:[NSString stringWithFormat:@"    → 结果: %@", RespStateName(s)]];
                [ws log:@""];
                [ws log:@"========== 探测结束 =========="];
                [ws dumpSDKLog];
                ws.busy = NO;
                ws.probeBtn.enabled = YES;
            });
        }];
}

#pragma mark - 自定义指令（高级，用于试探功能码）

- (void)onCustomCommand {
    if (!self.connected) { [self log:@"⚠️ 请先连接设备"]; return; }

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"发送自定义指令"
                                                               message:@"格式：功能码HEX,payloadHEX\n例：A4, 或 01,0011223344\n⚠️ 非读类指令会改变设备状态"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"A4,";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"发送" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [ws sendRawCommand:ac.textFields.firstObject.text];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)sendRawCommand:(NSString *)text {
    NSArray<NSString *> *parts = [[text stringByReplacingOccurrencesOfString:@" " withString:@""]
                                  componentsSeparatedByString:@","];
    if (parts.count == 0 || parts[0].length == 0) { [self log:@"⚠️ 格式错误"]; return; }

    unsigned int funCode = 0;
    sscanf([parts[0] UTF8String], "%x", &funCode);

    NSData *payload = nil;
    if (parts.count >= 2 && parts[1].length > 0) {
        payload = [KRWMUtils convertHexStrToData:parts[1]];
    }

    [self log:@""];
    [self log:[NSString stringWithFormat:@"→ 发送 funCode=0x%02X payload=%@",
               funCode, payload.length ? [KRWMUtils bytesStringWithData:payload] : @"(空)"]];

    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krPublicSendData:payload funCode:funCode
        dataCallback:^(KRSyncType t, NSData *d, NSString *orig) {
            dispatch_async(dispatch_get_main_queue(), ^{ [ws dumpRaw:@"响应" data:d original:orig]; });
        } result:^(KRSyncType t, KRSyncResponseState s) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [ws log:[NSString stringWithFormat:@"    → 结果: %@ (%@)", RespStateName(s), SyncTypeName(t)]];
            });
        }];
}

#pragma mark - 清除消费数据（写操作）

- (void)onClearConsumption {
    if (self.busy) { [self log:@"⚠️ 上一次操作还没结束"]; return; }
    if (!self.connected) { [self log:@"⚠️ 请先连接设备"]; return; }
    if (self.lastXfData.length == 0) { [self log:@"⚠️ 请先点「探测」采集到消费数据"]; return; }

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"清除设备消费数据"
        message:[NSString stringWithFormat:
                 @"将把采集到的原始数据原样回传给设备：\n\n%@\n\n"
                 @"⚠️ 这是写操作，会让设备从「待采集」回到「空闲」。确定继续？",
                 [KRWMUtils bytesStringWithData:self.lastXfData]]
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"确定发送" style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *a) { [ws doClearConsumption]; }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)doClearConsumption {
    self.busy = YES;
    [self log:@""];
    [self log:@"===== 清除消费数据 krClearConsumptionDetails ====="];
    [self log:[NSString stringWithFormat:@"发送 data = %@", [KRWMUtils bytesStringWithData:self.lastXfData]]];

    __weak typeof(self) ws = self;
    [[KRWMCore sharedCore] krClearConsumptionDetails:self.lastXfData
        dataCallback:^(KRSyncType t, NSData *d, NSString *orig) {
            dispatch_async(dispatch_get_main_queue(), ^{ [ws dumpRaw:@"清除响应" data:d original:orig]; });
        } result:^(KRSyncType t, KRSyncResponseState s) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [ws log:[NSString stringWithFormat:@"    → 结果: %@ (%@)", RespStateName(s), SyncTypeName(t)]];
                [ws dumpSDKLog];
                [ws log:@"下一步：再点一次「探测」，看设备是否已回到空闲状态。"];
                ws.busy = NO;
            });
        }];
}

#pragma mark - SDK 内部日志

- (void)dumpSDKLog {
    NSMutableString *s = [KRWMCore sharedCore].AllLogString;
    [self log:@""];
    [self log:@"===== SDK 内部日志（含收发的原始帧）====="];
    if (s.length == 0) {
        [self log:@"(空)"];
    } else {
        [self log:s];
    }
    [self log:@"===== SDK 日志结束 ====="];
}

#pragma mark - 报文解析

- (void)dumpRaw:(NSString *)tag data:(NSData *)d original:(NSString *)orig {
    if (!d) { [self log:[NSString stringWithFormat:@"    → %@: (无数据)", tag]]; return; }
    [self log:[NSString stringWithFormat:@"    → %@ 长度=%lu", tag, (unsigned long)d.length]];
    [self log:[NSString stringWithFormat:@"    → %@ HEX: %@", tag, [KRWMUtils bytesStringWithData:d]]];
    if (orig.length > 0) {
        [self log:[NSString stringWithFormat:@"    → %@ 原文: %@", tag, orig]];
    }
}

- (void)parseState:(NSData *)d {
    KRStateObject *st = [KRStateObject stateObjectWithDetailsFromData:d];
    if (!st) { [self log:@"      (状态解析失败)" ]; return; }
    [self log:@"      --- 状态字段 ---"];
    [self log:[NSString stringWithFormat:@"      productId(项目编号) = %@", st.productId]];
    [self log:[NSString stringWithFormat:@"      deviceId(设备ID)   = %@", st.deviceId]];
    [self log:[NSString stringWithFormat:@"      accountId(账号)    = %@", st.accountId]];
    [self log:[NSString stringWithFormat:@"      macAddress         = %@", st.macAddress]];
    [self log:[NSString stringWithFormat:@"      onCharge           = %@  (0空闲/1有订单/2刷卡/3待采集)", st.onCharge]];
    [self log:[NSString stringWithFormat:@"      status(故障)       = %@", st.status]];
    [self log:[NSString stringWithFormat:@"      ★ tacTimes(交易随机数) = %@", st.tacTimes]];
    [self log:[NSString stringWithFormat:@"      maxType=%@ minType=%@ macType=%@", st.maxType, st.minType, st.macType]];
    [self log:[NSString stringWithFormat:@"      chargeMethod(计费) = %@", st.chargeMethod]];
    [self log:[NSString stringWithFormat:@"      macTime            = %@ 分钟", st.macTime]];
    [self log:[NSString stringWithFormat:@"      verSoft=%@ commMode=%@", st.verSoft, st.commMode]];
    [self log:[NSString stringWithFormat:@"      cardmoney          = %@ 厘", st.cardmoney]];
    [self log:[NSString stringWithFormat:@"      KEYNO=%@ functionType=%@", st.KEYNO, st.functionType]];
    [self log:[NSString stringWithFormat:@"      reserved           = %@", [KRWMUtils bytesStringWithData:st.reserved]]];
}

- (void)parseConsumption:(NSData *)d {
    KRConsumptionDetailsObject *cd = [KRConsumptionDetailsObject consumptionDetailsObjectWithDetailsFromData:d];
    if (!cd) { [self log:@"      (消费详情解析失败)"]; return; }

    // 保存原始消费数据，供「清消费」回传给设备
    self.lastXfData = cd.xfData;
    self.clearBtn.enabled = (cd.xfData.length > 0);

    [self log:@"      --- 消费字段 ---"];
    [self log:[NSString stringWithFormat:@"      ★ rate(费率)       = %@   ← 关键！", cd.rate]];
    [self log:[NSString stringWithFormat:@"      ykMoney(预扣)      = %@ 厘", cd.ykMoney]];
    [self log:[NSString stringWithFormat:@"      consumeMone(消费)  = %@ 厘", cd.consumeMone]];
    [self log:[NSString stringWithFormat:@"      accountId=%@ accountType=%@ useCount=%@", cd.accountId, cd.accountType, cd.useCount]];
    [self log:[NSString stringWithFormat:@"      timeId=%@ productId=%@ deviceId=%@", cd.timeId, cd.productId, cd.deviceId]];
    [self log:[NSString stringWithFormat:@"      useTime=%@秒 flowRate=%@mL/6s pluseNum=%@", cd.useTime, cd.flowRate, cd.pluseNum]];
    [self log:[NSString stringWithFormat:@"      waterTemp=%@℃ totalCapacity=%@L pauseCnt=%@", cd.waterTemp, cd.totalCapacity, cd.pauseCnt]];
    [self log:[NSString stringWithFormat:@"      macAddress=%@", cd.macAddress]];
    [self log:[NSString stringWithFormat:@"      ★ tac=%@ keyNo=%@", cd.tac, cd.keyNo]];
    [self log:[NSString stringWithFormat:@"      xfData=%@", [KRWMUtils bytesStringWithData:cd.xfData]]];
}

#pragma mark - 日志与工具

- (void)log:(NSString *)text {
    if (![NSThread isMainThread]) {
        __weak typeof(self) ws = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [ws log:text]; });
        return;
    }
    [self.log appendFormat:@"%@\n", text];
    self.logView.text = self.log;

    // 自动滚到底部
    NSRange bottom = NSMakeRange(self.logView.text.length, 0);
    [self.logView scrollRangeToVisible:bottom];
}

- (void)setStatus:(NSString *)text color:(UIColor *)color {
    self.statusLabel.text = text;
    self.statusLabel.textColor = color;
}

- (void)onCopy {
    if (self.log.length == 0) return;
    [UIPasteboard generalPasteboard].string = self.log;
    [self log:@"📋 日志已复制到剪贴板"];
}

- (void)onClear {
    [self.log setString:@""];
    self.logView.text = @"";
}

@end
