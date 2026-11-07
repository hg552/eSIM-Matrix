## eSIM-Matrix v1.4.1 — 读卡器扫描不再静默失败

本次更新只解决一件事：**当某个读卡通道返回 0 个读卡器时，App 必须说清楚为什么**，而不是只显示 `0 reader(s)` 让人误判成 ROM 坏掉。

### 🔍 扫描明细里的明确原因

| 通道 | 之前 | 现在 |
| :--- | :--- | :--- |
| **QRTR** | `0 reader(s)` | 非高通机型直接点名 SoC：`no QRTR bus on MediaTek MT6769Z: QRTR is a Qualcomm-only modem bus`，并列出替代方案 |
| **QRTR** | 只区分 Shizuku 有没有跑 | 再区分「Shizuku 已运行但本应用未授权」 |
| **SE HAL** | `0 reader(s)` | 区分：Shizuku 未运行 / 已运行未授权 / ROM 未发布 `android.hardware.secure_element` / 已授权但没列出卡槽 |
| **Built-in OMAPI** | `native readers: []` | 追加：该 ROM 未把卡槽暴露给应用 OMAPI，改用 SE HAL / OTBridge / 外接读卡器 |

### 🧭 新增机型信息探针

`platformInfo` 现在上报：`ro.hardware`、`SOC_MANUFACTURER`、`SOC_MODEL`、`android.hardware.secure_element`、`android.hardware.se.omapi.uicc`。诊断报告据此按芯片给结论，不再靠猜。

### 📦 安装信息

- 包名（applicationId）：`io.github.hg552.esimmatrix.multi`（与 v1.4.0 相同，可直接覆盖升级）
- 三证书合一：ESTK `C47350...` + 9eSIM `D1C0F4...` + SakuraSIM `65D057...`
- **升级后请在 Shizuku 里确认为新包名授权**（Shizuku 授权按包名记录）

### 🔗 链接

- 仓库：https://github.com/hg552/eSIM-Matrix
- 上游：https://github.com/iebb/NekokoLPA2 （MIT License）
