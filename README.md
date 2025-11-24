# 河源职业技术学院校园网自动认证脚本 (HYPT Network Autologin)

![GitHub License](https://img.shields.io/github/license/Amekuro/hypt-network-autologin)
![Platform](https://img.shields.io/badge/Platform-OpenWrt%20%2F%20iStoreOS-blue)
![Shell](https://img.shields.io/badge/Language-Shell-green)

## 📖 简介

本项目是一个专为 **OpenWrt / iStoreOS** 软路由系统设计的 Shell 脚本，用于**河源职业技术学院**（HYPT）新版校园网（2025年11月启用）的自动认证。

脚本能够自动检测网络接口状态，在掉线时自动提取参数并重连，完美支持 **多WAN口 / 单线多拨** 环境。

> ✅ **测试环境**：iStoreOS 24.10.4 (基于 OpenWrt)
> 
> ⚠️ **注意**：本脚本依赖 OpenWrt 特有的网络工具 (`ifstatus`, `jsonfilter`)，**无法**在 Ubuntu/CentOS 等普通 Linux 发行版上直接运行。

## ✨ 核心特性

*   **⚡️ 智能多拨支持**：支持同时监控多个接口（如 `wan`, `vwan1`, `vwan2`...），独立管理每个接口的认证状态。
*   **🛡️ 路由表防冲突**：内置路由绑定逻辑，确保认证请求强制走对应的物理接口，防止多拨环境下流量“串线”导致认证失败。
*   **🔍 智能探测**：通过访问内网劫持页 (`2.2.2.2`) 精准判断登录状态，不仅能自动登录，还能检测“假在线”状态。
*   **📝 详细日志**：提供清晰的运行日志，支持 Debug 模式，方便排查网络问题。
*   **🔄 断线重连**：配合 Crontab 计划任务，实现全天候无人值守保活。

## 🚀 快速开始

### 1. 下载脚本

将仓库中的 `login.sh` 文件上传到你的路由器（建议路径 `/root/login.sh`）。

或者直接在路由器 SSH 中执行下载：
```bash
wget -O /root/login.sh https://raw.githubusercontent.com/Amekuro/hypt-network-autologin/main/login.sh
```

### 2. 修改配置

使用文本编辑器（如 `vim` 或 WinSCP）打开 `/root/login.sh`，修改文件顶部的 **配置区**：

```bash
# ======================= 配置区 =======================
# 1. 修改为你的学号和密码
USERNAME="YOUR_ACCOUNT"   # <--- 替换为你的真实学号
PASSWORD="YOUR_PASSWORD"  # <--- 替换为你的真实密码

# 2. 设置需要认证的接口名称 (空格分隔)
#    这些名称必须与 'mwan3 status' 或 '网络->接口' 中的名称一致
#    单线单拨通常是: "wan"
#    单线多拨可能是: "wan vwan1 vwan2"
INTERFACES="wan" 
# ======================================================
```

### 3. 授予权限

```bash
chmod +x /root/login.sh
```

### 4. 测试运行

手动运行脚本，检查是否能正常认证：

```bash
/root/login.sh
```

如果看到 `>>> 认证成功!` 字样，说明配置正确。

---

## ⏰ 设置自动运行 (计划任务)

为了实现掉线自动重连，建议设置每 2 分钟执行一次检查。

1.  进入 OpenWrt/iStoreOS 管理后台。
2.  点击菜单 **系统 (System)** -> **计划任务 (Scheduled Tasks)**。
3.  在末尾添加以下内容：

```cron
# 每2分钟检测一次校园网登录状态
*/2 * * * * /root/login.sh
```
4.  保存并提交。

---

## 🛠️ 调试指南 (Debug)

如果遇到认证失败或网络异常，可以使用调试模式查看详细的 HTTP 交互日志。

### 调试所有接口
```bash
/root/login.sh debug
```

### 调试特定接口 (推荐)
如果你配置了多拨，只想测试其中一个接口（例如 `vwan1`）：
```bash
/root/login.sh debug vwan1
```
*此模式下会强制修正路由表并输出详细的抓包级日志。*

---

## ❓ 常见问题 (FAQ)

**Q: 日志显示 `Failed to parse json data` 是什么意思？**
A: 这通常发生在脚本尝试读取一个**未启动**或**未获取到IP**的接口时（例如配置了 `vwan2` 但实际上拨号失败了）。脚本会自动跳过该接口，不影响其他正常接口的使用，请忽略此错误。

**Q: 调试模式下看到 `Connection timed out`？**
A: 只要日志显示 `状态: [已在线]` 或 `认证成功`，最后的超时可以忽略。这是因为脚本在认证后尝试访问注销页面以确认状态，但有时学校服务器响应较慢导致超时，不影响实际上网。

**Q: 为什么普通 Linux 跑不起来？**
A: 脚本使用了 `ifstatus` 和 `jsonfilter` 来精确获取接口的网关和物理设备名，这是 OpenWrt 系统特有的命令。

---

## ⚖️ 免责声明

1.  本脚本仅供技术研究和学习交流使用。
2.  请勿将本脚本用于任何违反当地法律法规或学校网络管理规定的用途。
3.  作者不对使用本脚本造成的任何账号封禁、网络异常或经济损失负责。

## 📄 许可证

本项目采用 [MIT License](LICENSE) 开源授权。
