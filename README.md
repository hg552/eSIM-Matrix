# eSIM-Matrix

<p align="center">
  <b>基于 Android 备用机的远程多国 eSIM (eUICC) 切卡、基带漫游监控、3D 异构海外环境联动（SIM + 代理 + 虚拟定位）与短信/验证码转发网关</b><br/>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square" alt="MIT License" /></a>
  <a href="https://github.com/iebb/NekokoLPA2"><img src="https://img.shields.io/badge/Upstream-NekokoLPA2-6E56CF?style=flat-square" alt="Based on NekokoLPA2" /></a>
  <a href="https://github.com/MIY-Y/eSIM-Matrix/releases"><img src="https://img.shields.io/badge/Release-v1.3.5-orange?style=flat-square" alt="Release v1.3.5" /></a>
  <a href="https://linux.do"><img src="https://img.shields.io/badge/Community-LINUX%20DO-f09433?style=flat-square" alt="LINUX DO 社区" /></a>
</p>

> **开源声明**：本项目基于 [iebb/NekokoLPA2](https://github.com/iebb/NekokoLPA2)（及 [OTBridge](https://github.com/iebb/OTBridge)、[remocard](https://github.com/iebb/remocard)）二次开发，遵循 [MIT License](LICENSE)；设计参考了 [cyDione/eSIM-SMS-Forwarder](https://github.com/cyDione/eSIM-SMS-Forwarder) 与 [SmsForwarder](https://github.com/pppscn/SmsForwarder)，并感谢 [LINUX DO 社区](https://linux.do) 支持。`NekokoLPA` 为 `SIMLINK LTD.` 注册商标，本项目由第三方独立维护，非官方产品（详见 [`NOTICE`](NOTICE) / [`BRANDING.md`](BRANDING.md)）。仅供个人管理自有合法 eSIM，严禁用于非法接码或未授权设备监控。

---

## 核心功能

将插有可插拔 eUICC 芯片（**9eSIM / ESTKme / esim.gg / SakuraSIM** 等）的闲置 Android 手机变为无人值守的远程接码、保号与海外环境联动网关：

- **🌐 3D 异构海外环境联动 (3D Overseas Environment Linkage)**：
  - **维度一 · SIM 身份与基带 (Cellular SIM Domain)**：无需拔插卡，秒级远程切换物理 eSIM Profile；支持持久切卡与 **5 分钟临时接码（倒计时结束后全自动切回默认主卡）**；支持双卡槽热切与 ESTK MAX 双芯片 (`SE0 ⇄ SE1`) 切换；4G/5G 漫游搜网状态机同时监听 CS 语音域与 PS 数据域，上报运营商、信号强度 (`dBm`) 与**芯片剩余闪存空间 (`KB`)**。
  - **维度二 · FlClash 代理节点联动 (Proxy Linkage)**：本地无缝对接 FlClash / Mihomo / sing-box 外部控制器（默认 `127.0.0.1:9090`）。切卡时秒级将指定策略组（如 `PROXY`）自动切换至与目标卡国家严格匹配的海外落地节点（支持 **ICCID 专属定向绑定** 与国家 Emoji/ISO/区号智能推导）；内置**漫游流量卫士 (Data Guard)** 自动锁死蜂窝移动数据与漫游开关，严防高额漫游资费偷跑；临时接码超时或切回主卡时**自动快照还原原始代理节点**。
  - **维度三 · 免 Root 虚拟定位 (Rootless GPS Mock & Fused Location)**：根据目标卡归属地自动将系统级 GPS 经纬度伪装至对应国家城市（预设香港尖沙咀、美国洛杉矶、英国伦敦、日本东京、爱沙尼亚塔林等）；支持「系统模拟位置」与「Shizuku 系统级 Fused Location 注入」两种免 Root 方案；切回主卡自动复原。**彻底解决海外平台（PayPal / WhatsApp / 银行 / 社交应用）因“出网 IP / SIM 归属地 / GPS 定位”三者冲突触发的异地高危风控**。
- **🤖 Telegram 全按钮远控**：左下角原生菜单 + 内联按钮面板，支持一键**持久切卡**、**5 分钟临时接码**、**二步确认删卡**、**远程改备注 (`/rename`)**、**读卡器切换 (`/readers`)**、**代理节点管理 (`/proxy`, `/proxy_node`)**、**流量卫士控制 (`/guard`)** 与**定时保号 (`/keepalive`)**。
- **📷 直接发送二维码图片远程下卡**：在 Telegram 聊天框直接发送 **eSIM 二维码图片**（内置图形预处理与反相容错引擎，无需手工裁剪）或粘贴 `LPA:1$...` 激活码即可远程写卡（内置 Speedtest 测试卡一键体验）。
- **🔑 验证码单击复制 + 失败重发 + 来电提醒**：智能提取 4~8 位数字与 `G-xxxxxx` 验证码并以 `<code>123456</code>` 置顶（在 Telegram 中点一下即复制），短信下方附带 **`[ 🏠 切回主卡 ]`** 快捷按钮；内置网络闪断指数退避重试队列与呼入来电振铃提醒。
- **🛡️ 定时自动保号 (`/keepalive`) & 芯片闪存自洁**：支持按周期（如每 90/180 天）全自动切卡漫游驻网 3 分钟后切回主卡；切卡稳定后本地静默秒清 `Enable/Disable` 通知，避免 `TRANSMIT_FAILED` 信道冲突与 NVRAM 闪存写满。
- **💻 暗色 Web 控制台 (`:8787`) & REST API**：提供轻量现代化的暗色 Web 仪表盘与完整 REST API，支持局域网或 Tailscale 异地虚拟内网直接访问，提供整机状态概览、一键切卡、3D 联动配置、FlClash 测通与短信/验证码实时收件箱。
- **🔋 备用机断电 / 低电量告警**：实时监控手机电量、充电与温度状态，意外断电、拔线或低电量自动推送 Telegram 紧急告警。
- **🩺 硬件与接口深度自愈诊断 & 一键排查报告**：空卡槽/未识别读卡器时原位展开诊断卡片，内置 10 种常见硬件与 ROM 根因分析，并提供一键脱敏排查报告复制功能，秒级定位 OMAPI / QRTR / SE HAL 接口问题。
- **🔔 自动检查新版本 & Telegram 推送**：App 启动与网关常驻时自动检查更新，发现新版本直接推送通知（含更新日志与下载地址）。

---

## 3 分钟快速上手

1. **安装授权**：将 eUICC 芯片插入备用机（推荐插在 `SIM 2` 槽），下载安装 [Releases 中的最新版 APK](https://github.com/MIY-Y/eSIM-Matrix/releases)（**全签名合一版**：单个安装包内置 ESTK `c47350...` + 9eSIM `d1c0f4...` + SakuraSIM `65d057...` 三套证书）；在 App 内授予电话、短信、定位与通知权限，将系统省电策略设为**「无限制」**。
2. **绑定 Telegram Bot**：
   - 找 [`@BotFather`](https://t.me/BotFather) 发送 `/newbot` 创建机器人并复制 **Bot Token**；
   - 在 Telegram 给你的机器人发送一次 `/start`；
   - 打开 App「短信转发」页 ➔ 填入 Token ➔ 点击 **「自动发现私聊 ID」** ➔ 开启开关并点击 **「保存配置」**。
3. **启用 3D 联动（可选）**：
   - 在「短信转发」页开启 **「代理联动」**（填写 FlClash External Controller `http://127.0.0.1:9090`）与 **「免 Root 虚拟定位联动」**，实现切卡时代理节点与 GPS 定位自动同步。

---

## 🌐 3D 异构海外环境联动实操指南

### 1. 为什么需要 3D 海外环境联动？
在跨境场景（注册/登录 PayPal、Stripe、WhatsApp、Telegram、海外银行如 Wise/OCBC/HSBC、TikTok 等），平台风控会同时交叉校验三组维度：
1. **SIM 身份**：手机插入的 SIM 运营商、国家代码 (MCC/MNC)、电话号码属地；
2. **网络出口 IP**：网络流量出口的 GeoIP 归属地与网络类型；
3. **物理定位**：Android 系统 GPS / Fused Location 经纬度及基站网络定位。

传统方案中，用户往往只换了卡，出网 IP 依然是国内或与 SIM 卡属地不符，且真实物理 GPS 暴露无遗，极易触发异地欺诈风控被封。  
**eSIM-Matrix 3D 联动引擎** 在切卡时实现原子级协同切换：
```text
远程触发切卡 (/use_temp 2)
  │
  ├─ 1. SIM 域：物理切卡 ➔ 漫游基站搜网注册 ➔ 上报运营商与信号
  ├─ 2. 代理域：漫游流量卫士锁死蜂窝 ➔ FlClash 策略组自动切至目标国落地节点
  └─ 3. 位置域：免 Root 系统级注入目标国经纬度 (如香港尖沙咀 / 洛杉矶)
  │
临时接码 5 分钟超时或收到验证码后点击 [ 🏠 切回主卡 ]
  │
  └─ 全自动回滚：切回主卡 ➔ 还原原始代理节点 ➔ 注销虚拟定位恢复真实 GPS
```

### 2. FlClash / Mihomo 代理联动配置
1. **FlClash 侧设置**：
   - 打开 FlClash ➔「设置」➔ 找到「外部控制 (External Controller)」；
   - 监听端口设为 `9090`（即 `127.0.0.1:9090`）；
   - 设置「控制密钥 (Secret)」（如无密码可留空）。
2. **eSIM-Matrix App 侧配置**：
   - 进入 App「短信转发」页 ➔ 下滑找到「切卡自动化联动」；
   - 开启「启用切卡自动联动代理」；
   - Controller 地址填入 `http://127.0.0.1:9090`，填入 Secret，目标策略组填入 `PROXY`（或你的代理组名称）；
   - 开启「临时接码回滚时自动还原代理节点」；
   - 点击「测试连接」，提示 `🟢 已连接` 即可。
3. **每卡专属绑定（优先级最高）**：
   - 在 App 首页 Profile 列表，**长按任意卡片** ➔ 点击「🌐 指定代理节点」；
   - 可直接从当前 FlClash 订阅池中指定固定节点（如将某张香港卡固定绑定为 `🇭🇰 香港 HKBN 01`）；
   - 若未单独绑定，系统按「国旗 Emoji ➔ 两字母国家代码 (ISO) ➔ 国际区号 ➔ 运营商关键词」自动匹配对应节点。
4. **漫游流量卫士 (Data Guard)**：
   - 海外卡漫游资费极其高昂。切卡时漫游流量卫士会自动禁用移动数据与数据漫游，并强制网络走 Wi-Fi / FlClash 本地代理，杜绝天价漫游账单。

### 3. 免 Root 虚拟定位预设模板与自定义经纬度
切卡时，系统会自动根据目标卡国家匹配注入经纬度：

| 国家/地区 | 预设伪装城市 | 经纬度 (Latitude, Longitude) | 常见对应卡片 |
| :--- | :--- | :--- | :--- |
| **香港 (HK)** | 香港 (尖沙咀) | `22.3193, 114.1694` | ClubSim, 3HK, HK Mobile, CSL |
| **美国 (US)** | 洛杉矶 (Los Angeles) | `34.0522, -118.2437` | Saily, T-Mobile, Ultra Mobile, Tellus |
| **英国 (GB)** | 伦敦 (London) | `51.5074, -0.1278` | giffgaff, Vodafone UK, EE, O2 |
| **爱沙尼亚 (EE)** | 塔林 (Tallinn) | `59.4370, 24.7536` | Elisa, Tele2 |
| **日本 (JP)** | 东京 (Tokyo) | `35.6762, 139.6503` | Sakura Mobile, IIJmio, Rakuten |
| **新加坡 (SG)** | 新加坡 (滨海湾) | `1.3521, 103.8198` | Singtel, StarHub, Circles.Life |
| **德国 (DE)** | 法兰克福 (Frankfurt) | `50.1109, 8.6821` | Telekom DE, Vodafone DE |
| **荷兰 (NL)** | 阿姆斯特丹 (Amsterdam) | `52.3676, 4.9041` | KPN, Vodafone NL |
| **法国 (FR)** | 巴黎 (Paris) | `48.8566, 2.3522` | Orange FR, Free Mobile |
| **台湾 (TW)** | 台北 (信义区) | `25.0330, 121.5654` | 中华电信, 台湾大哥大 |

- **开箱即用预设模板**：切卡时根据目标卡的国家代码自动套用上方预设核心商务区坐标，无需繁琐设置。
- **自定义经纬度覆盖**：支持在 App 设置、Web 控制台或 REST API 中为特定卡（按 ICCID）单独指定专属经纬度坐标（例如自定义为海外真实合租地址、境外服务器托管机房或目标居住地）。
- **双免 Root 方案支持**：
  1. **系统模拟位置**（开发者选项中指定应用）：简单快捷，支持大部分日常场景；
  2. **Shizuku 底层 Fused Location 注入**：免开发者选项留痕，零被检出风险，直通系统底层融合定位引擎。
- **全自动安全还原**：无论通过 Telegram、Web 还是 API 触发切回主卡，或 5 分钟接码倒计时归零，系统自动注销测试 Provider 并关闭虚拟定位，立刻无缝恢复真实物理 GPS。
---

## 💡 ESTKme 实体卡使用指南

本项目已原生适配 ESTK 全系列芯片，**开箱即用，无需使用电脑读卡器手动向卡内导入 ARA-M 证书**。

### 1. 支持型号
- **ESTKme ECO / Plus / C 系列**：单芯片结构，插卡即识别为单一卡槽。
- **ESTKme MAX (双芯片版)**：单卡内置独立双芯片（**SE0 主芯片 / SE1 副芯片**），本项目已深度解决多通道并发冲突，支持无缝双芯片热切。

### 2. 快速使用步骤
1. **插卡识别**：将 ESTKme 插入手机 SIM 槽（推荐插在闲置的 `SIM 2` 槽）；
2. **安装应用**：安装 [Releases 最新版 APK](https://github.com/MIY-Y/eUICC-Nexus/releases)（内置 ESTK 官方出厂 ARA-M 证书 `C47350...`）；
3. **读取卡片**：打开 App，首页将通过手机系统内置 OMAPI 自动读取卡内所有 Profile、芯片剩余闪存空间 (`Free NVRAM KB`) 与 `EID`；
4. **远程切卡与保号**：绑定 Telegram Bot 后，即可远程通过 `/list` 随时切卡，或通过 `/keepalive` 配置每 90/180 天全自动驻网保号。

### 3. 卡内 ARA-M 规则与密钥配置明细 (白名单配置)

> **注意**：安装本项目 Releases 提供的全签名合一版 APK，正常出厂的 ESTK 实体卡**默认已自带该证书，插卡即可直接识别使用**。  
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

---

## ❓ 常见问题 (FAQ)

- **Q：如何开启免 Root 虚拟定位？「系统模拟位置」与「Shizuku 模式」有什么区别？**  
  A：免 Root 虚拟定位用于解决切卡后真实物理 GPS 暴露引发的风控问题。提供两种工作方案：
  - **方案一：系统模拟位置 (Developer Options，推荐，免 Root / 免额外工具)**
    - **实现原理**：使用 Android 标准的 `LocationManager.addTestProvider`（注册 `gps`, `network`, `fused` 三大位置提供者）。
    - **配置步骤**：
      1. 打开手机「设置」➔「关于手机」➔ 连续点击「版本号」7 次进入「开发者模式」；
      2. 进入「开发者选项」➔ 找到「选择模拟位置信息应用」(Select mock location app)；
      3. 在应用列表中选中 **eUICC-Nexus**（`ee.nekoko.nlpa2.multi`）；
      4. 返回 eUICC-Nexus App「短信转发」页 ➔「虚拟定位联动」，伪装方案选择「系统模拟位置」，开启开关后点击「测试定位注入」验证香港尖沙咀坐标是否生效。
  - **方案二：Shizuku 底层 FusedLocation 模式 (高级，免 Root 系统级静默伪装)**
    - **实现原理**：利用 Shizuku 具备的系统 Shell 权限，静默授予 `cmd appops set ee.nekoko.nlpa2.multi android:mock_location allow`，并直接向底层的 `fused` 融合定位引擎与系统 Provider 注入经纬度。
    - **核心优势**：**无需在系统开发者选项中将本应用选为模拟位置**，彻底避免被部分海外高风控 App 探测到“已启用模拟位置”或在开发者选项中留痕，伪装度极高。
    - **配置步骤**：
      1. 手机安装并启动 [Shizuku](https://shizuku.rikka.app/)（已 Root 手机一键启动；未 Root 手机连接电脑执行一次 `adb shell sh .../start.sh`，或在 Android 11+ 上使用「无线调试」一键配对启动）；
      2. 打开 eUICC-Nexus 并在 Shizuku 授权弹窗中点击「允许」；
      3. 在 App「短信转发」页中将定位方案切换为「Shizuku 底层 FusedLocation」并开启联动。
  - **安全自动注销**：开启「回滚时停止模拟定位」后，当 5 分钟接码结束、用户发送 `/back` 或在控制台切回默认主卡时，网关会自动注销测试 Provider 并关闭虚拟定位，手机立刻恢复真实的物理 GPS。

- **Q：为什么提示「请连接兼容的读卡器以开始」？**  
  A：检查 App「设置」->「读卡器类型」中「内置 OMAPI」是否开启。如果开启后依然空白，查看首页原位展开的**「硬件诊断报告」**，若显示手机 ROM 缺少 `featureOmapiUicc` 或返回 0 个读卡器，说明该手机系统阉割了 OMAPI 接口，需配合 Root + OTBridge，或搭配 ESTK 官方 USB/蓝牙读卡器使用。

- **Q：「Qualcomm modem (QRTR)」和「SE HAL」开关点了没反应 / 报 `no QRTR socket`？**  
  A：**v1.3.4 之前的所有版本都没有打进 Rust 原生库**，这两个通道在旧包里是彻底不可用的，请先升级到最新版本。升级后仍失败，则多为手机 ROM 的 SELinux 不允许 `shell` 用户打开 QRTR socket（`errno 13`），属于系统策略限制。

- **Q：为什么提示「访问被拒绝 (Access Denied by ARA-M)」？**  
  A：请确认安装的是 Releases 发布的最新全签名合一版 APK。若曾使用第三方工具清空过卡内白名单，可进入手机系统自带的「SIM 卡应用 / STK」菜单恢复默认，或使用 ESTK 官方桌面工具重置卡片。

- **Q：「Qualcomm modem (QRTR)」和「SE HAL」这两个开关是干什么的？**  
  A：当手机 ROM 不把卡槽暴露给 OMAPI（诊断报告里 `UICC=false`、`Raw SE Readers (0)`）时，这两条通道**不依赖卡侧签名白名单**，可绕过 ARA-M 直接访问芯片。两者都需要 [Shizuku](https://github.com/RikkaApps/Shizuku)：在「设置 → 读卡器类型」页的 Shizuku 状态行点「安装」即可，App 会从 GitHub 拉取官方安装包（**安装包内不携带 Shizuku 副本**）。手机未 Root 时，每次重启后需从电脑执行一次 `adb shell <libshizuku.so 路径>`，页面的「启动指引」会直接显示本机可用的完整命令并可一键复制。

- **Q：高频切卡会磨损卡片闪存吗？**  
  A：不会。网关内置 NVRAM 防磨损冷却锁，并在每次切卡稳定后**自动在芯片本地静默清除安装/禁用通知日志**，彻底防止 ESTK 芯片有限的闪存空间被日志写满。

---

## 🤖 Telegram Bot 常用指令与实机交互示例

### 1. 指令速查表

| 指令 / 操作 | 说明 |
| :--- | :--- |
| `/list` | 查看卡内 eSIM 列表、**芯片剩余空间 (KB)**、**EID**，通过内联按钮一键切卡 / 5分接码 / 删卡 / 改名 |
| `/status` | 查看当前基带漫游注册、运营商、信号强度 (`dBm`)、**宿主机电量/温度**、FlClash 代理与定位联动状态 |
| `/use <序号>` | **持久切换** 到指定卡（一直保持生效，不自动回滚） |
| `/use_temp <序号>` | **临时切换 5 分钟接码**（倒计时结束后全自动切回默认主卡并恢复代理和定位） |
| `/default` | 将当前激活的卡片设为**默认主卡** |
| `/back` | 立即提前中断临时接码，切回默认主卡并复原 3D 环境 |
| `/proxy` | 查看 FlClash 外部控制器连接状态、当前策略组与可用节点列表 |
| `/proxy_node <序号/名称>` | 远程将 FlClash 策略组切换至指定节点（如 `/proxy_node 3` 或 `/proxy_node 香港 01`） |
| `/proxy_group <策略组名>` | 远程更改联动的策略组（例：`/proxy_group PROXY`） |
| `/guard` / `/guard_toggle` | 查看或开关漫游流量卫士（自动关闭数据漫游/移动数据，防高额账单） |
| `/keepalive` / `/keepalive_now` | 定时保号管理面板 / 立即对所有就绪卡片执行一次驻网保号 |
| `/rename <序号> <新名称>` | 远程修改卡片备注名称（例：`/rename 2 英国主力 +44`） |
| `/readers` | 远程查看并切换操作卡槽或外置读卡器（如 `SIM 1 ⇄ SIM 2`，或 ESTK MAX `SE0 ⇄ SE1`） |
| **发送二维码图片** | 在 Telegram 直接发送 eSIM 二维码截图/图片，机器人自动识别并写入芯片 |
| `/download <激活码>` | 发送 `LPA:1$...` 激活码远程写入 eSIM（附带 Speedtest 测试卡一键体验） |
| `/delete <序号>` | 发起二步确认删卡（生成 2 分钟安全 Token，需确认后擦除） |

---

### 2. 核心场景实机交互演示

#### 场景一：5 分钟临时切卡接码 + 3D 环境联动全闭环
```text
用户：/use_temp 2

Bot 回复：
⏳ 正在切换至卡片【Saily US】（临时接码 5 分钟模式）...
• 漫游流量卫士：已锁定蜂窝数据，防流量偷跑
• eUICC APDU 指令已下发，等待基带重新握手...

（约 10 秒后，基带搜网就绪，主动推送）
📡 搜网就绪！
已成功连接到基站：
• 运营商：AT&T / 中国联通
• 信号强度：-85 dBm (漫游中)
• 漫游流量卫士：🟢 已锁定移动网络
🌐 代理联动：已切换至【🇺🇸 美国 01 洛杉矶 BGP】
📍 虚拟定位：已注入【Los Angeles, USA】(34.0522, -118.2437)
⏱️ 临时接码倒计时已启动：剩余 300 秒自动切回默认主卡。

👉 卡片切换成功并已持久生效，现在可以前往目标平台接收验证码了！
[ 🏠 提前切回主卡 ] [ 🔄 刷新状态 ]

（此时前往目标海外平台点击发送验证码）
Bot 推送短信：
Saily US
📩 来自：<code>Google</code>
🔑 验证码 (点击复制)：<code>849201</code>

G-849201 是您的 Google 验证码。
[ 🏠 已收到码，切回主卡 ]

（用户在 Telegram 中轻点 849201 即可复制，点击底部按钮）
用户：点击 [ 🏠 已收到码，切回主卡 ]

Bot 回复：
🏠 已为您切回默认主卡：【ClubSim HK】。
🌐 代理节点已自动恢复为：【🇭🇰 香港 01 BGP】
📍 虚拟定位已注销，恢复真实 GPS 定位。
```

#### 场景二：查询与远程切换 FlClash 代理节点
```text
用户：/proxy

Bot 回复：
🌐 FlClash 代理联动控制台

开关：🟢 已启用
控制器：http://127.0.0.1:9090（🟢 已连接 · Clash.Meta v1.18.0）
策略组：PROXY
当前节点：🇭🇰 香港 01 BGP
回滚还原：是

可用节点（发 /proxy_node 序号或名称切换）：
1. 🇭🇰 香港 01 BGP
2. 🇭🇰 香港 02 CMI
3. 🇺🇸 美国 01 洛杉矶 BGP
4. 🇬🇧 英国 01 伦敦
5. 🇯🇵 日本 01 东京

[ ⚪ 关闭代理联动 ] [ 🔄 刷新节点 ]
[ 🛡️ 流量卫士 ] [ 📡 查看状态 ]

用户：/proxy_node 3

Bot 回复：
✅ 已把【PROXY】切到节点：【🇺🇸 美国 01 洛杉矶 BGP】
[ 🌐 代理联动设置 ] [ 📡 查看状态 ]
```

#### 场景三：直接发送二维码图片下卡
```text
用户：[直接在聊天框发送一张包含 eSIM 二维码的截图]

Bot 回复：
⏳ 正在识别二维码并连接 SM-DP+ 服务器写入 eUICC 芯片（通常需 15~45 秒），请稍候...

（30 秒后）
✅ eSIM Profile 下载并安装成功！
• ICCID：8904903211234567890F
• 卡位序号：#3

👇 可直接点击下方按钮测试启用或管理该卡片：
[ 🔄 启用卡片 ] [ ⏱️ 5分接码 ]
[ 📋 返回卡内列表 ]
```

---

## 💻 Web Console 暗色控制台与 REST API 使用指南

本项目在备用机本地运行轻量现代化的暗色 Web 控制台（端口 `:8787`），支持局域网直接访问，或搭配 **Tailscale / ZeroTier** 实现全球异地内网穿透直连。

### 1. 访问与安全认证
- **本地访问**：浏览器打开 `http://<备用机局域网IP>:8787`（如 `http://192.168.1.100:8787`）。
- **Tailscale 异地访问**：在备用机与电脑上安装 Tailscale 登录同一账号，直接打开 Tailscale 100.x 内网地址：`http://100.x.y.z:8787`。
- **安全鉴权**：可在 App「短信转发」页配置 `网关 API Token`。配置后，所有 Web 访问与 REST API 均需携带 Bearer Token 或在界面初次弹窗中填入密码，杜绝未授权访问。

---

### 2. 控制台功能模块

```text
┌────────────────────────────────────────────────────────────────────────┐
│ eUICC-Nexus Web Console          [网关运行中] [流量卫士·锁定] [代理·香港01] │
├────────────────────────────────────────────────────────────────────────┤
│ 📌 当前活跃会话                                                         │
│ • 卡片：【Saily US】 (89012...) · 状态：🟢 已就绪                       │
│ • 搜网：AT&T (漫游中) · 信号：-85 dBm · 芯片剩余：384.5 KB             │
│ • 临时接码倒计时：⏱️ 剩余 04:18 自动回主卡     [ 🏠 立即切回默认卡 ]     │
├────────────────────────────────────────────────────────────────────────┤
│ 🛡️ 流量卫士            │ 🌐 FlClash 代理联动                           │
│ 移动数据：[ 已锁死 🟢 ] │ 外部控制器：http://127.0.0.1:9090 [ 测通 🟢 ] │
│ 漫游保护：[ 开启 🟢 ]   │ 策略组：PROXY · 当前：🇺🇸 美国 01 洛杉矶 BGP   │
│ [ 立即锁定 ] [ 立即解锁 ]│ [ 保存并启用 ] [ 测试连接 ]                    │
├────────────────────────────────────────────────────────────────────────┤
│ 💳 eSIM Profile 列表                                                   │
│ #1 🇭🇰 ClubSim (89852...)   [ 默认主卡 ]      [ 启用 ] [ ⏱️ 5分接码 ]   │
│ #2 🇺🇸 Saily US (89012...)   [ 当前使用中 ]    [ 启用 ] [ ⏱️ 5分接码 ]   │
│ #3 🇪🇪 Elisa EE (89372...)   [ 待机中 ]        [ 启用 ] [ ⏱️ 5分接码 ]   │
├────────────────────────────────────────────────────────────────────────┤
│ 📩 实时短信与验证码收件箱                                                │
│ 14:32:05 Saily US · Google ➔ 验证码：849201       [ 🔑 一键复制验证码 ] │
│ 12:15:10 ClubSim · HSBC ➔ 验证码：431980          [ 🔑 一键复制验证码 ] │
└────────────────────────────────────────────────────────────────────────┘
```

1. **顶部状态指示**：实时呈现网关状态、流量卫士锁状态、代理节点名称与一键刷新。
2. **活跃会话面板**：展示当前激活卡、基带注册状态、临时接码剩余时间倒计时及一键切回主卡按钮。
3. **3D 联动控制卡片**：
   - 流量卫士一键锁定/解除蜂窝数据；
   - FlClash External Controller URL、Secret 与策略组配置，提供「测试连接」一键验证连通性与内核版本；
   - 虚拟定位当前注入状态。
4. **eSIM 卡片管理**：直接点选卡片进行持久启用、5 分钟临时接码或改备注。
5. **短信收件箱**：实时长轮询最新短信，高亮提取 4~8 位验证码，提供一键单击复制。

---

### 3. 核心 REST API 调用示例 (curl)

#### ① 获取整机状态与 3D 联动状态 (`GET /api/v1/dashboard`)
```bash
curl -X GET "http://127.0.0.1:8787/api/v1/dashboard" \
     -H "Authorization: Bearer <YOUR_TOKEN>"
```
*返回网关运行状态、当前激活卡、卡槽内所有 Profile 列表、基带信号、宿主机电量、流量卫士及 FlClash 代理联动详细参数。*

#### ② 远程触发临时切卡 5 分钟 (`POST /api/v1/switch`)
```bash
curl -X POST "http://127.0.0.1:8787/api/v1/switch" \
     -H "Authorization: Bearer <YOUR_TOKEN>" \
     -H "Content-Type: application/json" \
     -d '{"iccid": "89012345678901234567", "tempMinutes": 5}'
```
*触发物理切卡、锁定流量卫士、将 FlClash 策略组切换到对应国家节点、并注入虚拟定位，5 分钟后自动回滚。*

#### ③ 测试 FlClash 外部控制器连通性 (`POST /api/v1/proxy/test`)
```bash
curl -X POST "http://127.0.0.1:8787/api/v1/proxy/test" \
     -H "Authorization: Bearer <YOUR_TOKEN>" \
     -H "Content-Type: application/json" \
     -d '{"controllerUrl": "http://127.0.0.1:9090", "secret": "4oeko4rOpcrFtryEOYRtyNmKH0mr7IiG"}'
```
*返回代理内核版本、连通状态及所有可用的 Selector 策略组。*

#### ④ 手动切换 FlClash 策略组节点 (`POST /api/v1/proxy/switch`)
```bash
curl -X POST "http://127.0.0.1:8787/api/v1/proxy/switch" \
     -H "Authorization: Bearer <YOUR_TOKEN>" \
     -H "Content-Type: application/json" \
     -d '{"group": "PROXY", "node": "🇺🇸 美国 01 洛杉矶 BGP"}'
```

#### ⑤ 提前切回默认主卡并复原环境 (`POST /api/v1/revert`)
```bash
curl -X POST "http://127.0.0.1:8787/api/v1/revert" \
     -H "Authorization: Bearer <YOUR_TOKEN>"
```
*立即中断临时会话，切回默认主卡，并自动快照还原原始代理节点与真实 GPS 定位。*

#### ⑥ 获取短信与验证码记录 (`GET /api/v1/sms`)
```bash
curl -X GET "http://127.0.0.1:8787/api/v1/sms?limit=10" \
     -H "Authorization: Bearer <YOUR_TOKEN>"
```

---

## 开源协议

[MIT License](LICENSE) · 基于 [iebb/NekokoLPA2](https://github.com/iebb/NekokoLPA2) 构建 · 社区支持：[LINUX DO](https://linux.do)
