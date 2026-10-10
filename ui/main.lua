-- Desynced Command Console - UI Layer (v1.9.0)
-- 职责：把本地玩家的聊天/指令转成「玩家动作」发给服务端；服务端不信任本层传的任何身份信息
--
-- v1.9.0 变更：
--   1. 改用 Action.SendFromPlayer + PlayerAction.CmdServerExec —— 引擎提供权威 player_id，
--      不再从 arg 里自填 p_id/sender_name（那是可冒充的）
--   2. 不再把原始指令 print 进日志：/register、/login、/changepass 的参数含明文密码
--   3. 不再用 pcall 静默吞错：失败时把指令当普通聊天发出去，并提示玩家，避免「零反馈」

if not UI or not UI.Run then return end

local version = "1.10.2"
print("[CmdServerMod-UI] v" .. version .. " link deployed.")

---------------------------------------------------------------------------
-- 与 Data 层一致的脱敏逻辑：密码参数绝不出现在任何日志里
---------------------------------------------------------------------------
-- 指令脱敏：**失败关闭**（与 Data 层保持同一策略）
--
-- 教训（2026-10-07）：原来靠精确命令名匹配，玩家把 /register 打成 /rgister
-- 就完全绕过，明文密码进了日志。靠枚举「要脱敏的命令名」是防不住的。
-- 本层只是把玩家自己输入的命令写进**本客户端**的日志（不广播），
-- 但同样是密码落盘，必须一视同仁地挡住。
local SAFE_ARGS_COMMANDS = {
    help = true, ping = true, whoami = true, players = true, playerinfo = true,
    diag = true, cmdline = true, probe = true,
    speed = true, settings = true, kick = true, admin = true,
}
local SECRET_ARG_COMMANDS = {
    register = true, login = true, changepass = true, account = true, setupkey = true,
}

local function sanitize(text)
    if type(text) ~= "string" or text:sub(1, 1) ~= "/" then return text end
    local parts = {}
    for p in text:sub(2):gmatch("%S+") do parts[#parts + 1] = p end
    if #parts == 0 then return text end
    local cmd = parts[1]:lower()
    local argc = #parts - 1
    if argc == 0 then return "/" .. parts[1] end
    if SAFE_ARGS_COMMANDS[cmd] then return text end
    if SECRET_ARG_COMMANDS[cmd] then
        return "/" .. parts[1] .. " (" .. argc .. " args hidden)"
    end
    -- 未知/拼错的命令：绝不记录参数（很可能是打错的 register/login）
    return "/" .. parts[1] .. " (" .. argc .. " args hidden, unknown command)"
end

---------------------------------------------------------------------------
-- 拦截本地玩家的聊天发送
-- 本地玩家自己的消息也会触发服务端广播回来的 Chat.Text；这里只处理「发送」这一侧。
---------------------------------------------------------------------------
local original_send_chat = UI.SendChatGlobal
UI.SendChatGlobal = function(msg_type, arg)
    if msg_type == "Text" and arg and arg.txt and #arg.txt > 0 then
        local is_cmd = arg.txt:sub(1, 1) == "/"

        print(string.format("[CmdServerMod-UI] sending: %s", sanitize(arg.txt)))

        local sent = false
        if Action and Action.SendFromPlayer then
            local ok, err = pcall(function()
                -- 第二个参数只带指令文本；身份由引擎注入，客户端伪造不了
                Action.SendFromPlayer("CmdServerExec", { txt = arg.txt, is_command = is_cmd })
            end)
            sent = ok
            if not ok then
                print("[CmdServerMod-UI] SendFromPlayer failed: " .. tostring(err))
            end
        else
            print("[CmdServerMod-UI] Action.SendFromPlayer unavailable")
        end

        if is_cmd then
            -- 指令不广播（防刷屏）。但若根本没发出去，就别把玩家闷死：
            -- 退回普通聊天，至少让玩家看到自己的指令有反应。
            if sent then return true end
            if Chat and Chat.Text then
                Chat.Text({ txt = "[SERVER] Command channel unavailable; command was not sent." }, Game.GetLocalPlayerId())
            end
            return true
        end
    end

    if original_send_chat then
        return original_send_chat(msg_type, arg)
    end
end

---------------------------------------------------------------------------
-- ★ 联调用：客户端侧自动以「玩家身份」发一条指令。正式发布必须保持 nil。
--
-- 为什么必须在客户端发：
--   Action.RunUI 要求「正在执行的动作」上下文（文档：Must be called while executing
--   an action）。服务端 MapMsg.OnTick 里没有该上下文 —— 实测确认 RunUI 会静默失效，
--   于是所有 UI 层探针都发不出去。只有玩家动作能建立这个上下文。
--   而本机自动化又敲不进游戏聊天框（xdotool 在 Connect 对话框里能用，聊天框里不行），
--   所以干脆让客户端的模组自己发。
--
-- 会周期性地发若干次，覆盖「前端加载 → 连上服务器」这段窗口。
local DEV_AUTOCMD = nil          -- 例："/probe alpha"
local DEV_AUTOCMD_TIMES = 120    -- 最多发几次（覆盖到服务端注册完成之后）
local DEV_AUTOCMD_EVERY = 8      -- 每次间隔秒数

if DEV_AUTOCMD and UI and UI.Delay then
    local left = DEV_AUTOCMD_TIMES
    local function fire()
        left = left - 1
        if left < 0 then return end
        pcall(function()
            Action.SendFromPlayer("CmdServerExec", { txt = DEV_AUTOCMD, is_command = true })
        end)
        UI.Delay(DEV_AUTOCMD_EVERY, fire)
    end
    UI.Delay(15, fire)
end

---------------------------------------------------------------------------
-- 探针回执（★ 核心机制）
--
-- 问题：客户端没有可读的日志文件（UE shipping 构建不写 .log），stdout 也被
--       Steam/Proton 丢进 /dev/null。所以「另一个客户端看到了什么」无法直接观察。
--
-- 解法：注册一个**我们自己的聊天类型** Chat.CmdServerProbe。服务端发起探针时
--       通过 UI.SendChatGlobal / SendChatPlayer 调用它 —— 引擎会在**目标客户端的
--       UI VM 里**执行这个函数。于是每个客户端可以主动把「我收到了」发回服务端
--       （Action.SendFromPlayer，身份由引擎注入），全部结果汇总到**服务端控制台**，
--       一处即可看到完整可见性矩阵，不需要去翻任何客户端的日志。
---------------------------------------------------------------------------
Chat.CmdServerProbe = function(arg, sender, scope)
    if type(arg) ~= "table" then return end
    local me = -1
    pcall(function() me = Game.GetLocalPlayerId() end)
    local tag = tostring(arg.tag or "?")
    local ch  = tostring(arg.channel or "?")

    -- UI 层 print：只应出现在本客户端与该客户端 ID 对应的日志里
    pcall(print, string.format("[PROBE:recv] ch=%s tag=%s me=%s", ch, tag, tostring(me)))

    -- 在本地聊天栏显示一条（用于验证聊天栏可见性）
    pcall(function()
        if Chat and Chat.Text then
            Chat.Text({ txt = string.format("[PROBE:chatbar] ch=%s tag=%s", ch, tag),
                        player_id = me }, me)
        end
    end)

    -- ★ 回报服务端：谁收到了哪条探针
    pcall(function()
        Action.SendFromPlayer("CmdServerProbeReport", {
            channel = ch, tag = tag, me = me,
            sender = sender, scope = tostring(scope),
        })
    end)
end

---------------------------------------------------------------------------
-- 探针（Probe）：测定「哪一条通道能被谁看到」
--
-- 由 Data 层经 Action.RunUI 调用。触发方式是游戏内超管指令：
--     /probe <标记>
-- 每个通道用不同的可搜索前缀发一条消息，然后把
--   【服务端控制台 / 客户端A日志 / 客户端B日志 / 客户端A聊天栏 / 客户端B聊天栏】
-- 五处的实际出现情况记下来，就能确定每种通道的可见范围。
--
-- ⚠️ 本函数会被 dump/load 到 UI VM 里执行，只能依赖全局，不能依赖 Data 层 upvalue。
-- ⚠️ 全局广播必须用 **original_send_chat**（被 hook 之前的原函数）：
--    我们的 UI.SendChatGlobal 钩子会把 "Text" 消息转成玩家动作发给服务端，
--    用它会把探针消息当成玩家发言、反而广播不出去。
---------------------------------------------------------------------------
_G.CmdServerProbeUI = function(tag, self_id, other_id)
    tag = tostring(tag)

    -- 通道 U1：UI 层 print（预期：只进本客户端日志）
    pcall(print, "[PROBE:ui-print] " .. tag)

    -- 通道 U2：私聊给自己（预期：只有自己聊天栏 + 自己日志）
    pcall(function()
        if Chat and Chat.Text then
            Chat.Text({ txt = "[PROBE:ui-chat-self] " .. tag, player_id = self_id }, self_id)
        end
    end)

    -- 通道 U3：全局广播（预期：所有人聊天栏 + 所有人日志）
    pcall(function()
        local send = original_send_chat or (UI and UI.SendChatGlobal)
        if send then
            send("Text", { txt = "[PROBE:ui-chat-global] " .. tag })
        end
    end)

    -- 通道 U4：只发给另一个玩家（预期：只有对方聊天栏 + 对方日志）
    if other_id then
        pcall(function()
            if UI and UI.SendChatPlayer then
                UI.SendChatPlayer("Text", other_id, { txt = "[PROBE:ui-chat-other] " .. tag })
            end
        end)
    end

    pcall(print, "[PROBE:ui-done] " .. tag)
end
