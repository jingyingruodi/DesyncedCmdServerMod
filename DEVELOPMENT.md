# Command Console - 开发者技术文档 (v1.6.3)

[English](#english) | [中文](#中文)

## 🏗️ 架构设计 (Architecture)

本项目采用 **UI-Simulation 双层解耦架构**，以确保在多人游戏和专用服务器（Dedicated Server）环境下的绝对稳定性。

### 1. UI 层 (`ui/main.lua`)
- **职责**：本地输入拦截、身份标记、动作封装。
- **关键技术**：
    - Hook `UI.SendChatGlobal` 拦截所有文本输入。
    - 使用 `Action.SendForLocalFaction` 将捕获到的内容同步给服务端。
    - **禁止**在 UI 层直接执行管理逻辑，所有指令必须由服务器确认。

### 2. 逻辑层 (`data/main.lua`)
- **职责**：指令解析、权限校验、服务端播报、心跳维护。
- **关键技术**：
    - **OnTick 定时器**：使用 `MapMsg.OnTick` 配合本地变量实现 10s 循环。避免了 `Map.Delay` 被序列化进存档导致的多线程重影问题。
    - **FactionAction 接收器**：注册 `CmdServerExec` 处理函数。这是跨越 UI 与仿真环境的唯一可靠通道。
    - **私密回执**：使用 `Action.RunUI` 回调。该 API 确保执行结果仅发回给指令的发起玩家，且运行在正确的 UI 上下文中。

---

## 🛠️ 开发规范 (Standards)

为了维持项目整洁，后续开发请遵循以下准则：

### 1. 指令注册
所有新指令必须在 `data/main.lua` 的 `commands` 表中注册，格式如下：
```lua
register_command("name", "description", function(args, p_id)
    -- 逻辑代码
    return "反馈文本"
end)
```

### 2. 性能考量
- 游戏的 TPS (Ticks Per Second) 稳定在 **5**。
- 逻辑层中的 `print` 会直接输出到专用服务器的后台控制台，这是监控玩家活动的唯一手段。

### 3. 环境识别
- 永远不要在包加载阶段（Main Chunk）调用 `Map.Delay`。
- 只有在 `package:init()` 之后，仿真环境才算完全就绪。

---

## 📅 未来路线 (Roadmap)
- [ ] **Rank 权限分级**：实现 Admin 和 SuperAdmin 的等级划分。
- [ ] **持久化管理**：将管理员名单保存至 `Map.GetSave()`。
- [ ] **指令扩展**：增加 `/kick`, `/speed`, `/weather` 等实用服务器工具。

---
*遵循 [AI_RULES.md](AI_RULES.md) 进行协作维护。*
