# eUICC-Nexus

<p align="center">
  <b>基于 Android 备用机的远程多国 eSIM (eUICC) 切卡、基带漫游监控与短信/验证码转发网关</b><br/>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square" alt="MIT License" /></a>
  <a href="https://github.com/iebb/NekokoLPA2"><img src="https://img.shields.io/badge/Upstream-NekokoLPA2-6E56CF?style=flat-square" alt="Based on NekokoLPA2" /></a>
  <a href="https://github.com/MIY-Y/eUICC-Nexus/releases"><img src="https://img.shields.io/badge/Release-v1.3.1-orange?style=flat-square" alt="Release v1.3.1" /></a>
  <a href="https://linux.do"><img src="https://img.shields.io/badge/Community-LINUX%20DO-f09433?style=flat-square" alt="LINUX DO 社区" /></a>
</p>

> **开源声明**：本项目基于 [iebb/NekokoLPA2](https://github.com/iebb/NekokoLPA2)（及 [OTBridge](https://github.com/iebb/OTBridge)、[remocard](https://github.com/iebb/remocard)）二次开发，遵循 [MIT License](LICENSE)；设计参考了 [cyDione/eSIM-SMS-Forwarder](https://github.com/cyDione/eSIM-SMS-Forwarder) 与 [SmsForwarder](https://github.com/pppscn/SmsForwarder)，并感谢 [LINUX DO 社区](https://linux.do) 支持。`NekokoLPA` 为 `SIMLINK LTD.` 注册商标，本项目由第三方独立维护，非官方产品（详见 [`NOTICE`](NOTICE) / [`BRANDING.md`](BRANDING.md)）。仅供个人管理自有合法 eSIM，严禁用于非法接码或未授权设备监控。

---

## 核心功能

将插有可插拔 eUICC 芯片（**9eSIM / ESTKme / esim.gg / SakuraSIM** 等）的闲置 Android 手机变为无人值守的远程接码与保号网关：

- **🤖 Telegram 全按钮远控**：左下角原生菜单 + 内联按钮面板，支持一键**持久切卡**、**5 分钟临时接码（自动切回主卡）**、**二步确认删卡**、**远程改备注 (`/rename`)** 及**双卡槽/读卡器切换 (`/readers`)**。
- **📷 直接发送二维码图片远程下卡**：在 Telegram 直接发送 **eSIM 二维码图片**或粘贴 `LPA:1$...` 激活码即可远程写卡（内置 Speedtest 测试卡一键体验）。
- **📡 4G/5G 漫游搜网状态机**：同时监听 CS 语音域与 PS 数据域（兼容纯流量漫游卡），过滤切卡瞬间旧卡缓存与“仅限紧急呼叫”，真实挂上基站后主动汇报运营商、信号强度 (`dBm`) 与**芯片剩余空间 (`KB`)**。
- **🔑 验证码单击复制 + 失败重发 + 来电提醒**：自动提取短信验证码并以 `<code>123456</code>` 置顶（在 TG 中点一下即复制），短信下方直接附带 **`[ 🏠 切回主卡 ]`** 按钮；内置网络闪断指数退避重试队列与呼入来电振铃提醒。
- **🛡️ 定时自动保号 (`/keepalive`) & 芯片闪存自洁**：支持按周期（如每 90 天）自动切卡漫游驻网 3 分钟后切回主卡；切卡稳定后本地静默秒清 `Enable/Disable` 通知，避免 `TRANSMIT_FAILED` 信道冲突与芯片闪存写满。
- **🔋 备用机断电 / 低电量告警 & Tailscale API**：实时监控手机电量、充电与温度状态，意外断电或低电量自动告警；同时提供 `:8787` 暗色 Web 面板与 REST API。
- **🩺 硬件与接口深度自愈诊断 & 一键排查报告**：空卡槽/未识别读卡器时原位展开诊断卡片，内置 10 种常见硬件与 ROM 根因分析，并提供一键脱敏排查报告复制功能，无需翻找底层 log 即可秒级定位问题。

---

## 3 分钟快速上手

1. **安装授权**：将 eUICC 芯片插入备用机，下载安装 [Releases 中的 `eUICC-Nexus-v1.3.1.apk`](https://github.com/MIY-Y/eUICC-Nexus/releases/tag/v1.3.1)（**全签名合一版**：单个安装包同时内置 **ESTK / NekokoLPA `c47350...` + 9eSIM `d1c0f4...` + SakuraSIM `65d057...`** 三套证书，通杀主流实体卡与小白卡；**v1.3 新增空卡槽深度自愈诊断与一键复制排查报告**）；在 App 内授予电话、短信与通知权限并将省电设为**「无限制」**。
2. **绑定 Telegram Bot**：
   - 找 [`@BotFather`](https://t.me/BotFather) 发送 `/newbot` 创建机器人并复制 **Bot Token**；
   - 在 Telegram 给你的机器人发送一次 `/start`；
   - 打开 App「短信转发」页 ➔ 填入 Token ➔ 点击 **「自动发现私聊 ID」** ➔ 开启开关并点击 **「保存配置」**。

---

## 💡 ESTKme 实体卡使用指南

本项目已原生适配 ESTK 全系列芯片，**开箱即用，无需使用电脑读卡器手动向卡内导入 ARA-M 证书**。

### 1. 支持型号
- **ESTKme ECO / Plus / C 系列**：单芯片结构，插卡即识别为单一卡槽。
- **ESTKme MAX (双芯片版)**：单卡内置独立双芯片（**SE0 主芯片 / SE1 副芯片**），本项目已深度解决多通道并发冲突，支持无缝双芯片热切。

### 2. 快速使用步骤
1. **插卡识别**：将 ESTKme 插入手机 SIM 槽（推荐插在闲置的 `SIM 2` 槽）；
2. **安装应用**：安装 [Releases 中的 `eUICC-Nexus-v1.3.1.apk`](https://github.com/MIY-Y/eUICC-Nexus/releases/tag/v1.3.1)（内置 ESTK 官方出厂 ARA-M 证书 `C47350...`）；
3. **读取卡片**：打开 App，首页将通过手机系统内置 OMAPI 自动读取卡内所有 Profile、芯片剩余闪存空间 (`Free NVRAM KB`) 与 `EID`；
4. **远程切卡与保号**：绑定 Telegram Bot 后，即可远程通过 `/list` 随时切卡，或通过 `/keepalive` 配置每 90/180 天全自动驻网保号。

### 3. 卡内 ARA-M 规则与密钥配置明细 (白名单配置)

> **注意**：安装本项目 Releases 提供的 `eUICC-Nexus-v1.3.1.apk`（全签名合一版），正常出厂的 ESTK 实体卡**默认已自带该证书，插卡即可直接识别使用**。  
> **但如果你的卡片被误清空过、使用了早期空白卡、或者出现 `Access Denied by ARA-M` 报错**，请打开 **ESTKme 官方 App**、**手机自带 STK 菜单**、**EasyEUICC** 或 **PC 读卡器工具**，手动添加以下规则：

#### 🔑 核心密钥参数（直接复制粘贴）

| 配置项 (Field) | 填写内容 (Value) | 说明 |
| :--- | :--- | :--- |
| **规则名称 (Name)** | `eUICC-Nexus` 或 `NekokoLPA` | 自定义标识名称 |
| **应用 AID (Target AID)** | `A0000005591010FFFFFFFF8900000100` | GSMA ISD-R 根应用 AID（部分工具若支持通配可填 `FFFFFFFFFFFF`） |
| **证书哈希 (SHA-1)** | **`C47350C7BA682B34A3E584A0D58463EA42B1AD73`** | **【必填】ESTK / NekokoLPA 官方证书指纹** |
| **证书哈希 (SHA-256)** | `4139278AACCE8338C03DC9A6B0172C1880E0A4949FF3E05292C2E781765026FA` | 备用（部分新版 GlobalPlatform ARA-M 工具要求 SHA-256 时填入） |
| **权限 (Permission)** | `01` / `Always Allowed` / `允许全部 APDU` | 允许执行切卡、读写与删除 APDU 指令 |

#### 📋 一键复制（SHA-1 证书指纹）
```text
C47350C7BA682B34A3E584A0D58463EA42B1AD73
```

*(如果你的卡槽中还混插了 9eSIM 或其他小白卡，对应出厂 SHA-1 如下，安装本项目的全签名 APK 均已自动兼容：)*
- **9eSIM 原厂 SHA-1**：`D1C0F48B370E74D4EA4770ED4C3CD70A3198D31F`
- **SakuraSIM (小白卡) 原厂 SHA-1**：`65D0571854AFEC519A90F92D7C5D8CF8148DA373`

---

#### 📱 三种添加方式（保姆级步骤）

- **方式一：通过手机自带的「SIM 卡应用 / STK」添加（无需任何外置读卡器）**：
  1. 手机插入 ESTK 卡，打开系统设置 ➔ 找到 **「SIM 卡应用」**（或「STK」/「SIM Toolkit」）；
  2. 点击进入 **ESTKme 菜单** ➔ 选择 **「ARA-M」** ➔ **「Add Rule (添加规则)」**；
  3. 在证书哈希输入框粘贴上方 SHA-1：`C47350C7BA682B34A3E584A0D58463EA42B1AD73`；
  4. 确认保存并重启手机飞行模式生效。

- **方式二：通过 ESTKme 官方手机 App 添加**：
  1. 打开 ESTKme 官方 App ➔ 点击底部 **「设置 (Settings)」** ➔ 选择 **「ARA-M 管理」**；
  2. 点击右上角 **「+」** 新建规则；
  3. **AID** 填入 `A0000005591010FFFFFFFF8900000100`（或勾选 ISD-R）；
  4. **SHA-1** 填入 `C47350C7BA682B34A3E584A0D58463EA42B1AD73`，权限选择 **`Always / 允许`**，保存即可。

- **方式三：通过电脑 USB 读卡器 + EasyEUICC / GlobalPlatformPro (gp.exe)**：
  - 将 ESTK 卡插入电脑 PC/SC 智能卡读卡器，打开 EasyEUICC ➔ 切换到「ARA-M Rules」标签页 ➔ 点击「Add」➔ 粘贴上述 SHA-1 保存即可。

### 4. ESTKme MAX 双芯片 (SE0 ⇄ SE1) 切换
ESTK MAX 内部拥有两颗独立的物理安全元件。在 eUICC-Nexus 中无需拔卡即可自由切换管理两颗芯片：
- **App 端切换**：进入 App 首页，点击顶部读卡器栏，在下拉菜单中直接点选 **`ESTK Max SE0 (主芯片)`** 或 **`ESTK Max SE1 (副芯片)`**，系统将自动重新枚举并展示对应芯片内的 Profile 列表；
- **Telegram 远程切换**：发送 `/readers` 指令，机器人会弹出卡槽与芯片切换按钮，点击对应按钮即可秒级远程切至目标芯片。

### 5. 远程发送二维码下卡
- 在 Telegram 聊天框中**直接发送一张 eSIM 二维码截图/照片**（网关内置图像预处理与反相容错引擎，无需手工裁剪），系统自动识别 `LPA:1$...` 并直接写入当前激活的 ESTK 芯片中；
- 也支持直接发送纯文本激活码（如 `LPA:1$smdp.example.com$MATCHING-ID`）下卡。

### 6. 常见问题 (FAQ)
- **Q：为什么提示「请连接兼容的读卡器以开始」？**  
  A：检查 App「设置」->「读卡器类型」中「内置 OMAPI」是否开启。如果开启后依然空白，查看首页原位展开的**「硬件诊断报告」**，若显示手机 ROM 缺少 `featureOmapiUicc` 或返回 0 个读卡器，说明该手机系统阉割了 OMAPI 接口，需配合 Root + OTBridge，或搭配 ESTK 官方 USB/蓝牙读卡器使用。
- **Q：为什么提示「访问被拒绝 (Access Denied by ARA-M)」？**  
  A：请确认安装的是 Releases 发布的 `eUICC-Nexus-v1.3.1.apk` 全签名合一版。若曾使用第三方工具清空过卡内白名单，可进入手机系统自带的「SIM 卡应用 / STK」菜单恢复默认，或使用 ESTK 官方桌面工具重置卡片。
- **Q：高频切卡会磨损卡片闪存吗？**  
  A：不会。网关内置 NVRAM 防磨损冷却锁，并在每次切卡稳定后**自动在芯片本地静默清除安装/禁用通知日志**，彻底防止 ESTK 芯片有限的闪存空间被日志写满。

---

## Telegram 常用指令

| 指令 / 操作 | 说明 |
| :--- | :--- |
| `/list` | 查看卡内 eSIM 列表、**芯片剩余空间 (KB)**、**EID**，通过下方按钮一键切卡 / 5分接码 / 删卡 / 改名 |
| `/status` | 查看当前基带漫游注册、运营商、信号 (`dBm`)、**备用机电量/温度**及芯片空间 |
| `/use <序号>` / `/use_temp <序号>` | 持久切换到指定卡 / 临时切换 5 分钟接码后自动切回默认主卡 |
| `/keepalive` | 定时自动切卡保号管理（设置每 N 天自动驻网 3 分钟保号，或立即执行保号） |
| `/rename <序号> <新名称>` | 远程修改卡片备注名称（例：`/rename 2 英国主力 +44`） |
| `/readers` | 远程查看并切换操作卡槽或外置读卡器（如 `SIM 1 ⇄ SIM 2`） |
| **发送二维码图片** 或 `LPA:1$...` | 自动识别二维码图片或激活码文本并远程下载写入 eSIM |
| `/default` / `/back` | 将当前激活卡设为默认主卡 / 立即切回默认主卡 |
| `/delete <序号>` | 发起二步确认删卡（自动向 SM-DP+ 发送释放通知） |

---

## 开源协议

[MIT License](LICENSE) · 基于 [iebb/NekokoLPA2](https://github.com/iebb/NekokoLPA2) 构建 · 社区支持：[LINUX DO](https://linux.do)
