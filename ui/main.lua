-- Desynced Command Console - UI Layer (v1.8.0)
-- 职责：全量监控同步 + 携带发送者 ID

if not UI or not UI.Run then return end

local version = "1.8.0"
print("[CmdServerMod-UI] v" .. version .. " Authority Link Deployed.")

local original_send_chat = UI.SendChatGlobal
UI.SendChatGlobal = function(msg_type, arg)
    if msg_type == "Text" and arg and arg.txt then
        local p_id = Game.GetLocalPlayerId()
        local p_name = Game.GetPlayerName(p_id) or "Unknown"
        local is_cmd = arg.txt:sub(1, 1) == "/"

        -- UI本地日志：确认发送前状态
        print(string.format("[CmdServerMod-UI] P%d Sending: %s", p_id, arg.txt))

        -- 核心修正：使用标准的 LocalFaction 动作发送，并携带 p_id
        if Action and Action.SendForLocalFaction then
            pcall(function()
                Action.SendForLocalFaction("CmdServerExec", {
                    txt = arg.txt,
                    sender_name = p_name,
                    is_command = is_cmd,
                    p_id = p_id
                })
            end)
        end

        -- 拦截指令广播，防止刷屏
        if is_cmd then
            return true
        end
    end
    
    if original_send_chat then
        return original_send_chat(msg_type, arg)
    end
end
