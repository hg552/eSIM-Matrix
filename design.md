# eUICC-Nexus 架构设计与技术规范 (design.md)

## 1. 项目背景与设计目标

当前方案是在普通、非 Root Android 备用机上运行 `m`（Multi）APK；不要求 KernelSU、Magisk、OTBridge 或 LSPosed。SIM 2 可安装实体可插拔 eUICC 芯片（如 ESTKme / 9eSIM / esim.gg），内部预存多国漫游 eSIM Profile。切卡复用现有 LPA，通过卡片／固件已授权的 OMAPI 或外接读卡器访问；三签名不保证任意卡或固件放行，尚未在目标手机实测的能力不能视为已支持。

单卡槽非 MEP 场景同一时刻只能激活一个 Profile。目标是在普通应用权限下提供远程指令、基带状态监听与短信转发；`m` 的持久选卡会话需用户 `/back` 或停止网关才返回默认卡。网络状态与短信接收使用运行时权限，不以 Root 桥接作为前提。只有底层读卡器已获访问授权时，才能执行 Profile 操作。

---

## 2. 历史技术路线评估（不是当前非 Root 部署步骤）

以下保留初期 Root 候选方案的比较；当前非 Root 交付不采用其中的 OTBridge、Root Shell 或 Hook 路线，也不要求安装其模块。复用既有 LPA 不等于必须使用 Root：卡片和系统允许的本地 OMAPI，以及获准的外接读卡器，都可以承载既有 LPA 命令。

| 评估维度 | 方案 A：基于 OTBridge / RemoCard | 方案 B：直接集成 `lpac` + Android OMAPI | 方案 C：Root Shell (`cmd phone`) / Hook 系统服务 |
| :--- | :--- | :--- | :--- |
| **底层通信机制** | 通过 ContentProvider / Socket 暴露底层 OMAPI/TMAPI 通道，由上层 LPA 组织 SGP.22 APDU | 在 Android 端交叉编译 `lpac` (C 原生程序)，通过 libomapi 或 JNI 封装接入 Smartcard API | 调用隐藏系统命令 `cmd phone euicc`，或通过 LSPosed Hook `EuiccManager` / 系统 LPA |
| **实际接口约束** | **OTBridge** 实质为 ContentProvider (`ee.nekoko.nbridge.provider`)，仅传输原始 APDU，未暴露高阶切卡 IPC；**RemoCard** 则是 TCP Socket 远程读卡器，不含切卡业务逻辑 | `lpac` 依赖原生 SGP.22 状态机；但在 Android 环境下无标准 PC/SC，需自行对接 Android OMAPI / SE HAL，引入额外 JNI 与 C/Rust 动态库打包开销 | Android 原生 `EuiccManager` 强校验运营商特权证书（Carrier Privileges Rules / ARA-M）与特权签名；MIUI/HyperOS 的 `cmd phone` 对外置 eUICC 支持极不稳定 |
| **NVRAM 磨损与卡顿恢复** | 依赖上层状态机防抖，缺少对 eUICC 芯片重置期间（`6881` / `6985`）的瞬态重试捕获 | 需要自行在 C 层实现针对物理卡片 reset、REFRESH 主动命令的等待重试机制 | 强行切卡可能因基带与卡片状态脱节导致 RIL 挂死，需重启基带或手机 |
| **选型结论** | **最佳路径：复用本地既有 LPA 引擎（NekokoLPA2 核心）**。由应用内直接持有 `CompositeAdapter` 与 `ProfileManager`，不经外层 Socket 走弯路，直接控制 `ISD-R` 通道。 | **不采用作为主方案**：重复引入一套 C 语言 ASN.1 栈，增加构建链复杂度，收益与直接复用 Dart/Kotlin LPA 一致。 | **坚决废弃**：非公开命令行及系统 Hook 严重受制于厂商 ROM 版本与 SELinux 策略，稳定性无法达到长期无人值守要求。 |

---

## 3. 系统架构与模块边界

系统分为 **Android 原生宿主层**、**Headless 状态机引擎** 以及 **远端交互控制面**：

```mermaid
flowchart TD
    subgraph 远端控制面 [Control Plane via Tailscale LAN]
        Client[curl / Tern / Web Dashboard] -->|HTTP Bearer Token| RestAPI[REST API :8787]
        TGUser[Telegram App] -->|Private Command Whitelist| TGBot[Telegram Bot Poller]
    end

    subgraph 守护网关核心 [eUICC-Nexus Engine: Dart Headless Runtime]
        RestAPI --> GatewayService[RemoteGatewayService]
        TGBot --> GatewayService
        GatewayService --> ProfileCtrl[RemoteProfileControl]
        GatewayService --> AlarmMgr[Exact Alarm Fallback Scheduler]
    end

    subgraph Android 原生与基带监控 [Android Native / Telephony]
        ProfileCtrl -->|ProfileStateTransition| LpaCore[NekokoLPA2 LPA Core]
        LpaCore -->|获准的 OMAPI / 外接读卡器| EuiccChip[SIM 2 eUICC Card]
        TelephonyCallback[TelephonyCallback / ServiceState] -->|EventChannel| NetService[NetworkStatusService]
        NetService -->|Baseband Updates| GatewayService
        SMSBroadcast[SMS_RECEIVED Broadcast] -->|goAsync + Keystore| SmsRelay[SmsRelayReceiver]
        SmsRelay -->|HTTPS Webhook / TG API| PushDest[TG Chat / Webhook]
    end
```

### 3.1 核心组件职责划分

1. **常驻宿主服务 (`RemoteGatewayForegroundService`)**：
   - 采用 Android 前台服务（FGS，`foregroundServiceType="specialUse"`），防止常驻后台被 MIUI 杀进程；
   - 在 `MainApplication` 中常驻初始化预热 Flutter Engine (`nlpa2_multi_engine`)，保持 Headless 模式运行。
2. **硬件交互与容错层 (`RemoteProfileController`)**：
   - 包装 `ProfileManager`，执行 Profile 枚举与启用；
   - 针对可插拔 eUICC 在切卡瞬间可能出现的通道重置与芯片繁忙异常（`CardBusyException`、`ProactiveRefreshException`、`6999` 等），通过 `ProfileStateTransition` 状态机执行重试与状态校验。
3. **基带状态监听器 (`NetworkStatusPlugin`)**：
   - 基于 Android 12+ (API 31+) `SubscriptionManager` 与 `TelephonyCallback`；
   - 监听 `ServiceState` 变化，精准捕获 `VoiceRegistrationState.inService`、漫游标记 (`roaming`) 以及小区信号强度 (`signalDbm`)。
4. **短信截获推送器 (`SmsRelayReceiver`)**：
   - 静态声明 `BROADCAST_SMS` 广播接收器；
   - 收到下行短信后使用 Android Keystore 加密存储的 Bot Token，直接异步 POST 转发至 Telegram 私聊或指定 Webhook，正文绝不落盘缓存。
5. **硬件熔断兜底 (`GatewayAlarmReceiver` + `AlarmManager`)**：
   - 每次切换目标 Profile 前，向系统注册 5 分钟后的 `RTC_WAKEUP` 精确唤醒闹钟（`setExactAndAllowWhileIdle`）；
   - 即使 Dart 引擎崩溃或主进程意外退出，底层硬件闹钟到期仍能触发广播唤醒 FGS 执行 Profile 强制回滚。

---

## 4. 核心状态机流转设计

```mermaid
stateDiagram-v2
    [*] --> IDLE: 系统启动 / 载入默认 Profile

    IDLE --> SWITCHING: 收到 /use <iccid_or_alias> 或 API POST /switch
    
    state SWITCHING {
        [*] --> CooldownCheck
        CooldownCheck --> SaveSession: 冷却时间 >= 30s
        CooldownCheck --> SwitchRejected: 处于冷却锁中
        SaveSession --> InvokeLPA: 保存持久会话 (deadlineEpochMillis=0)，不注册回切闹钟
        InvokeLPA --> StateVerified: ProfileStateTransition 校验成功
        InvokeLPA --> SwitchFailed: 重试超限
    }

    SWITCHING --> WAITING_BASEBAND: 状态确认已启用
    SWITCHING --> IDLE: 切换被拒或切换失败

    WAITING_BASEBAND --> READY_FOR_OTP: TelephonyManager 报告 STATE_IN_SERVICE (带漫游/信号强度)
    WAITING_BASEBAND --> MANUAL_REVERT: 用户提前发送 /back

    READY_FOR_OTP --> LISTENING_SMS: 推送 Telegram 就绪就绪通知
    
    state LISTENING_SMS {
        [*] --> AwaitSms
        AwaitSms --> SmsForwarded: 收到系统 SMS_RECEIVED 广播
        SmsForwarded --> AwaitSms: 成功转发至 TG / Webhook
    }

    LISTENING_SMS --> MANUAL_REVERT: 用户收到验证码后手动 /back

    MANUAL_REVERT --> REVERTING: 触发切回流程

    state REVERTING {
        [*] --> SwitchToDefault: 调用 LPA 启用默认常驻 Profile
        SwitchToDefault --> ClearSession: 恢复默认 Profile
        ClearSession --> NotifyUser: 清除会话并返回操作结果
    }

    REVERTING --> IDLE: 会话结束，重置就绪标记
```

### 状态详细契约

1. **`[IDLE]` 待机状态**：
   - 当前激活预设的默认 Profile（如国内主卡或常驻低资费卡）。
   - 允许查询 `/status`、`/list`，允许设置 `/default`。
2. **`[SWITCHING]` 切换中状态**：
   - **磨损防抖（Flash NVRAM Wear Levelling Protection）**：两次切卡请求必须满足至少 30 秒硬性冷却锁，杜绝突发重复触发。
   - 锁定执行队列，预存目标 ICCID、默认卡 ICCID 与 `deadlineEpochMillis=0`（永久选择，无自动回切截止时间）。
   - 提交底层 APDU 命令切换，并反复轮询确认卡片内部启用标记变为 true。
3. **`[WAITING_BASEBAND]` 等待基带驻网**：
   - 卡片逻辑切换完毕后，基带将经历 SIM 掉线重识、搜网握手与鉴权漫游（通常耗时 15~40 秒）。
   - `RemoteGatewayService` 持续监听 `NetworkStatusService` 广播。
4. **`[READY_FOR_OTP]` 就绪通知**：
   - 判定基带成功处于 `STATE_IN_SERVICE` 后，立即向 Telegram 发送格式化推送：
     > `[Target Profile] is registered (roaming) on [Carrier], -85 dBm. Selection persists; send /back to return.`
5. **`[MANUAL_REVERT]` 回切与恢复**：
   - 接码完成后用户可通过 Telegram `/back` 或 `POST /api/v1/back` 恢复本次会话的默认 Profile；显式停止网关同样执行回切。
   - 进程恢复不能把 `deadlineEpochMillis=0` 当作过期时间；永久选择不恢复回切计时器，并取消残留闹钟。仅磁盘中已有正数截止时间的限时会话按原截止时间恢复。
   - 删除 Profile 在请求和确认阶段都保护当前默认卡与活动会话回切目标，防止确认期间默认卡变化导致误删。

---

## 5. 控制面协议与安全模型

### 5.1 鉴权与网络暴露面
- **网络绑定**：REST HTTP 服务默认探测并**仅绑定 Tailscale / Headscale CGNAT 私网地址**（`100.64.0.0/10` 或 `fd7a:115c:a1e0::/48`），禁止监听公共网络。
- **Token 校验**：所有 API 请求必须携带 `Authorization: Bearer <token>` 请求头。Token 为 256 位安全伪随机生成（Base64URL 43 字符），使用**恒定时间算法（Constant-time Equality）**比对，防范时序侧信道攻击。
- **Telegram 限制**：严格比对 `chat.type == private` 以及发送者 ID 是否精确匹配配置的私聊白名单 ID，忽略群组及任何非授权用户的消息。
### 5.1.1 发布包签名与升级兼容性

已发布的 `ee.nekoko.nlpa2.multi`（v1.3.5）采用 **APK Signature Scheme v2 + 三个签名者**（不是 v1/v2/v3 三方案；实测 v1=false、v2=true、v3/v3.1/v4=false）：

| # | keystore | 证书 | SHA-256 |
|---|---|---|---|
| 1 | `community.jks` (`communitykey`) | `C=CN` | `4139278a…026fa` |
| 2 | `9eSIMCommunityKey.jks` (`key0`) | `CN=esim` | `6966004a…d3a4` |
| 3 | `sakurasim.jks` (`sakurasim`) | `CN=Unknown,…` | `dd0dddb…eab13` |

三签名由 `scripts/build.py` 的 `--next-signer` 链生成；Gradle 侧 flavor `m` 与 debug/release 都只显式配置了 `esim9`，因此**直接 `flutter build apk` 得到的产物只有 1 个签名者**。签名者集合与已安装应用不一致时覆盖安装会报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`（且卸载重装会丢本地配置）。任何要覆盖安装到现有设备的包，都必须用三个 keystore 重新 `apksigner sign`，保持 `--v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled false` 与上述顺序，再用 `apksigner verify --print-certs` 核对三个指纹。

### 5.2.0 配置入口（去哪里设置）

| 功能 | 入口 | 备注 |
|---|---|---|
| Cloudflare 加密隧道（Web 接码） | App「短信转发」页 → 目标通道 → **Cloudflare 加密隧道 (Web接码)** | 同页填 Worker 地址、通道 ID、通道密钥（密钥加密存 AndroidKeyStore）；`/tunnel` 查当前通道状态，不回显完整通道 ID 与密钥 |
| 流量卫士（切卡关移动数据） | App「短信转发」页 → **切卡自动化** 卡片；或 Telegram `/guard` | `/guard_toggle` 切换开关、`/guard_now` 立即锁定当前卡 |
| 代理自动切节点 | App「短信转发」页 → **切卡自动化** 卡片；或 Telegram `/proxy` | 卡片含 Controller 地址、Secret、策略组、测试连接；`/proxy_toggle` 开关、`/proxy_group <名称>` 改组、`/proxy_node <序号或名称>` 手动切节点 |
| 虚拟定位联动（免Root GPS Mock） | App「短信转发」页 → **切卡自动化** 卡片 | 开关、注入模式（系统模拟位置 / Shizuku Fused）、回滚自动还原、一键测试；支持按 ICCID 定制经纬度 |
| 以上全部 | Web 控制台（Tailnet `http://<ip>:8787/`）同名卡片 | 需先接入 Tailscale，REST 才监听 |

Telegram 主菜单加入「🛡️ 流量卫士 / 🌐 代理联动 / 📡 接码通道状态」三个按钮；**新增文本命令必须同步加入 `_handleTelegramMessage` 的命令白名单正则**，否则消息会被静默忽略。


### 5.2 交互指令规范

#### Telegram Bot 交互
- `/list`：列出当前芯片内所有 Profile 别名及 ICCID 后四位，标记当前激活项。
- `/status`：查看网关、会话与基带状态；永久选择的 `remainingSeconds` 为 null，不显示虚假的零秒倒计时。
- `/default`：将当前已激活的 Profile 设定为默认回滚卡。
- `/use <alias|iccid>`：切换至目标卡，等待驻网并保持选择，直到明确回切。
- `/back`：提前结束接码会话，立刻切回默认卡。
- `/guard`：流量卫士状态（开关、回滚恢复、本次会话锁定情况、强制能力）；`/guard_toggle` 切换；`/guard_now` 立即锁定当前卡。
- `/proxy`：代理联动状态（控制器连通性、策略组、当前节点、可用节点列表）；`/proxy_toggle` 开关；`/proxy_group <名称>` 改组；`/proxy_node <序号或名称>` 手动切节点。
- `/tunnel`：接码通道状态（CF Worker 地址、脱敏通道 ID、密钥配置状态、最近投递与失败数），并提示配置入口。

#### REST API 接口定义
- `GET /`：内置轻量暗色系 Web 控制台（无外网静态资源依赖）。
- `GET /api/v1/dashboard`：控制台首屏聚合数据（状态、Profile 矩阵、最近短信、流量卫士状态），一次往返完成整屏重绘。
- `GET /api/v1/status`：获取当前网关状态与 SIM 卡注册详情 JSON。
- `GET /api/v1/profiles`：枚举当前卡片 Profile 清单。
- `POST /api/v1/default`：锁定当前卡为回滚卡。
- `POST /api/v1/switch`（JSON: `{"profile": "alias_or_iccid", "temporaryMinutes": 5}`）：发起切卡。
- `POST /api/v1/back`：强制回滚至默认卡。
- `GET /api/v1/sms/history?limit=N`：按时间倒序返回短信记录（含提取到的 OTP 与投递状态）。
- `GET /api/v1/proxy` / `POST /api/v1/proxy/config` / `POST /api/v1/proxy/test` / `POST /api/v1/proxy/switch`：代理联动查询、配置、连通性测试与手动切节点。
- `POST /api/v1/dataguard`（JSON: `{"enabled": true, "restoreOnRevert": true}`）：漫游流量安全锁开关。
- `POST /api/v1/dataguard/apply`：立即对当前会话（或指定 `subscriptionId`）关闭移动数据；无订阅时返回 `subscription_not_found`，绝不伪报成功。


### 5.3 免Root虚拟定位联动架构规范 (Rootless Virtual Location Linkage)

#### 5.3.1 架构动机与 3D 联动模型 (3D Overseas Environment Linkage)
在跨境业务场景（境外社交媒体、跨国银行网银、加密货币合规交易平台、电商风控等）中，风控策略普遍通过多重物理与逻辑维度交叉核验终端的真实运行环境：
1. **物理基带层 (Physical Cellular Identity)**：SIM 2 物理 eUICC 卡槽激活的 Profile、MCC/MNC、PLMN 注册网络标识、IMSI 与短信下行链路；
2. **网络出网层 (IP Network Egress)**：FlClash 代理节点出口 IP 归属地、ISP/ASN 属性及 DNS 污染抑制；
3. **传感器与系统定位层 (Sensor & GNSS Coordinates)**：Android 系统融合定位（Fused Location Provider）、GPS 与网络基站定位上报的地理经纬度。

若终端激活境外本地卡（如香港 ClubSim）且出口代理切至香港，但系统底层 GPS 仍上报国内或返回空坐标，极易在风控引擎中触发「代理环境与传感器地理位置冲突」的欺诈标记。

因此，eUICC-Nexus 构建了 **Profile + Proxy + Location 三维一体化联动引擎 (3D Linkage Engine)**：

```
                    ┌─────────────────────────┐
                    │  切卡事件 / 恢复回滚     │
                    │  (Telegram / REST / UI) │
                    └───────────┬─────────────┘
                                │
         ┌──────────────────────┼──────────────────────┐
         ▼                      ▼                      ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│  基带层切卡      │  │  网络层代理联动  │  │  系统定位层联动  │
│  (eUICC Profile) │  │ (FlClash Egress) │  │   (Mock GPS)     │
├──────────────────┤  ├──────────────────┤  ├──────────────────┤
│• LPA APDU 切卡   │  │• REST 控制器通讯 │  │• 自动推导/自定义  │
│• 漫游数据安全锁  │  │• 国别策略组匹配   │  │• System Mock 或   │
│• CS/IMS 驻网监听 │  │• 快照记录与恢复   │  │  Shizuku Fused    │
│• 验证码短链转发  │  │• 本地节点定向绑定 │  │• 周期性坐标注入   │
└──────────────────┘  └──────────────────┘  └──────────────────┘
```

- **联动触发与时序**：
  - **切卡激活阶段**：无论是从 Telegram `/use`、REST API `POST /api/v1/switch`、Web 控制台还是 App 主页发起切卡，在目标 Profile 经 LPA 激活成功且基带进入就绪状态（或主页切卡二次确认后），网关并行调度 `ProxyLinkageService.switchNodeForProfile` 与 `RemoteGatewayService.applyLocationForProfile`，一次性对齐基带归属、代理出口与 GPS 坐标。
  - **回切与会话重置阶段**：当用户发送 `/back`、调用 `POST /api/v1/back`、限时会话到期或手动恢复时，若开启了 `mockLocationAutoRestore = true`（默认启用），系统自动触发 `stopMockLocation()` 注销测试 Provider 并关闭周期注入，还原系统真实定位状态；同时回退代理节点快照并恢复蜂窝数据开关。

---

#### 5.3.2 两种免Root注入模式实现机制

为确保在普通非 Root 环境或系统权限严格受限的设备上均能可靠注入坐标，`MockLocationPlugin`（Kotlin 原生插件，MethodChannel `ee.nekoko.mock_location`）与 `MockLocationService`（Dart 门面）提供了两种完全免 Root 的工作模式：

##### 1. 系统模拟位置模式 (System Mock Location)
- **机制与权限**：
  - 基于 Android 官方标准 `LocationManager` Test Provider 体系；
  - 在 `AndroidManifest.xml` 中静态声明 `android.permission.ACCESS_MOCK_LOCATION`（标记 `tools:ignore="MockLocation"`）；
  - 首次使用需用户在 Android 系统「开发者选项」→「选择模拟位置信息应用」中勾选 `eUICC-Nexus`（包名 `ee.nekoko.nlpa2.multi`）。
- **运行期探针**：
  - 调用 `AppOpsManager.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_MOCK_LOCATION, Process.myUid(), packageName)`（API 29+）或 `checkOpNoThrow` 动态检查授权状态（`isMockApp()`）；未授权时向用户提示明确的开启指引。
- **Provider 注册与周期注入**：
  - 动态为 `gps`、`network` 和 `fused` 三大核心 Provider 分别创建测试提供商：
    ```kotlin
    lm.addTestProvider(
        provider,
        requiresNetwork, requiresSatellite,
        false, false, true, true, true,
        ProviderProperties.POWER_USAGE_LOW, accuracy
    )
    lm.setTestProviderEnabled(provider, true)
    ```
  - 启动主线程 1000ms 周期循环任务，持续向处于激活状态的 Provider 推送结构完整的 `Location` 对象（注入精确纳秒时间戳 `elapsedRealtimeNanos`、水平精度 `accuracy`、海拔高度 `altitude`、垂直精度及速度/方位精度），杜绝应用因缺少传感器辅助字段判定为伪造坐标。

##### 2. Shizuku FusedLocation 模式 (Rootless Shizuku IPC)
- **机制与优势**：
  - 针对国内定制 ROM（如小米 HyperOS / MIUI、OPPO ColorOS 等）偶发开发者选项被系统后台自动重置、或追求全自动化无需人工翻找系统设置的免交互场景；
  - 通过 Shizuku 提供的免 Root Binder IPC，直接调用 Android 系统底层 `cmd` 服务。
- **免交互静默提权 (Silent AppOps Grant)**：
  - 探测 `Shizuku.pingBinder()` 与 `Shizuku.checkSelfPermission()`；
  - 执行 `cmd appops set <packageName> android:mock_location allow`，**完全静默自动授予当前应用模拟位置权限**，无需用户手动进入系统设置翻找开发者选项。
- **全局底座接管与双重注入**：
  - 执行 `cmd location providers add-test-provider gps` 与 `set-test-provider-enabled gps true`；
  - 同步启用 `network` test provider；
  - 周期性注入时，在调用原生 LocationManager 的同时，双重执行 `cmd location providers set-test-provider-location gps --location <lat>,<lng> --accuracy <acc>`，确保系统框架层 `FusedLocationProviderClient` 被全局精确接管。
- **干净注销清理**：
  - 停止模拟时，通过 Shizuku 依序移除 `cmd location providers remove-test-provider gps` 与 `network`，并结合 Java 层注销，避免测试 Provider 残留导致高德/Google 地图黑屏或位置冻结。

---

#### 5.3.3 坐标匹配策略与默认坐标库

`LocationMappingResolver` 实现了四级容错匹配算法，严格按如下优先级进行经纬度解析：
**自定义覆盖规则 (Custom Override) > 卡片别名正则智能推导 (Alias Regex) > MCC 移动国家码映射 (MCC Mapping) > 默认保底坐标 (Fallback)**。

##### 1. 匹配优先级与解析逻辑
1. **自定义覆盖规则 (Custom Override)**：
   - 优先比对 `AppSettings.mockLocationCustomRules` 中是否存在匹配当前 `ICCID` 或 `Alias` 的规则条目；
   - 命中且经纬度解析合法即返回，置 `confidence = 'custom'`。
2. **卡片别名智能正则推导 (Exact Country via Alias)**：
   - 使用内置 `countryPatterns` 规则库匹配卡片别名（含国旗 Emoji、中文名、英文名、国际电话区号与运营商关键词）；
   - 命中对应国别即提取该国标准坐标，置 `confidence = 'exact_country'`。
3. **MCC 归属地推导 (MCC Mapping)**：
   - 当别名无明显国别标识时，提取 SIM 卡的 3 位 MCC 码（如 `454`、`310`、`248` 等）映射到对应国家，置 `confidence = 'mcc'`。
4. **默认保底回退 (Fallback)**：
   - 若以上规则均未命中，安全回退至亚太核心枢纽坐标（中国香港尖沙咀），置 `confidence = 'fallback'`。

##### 2. 预设标准国家坐标库 (`standardCoordinates`)
系统内置覆盖主流跨国漫游接码卡所在国家与核心互联网数据中心的基准城市坐标：

| 国家代码 | 国家/地区名称 | 代表性城市及地标中心 | 纬度 (Latitude) | 经度 (Longitude) | 识别关键词 / 运营商 / 区号 / MCC |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **HK** | 中国香港 | 香港尖沙咀 (Tsim Sha Tsui) | `22.3193` | `114.1694` | ClubSim, 🇭🇰, 香港, +852, MCC 454 |
| **US** | 美国 | 洛杉矶 (Los Angeles) | `34.0522` | `-118.2437` | Saily, 🇺🇸, USA, T-Mobile, +1, MCC 310-316 |
| **EE** | 爱沙尼亚 | 塔林 (Tallinn) | `59.4370` | `24.7536` | Elisa, 🇪🇪, 爱沙尼亚乌龟卡, Top Connect, +372, MCC 248 |
| **GB** | 英国 | 伦敦 (London) | `51.5074` | `-0.1278` | Giffgaff, 🇬🇧, UK, London, Vodafone, +44, MCC 234/235 |
| **JP** | 日本 | 东京 (Tokyo) | `35.6762` | `139.6503` | Docomo, SoftBank, 🇯🇵, Japan, +81, MCC 440/441 |
| **SG** | 新加坡 | 滨海湾 (Marina Bay) | `1.3521` | `103.8198` | Singtel, 🇸🇬, Singapore, +65, MCC 525 |
| **DE** | 德国 | 法兰克福 (Frankfurt) | `50.1109` | `8.6821` | Telekom, 🇩🇪, Germany, +49, MCC 262 |
| **NL** | 荷兰 | 阿姆斯特丹 (Amsterdam) | `52.3676` | `4.9041` | KPN, 🇳🇱, Netherlands, +31, MCC 204 |
| **FR** | 法国 | 巴黎 (Paris) | `48.8566` | `2.3522` | Orange, 🇫🇷, France, +33, MCC 208 |
| **TW** | 中国台湾 | 台北 (Taipei) | `25.0330` | `121.5654` | 中华电信, 🇹🇼, Taiwan, +886, MCC 466 |
| **MO** | 中国澳门 | 澳门 (Macau) | `22.1987` | `113.5439` | CTM, 🇲🇴, Macau, +853, MCC 455 |
| **AU** | 澳大利亚 | 悉尼 (Sydney) | `-33.8688` | `151.2093` | Telstra, 🇦🇺, Australia, +61, MCC 505 |
| **CA** | 加拿大 | 多伦多 (Toronto) | `43.6532` | `-79.3832` | Rogers, Bell, 🇨🇦, Canada, +1, MCC 302 |

---

#### 5.3.4 自定义覆盖规则语法与持久化格式

当业务场景需要固定至特定经纬度（例如特定的海外分行、住宅地址或机房）时，支持针对 ICCID 单独指定坐标：

##### 1. 规则语法规范
自定义规则为英文逗号分隔的字符串：
```text
<纬度>, <经度>[, <城市或备注标签>]
```
- `<纬度>`（必须，浮点数）：范围 `[-90.0, 90.0]`，例如 `22.2783`；
- `<经度>`（必须，浮点数）：范围 `[-180.0, 180.0]`，例如 `114.1747`；
- `<城市或备注标签>`（可选，字符串）：展示于日志与状态面板的友好地名，缺省为 `Custom`。

**配置示例**：
- 香港湾仔：`22.2783, 114.1747, Wan Chai`
- 美国特拉华免税州：`39.7447, -75.5484, Wilmington DE`
- 英国伦敦金融城：`51.5155, -0.0922, City of London`

##### 2. 持久化与生效逻辑
- **存储结构**：在 Android `SharedPreferences` 的 `mockLocationCustomRules` 键中以 JSON Map 存储（`Map<String, String>`，Key 为 ICCID 或别名，Value 为规则字符串）。
- **管理与热重载**：
  - 在 App 主页 Profile 长按菜单中选择「📍 定制虚拟位置」或在「切卡自动化」卡片中输入；
  - 若当前卡片正在使用中，保存规则后立即对当前位置进行热重载，无需重新经历 APDU 切卡过程。

---

#### 5.3.5 运维排障与日志审计指南 (Operational Manual)

1. **权限排查与测试**：
   - 进入 App「短信转发」页 →「切卡自动化」卡片，点击「测试虚拟定位」；
   - 系统执行权限自检：
     - **系统模拟模式未就绪**：提示用户前往系统「开发者选项」→「选择模拟位置信息应用」选中本项目；
     - **Shizuku 模式未就绪**：检查 Shizuku 是否已启动并授权当前应用，或通过 App 引导一键完成静默授权。
2. **系统缓存与第三方应用生效机制**：
   - Android 系统及 Google Play Services 维护有 `LastKnownLocation` 缓存。在切换位置瞬间，插件会向 `gps`、`network`、`fused` 三个 Provider 同时推送高精度坐标，确保下游应用在首次发起 `getLastLocation()` 或 `requestLocationUpdates()` 时立即可见新坐标。
3. **运行日志审计**：
   - 关键操作均向 Android Logcat（Tag: `NexusMockLocation`）及网关运行日志输出规范审计行：
     > `Mock location: injected [Hong Kong (Tsim Sha Tsui)] (22.3193, 114.1694) for 8985200014632217637 (mode=system, confidence=exact_country)`
     > `Mock location stopped`
---

## 6. 漫游流量安全锁（Roaming Data Safeguard）

**动机**：跨国保号卡在本地漫游时按 MB 计费，系统后台同步、应用更新或 Play 服务任意一次联网即可产生高额账单。接码只需 CS/IMS 短信信道，不需要分组数据。

**实现**：`CellularDataGuardianPlugin`（Kotlin，MethodChannel `ee.nekoko.data_guard`）+ `CellularDataGuardian`（Dart 门面）。

- **执行路径分级**：
  1. 反射调用 `TelephonyManager.setDataEnabled(subId, false)` / `setDataRoamingEnabled(subId, false)`（需要 `MODIFY_PHONE_STATE`，特权构建自带）；
  2. 上述不可用时回退 `su -c svc data disable`（仅对默认数据卡有效，作为尽力而为的兜底）；
  3. 两者皆不可用时**明确上报未强制**，由 Telegram 与 Web 控制台提示用户手动关闭数据漫游。
- **时序**：`_switchProfile` 在 `enableProfile` 前做一次尽力而为的锁定，`enableProfile` 返回后再做一次权威复核（SIM 复位可能把数据开关恢复成 ROM 默认）；基带进入 `ready` 时再复核一次，防止系统层重新打开数据。
- **快照与回滚**：会话在 `_RemoteSession` 中持久化 `guardSubscriptionId`、切卡前的 `dataEnabled`/`roamingEnabled` 与 `guardEnforced`；`_revert` 成功后按快照恢复。切换失败时也立即恢复，避免出现「数据已关闭但没有会话负责恢复」的悬挂状态。
- **验证边界**：订阅级开关需要真实 SIM/eUICC 才能观测生效；无 SIM 的模拟器只能验证通道、能力探测与降级语义。

---

## 7. 代理联动（Proxy Linkage）

**动机**：出网 IP 与 SIM 归属地不一致是跨境平台风控的高危信号。

- `ProxyLinkageService` 对接 Clash / Mihomo（FlClash）/ sing-box 的 External Controller（默认 `127.0.0.1:9090`），仅依赖标准 REST：`GET /proxies`、`GET /proxies/{group}`、`PUT /proxies/{group}`。
- `ProxyMappingResolver` 按「自定义规则 → 国旗 Emoji → 国际区号 → 品牌/关键词 → 区域回退」推导目标节点；两字母国家代码带字母边界守卫（避免 `in` 命中 `Singapore`、`us` 命中 `Russia`），并过滤 `DIRECT`/`REJECT`/剩余流量等非实体节点。
- 切卡前记录策略组当前节点快照，就绪后按目标卡国别切换；回滚或会话结束时还原快照。控制器离线、密钥错误或分组缺失时只记录告警，绝不阻塞物理切卡。
- **每卡定向绑定（主页入口）**：主页 Profile 长按菜单 →「🌐 指定代理节点」，从 FlClash 实时节点列表里挑一个具体节点，绑定以 `AppSettings.proxyCustomRules[iccid] = 节点名` 持久化。选「自动匹配」则删除该键，退回按国别推导；控制器离线时降级为手动输入节点名。
- `RemoteGatewayService.applyProxyForProfile()` 是唯一的选择入口：**显式绑定 > 国别 resolver**（绑定节点若已从订阅池消失则安全回退到 resolver，不报错）。网关切卡（`_switchProfile`）与**主页本地直接切卡**（`profiles_screen` 验证成功后）都调用它，所以从 Bot / Web 控制台 / 主页三处切卡行为一致；若被绑定的卡当前已激活，保存绑定时立即应用一次。
- Telegram `/proxy` 会列出所有已绑定的卡（ICCID 脱敏）→ 节点，便于核对。


---

## 8. 保号引擎（Keep-Alive）的实际实现

代码已实现**到点自动执行**，与早期「只做手动」的设想不同：网关每 20 秒跑一次维护，每 3 次（约 60 秒）检查一次保号规则；`_checkScheduledKeepAlive` 在**当前无会话**（`_session == null`）且 `now >= nextRunEpochMillis` 时自动触发 `runKeepAliveNow`，一次 tick 只启动一条规则，切卡后按 `dwellSeconds` 驻留再自动回滚，并通过 Telegram 汇报。

仍保留的限制（也是必须限制的部分）：
1. **单飞与互斥**：已有会话时不触发，避免与接码会话争抢同一张 eUICC；一次只跑一条规则，防止多卡轮巡互相堵塞。
2. **NVRAM 磨损与风控**：间隔由规则决定（默认 90 天），不做高频轮换；频繁重置会磨损闪存并可能触发运营商漫游风控。
3. **短信上行**：保号只做驻网（CS/IMS 注册），不自动发短信、不自动走流量，避免产生漫游资费。
4. **流量与代理**：保号会话同样走流量卫士（数据关闭）与代理联动（按国别切节点），因此驻网期间不会偷跑漫游流量。
