-- ============================================================================
-- Desynced Command Console - 扩展开发指南 (v1.6.3)
-- ============================================================================

--[[
本文件说明如何为 v1.6.3+ 架构的命令台模组添加新功能。

【核心规则】：
1. 所有逻辑必须在 data/main.lua (Simulation 环境) 中注册。
2. 严禁在命令处理函数中直接访问 UI 或 Chat 对象。
3. 执行结果应通过 'return' 返回字符串，框架会自动通过私密通道发给玩家。

注册函数定义：
  register_command(name, description, handler)

处理函数签名：
  function(args, sender_id)
    - args (table): 参数数组 (e.g. /msg hello -> args[1] = "hello")
    - sender_id (integer): 发送者的 PlayerID
]]

-- ============================================================================
-- 示例 1: 简单的信息查询 (无权限限制)
-- ============================================================================

--[[
register_command("tick", "查询服务器当前 Tick", function(args, p_id)
    local current_tick = Map.GetTick()
    return "Current Server Tick: " .. current_tick
end)
]]

-- ============================================================================
-- 示例 2: 处理参数与错误校验
-- ============================================================================

--[[
register_command("echo", "回显测试", function(args, p_id)
    if #args == 0 then
        return "Usage: /echo <message>"
    end

    local message = table.concat(args, " ")
    return "You said: " .. message
end)
]]

-- ============================================================================
-- 示例 3: 操作游戏世界逻辑 (仅在服务端生效)
-- ============================================================================

--[[
register_command("setspeed", "修改游戏速度", function(args, p_id)
    -- 以后可以在此处加入权限校验：if not IsAdmin(p_id) then return "Denied" end
    
    local speed = tonumber(args[1])
    if not speed or speed < 0.1 or speed > 10 then
        return "Invalid speed. Use 0.1 to 10.0"
    end
    
    Map.SetGameSpeed(speed)
    return "Game speed set to " .. speed
end)
]]

-- ============================================================================
-- 最佳实践与注意事项
-- ============================================================================

--[[
1. 私密性：
   框架使用 Action.RunUI 确保 return 的结果只有指令发起者能看到。

2. 服务端日志：
   所有通过本框架执行的指令都会自动记录在 Dedicated Server 的控制台日志中。

3. 性能：
   由于命令运行在 Simulation 层，请避免在处理函数中执行耗时过长的循环。

4. 跨包调用：
   如果你需要调用本模组的执行引擎，请使用全局对象：
   _G.CmdServerMod.execute_command(text, player_id)
]]

print("[CmdServerMod] Extension Guide Updated to v1.6.3 Standard.")
