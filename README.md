# 热水探测（QZNBLEProbe）

一个 iOS 只读探针，用来和「趣智校园」体系的校园热水/水控设备做蓝牙通信，
**把设备的原始报文全部捞回来**，为后续逆向交易报文布局提供素材。

## 为什么需要它

`SDKQZNetworkOffline`（趣智校园蓝牙交互 SDK 网络版）只提供编译好的静态库，
其中 `KRTransactionObject` / `KRRateObject` 这两个关键的报文构造类**没有任何公开头文件**，
无法知道「开始交易」要往 `krTransactionRateForDetails:` 里塞什么字节。

所以第一步不是「开水」，而是**读**——把设备状态、消费记录读出来，
从中拿到项目编号、费率、随机数等真实数据，再反推报文格式。

## 设计原则

**只发送读类指令，不会改变设备任何状态。** 具体只做四件事：

| 步骤 | 调用 | 作用 |
|---|---|---|
| 1 | `krGetStateOfDevice` | 读设备状态（项目编号、计费方式、交易随机数、密钥编号…） |
| 2 | `krGetConsumptionDetails` | 读消费记录（**费率**、预扣金额、用水量、水温…） |
| 3 | `krColdWaterMeterGetStateOfDevice` | 读冷水表信息 |
| 4 | `krReadingDeviceDataType`（读模式） | 读设备类型 |

界面里还有两个按钮：

- **「指令」**：手动发送任意功能码（用于试探未知指令，**属于写操作，慎用**）
- **「清消费」**：把采集到的消费原始数据回传给设备，清除「待采集」状态
  （设备必须先回到空闲才能开始新交易；**属于写操作**）

每次探测或写操作结束后，会自动打印 **SDK 内部日志**（`AllLogString`），
其中包含 SDK 实际收发的原始帧，这是逆向功能码表最直接的素材。

## 真机验证记录（2026-10-15）

设备：`KLCXKJ-Water`，MAC `c47f0edbd142`

协议帧格式已用真机数据 100% 验证：

```
60 | 长度(2字节大端) | control | funCode | 00 | payload | 校验和 | 16
```

- 长度字段 = payload 长度 + 3
- 校验和 = `(control + funCode + 0x00 + Σpayload) & 0xFF`（两帧全部吻合）
- 实测功能码：`0x85` = 读消费详情，`0x18` = 读设备类型
- 设备响应帧的 control 固定为 `0x81`，发送帧为 `0x80`

### 功能码表（真机实测 + 反汇编交叉验证）

| funCode | 操作 | 验证方式 |
|---|---|---|
| `0x18` | 读设备类型 | 真机 |
| `0x23` | 读设备状态 | 真机 + 反汇编（`krGetStateOfDevice` 内 `movz w3,#0x23`） |
| `0x31` | **开始交易（放水）** | 反汇编（`krTransactionRateForDetails` 内 `movz w3,#0x31`） |
| `0x32` | **结束交易** | 反汇编（`krEndTransactionMAXType` 内 `movz w3,#0x32`） |
| `0x85` | 读消费详情 | 真机 |
| `0x86` | 清除消费数据 | 真机 |

### 已确认的重要行为

- **清除消费数据不需要 tac**：`krClearConsumptionDetails:` 的 payload 就是
  采集到的 `xfData` 原样回传，设备回 `81 01` 表示成功。
  清除后设备从「待采集」回到可读状态（读状态不再超时）。
- **`krTransactionRateForDetails:` 只是转发外部 data**：SDK 内部不做任何构造，
  payload 格式完全由调用方决定。头文件注释引用的 `KRTransactionObject` /
  `KRRateObject` 在二进制里**根本不存在**（已用符号表确认）。
- **SDK 的 payload 是手工按字节拼的**：例如 `krAssignNumForDevice:productId:`
  内部固定构造 8 字节 payload。

### 设备状态 payload（48 字节，部分字段）

| 偏移 | 长度 | 字段 |
|---|---|---|
| 0 | 1 | 固定标志 `0x80` |
| 1 | 4 | productId |
| 5 | 4 | deviceId |
| 9 | 4 | accountId |
| 13 | 6 | macAddress |
| 19 | 1 | 单字节字段（onCharge / status 之一） |
| 20 | 1 | 单字节字段 |
| 21 | 2 | 双字节字段（疑似 maxType/minType） |
| 23 | 1 | 单字节字段 |
| 24 | 4 | 四字节字段 |
| 28–31 | 4 | 单字节字段组 |
| 41 | 7 | reserved（全零） |

单字节字段与 `KRStateObject` 属性的精确对应关系尚未完全确定。

消费详情 payload（62 字节）字段布局：

| 偏移 | 长度 | 字段 |
|---|---|---|
| 0 | 1 | 固定标志 `0x80` |
| 1 | 6 | timeId（BCD 时间，如 `261015180739`） |
| 7 | 4 | productId 项目编号 |
| 11 | 4 | deviceId |
| 15 | 4 | accountId |
| 19 | 1 | accountType |
| 20 | 4 | useCount |
| 24 | 4 | ykMoney 预扣金额（厘） |
| 28 | 4 | consumeMone 消费金额（厘） |
| 32 | 4 | rate 费率 |
| 36 | 6 | macAddress |
| 42 | 20 | 后半段字段（受 SDK 长度判断限制，见下） |

**已知问题**：SDK 解析后半段字段要求 `长度 >= 63`（`cmp x0, #0x3f`），
而实测设备只返回 62 字节，导致 `useTime` / `flowRate` / `waterTemp` / `tac` 等
全部解析为 `null`。这是设备固件与 SDK 预期的差异，需要自行按偏移解析。

## 目录结构

```
.
├── Sources/
│   ├── main.m                      入口
│   ├── AppDelegate.h/.m            应用委托
│   └── ProbeViewController.h/.m    探针主界面（核心逻辑）
├── Frameworks/
│   └── QZNOSDK.framework           来自 SDKQZNetworkOffline 1.2.1（MIT，作者 李志权）
├── Info.plist
├── project.yml                     xcodegen 工程描述
└── .github/workflows/build-ipa.yml GitHub Actions 构建流水线
```

## 构建

本地不构建（Windows 无法编译 iOS 目标），全部交给 GitHub Actions：

1. 把本目录推到一个 GitHub 仓库（分支 `main` 或 `master`）
2. Actions 会自动跑 `Build IPA`，也可以用 `workflow_dispatch` 手动触发
3. 构建完成后在 Actions 页面的 Artifacts 里下载 `QZNBLEProbe-ipa`

产物是**未签名 IPA**，专门给 TrollStore 用。

## 安装（TrollStore）

1. 下载 `QZNBLEProbe.ipa` 到手机
2. 用 TrollStore 打开它 → Install
3. 首次启动时允许蓝牙权限

## 使用

1. 点「扫描」→ 等设备列表刷出来 → 再点一次「停止」
2. 在弹出的列表里选择你的热水设备（名字形如 `HX4-055` 之类）
3. 连接成功后点「探测」，等四步跑完
4. 点「复制」，把日志发出来

日志里会包含每一步的 **原始 HEX 报文**、SDK 解析出的字段值，以及 SDK 内部日志。

## 已知限制

- 只支持真机（arm64），不支持模拟器
- 蓝牙扫描需要设备未被其他手机占用
- `RSSI` 在 iOS 上通常拿不到（系统限制），显示为 0 属正常
- 第 4 步「读设备类型」虽然标为读模式，仍属设置类指令，若设备异常可跳过

## 许可

`Frameworks/QZNOSDK.framework` 来自
[zhiquanlo/SDKQZNetworkOffline](https://github.com/zhiquanlo/SDKQZNetworkOffline)，
MIT License，Copyright (c) 2020 李志权。本仓库仅做研究用途转发，版权归原作者所有。
