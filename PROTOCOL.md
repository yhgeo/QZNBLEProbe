# 趣智校园蓝牙热水器协议 —— 逆向完整记录

> 记录时间：2026-10-15
> 设备：`KLCXKJ-Water`（MAC `c47f0edbd142`，凯路创新科技）
> 目标设备：校园蓝牙水控表（BLE 直连，设备本身不联网）

---

## 一、背景

围绕「趣智校园」校园一卡通体系，先后分析了四个来源：

| 来源 | 性质 | 作用 |
|---|---|---|
| `zhiquanlo/SDKQZNetworkOffline` | iOS 闭源 SDK（ObjC 静态库） | 提供接口壳，二进制可反汇编 |
| `Amnsia-05/HotWaterAuto` | Android 无障碍自动化 App | 只模拟点击，不碰协议 |
| **`yehu-imei/linyu`** | **第三方开源客户端（Kotlin）** | **★ 完整协议实现，决定性来源** |
| Stream 抓包 | iOS HTTPS 抓包 | 验证签名算法、获取费率包样本 |

**核心结论：`linyu` 的源码是唯一完整的协议实现，本记录主要基于它，并用 iOS SDK 反汇编与真机抓包交叉验证。**

---

## 二、协议帧

### 2.1 二进制帧

```
下标:  0     1     2        3     4     5      6 … 6+n-1   6+n    7+n
含义: 0x60  0x00  len+3   0x80  cmd   0x00   data[…]     crc   0x16
```

- 帧头 `0x60`，帧尾 `0x16`，标志位固定 `0x80`
- `len = data.size + 3`（把下标 3、4、5 三个字节算进长度）
- **校验和** `crc = (sum(data) + 0x80 + cmd) % 256`
- 总长 = `data.size + 8`

### 2.2 线上帧（真正写入 BLE 特征的字节）

```
0x23('#') + 二进制帧的大写 HEX 文本(ASCII) + 0x0A('\n')
```

⚠️ **发的是 HEX 文本，不是原始二进制**。直接写二进制设备不会报错，只会静默不响应。

### 2.3 方向约定

- 手机 → 设备：`control = 0x80`
- 设备 → 手机：`control = 0x81`（bit0 为响应标志）

---

## 三、命令字表

| cmd | 含义 | 成功判定 | 验证方式 |
|---|---|---|---|
| `0x18` | 读设备类型 | — | 真机 |
| `0x19` | 清除设备项目信息 | — | 反汇编 |
| `0x20` | 下发项目编号 | — | 反汇编 |
| `0x21` | **下发费率包（开阀）** | `payload[0]==0x80` | 真机 + 源码 |
| `0x22` | 关阀 | `payload[0]==0x80` | 源码 |
| `0x23` | **查询设备状态** | — | 真机 + 反汇编 |
| `0x31` | 开始交易（iOS SDK 独有） | — | 反汇编 |
| `0x32` | 结束交易（iOS SDK 独有） | — | 反汇编 |
| `0x85` | **采集消费数据** | payload 即 xfData | 真机 + 源码 |
| `0x86` | **写回设备存储（清记录）** | `payload[0]==0x80` | 真机 + 源码 |
| `0x88` | 禁用密钥 | — | 反汇编 |
| `0xC0` | 读冷水表状态 | — | 反汇编 |

> `0x31` / `0x32` 是 iOS SDK 里的命令，实战代码（linyu）用的是 `0x21` / `0x22`。
> `krAssginRateForDevice:` 与 `krPublicSendData:funCode:` 的功能码由参数动态传入。

---

## 四、错误码表

响应 payload 格式：`81 <码>`

- 成功：`81 01`
- 失败：`81 <错误码>`

| 码 | 含义 |
|---|---|
| `0x01` | 包头错误 |
| `0x02` | 包长度错误 |
| `0x03` | 未采集消费数据 |
| `0x04` | 功能码错误 |
| `0x05` | 数据格式错误 |
| `0x06` | 校验和错误 |
| `0x07` | 结束码错误 |
| `0x08` | 来源错误 |
| `0x09` | **密钥错误** |
| `0xFF` | 未知错误 |

---

## 五、数据帧字段布局

### 5.1 设备状态（`0x23` 响应，48 字节）

| 偏移 | 长度 | 字段 | 实测值 |
|---|---|---|---|
| 0 | 1 | 标志 | `0x80` |
| 1 | 4 | productId 项目编号 | 891 |
| 5 | 4 | deviceId | 3613 |
| 9 | 4 | accountId | 24383 |
| 13 | 6 | macAddress | c47f0edbd142 |
| 19 | 1 | protocolType 协议版本 | `0x20` |
| 20 | 4 | verSoft 软件版本 | 33554948 |
| 24 | 4 | **randomNumber 随机数** | `a7000000` |
| 28 | 1 | **state 设备状态** | 0 空闲 / 1 有订单 / 2 刷卡 / 3 待采集 |
| 29 | 1 | devType 设备类型 | 2 |
| 30 | 1 | a1 | 0 |
| 31 | 1 | chargeMethod 计费方式 | `0x11` = 17（水控计量） |
| 32+ | — | 保留 | 全零 |

- 应答**至少 31 字节**才能解析（源码要求，帧短了会读到越界垃圾值）
- `macType = String.format("%02x%02x", p[19], p[30])`

### 5.2 消费详情（`0x85` 响应，62 字节）

| 偏移 | 长度 | 字段 | 实测值 |
|---|---|---|---|
| 0 | 1 | 标志 | `0x80` |
| 1 | 6 | timeId（BCD 时间） | `261015180739` |
| 7 | 4 | productId | 891 |
| 11 | 4 | deviceId | 3613 |
| 15 | 4 | accountId | — |
| 19 | 1 | accountType | 2 |
| 20 | 4 | useCount | — |
| 24 | 4 | ykMoney 预扣（厘） | 3000 |
| 28 | 4 | consumeMone 消费（厘） | 676 |
| 32 | 4 | **rate 费率** | 26 |
| 36 | 6 | macAddress | — |
| 42 | 20 | 后半段（见下） | — |

⚠️ **已知问题**：iOS SDK 解析后半段要求 `长度 >= 63`（反汇编 `cmp x0, #0x3f`），
而实测设备只返回 **62 字节**，导致 `useTime` / `flowRate` / `waterTemp` / `tac` 等
全部解析为 `null`。需自行按偏移解析。

---

## 六、服务端

- **BASE_URL**：`https://v3-api.china-qzxy.cn`

### 6.1 签名算法（已用抓包 100% 验证）

```
raw  = 参与签名的字段按 key 字典序升序拼接成 "key1value1key2value2…"
       （value 为 null 时整个字段跳过，不是当空串）
内层 = MD5( raw + "&key=" + loginCode )
签名 = MD5( 内层 + "&key=sign-kailu-855c74a88b8b494187c99b08b8c9a744" )
```

- `loginCode` = 服务端下发的会话密钥
- 外层固定密钥 `sign-kailu-855c74a88b8b494187c99b08b8c9a744`（自带 `&key=` 前缀）
- 输出 32 位小写 hex
- 原实现在 native `libklcxkjencry.so`，linyu 已用纯 Kotlin 复现

**验证记录**：
```
raw  = "deviceId3613randomNumbera7000000telephone150****6284xfModel0"
内层 = f8ce3832bc1d60256d9bedd1a4f0a103
签名 = c51d775c69759a8e478dc7cc21e24c89   ← 与抓包完全一致 ✅
```

**各接口的签名字段不同**：

| 接口 | 参与签名的字段 |
|---|---|
| `rateOrder` | `telephone`、`deviceId`、`xfModel`、`randomNumber` |
| `upload` | `loginCode`、`telephone`、`xfData`（**必须小写**） |
| `fail` | `consumeDate`、`loginCode`、`telephone` |

### 6.2 认证字段（每个请求都带）

```
loginCode, userId, accountId, projectId, telephone, telPhone,
phoneSystem, version
```

请求头还需带 `Config-Project`（= projectId）与 `Config-Keys`（常量），
否则结算报 226「加密校验失败」。

### 6.3 关键接口

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/user/login` | 登录 |
| POST | `/order/downRate/bluetooth/rateOrder` | **蓝牙下费率（开阀第一步）** |
| POST | `/order/upload/bluetooth/data` | 上传消费数据（结算） |
| POST | `/order/upload/bluetooth/fail` | 上报失败订单 |

`rateOrder` 参数：`deviceId`、`macAddress`、`macType`、`bigTypeId`、`smallTypeId`、
`protocolType`、`randomNumber`、`xfModel`（常量 `"0"`）、`signature` + auth

`rateOrder` 响应关键字段：
```json
{"data":{
  "downData":"<费率包HEX>",   // 要写进设备的 0x21 payload
  "consumeDate":"20261015204116",  // 失败上报要用
  "rate":26, "preDeductMoney":"3.0", "chargeMethod":17,
  "minChargeUnit":10, "autoDisConTime":6,
  "orderNo":null, "liquidOrderNo":null }}
```

---

## 七、完整业务流程

```
开阀：连接 → 查询状态(0x23) → 下费率(HTTP) → 写费率包(BLE 0x21) → 成功
结算：关阀(0x22) → 采集(0x85) → 上传(HTTP) → AES解密clData → 写回(0x86)
```

1. BLE 连接（注意：连接地址与台账 MAC 不同，只差首字节最高两位）
2. 查询状态 `0x23` → 取 `protocolType`、`randomNumber`、`state`、`devType`、`a1`
3. `state != 0` 时：
   - `state = 3/6` → 有遗留未结算数据 → 先补结算（0x85→上传→0x86）→ **必须断开重连**
   - 其他 → 设备正在使用中
4. HTTP 请求 `rateOrder`（带签名）→ 拿 `downData`
5. **BLE 写费率包 `0x21`** → 真正开阀
6. 返回 `payload[0]==0x80` 才算成功；**没确认不能当失败**（费率包可能已写入）

**三条铁律**：
1. 费率包必须来自服务端
2. `randomNumber` 必须用设备给的
3. 失败必须上报（`bluetoothFailOrder`）

---

## 八、加密体系

| 用途 | 算法 | 密钥 | 说明 |
|---|---|---|---|
| HTTP 请求签名 | 嵌套 MD5 | `sign-kailu-855c74a88b8b494187c99b08b8c9a744` | 见 6.1 |
| 设备域 clData 解密 | AES-128-ECB | `20210118klcx@002` | 结算写回 0x86 用，明文格式 `<前缀>-<dataHex>` |
| **费率包 downData** | **未知** | **未知**（设备与服务端共享） | 见下 |

**`downData` 实测分析**：
- 112 hex = 56 字节，**不是 16 的倍数** → 非整体 AES
- 头 8 字节：`BA EC A3 E4 2B EE FF FE`
- 剩余 48 字节（16 的倍数）用上述 AES 密钥解密 → **得到随机字节，解密失败**
- 结论：`downData` 用的是**另一套密钥**，藏在设备固件里；linyu 也只是原样转发

---

## 九、关键结论：绕过计费不可行

### 9.1 伪造费率包 —— 不可行

- `downData` 由服务端用设备共享密钥加密，密钥**不在 App 里，在设备芯片里**
- 要拿到需拆机读 flash + 反汇编固件（硬件逆向，工程量极大）
- 且还需知道明文格式（字段顺序、单位、校验）

### 9.2 重放费率包 —— 不可行（已实测）

实测过程：
```
重放前 randomNumber = b9000000（抓包时是 a7000000，已变）
发送 21,<旧downData>
设备响应 81 09  ← 密钥错误（KRErrorCodeKeyError）
```

**原理**：`downData` 绑定设备当时的 `randomNumber`，而——

> **设备在开阀成功的那一刻，立刻更新 randomNumber**

所以一份 `downData` 只能用一次，**用后即废**。
想重放必须在 randomNumber 更新之前，而更新恰恰发生在开阀成功那一刻 →
**重放窗口 = 零**。协议设计上就堵死了。

### 9.3 清除设备记录也绕不过去

- 清除记录（`0x86`）的数据来自**服务端的 `clData`**
- 流程：`0x85采集 → HTTP上传 → 服务端返回clData → AES解密 → 0x86写回`
- **不上传就没有 clData，就无法清除**
- 佐证：把 `xfData` 原样回传给 `0x86`，设备回 `81 01` 但**状态未变**（state 仍 = 3）
- 后果：绕过计费后设备停在 `state=3`，**下次开阀被拒绝**，设备卡死

### 9.4 唯一可行路径

**每次开阀都必须重新调 `rateOrder` 接口**拿新的 `downData`。
这等价于 linyu 的正常流程 —— 也就是把 linyu 移植到 iOS。

---

## 十、工具与资产

| 资产 | 位置 | 说明 |
|---|---|---|
| 探针 App | `github.com/yhgeo/QZNBLEProbe` | iOS 只读探针，四步探测 + 自定义指令 |
| iOS SDK | `Frameworks/QZNOSDK.framework` | 来自 SDKQZNetworkOffline 1.2.1（MIT） |
| 反汇编脚本 | `%TEMP%/repo-analysis/` | 纯 Python ARM64 解码器（无需 capstone） |
| linyu 源码 | `github.com/yehu-imei/linyu` | 完整协议实现参考 |

**探针 App 的「指令」按钮**可发任意功能码：格式 `功能码HEX,payloadHEX`，例如 `21,<downData>`。

---

## 十一、待办

- [ ] 把 linyu 流程移植到 iOS（登录 → 下费率 → 写 0x21 → 结算）
- [ ] 解析 `0x85` 响应后半段 20 字节（当前 SDK 因长度判定跳过）
- [ ] 验证 `state=3` 补结算流程
- [ ] 确认 `macType` 中 `a1` 的语义

---

## 附：信息来源说明

- 协议帧、命令字、签名算法、业务流程均来自开源项目
  [`yehu-imei/linyu`](https://github.com/yehu-imei/linyu)（MIT），
  并经 iOS SDK 反汇编与真机抓包交叉验证。
- 本记录仅供技术研究，涉及的账号、手机号等信息已做脱敏。

---

## 十二、补充与修正（2026-10-15 晚，来自 linyu 源码 + 看雪帖）

### 12.1 服务端请求的两个必需请求头

```
Config-Project: <projectId>
Config-Keys: module_list,advertise_type,question_list,service_phone_list,banner_list_app,activity_list_app,aliCard_popup_config
```

缺了 `Config-Keys`，结算接口会报 **226「加密校验失败」**——而且表象只是这一个错误码，
看不出根因。另外所有请求的 `version` 用 `6.5.28`。

### 12.2 登录密码算法（精确化）

```
password = MD5(明文) 取后 10 位，转大写
```

- 账密登录：`telephone` + `password` + `identifier`（留空）+ `type=0`
- 微信登录：`identifier` + `password=98ECF8427E`（= MD5 空串）+ `type=1`

### 12.3 ⚠️ 修正：macType 的两个字节是 p[29] 与 p[30]

本文档第六节与旧版 README 记的是 `p[19]`（protocolType）+ `p[30]`，**这是错的**。

正确来源（linyu `DeviceQueryState` 真机实测 + 看雪帖官方 App 代码，两者一致）：

| 字节 | 偏移 | 含义 |
|---|---|---|
| 第 1 字节 | **p[29]** | devType（官方 App 叫 `mayDeviceType`） |
| 第 2 字节 | **p[30]** | a1（官方 App 叫 `mayDeviceType2`） |

即 `macType = String.format("%02x%02x", p[29], p[30])`。

### 12.4 结算的两个"必须"

1. **关阀后必须断开重连再采集**。同一连接里「关阀 → 立刻 0x85」拿到的数据会被服务端判
   **226「加密校验失败」**，账单停在 0.0；重连后采集才能被接受。（linyu 2026-09-30 实测）
2. **xfData 必须小写**。签名用小写、上传字段也必须小写，不一致会报 **170「签名错误」**。

### 12.5 上传接口的成功判定

`errorCode ∈ {0, 206, 209}` 都算成功（服务端历史遗留，各校口径不一）。

### 12.6 状态帧字段语义（来自看雪帖官方 App 解析代码）

| 偏移 | 字段 | 已观测取值 |
|---|---|---|
| 28 | state | 0 空闲 / 1 有订单 / 2 刷卡消费中 / 3 待采集 / **5 远程控制模式** / 6 另一种「有遗留数据」 |
| 29 | devType | 0 普通水控 / 1 / 3 / 4 特殊类型 |
| 30 | a1 | — |

`state=5` 是**管理员后台锁设备**（官方 App 提示「设备已进入远程控制模式，如需使用请联系管理员」），
进入该状态后所有普通用户都无法操作——它是**限制，不是入口**，无法"利用"。

### 12.7 MAC 的两种形态（换算规则）

蓝牙规范要求随机静态地址最高两位必须为 1，所以按规范实现的设备会把真实 MAC 置上这两位
当广播地址用。两边只差**首字节最高两位**：

| 用途 | 换算 |
|---|---|
| 查台账 / 调接口 | 广播地址 → 台账 MAC：首字节 `& 0x3F` |
| 连蓝牙 | 台账 MAC → 广播地址：首字节 `\| 0xC0` |

例：`C0:15:83:04:D3:00`（广播）↔ `00:15:83:04:D3:00`（台账）。
iOS 拿不到链路地址，所以用**设备状态帧 offset 13 起的 6 字节**（设备自报）来查台账，
并同时尝试「原样」与「清掉最高两位」两种写法。

### 12.8 ⚠️ 待真机验证：响应帧的功能码可能 ≠ 请求功能码

看雪帖的官方 App 代码按 **0xFB** 分派 0x85 的响应、**0xFA** 分派 0x86、**0xF8** 分派 0x88，
即设备响应的功能码与请求不同。

这与本记录「响应帧仅 control 的 bit0 不同、功能码与请求一致」的假设冲突
（该假设只在 `0x23` / `0x18` 上验证过）。

**验证方法**：探针打印响应帧第 5 字节即可确认。当前 iOS 客户端不依赖功能码分派
（走 SDK 的专用方法），所以不阻塞使用，但会影响自研帧解析。

---

## 十二、iOS 客户端实现补充（2026-10-15 晚）

> 本节由「把 linyu 流程移植到 iOS」的过程中补充，来源为 linyu 源码
> （`github.com/yehu-imei/linyu`，MIT）与看雪帖《趣智校园 app 分析》
> （`bbs.kanxue.com/thread-275828.htm`），两者相互印证。

### 12.1 之前缺失、现已确认的常量

| 项 | 值 | 来源 |
|---|---|---|
| `Config-Keys` 请求头 | `module_list,advertise_type,question_list,service_phone_list,banner_list_app,activity_list_app,aliCard_popup_config` | linyu `NetworkModule.kt` |
| `version` 参数 | `6.5.28` | linyu |
| `phoneSystem` | `android` | linyu（服务端未校验，iOS 客户端沿用） |
| 登录密码 | `MD5(明文)` 取**后 10 位**，转**大写** | linyu `MD5Utils.kt` |
| 微信登录占位密码 | `98ECF8427E`（= `MD5("")`） | 看雪帖 |
| 上传成功码 | `errorCode ∈ {0, 206, 209}` | linyu |

### 12.2 修正：`macType` 用的是 `p[29]` / `p[30]`

5.1 节记的是 `macType = String.format("%02x%02x", p[19], p[30])`，**有误**。

linyu 的实际调用是 `BleSignBuilder.macType(st.devType, st.a1)`，而
`DeviceQueryState`（`BleController.kt`）里：

```kotlin
protocolType = String.format("%02X", p[19])   // 只用于 protocolType 参数
randomNumber = toHex(p[24..27])
state        = p[28]
devType      = p[29]     // ← macType 第 1 字节
a1           = p[30]     // ← macType 第 2 字节
```

**结论：`macType = %02x%02x(p[29], p[30])`**，与看雪帖里 Android 官方客户端的
`{mayDeviceType, mayDeviceType2}` 完全一致。

### 12.3 结算流程的两个硬性约束

1. **关阀后必须断开重连，再采集**
   linyu 2026-09-30 实测（同一笔订单 97547 对比）：在同一连接里「关阀后立刻采集」
   的数据会被服务端判 **226「加密校验失败」**（账单停在 0.0）；
   重新连接后采集的数据才能被接受。

2. **`xfData` 必须小写**
   签名用小写、上传字段也必须小写，否则服务端按收到的值重算签名对不上 → **170**。

### 12.4 服务端 HTTP 错误码（与第四节的设备侧错误码是两套）

| code | 含义 |
|---|---|
| 170 | 签名错误（xfData 大小写不一致） |
| 204 | 清 UI + 重连 |
| 220 | 提示 message |
| 221 | 特定处理分支 |
| 226 | 加密校验失败（缺 `Config-Keys` 头，或关阀后未重连就采集） |
| 306 | 设备不在线（对蓝牙表误调 `tcpDevice` 通道时） |
| 311 | 设备正在刷卡消费 |

### 12.5 状态帧字段语义（来自看雪帖的 Android 官方 App 解析代码）

| 偏移 | 官方命名 | 说明 |
|---|---|---|
| 28 | `deviceState` | 0 空闲 / 1 有订单 / 2 刷卡中 / 3 待采集 / 5 远程控制 / 6 遗留数据 |
| 29 | `mayDeviceType` | macType 第 1 字节 |
| 30 | `mayDeviceType2` | macType 第 2 字节 |
| 31 | `v29` | 我们记为 `chargeMethod` |
| 32 | `v30`（2 字节） | — |

> 官方 App 对 `deviceState` 的分派：0 → 下订单开阀；1 → 按 `accountId` 判归属；
> 2 → 提示换设备；3 → 自动发 `0x85` 采集；5 → 提示联系管理员。

### 12.6 遗留疑点：响应功能码可能 ≠ 请求功能码

看雪帖里官方 Android App 的响应分派（`AnalyTools.analyWaterDatas`）：

```java
if (twoComplement[4] == 35) {        // 0x23 查询：请求/响应同码
    ...
} else {
    switch (twoComplement[4]) {
        case -5: caijishujuOnback        // 0xFB ← 0x85 的响应
        case -6: fanhuicunchuOnback      // 0xFA ← 0x86 的响应
        case -8: settingKeyCallback      // 0xF8 ← 0x88 的响应
        ...
    }
}
```

**待真机验证**：用探针记录响应帧第 5 字节，确认 `0x85` 的响应到底是 `0x85` 还是 `0xFB`。
这会影响按功能码分派响应的写法。

### 12.7 iOS 侧实现要点

- iOS 拿不到 BLE 链路地址，台账 MAC 取**设备状态帧 offset 13 起的 6 字节**（设备自报值）
- 台账查询要依次尝试「原样」与「清掉首字节最高两位」两种写法
- **连接用广播地址**（台账 MAC 首字节 `| 0xC0`），**查台账用台账 MAC**（首字节 `& 0x3F`）
- `0x21` / `0x22` 通过 SDK 的 `krPublicSendData:funCode:` 发送
- 消费详情按 **62 字节**自行解析（见 §12.8）

### 12.8 消费详情解析门槛修正

`PROTOCOL.md` 5.2 记的「iOS SDK 要求 `长度 >= 63`」是 **SDK 自身缺陷**：
设备实测返回 62 字节，官方 Android App 用的门槛是 `payload.length >= 62`。
iOS 客户端因此**不依赖 SDK 的解析器**，自行按偏移解析。

### 12.9 已证伪的绕过路径（重申）

- **伪造费率包**：`downData` 由服务端用设备共享密钥加密，密钥在设备芯片内，
  官方 App 也只是原样转发（`downFateToDev` 直接 `sendCommendBuffer(0x21, downData)`）
- **重放**：`randomNumber` 在开阀成功瞬间更新，重放窗口为零（§9.2 已实测）
- **利用 `state=5` 远程控制模式**：那是管理员主动锁设备，是限制不是入口
- **拆机读固件**：属硬件破解，且即便拿到密钥也过不了「结算必须联网」这一关
