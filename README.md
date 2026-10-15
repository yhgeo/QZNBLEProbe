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

界面里还有一个「指令」按钮，可以手动发送任意功能码（用于试探未知功能码，
**属于非读操作，慎用**）。

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
