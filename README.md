# Desynced Command Console (v1.6.3)

[English](#english) | [中文](#中文)

A robust server-side command and authority management framework for Desynced. Designed for high performance, multiplayer security, and headless server monitoring.

---

## 🌟 Features

- 🛰️ **Action-Based Sync**: Reliable cross-context execution between UI and Simulation layers.
- 🔒 **Private Feedback**: Command results are sent only to the initiator via secure action callbacks.
- 🖥️ **Server Monitoring**: Full logging of player chats and commands in the Dedicated Server console.
- ⚡ **Zero-State Timer**: Performance-friendly heartbeat system that doesn't bloat save files.
- ✅ **Authority First**: Commands are executed only after server-side validation.

## 🛠️ Available Commands

| Command | Description | Rank Required |
| :--- | :--- | :--- |
| `/help` | List available commands | 0 (User) |
| `/ping` | Verify server authority status | 0 (User) |

---

## 中文

一个专为 Desynced 打造的稳健的服务端命令与权限管理框架。旨在提供高性能、多人游戏安全性和专用服务器后台实时监控。

### 🌟 核心特性

- 🛰️ **动作同步机制**：利用 Action 系统实现 UI 层与仿真层（Simulation）的可靠跨端通信。
- 🔒 **私密反馈**：指令执行结果通过私有的 Action 回调仅发回给指令发起者，不干扰其他玩家。
- 🖥️ **服务端监控**：在专用服务器控制台实时播报玩家对话与指令输入。
- ⚡ **零状态定时器**：基于 `OnTick` 的心跳系统，不产生存档残留，不影响服务器性能。
- ✅ **权威执行**：所有指令均在服务端校验后执行，确保管理的绝对安全。

### 🛠️ 已实现指令

- `/help`：显示当前权限可用的所有指令列表。
- `/ping`：检查服务端逻辑层是否在线并验证身份。

---

## 📂 Project Structure

- `data/main.lua`: Core logic (Simulation), handles parsing and server-side execution.
- `ui/main.lua`: UI interceptor, handles input capture and secure action dispatching.
- `AI_RULES.md`: Guidelines for future AI contributors to prevent project clutter.

**Author**: jingyingruodi(镜影若滴)
**License**: MIT
