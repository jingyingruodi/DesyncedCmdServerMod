-- Desynced Command Console - UI Layer (v1.9.0)
-- 职责：把本地玩家的聊天/指令转成「玩家动作」发给服务端；服务端不信任本层传的任何身份信息
--
-- v1.9.0 变更：
--   1. 改用 Action.SendFromPlayer + PlayerAction.CmdServerExec —— 引擎提供权威 player_id，
--      不再从 arg 里自填 p_id/sender_name（那是可冒充的）
--   2. 不再把原始指令 print 进日志：/register、/login、/changepass 的参数含明文密码
--   3. 不再用 pcall 静默吞错：失败时把指令当普通聊天发出去，并提示玩家，避免「零反馈」

if not UI or not UI.Run then return end

local version = "1.9.6"
print("[CmdServerMod-UI] v" .. version .. " link deployed.")

---------------------------------------------------------------------------
-- 与 Data 层一致的脱敏逻辑：密码参数绝不出现在任何日志里
---------------------------------------------------------------------------
local function sanitize(text)
    if type(text) ~= "string" or text:sub(1, 1) ~= "/" then return text end
    local parts = {}
    for p in text:sub(2):gmatch("%S+") do parts[#parts + 1] = p end
    if #parts == 0 then return text end
    local cmd = parts[1]:lower()
    if cmd == "register" then
        if #parts >= 4 then return "/register *** *** " .. table.concat(parts, " ", 4)
        elseif #parts >= 3 then return "/register *** ***"
        else return "/register ***" end
    elseif cmd == "login" then
        return "/login ***"
    elseif cmd == "changepass" then
        return "/changepass *** ***"
    end
    return text
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
