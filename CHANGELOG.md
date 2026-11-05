# Changelog (更新日志)

All notable changes to **eUICC-Nexus** (and upstream NekokoLPA2) are documented in this file.

## [v1.3.4] - 2026-11-05 (`1.3.4+134`)

### ✨ 新增 (Added)
- **自动检查新版本 + 一键复制排查报告的发布侧闭环（`UpdateNotifier` / `UpdateCheckPolicy`）**：
  - **更新源可配置**：沿用上游的更新 feed 格式与选择逻辑（`UpdateFeed`），但把 feed 地址改为构建期注入（`--dart-define=APP_UPDATE_FEED_URL=...`）；上游 flavor 仍默认指向 `updates.lpa.ee`，本项目的 flavor 指向本仓库发布的 `update_feed.json`；
  - **自动检查**：`App` 启动时与**网关常驻运行**时都会检查更新。网关是无头运行的，没人打开 App 就收不到任何提示，因此发现新版本会**直接推送 Telegram 通知**（含版本号、更新日志与下载地址）；
  - **不再打扰**：同一次安装最多每 24 小时检查一次；应用自身升级后立即检查一次；用户点「以后再说」的版本不再重复弹窗；已通知过的版本不会重复通知（`UpdateCheckPolicy` 纯函数，11 个用例覆盖）；
  - **发布脚本**：`scripts/publish_update_feed.mjs` 从已签名 APK 里读出三套 ARA-M 证书指纹，写入 `update_feed.json`；签名不匹配的 APK 不会被推荐更新。
- **发布构建闸门**：`scripts/build_android_release.sh` 在编译后**强制校验** APK 内含 `librust_lib_nlpa2.so`，缺失即构建失败。

### 🐛 修复 (Fixed)
- **修复此前所有版本都缺少 Rust 原生库**：Cargokit 在找不到 Rust 工具链时是**软失败**，Gradle 仍会出包，于是 `librust_lib_nlpa2.so`（QRTR 调制解调器总线）从未被打进 APK —— **QRTR / SE HAL 读卡器在 v1.0.0 ~ v1.3.3 的所有安装包里都是不可用的**。v1.3.4 起由构建脚本强制校验。
- **修复更新检查永远无法命中（真机实测发现）**：发布脚本此前传 `--dart-define=APP_VARIANT=m`，而 `AppSettings.variant` 会原样返回该值，更新源因此去匹配名为 `m` 的渠道，而本项目发布的 feed 键是 `multi` —— **自动更新对所有用户都是死的**。改为 `APP_VARIANT=multi`（与上游 multi flavor 及 `scripts/build.py` 一致）。
- **修复更新弹窗显示上游品牌**：更新弹窗与窗口标题此前恒为「NekokoLPA 2」，现改为构建期注入 `--dart-define=APP_DISPLAY_NAME=eUICC-Nexus`，上游 flavor 不受影响。

### ✅ 真机验证 (Verified on device)
- **SE HAL 读卡器实测可用**：在 Android 16 / HyperOS 3 / 高通机型上通过 SE HAL 成功读取 eUICC 的 EID 与剩余空间（补库前为 `NO_SERVICE`）。
- **更新检查全链路实测通过**：手动检查与「启动时自动检查」均能正确弹出更新框（含更新日志），「以后再说」后不再重复弹出，24 小时节流生效。
- QRTR 在该机型仍失败于 `no QRTR socket: errno 13`（手机 ROM 的 SELinux 不允许 `shell` 打开 QRTR socket，属系统策略限制）。

## [v1.3.3] - 2026-11-04 (`1.3.3+133`)

### 🧪 测试与重构 (Tests)
- **给 Shizuku 下载逻辑补上可测接缝与单元测试**（无行为变更）：
  - 把「从 GitHub Release JSON 里挑 `.apk` 资源」「候选 URL 排序与去重」「下载体是否够大」三件事从插件里抽成纯逻辑 `ShizukuDownload`，不再与网络、Android API 纠缠；
  - 新增 **`ShizukuDownloadTest`（8 个用例）**：只挑第一个 `.apk`、忽略非 APK 资源、拒绝非 HTTPS 链接、容忍空/异常的 Release 响应、API 失败时回退到固定直链、固定直链不重复尝试、500 KB 阈值边界。
- **新增状态行的 Widget 测试**（`shizuku_status_tile_test.dart`，4 个用例）：
  - 未安装 → 显示「未安装」并只提供「安装」；
  - 已安装未运行 → 显示「服务端未运行」并只提供「启动指引」，点开后对话框含启动命令与「复制命令」；
  - 运行中 → 显示「运行中」并只提供「打开」，不出现「启动指引」；
  - 通道无应答 → 仍渲染该行，且不得误报「运行中」。

## [v1.3.2] - 2026-11-04 (`1.3.2+132`)

### ✨ 新增 (Added)
- **Shizuku 按需下载安装（QRTR / SE HAL 的必备依赖）**：
  - Shizuku 是独立应用，Android 不允许把两个 APK 合并成一个，因此本项目**不在安装包内携带它的副本**；只有用户点击安装时，才会从 GitHub 上游拉取最新的 Shizuku 安装包，并交给系统安装器确认；
  - 「设置 → 读卡器类型」新增 **Shizuku 状态行**：未安装 / 已安装未运行 / 运行中三态一目了然。未安装时点「安装」即下载并调起系统安装器（首次会引导开启「安装未知应用」权限）；已安装时同样显示「打开」；
  - 已安装但服务端未运行时，点击「启动指引」会显示**本机实际可用的 `adb shell <path>/libshizuku.so` 启动命令**（按已安装版本动态解析路径），并支持一键复制；手机未 Root 时每次重启都需执行一次，这正是用户最容易漏掉的一步；
  - 从安装器或 Shizuku 界面返回时自动重新检测状态，无需手动刷新。

### 📌 说明 (Note)
- APK 体积不变（不内置 Shizuku 二进制）。安装仍需用户在系统弹窗中确认，本项目不会静默安装任何应用。
- 下载地址优先取 GitHub Releases API 的最新版本，失败时回退到固定版本直链；下载结果小于 500 KB 视为错误页而非 APK，会拒绝交给安装器。
- 第三方声明见 `third_party/shizuku/NOTICE.txt` 与 `LICENSE.txt`。



## [v1.3.1] - 2026-11-04 (`1.3.1+131`)

### 🐛 修复 (Fixed)
- **修复诊断报告把「跑不起来的读卡器来源」误记为正常**：`QRTR modem` 与 `SE HAL` 两个来源在 Shizuku 未安装/未运行、或连接开关关闭时，会直接返回空列表；诊断报告此前一律记为 `[OK] 0 reader(s)`，让人误以为该通道已排查过。现在改为明确的 `[SKIP]` 并附带原因（`Shizuku is not installed or not running` / `QRTR connector is off in settings` / `this SoC has no QRTR bus`）。

## [v1.3.0] - 2026-11-03 (`1.3.0+130`)

### ✨ 新增与优化 (Added)
- **底层硬件与接口深度诊断引擎 & 一键复制排查报告 (`DiagnosticsService`)**：
  - **空读卡器原位诊断卡片 (`ReaderDiagnosticsView`)**：当检测不到读卡器时，首页不再只显示空泛的“请连接兼容读卡器”，而是直接原位展开详尽的**硬件与接口诊断卡片**，通过规则引擎自动分析 10 种常见硬件与系统配置根因并给出明确的解决建议（如：设置中内置 OMAPI 读卡器被误关闭、系统版本低于 Android 9、OMAPI 会话损坏需重启、系统 ROM 未向 OMAPI 暴露卡槽接口等）；
  - **一键复制脱敏诊断报告**：提供「一键复制完整诊断报告」按钮，一键聚合系统版本、HyperOS/MIUI 版本、OMAPI UICC 特性声明、基带卡槽状态、SEService 连接状态、各来源扫描耗时与明细、以及过滤脱敏后的关键日志（自动隐藏 ICCID、EID 与 Telegram Bot Token），方便用户一键发送给开发者调试；
  - **控制台与无卡状态联动**：在「应用日志/控制台」页面底部新增「复制排查报告」快捷入口；在「未检测到卡片」页面中新增「查看排查报告」入口，覆盖所有卡片未识别场景；
  - **OMAPI 底层异常透传与捕获**：修复 Dart 端 `OmapiAdapter` 静默吞掉系统异常导致报告显示空白的问题，并在 Android 原生层新增 `getDiagnostics` 接口穿透受损会话直接读取底层硬件与基带状态。

## [v1.2.0] - 2026-11-03 (`1.2.0+120`)

### ✨ 新增与适配 (Added)
- **全签名合一安装包 (`eUICC-Nexus-v1.2.0.apk`) & ESTK MAX 双芯片 (`SE0 / SE1`) 深度适配**：
  - 单个 APK 同时集成 **ESTK / NekokoLPA Community (`c47350c7ba682b34a3e584a0d58463ea42b1ad73`)**、**9eSIM (`d1c0f48b370e74d4ea4770ed4c3cd70a3198d31f`)** 与 **SakuraSIM (`65d0571854afec519a90f92d7c5d8cf8148da373`)** 三套 ARA-M 签名证书；
  - **修复 ESTK MAX 在手机内置卡槽 (OMAPI) 下无法读取卡片列表的 Bug**：修正默认 AID 优先级为优先连接主芯片 **`SE0` (`A06573746B6D65FFFF4953442D522030`)**（而非副芯片 `SE1 ...31`），禁用 OMAPI 下 `EstkPlugin` 并发探测 `aidMgt` 私有通道，并修复 `OmapiPlugin.kt` 在探测副通道失败时调用 `cleanupReaderSessions` 误杀主通道导致 `CHANNEL_NOT_FOUND` 的缺陷；
  - **支持 Telegram `/readers` 远程切换 ESTK MAX 主副芯片 (`SE0 ⇄ SE1`)**：检测到 ESTK 卡片时，支持在 App 顶部按钮及 Telegram `/readers` 中一键切换 `ESTK Max SE0 (主芯片)` 与 `ESTK Max SE1 (副芯片)`。

### 🐛 修复与优化 (Fixed)
- **修复小米澎湃 OS (HyperOS / MIUI) 拦截通知类/验证码短信广播 (`MIUILOG- Sms Filter`) 问题**：
  - 声明并动态请求 `READ_SMS` 与 `com.miui.permission.READ_NOTIFICATION_SMS`，提升 `SmsRelayReceiver` 广播优先级至最高 (`2147483647`)；
  - 在 `RemoteGatewayForegroundService` 常驻服务中新增 **`content://sms/inbox` 数据库 `ContentObserver` + 3 秒增量扫描双引擎兜底**（带 25 秒去重窗口），即使系统底层过滤了 `SMS_RECEIVED` 广播，只要短信写入系统收件箱即可在 1 秒内自动补抓并转发。
- **修复短时间高频涌入多条短信时的漏转与限流问题**：
  - `SmsRelayReceiver.onReceive` 改为 `<5ms` 毫秒级落盘至 `SmsRelayStore` 后立即结束广播，避免阻塞系统 `GsmInboundSmsHandler` 有序广播队列；
  - 后台发送队列扩容至 `256`，新增 `280ms` 突发消息平滑节流锁，并在 `TelegramBotClient` 中支持 `HTTP 429 Too Many Requests` (`retry_after`) 自动退避重发。
- **修复应用底部导航栏偶发隐藏「短信转发」页面的问题**：在 `MainTabScreen` 中将 Android 端「短信转发」Tab 默认设为常驻可见，并隔离后台预热启动时的权限请求异常，防止异常回调将 Tab 状态重置为隐藏。

## [v1.1.0] - 2026-11-03 (`1.1.0+110`)

### ✨ 新增功能 (Added)
- **验证码智能提取与单击复制 (`<code>OTP</code>`)**：自动从多国短信中提取 4~8 位纯数字及 `G-xxxxxx` 验证码置顶展示，使用 Telegram HTML `<code>` 标签包裹（在 Telegram 中轻点验证码即可复制），并在每条转发短信底部附带 **`[ 🏠 已收到码，切回主卡 ]`** 快捷按钮；App 内历史记录卡片同步新增 **`[ 🔑 复制验证码 ]`** 按钮。
- **5 分钟临时接码模式 (`/use_temp`) 与定时自动保号引擎 (`/keepalive`)**：
  - `/list` 列表同时提供 **`[ 🔄 启用 ]`**（持久切卡）与 **`[ ⏱️ 5分接码 ]`**（5 分钟倒计时结束后自动切回默认主卡）双模式按钮；
  - 新增 `/keepalive` 定时保号管理面板，支持为任意卡片配置周期性保号任务（如每 90 天自动切换并驻留漫游基站 3 分钟后自动切回主卡），也支持一键 **`[ ⚡ 立即保号 ]`**。
- **Telegram 直接发送二维码图片远程下卡 & 远程改备注名 (`/rename`)**：
  - 支持直接在 Telegram 聊天框发送 **eSIM 二维码截图/照片**，网关自动在内存解码 `LPA:1$...`（含暗色反相二维码容错）并执行 ES9+/ES10b 远程写卡；
  - 新增 `/rename <序号> <新名称>` 指令与按钮，支持远程修改卡片备注昵称。
- **芯片剩余闪存空间 (`Free NVRAM KB`) 与 `EID` 实时展示**：在 `/list`、`/status` 与 Web 控制台中直接读取并展示当前 eUICC 芯片剩余可用空间（`KB`）与 `EID`。
- **宿主机备用机电量 / 断电 / 温度健康监控与告警**：`/status` 实时显示手机电量百分比、充电类型 (`AC`/`USB`)、电池温度 (`°C`) 与网络类型；当检测到外部电源断开、电量 `≤ 20%` 或温度 `≥ 45°C` 时自动向 Telegram 发送告警。
- **呼入电话 / 来电振铃提醒 (`CallRelayReceiver`)**：监听 `PHONE_STATE` 振铃广播，收到语音验证码呼入或来电时实时推送来电号码与卡槽提醒至 Telegram / Webhook。
- **双卡槽与多读卡器远程切换 (`/readers`)**：支持在 Telegram 或 REST API 远程查看并切换 `SIM 1`、`SIM 2` 及蓝牙/USB 读卡器。
- **短信失败离线重试队列 (`/retry_sms`)**：支持指数退避重试、后台定时自动补发未送达短信，以及通过 `/retry_sms` 或 App 历史页 **`[ 🔄 重发 ]`** 按钮一键补发。

### 🐛 修复与优化 (Fixed)
- **修复小米澎湃 OS (HyperOS / MIUI) 拦截通知类/验证码短信广播 (`MIUILOG- Sms Filter`) 问题**：
  - 声明并动态请求 `READ_SMS` 与 `com.miui.permission.READ_NOTIFICATION_SMS`，提升 `SmsRelayReceiver` 广播优先级至最高 (`2147483647`)；
  - 在 `RemoteGatewayForegroundService` 常驻服务中新增 **`content://sms/inbox` 数据库 `ContentObserver` + 增量扫描双引擎兜底**（带去重窗口），即使系统底层过滤了 `SMS_RECEIVED` 广播，只要短信写入系统收件箱即可在 1 秒内自动补抓并转发。
- **修复短时间高频涌入多条短信时的漏转与限流问题**：
  - `SmsRelayReceiver.onReceive` 改为 `<5ms` 毫秒级落盘至 `SmsRelayStore` 后立即结束广播，避免阻塞系统 `GsmInboundSmsHandler` 有序广播队列；
  - 后台发送队列扩容至 `256`，新增 `280ms` 突发消息平滑节流锁，并在 `TelegramBotClient` 中支持 `HTTP 429 Too Many Requests` (`retry_after`) 自动退避重发。
- **修复应用底部导航栏偶发隐藏「短信转发」页面的问题**：在 `MainTabScreen` 中将 Android 端「短信转发」Tab 默认设为常驻可见，并隔离后台预热启动时的权限请求异常，防止异常回调将 Tab 状态重置为隐藏。
## [1.0.0+100]

### Released
- First public 1.0.0 release of **eUICC-Nexus** (built upon NekokoLPA 2 under the MIT License):
  - Android eUICC remote profile switching, download (`LPA:1$...` + one-click Speedtest test profile), and two-step safe deletion over local OMAPI / external readers / OTBridge.
  - Real-time Android 4G/5G/CS/PS baseband roaming registration state machine (`STATE_IN_SERVICE`, `NetworkRegistrationInfo`, signal dBm) with post-switch stale-state protection and 6-second hardware cooldown lock.
  - Automatic local cleanup of `Enable`/`Disable` SGP.22 notifications from eUICC NVRAM after profile switches to prevent OMAPI channel contention (`TRANSMIT_FAILED`) and NVRAM exhaustion, while retaining SM-DP+ `Delete` notification reporting.
  - Incoming SMS & OTP forwarding to Telegram Bot or HTTPS Webhook with Android Keystore AES-GCM credential encryption and local SMS forwarding history UI (up to 100 entries, copy/delete/clear).
  - Interactive Telegram Bot control plane (`setMyCommands` native menu, Inline Keyboard button dashboard, `callback_query` toast feedback, direct `LPA:1$...` paste download) + LAN/Tailscale HTTP REST API & dark-mode Web UI (`:8787`).
  - Public build with all personal Telegram Bot tokens/chat IDs removed.

## [0.0.8-beta0.14+14]

### Fixed
- Sync `_session` with `savedDefault` in `setDefaultProfile` and `_restoreFallback`, and check `savedDefault?.iccid ?? _session?.defaultIccid` when deleting or reverting profiles so a former default profile is no longer blocked from deletion after setting a new default profile.

## [0.0.8-beta0.13+13]

### Fixed
- Allow GSMA Root CI TLS certificates on `SmdpClient` ES9+ connections (`rsp.truphone.com`, etc.), fixing `HandshakeException: CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate` when downloading eSIM profiles while keeping eUICC hardware signature verification (`ES10b.AuthenticateServer`) intact.

## [0.0.8-beta0.12+12]

### Added
- Add one-click Speedtest public test eSIM (`LPA:1$rsp.truphone.com$QRF-SPEEDTEST`) download test option in `DownloadProfilePage`, `SmsRelayPage`, Web UI dashboard, and Telegram Bot.
- Upgrade Telegram Bot with interactive Inline Keyboard button panels (`inline_keyboard`), `callback_query` button execution + toast feedback (`answerCallbackQuery`), native slash command menu registration (`setMyCommands`), and direct `LPA:1$...` message recognition.

## [0.0.8-beta0.11+11]

### Added
- Add persistent SMS forwarding history in `SmsRelayPage` showing full forwarded message content, sender, SIM slot/carrier, delivery status, copy button, single-entry deletion, and one-tap clear-all.
- Add in-app Remote eSIM Control Panel in `SmsRelayPage` and `/help` Telegram menu supporting remote eSIM profile download (`/download`, `/download_test`), two-step safe profile deletion (`/delete`, `/delete_confirm`) with automatic SM-DP+ delete notification reporting, and profile switching.

## [0.0.8-beta0.10+10]

### Fixed
- Enable automatic local deletion (without server upload) of `Enable` and `Disable` SGP.22 notifications after profile switches (`notifProcessAfterSwitch = true`, `notifDeleteWithoutSendingEnable = true`, `notifDeleteWithoutSendingDisable = true`), skipping full certificate reads and running after SIM `REFRESH` / baseband registration completes so chip NVRAM never fills up and OMAPI channels never collide.
- Filter out emergency-only / no-service placeholder carrier strings (`只能拨打紧急求助电话`, `Emergency calls only`, `无服务`) and guard against 1-second stale pre-switch `inService` snapshots before SIM reset completes.
- Shorten profile switch cooldown from 30 seconds to 6 seconds with a friendly Telegram wait message.
## [0.0.8-beta0.08+8]

### Fixed
- Detect both CS voice (`ServiceState.state`) and 4G/5G PS data (`NetworkRegistrationInfoList`) roaming/home registration in `NetworkStatusPlugin`, synchronously read `serviceState` and `signalStrength` on `refresh`, and poll baseband status every 2 seconds while `RemoteGatewayService` awaits network registration.
- Stop reopening an ISD-R OMAPI channel immediately after a successful `enableProfile` with `refreshFlag`, avoiding `6985` card-busy contention while the handset modem processes the SIM `REFRESH`.
- Persist the SMS forwarding toggle immediately in `SmsRelayPage` and avoid overwriting in-progress UI state on `AppLifecycleState.resumed`.
- Pre-configure the test Telegram Bot Token and Chat ID in `SmsRelayStore` and auto-start the remote gateway on launch.

## [0.0.7-beta0.07+7]

### Security
- Remove the global `HttpOverrides` and per-client `badCertificateCallback` TLS bypass from `SmdpClient` and `NotificationsScreen`, preventing SM-DP+ requests from disabling certificate validation across the Dart VM.

### Fixed
- Initialize `OmapiPlugin` background thread and `SEService` on engine attach in the cached-engine Multi variant and keep `SEService` alive across `MainActivity` detach, enabling headless OMAPI operations after boot or after closing the UI.
- Wait for `SEService` connection readiness in `OmapiPlugin.handleConnect` and `getOrCreateSession` during cold headless startup, and retain `SharedPreferencesOmapiSafetyStore` durable crash/poison protection across all variants.
- Verify remote profile switches with `ProfileStateTransition`, hold `ForegroundCardSession` during remote card operations, and stop swallowing switch/revert failures in `RemoteGatewayService`.
- Recreate the Telegram `HttpClient` on gateway stop, hot-reload Telegram polling when credentials change at runtime, start/resume the gateway when Telegram control is configured even if SMS forwarding is off, and enable `/download`, `/download_test`, `/delete`, and `/delete_confirm` in Telegram command parsing (including multi-line arguments).
- Share a single broadcast stream in `NetworkStatusService` so pausing `NetworkStatusPage` does not cancel `RemoteGatewayService` baseband monitoring; re-register `SubscriptionsChangedListener` on `refresh` after runtime permission grants and fall back to active subscriptions when external readers do not embed a slot index in their reader ID.

## [0.0.6-beta0.06+6]

### Security
- Enforce standard TLS certificate validation for TS.43 entitlement connections; untrusted peers are rejected before credentials are sent.
- OTBridge 1.2.2 now requires explicit in-app consent for external applications, pinned to their installed package/UID. Public community signing keys do not grant access. Logical channels are isolated by caller UID; revocation also closes owned channels.

### Fixed
- Preserve permanent profile selections across gateway recovery instead of treating the zero/no-deadline marker as an expired timer; report no countdown for permanent sessions.
- Recheck default and active-session fallback protection at profile deletion confirmation, including changes made after the confirmation token was issued.
- Repair WebCard version-request UID generation and contain synchronous failures within the extension-unavailable fallback.

## [0.0.5-beta0.05+5]

### Fixed
- Forward long inbound SMS without the former 4096-character rejection; preserve Unicode across Telegram chunks.
- Remove the unconditional second `/back` message, so its failure cannot misreport an already-forwarded SMS as failed.
- Include available SIM slot, subscription ID and carrier in Telegram headers and webhook fields; missing metadata stays unknown.
- Allow explicitly confirmed negative Telegram group/channel IDs. Discovery remains private-only; selecting a group destination does not enable group control commands.
- Hold a timeout-bounded partial wake lock during asynchronous SMS delivery, releasing it on success, failure and queue rejection. This does not extend Android broadcast deadlines or provide persistent retry.
- Keep displayed and platform version names consistent using the prerelease version `0.0.5-beta0.05` (build 5).

## [2.4.3+603] - 2026-10-31

### Fixed
- Restore standard iOS Bluetooth discovery so BeeSIM and other name-discovered readers are not excluded by AccessorySetupKit service filters.
- Keep Bluetooth reader setup errors inside the dialog error handler.
- Keep delivered notifications visible while they remain on the eUICC, and verify card removal before reporting success (#42).
- Preserve a minimal delivery receipt when local history is deleted, preventing an already delivered notification from being sent again (#42).
- Queue automatic notification processing after profile operations instead of losing requests during a concurrent badge refresh (#43).
- Send notifications without requiring an unrelated connectivity-probe server to be reachable (#43).

### Build and distribution
- Build Community and rooted Community Android APKs from public source without private credentials, verifying identical signed APKs across two clean builds.
- Publish shared build and release tooling in NekokoLPA2; keep brand data and distribution credentials separate.

## [2.4.2+602] - 2026-10-31

### Fixed
- Keep iOS AccessorySetupKit registration out of the shared macOS Bluetooth implementation.
- Close released cached OMAPI channels immediately when Android enters the background, addressing the restart safety-marker path reported in #58. Keep active operations and reboot protection after a real channel-close failure.
- Retry WebCard AID selection on the basic channel when a driver allocates a logical channel but SELECT returns 6881 (#31).

### Added
- Recognize the optional ATR eUICC capability flag and show OMAPI users a notice about keeping the SIM/eSIM slot enabled in Android system settings.
- Published the 3HK number, line-expiry and package-status plugin. All provider plugins now live in the public repository.
- Added iOS accessory setup for supported Bluetooth readers.

### Changed
- Name the public Android variant Community, retaining the existing package ID and signing certificate for upgrades. Desktop and web builds use NekokoLPA 2.
- Publish the shared Windows/Linux builds to standard desktop update feeds, retaining earlier channel and filename compatibility.
- Move Crowdin synchronization, validation and translation documentation into NekokoLPA2.

### Upgrade notes
- An existing reboot-required OMAPI marker still needs one device restart after updating; clearing app data is unnecessary.
- Xiaomi and WebCard fixes have automated regression coverage; confirmation on the affected hardware is pending. See [issue review](docs/issue-audit-602.md).

## [2.4.1+601] - 2026-10-29

### Performance
- Initialize tabs on first visit and pause inactive Flutter animations while retaining page state.
- Isolate settings-row repaint work, cache profile-size/icon misses, and index/cache size predictions with reference parsing outside the mobile UI isolate.

### Added
- Published eSIM.cc rewards/portal integration and eSIM.gg number, balance and package status integration.

### Fixed
- Clear the OMAPI crash guard only at a verified channel-free idle checkpoint, preventing normal app restarts from hiding built-in readers. Actual failed channel cleanup remains reboot-required.
- Wait for asynchronous OMAPI service connection, refresh discovery when it connects, honor forced reader refresh and show reboot-required discovery errors instead of an empty-reader prompt.
- Keep built-in reader defaults available if an installed OTBridge provider fails discovery.

### Upgrade notes
- If 2.4.0 already left OMAPI blocked with a reboot-required safety marker, install this update and restart the device once. Clearing app data is not required.
- Scrolling work has been reduced and regression-tested; physical-device frame timing has not yet been measured.

## [2.4.0+600] - 2026-10-28

### Added
- Published TYBLE reader support.
- Published experimental desktop VoWiFi/SMS for Windows, macOS and Linux, with explicit opt-in and the existing 9eSIM-build restriction.
- Published plain-SIM identity and operator probing for readers that support raw APDUs.
- Added eSTK.me slot selection, Android SE HAL readers and profile database import/export.
- Moved OTBridge source and APK/Magisk/KernelSU module builds into NekokoLPA2.
- Retained full rooted Android APK/module builds alongside normal and helper-based installations.

### Fixed
- Fixed 9eSIM B0 Plus detection for eight-digit advertised names and authentication using the advertised device UID.
- Enforced the Android and OMAPI VoWiFi restrictions at reader and service entry points.
- Improved desktop IMS authentication with quoted Digest challenges, MCC-independent qop negotiation, AUTS resynchronization, binary RES handling and nonce counts.
- Matched SIP final responses to their transactions, retained registration service routes, honored Min-Expires and serialized overlapping socket writes.

### Documentation
- Added a README banner, getting-started and build instructions, VoWiFi restrictions, troubleshooting and an IMS research/verification guide.

## [2.2.5+587] - 2026-09-24

### Changed
- The macOS app requires macOS 12 or later.

### Fixed
- eUICC signing requests from websites accept a non-standard IMEI or TAC given as integers, instead of failing with "IMEI integer must contain exactly 15 decimal digits".
- When a profile fails to install, the reason (such as insufficient memory) is shown even on cards holding many install notifications, instead of an APDU error over Bluetooth readers.

## [2.2.4+586] - 2026-08-29

### Fixed
- Confirmation codes are hashed over the transaction identifier itself rather than its text form, so a server that issues a short identifier no longer rejects a correct code.
- Carrier eSIM transfers send the device IMEI in the right digit order; carriers that validate it no longer refuse the transfer.
- USB card readers release their connection when disconnected, instead of leaking one per session until connecting stopped working.
- Profile downloads give up on an unresponsive server instead of waiting indefinitely, and the screen now explains why it cannot be dismissed mid-operation.
- Rejecting a previewed profile ends the session with the server, so the next attempt is not refused as already in progress.
- Reader actions such as loading the current SIM to VoWiFi act on the profiles currently on the card rather than a stale list.

## [2.2.1+583] - 2026-08-11

### Fixed
- Fixed eUICC signing when a valid 15-digit IMEI is supplied as unsigned integer bytes.

## [2.1.5+575] - 2026-07-10

### Added
- Added Russian localization from Crowdin.

## [2.1.4+574] - 2026-07-10

### Fixed
- Show and edit the device TAC instead of the internal 16-digit stored IMEI encoding.
- Use TAC `35383741` by default while still accepting a full 15-digit IMEI.

## [2.1.0+569] - 2026-06-01

### Changed
- Prepared public store branding and standard platform icons.
- Restricted GitHub release publishing to the release branch.

## [2.0.10+568] - 2026-05-24

### Added
- Added distinct OMAPI and Telephony API reader icons.
- Added notification send, delete, and completion animations with a session-only pause control.

### Changed
- Improved eSIM switching stability across OMAPI and Telephony API readers.
- Notification processing now follows auto-trigger settings unless paused by the user.

### Fixed
- Fixed launch-time eSIM switching failures and reader deduplication for channels pointing at the same card.
- Fixed notification count taps showing stale sent notifications before fresh metadata finishes loading.

## [2.0.8+564] - 2026-04-03

### Added
- Android now detects rooted devices and shows that OTBridge can be used to enable Telephony support and bypass OMAPI ARA-M restrictions.

### Changed
- Android prefers the external OTBridge provider path when present.
- Android CI no longer builds the privileged NekokoLPA2 variant.

## [2.0.4+555] - 2026-02-15

### Added
- Improved eSTK.me Card support

## [2.0.2+543] - 2026-01-25

RemoCard v2.0 and minor UI fixes

## [2.0.2+542] - 2026-01-25

Added a browser with signing capabilities.

## [2.0.2+541] - 2026-01-25

Profile Size Predictions, Optimized Reset Flag

## [2.0.2+540] - 2026-01-24

### Added
- **IMEI**: Added IMEI to settings.

### Fixed
- **Wrong IMEI generation**: Fixed wrong IMEI generation. Previously it might contain non-numeric characters.

## [2.0.2+538] - 2026-01-22

### Changed
- **Version**: Bumped version to 2.0.2+538 to make Apple Happy.

### Fixed
- **TMAPI Handling**: Now it should work on Android 13- devices.
- **Remote Card Handling**: Now it should work again.

### Added
- **Download Size Prediction**: Allow predicting download size before downloading.

## [2.0.1+537] - 2026-01-22

### Changed
- **Version**: Bumped version to 2.0.1+537 to allow upgrading

### Added
- **Size Data Migration**: Now it's possible to read from v1 App's size stats and migrate them to v2 App with same package name.

## [2.0.1+35] - 2026-01-22

### Added
- **EUICC Signatures**: Added EUICC Signatures support.
- **Connection Stability**: Improved how the app manages smart card connections to prevent "channel busy" errors and ensure smoother profile loading.

## [2.0.1+34] - 2026-01-21

### Added
- **Deep Link Direct Download**: Added Deep Link Direct Download support. Now you can use urls to download profiles directly from the app, including webviews.

## [2.0.1+33] - 2026-01-20

### Added
- **Deep Linking Support**: Added Deep Linking support. Now you can use urls such as https://install.lpa.ee/LPA:1$smdp.example$MATCHING-ID to open the app.


## [2.0.0+32] - 2026-01-20

### Added
- **Linux Support**: Added Linux support.

## [2.0.0+31] - 2026-01-19

### Improved
- **Connection Stability**: Improved how the app manages smart card connections to prevent "channel busy" errors and ensure smoother profile loading.
- **Better User Feedback**: Fixed a bug where the app showed "Not Connected" while still trying to connect to a reader.
- **Connection Recovery**: Added easy "Cancel" and "Retry" buttons if a connection to a card reader takes too long.


## [2.0.0+30] - 2026-01-18

### Added
- **Variant-Specific Branding**: Added dynamic logos for app variants.
- **Improved Variant Detection**: Support for variants via package name and build environment.

### Fixed
- **Rooted Device Support**: Robustified Telephony/TMAPI plugin to prevent crashes on high-privileged builds on some devices.

## [2.0.0+29] - 2026-01-17

### Fixed
- **Multi-Language Support**: Improved translations.
- **Bluetooth Connection**: Improved Bluetooth connection handling.

## [2.0.0+28] - 2026-01-15

### Added
- **Multi-Language Support**: Added support for Spanish, French, Japanese, and Chinese.
- **Bluetooth-on-Windows Support**: Added support for Bluetooth on Windows.

## [2.0.0+27] - 2026-01-14

### Added
- **Phone Number Parsing**: Customizable E.164 / National Number Parsing

### Fixed
- **Card Switch Handling**: Better support for Android on OMAPI

## [2.0.0+26] - 2026-01-14

### Added
- **Custom Profile Icons**: Set custom icons for profiles from gallery, remote Nekoko icons, or eSIM card icons
- **Copy ICCID**: Quick copy profile ICCID to clipboard from context menu
- **Enhanced Tag Notifications**: Tag-based notification scheduling system

### Changed
- **Compact UI**: Improved space efficiency on small screens with scrollable dialogs and menus

### Fixed
- **Permission Handling**: Better support for Linux/macOS with clear unsupported platform messages
