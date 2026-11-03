# eUICC-Nexus

<p align="center">
  <b>基于 Android 备用机的远程多国 eSIM (eUICC) 切卡、基带漫游监控与短信/验证码转发网关</b><br/>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square" alt="MIT License" /></a>
  <a href="https://github.com/iebb/NekokoLPA2"><img src="https://img.shields.io/badge/Upstream-NekokoLPA2-6E56CF?style=flat-square" alt="Based on NekokoLPA2" /></a>
  <a href="https://github.com/MIY-Y/eUICC-Nexus/releases"><img src="https://img.shields.io/badge/Release-v1.1.0-orange?style=flat-square" alt="Release v1.1.0" /></a>
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

---

## 3 分钟快速上手

1. **安装授权**：将 eUICC 芯片插入备用机，安装 [Releases](https://github.com/MIY-Y/eUICC-Nexus/releases) 中的 APK；在「网络」与「短信转发」页授予电话、短信与通知权限，并将省电策略设为**「无限制」**。
2. **绑定 Telegram Bot**：
   - 找 [`@BotFather`](https://t.me/BotFather) 发送 `/newbot` 创建机器人并复制 **Bot Token**；
   - 在 Telegram 给你的机器人发送一次 `/start`；
   - 打开 App「短信转发」页 ➔ 填入 Token ➔ 点击 **「自动发现私聊 ID」** ➔ 开启开关并点击 **「保存配置」**。

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
