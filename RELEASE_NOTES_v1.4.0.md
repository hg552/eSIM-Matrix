## eSIM-Matrix v1.4.0 — 全新品牌与 3D 异构海外环境联动

本次发布是项目全面重塑：**eUICC-Nexus 正式更名为 eSIM-Matrix**，应用名、Web 控制台与 Telegram 主控台全部焕新。

### 📦 安装包特性
- **三证书合一**：单个 APK 同时内置 ESTK（`C47350...`）、9eSIM（`D1C0F4...`）、SakuraSIM（`65D057...`）三套 ARA-M 出厂证书，插卡即用，无需电脑读卡器写规则。
- **包名（applicationId）**：`io.github.hg552.esimmatrix.multi`（全新独立包名，与原版 NekokoLPA 2 完全隔离，可同机共存）。

### ✨ 3D 异构海外环境联动
- **维度一 · SIM 身份与物理基带**：秒级 Profile 热切换、5 分钟临时接卡自动回滚、CS 语音域 + PS 数据域双域搜网状态机。
- **维度二 · 代理节点联动**：FlClash / Mihomo / sing-box 外部控制器联动，支持 ICCID 专属绑定与国家 Emoji/ISO/区号智能推导；内置漫游流量卫士（Data Guard）锁死蜂窝，切回主卡自动快照还原。
- **维度三 · 虚拟定位联动**：内置 17 个全球重点城市地标模板，并支持**手动输入任意经纬度**、保存为常用模板、按卡片定向绑定；切卡激活时即时注入，切回主卡自动复原。

### 🛠️ 其它
- eUICC 芯片闪存自洁：切卡稳定后静默秒清 Enable/Disable 通知，杜绝 NVRAM 写满与 `TRANSMIT_FAILED`。
- 全面加入 [LINUX DO](https://linux.do) 社区友链与开源致谢。

### 🔗 链接
- 仓库：https://github.com/hg552/eSIM-Matrix
- 上游：https://github.com/iebb/NekokoLPA2 （MIT License）
