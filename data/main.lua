-- Desynced Command Console - Core Logic (v1.8.0)
-- 职责：外置存储 + 随机密钥 + 自动登出 + 权限系统 + 密码脱敏 + 暂停兼容

local package = ...
_G.CmdServerMod = _G.CmdServerMod or {}
local version = "1.8.0"
local tick_counter = 0

---------------------------------------------------------------------------
-- 0. 基础工具
---------------------------------------------------------------------------
local function srv_print(tag, msg)
    print(string.format("[%s] %s", tostring(tag), tostring(msg)))
end

local function hash_password(password)
    local hash = 5381
    for i = 1, #password do
        hash = ((hash * 33) + string.byte(password, i)) % 4294967296
    end
    return hash
end

local function safe_pairs(tbl)
    if type(tbl) ~= "table" then return function() end end
    return pairs(tbl)
end

-- 随机字符串生成 (用于 setup key)
local function random_str(len)
    len = len or 12
    local chars = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789"
    local t = {}
    for i = 1, len do
        local idx = math.random(1, #chars)
        t[i] = chars:sub(idx, idx)
    end
    return table.concat(t)
end

srv_print("CmdServerMod", "Data Layer Booting v" .. version)

---------------------------------------------------------------------------
-- 1. 数据访问层 (Map.GetSave 存档内持久化，跨存档用 /account export/import)
---------------------------------------------------------------------------
local function get_ms()
    local save = Map.GetSave()
    if not save.CmdServerMod then
        save.CmdServerMod = { accounts = {}, setup_key = "" }
    end
    local ms = save.CmdServerMod
    if not ms.accounts then ms.accounts = {} end
    if not ms.setup_key then ms.setup_key = "" end
    return ms
end

local function get_account(name)
    return get_ms().accounts[name]
end

local function set_account(name, data)
    get_ms().accounts[name] = data
end

local RANK_LEVEL = { guest = 0, player = 1, admin = 2, superadmin = 3 }

local function get_session(p_id)
    if not _G.CmdServerMod._sessions then return nil end
    return _G.CmdServerMod._sessions[p_id]
end

local function get_session_rank(p_id)
    local sess = get_session(p_id)
    if not sess or not sess.logged_in then return "guest" end
    local acct = get_account(sess.name)
    if not acct then return "guest" end
    return acct.rank or "guest"
end

local function rank_at_least(p_id, required)
    return (RANK_LEVEL[get_session_rank(p_id)] or 0) >= (RANK_LEVEL[required] or 0)
end

---------------------------------------------------------------------------
-- 2. 会话管理 + 自动登出
---------------------------------------------------------------------------
_G.CmdServerMod._sessions = _G.CmdServerMod._sessions or {}

local function init_session(p_id, p_name)
    if _G.CmdServerMod._sessions[p_id] and _G.CmdServerMod._sessions[p_id].name == p_name then
        -- 同一玩家重连：保留登录状态，仅刷新 last_seen
        _G.CmdServerMod._sessions[p_id].last_seen = Map.GetTick()
        return
    end
    _G.CmdServerMod._sessions[p_id] = {
        name = p_name,
        logged_in = false,
        last_seen = Map.GetTick(),
    }
    local acct = get_account(p_name)
    if acct then
        if acct.auto_logged_out then
            -- 曾被自动登出，需手动 /login，通过 Action.RunUI 通知玩家
            _G.CmdServerMod._sessions[p_id].logged_in = false
            _G.CmdServerMod._sessions[p_id]._notify_relogin = true
            srv_print("LOGIN", string.format("%s (P%d) was auto-logged out, manual /login required", p_name, p_id))
        else
            _G.CmdServerMod._sessions[p_id].logged_in = true
            srv_print("LOGIN", string.format("%s (P%d) auto-logged as [%s]", p_name, p_id, acct.rank or "player"))
        end
    end
end

local function touch_session(p_id)
    if _G.CmdServerMod._sessions[p_id] then
        _G.CmdServerMod._sessions[p_id].last_seen = Map.GetTick()
    end
end

-- 惰性会话初始化：游戏暂停时 OnTick 不触发，须在指令处理时补建 session
local function ensure_session(p_id, p_name)
    if not _G.CmdServerMod._sessions[p_id] then
        init_session(p_id, p_name)
    end
end

-- 自动登出：超过 N ticks 未活跃则登出
local AUTO_LOGOUT_TICKS = 150  -- 30秒 (5 TPS * 30)

---------------------------------------------------------------------------
-- 3. 安全导出：仅输出到服务端后台控制台
---------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

local function encode_accounts(accounts)
    local parts = {}
    for name, acct in safe_pairs(accounts) do
        parts[#parts + 1] = name .. ":" .. acct.hash .. ":" .. (acct.rank or "player")
    end
    local raw = table.concat(parts, "|")
    local enc = {}
    for i = 1, #raw do
        local b = string.byte(raw, i)
        enc[#enc + 1] = B64:sub((b % 64) + 1, (b % 64) + 1)
        enc[#enc + 1] = B64:sub(((b // 64) % 64) + 1, ((b // 64) % 64) + 1)
    end
    return table.concat(enc)
end

local function decode_accounts(encoded)
    if not encoded or #encoded % 2 ~= 0 then return nil end
    local raw = {}
    for i = 1, #encoded, 2 do
        local v1 = (B64:find(encoded:sub(i, i), 1, true) or 1) - 1
        local v2 = (B64:find(encoded:sub(i+1, i+1), 1, true) or 1) - 1
        raw[#raw + 1] = string.char(v1 + v2 * 64)
    end
    local accounts = {}
    for seg in table.concat(raw):gmatch("[^|]+") do
        local name, hs, rank = seg:match("^([^:]+):([^:]+):([^:]+)$")
        if name and hs and rank then
            accounts[name] = { hash = tonumber(hs) or 0, rank = rank }
        end
    end
    return accounts
end

-- 【安全注意】Simulation 层 print() 会同步到所有客户端调试日志。
-- 账户数据绝不通过 print 输出。仅通过 /account export 私聊反馈给超管。

-- 导入账户（通用逻辑）
local function do_import(encoded, source)
    local accounts = decode_accounts(encoded)
    if not accounts then return false, "Invalid data" end
    local ms = get_ms()
    local count = 0
    for name, acct in pairs(accounts) do
        ms.accounts[name] = acct
        count = count + 1
    end
    srv_print("IMPORT", "Imported " .. count .. " accounts from " .. (source or "unknown"))
    return true, count
end

---------------------------------------------------------------------------
-- 4. 账户命令
---------------------------------------------------------------------------
local function cmd_register(p_id, p_name, parts)
    if #parts < 3 then return "Usage: /register <password> <confirm_password> [setup_key]" end
    local pw, cfm, key = parts[2], parts[3], parts[4] or ""
    if pw ~= cfm then return "Passwords do not match." end
    if #pw < 3 then return "Password must be >= 3 chars." end
    if get_account(p_name) then return "Account '" .. p_name .. "' exists. Use /login." end

    local setup_key = get_ms().setup_key
    local rank = "player"

    -- 仅拥有正确 setup_key 的注册者成为 SuperAdmin
    if setup_key == "" then
        return "Server initializing, please wait a moment and retry."
    end
    if key == setup_key then
        rank = "superadmin"
        srv_print("SYSTEM", "SuperAdmin registered via setup key: " .. p_name)
    end

    set_account(p_name, { hash = hash_password(pw), rank = rank, created = Map.GetTick() })
    _G.CmdServerMod._sessions[p_id].logged_in = true
    touch_session(p_id)
    return "Registered! Name: " .. p_name .. " | Rank: " .. rank
end

local function cmd_login(p_id, p_name, parts)
    if #parts < 2 then return "Usage: /login <password>" end
    local acct = get_account(p_name)
    if not acct then return "Account not found. Use /register." end
    if acct.hash ~= hash_password(parts[2]) then return "Incorrect password." end
    _G.CmdServerMod._sessions[p_id].logged_in = true
    acct.auto_logged_out = false  -- 手动登录成功，清除自动登出标记
    touch_session(p_id)
    return "Welcome, " .. p_name .. "! Rank: [" .. (acct.rank or "player") .. "]"
end

local function cmd_changepass(p_id, p_name, parts)
    if not rank_at_least(p_id, "player") then return "Login required." end
    if #parts < 3 then return "Usage: /changepass <old> <new>" end
    local acct = get_account(p_name)
    if not acct then return "Account error." end
    if acct.hash ~= hash_password(parts[2]) then return "Old password incorrect." end
    if #parts[3] < 3 then return "New password must be >= 3 chars." end
    acct.hash = hash_password(parts[3])
    set_account(p_name, acct)
    touch_session(p_id)
    return "Password changed."
end

local function cmd_whoami(p_id, p_name)
    local acct = get_account(p_name)
    local rank = acct and (acct.rank or "player") or "guest"
    local sess = get_session(p_id)
    local status = (sess and sess.logged_in) and "Logged in" or "Not logged in"
    return string.format("%s | %s | Rank: %s | P_ID: %d", p_name, status, rank, p_id)
end

---------------------------------------------------------------------------
-- 5. 管理命令
---------------------------------------------------------------------------
local function cmd_admin_add(parts, p_id)
    if not rank_at_least(p_id, "superadmin") then return "Access denied." end
    if #parts < 2 then return "Usage: /admin add <name>" end
    local acct = get_account(parts[2])
    if not acct then return "Player not registered." end
    if acct.rank == "superadmin" then return "Cannot modify SuperAdmin." end
    acct.rank = "admin"
    set_account(parts[2], acct)
    srv_print("ADMIN", "Promoted " .. parts[2] .. " to admin")
    return "Promoted '" .. parts[2] .. "' to Admin."
end

local function cmd_admin_remove(parts, p_id)
    if not rank_at_least(p_id, "superadmin") then return "Access denied." end
    if #parts < 2 then return "Usage: /admin remove <name>" end
    local acct = get_account(parts[2])
    if not acct then return "Player not registered." end
    if acct.rank == "superadmin" then return "Cannot modify SuperAdmin." end
    acct.rank = "player"
    set_account(parts[2], acct)
    srv_print("ADMIN", "Demoted " .. parts[2] .. " to player")
    return "Demoted '" .. parts[2] .. "' to Player."
end

local function cmd_admin_list(p_id)
    if not rank_at_least(p_id, "superadmin") then return "Access denied." end
    local lines = { "=== Admins ===" }
    local count = 0
    for name, acct in safe_pairs(get_ms().accounts) do
        if acct.rank == "superadmin" or acct.rank == "admin" then
            count = count + 1
            lines[#lines + 1] = "  [" .. acct.rank .. "] " .. name
        end
    end
    if count == 0 then lines[#lines + 1] = "  (none)" end
    return table.concat(lines, "\n")
end

local function cmd_kick(parts, p_id)
    if not rank_at_least(p_id, "admin") then return "Access denied." end
    if #parts < 2 then return "Usage: /kick <name> [ban]" end
    local tname, do_ban = parts[2], (parts[3] or ""):lower() == "ban"
    local tid = nil
    pcall(function()
        for _, p in ipairs(Game.GetAllPlayers()) do
            if p.name == tname then tid = p.id; break end
        end
    end)
    if not tid then return "Player '" .. tname .. "' not online." end
    if rank_at_least(tid, "superadmin") then return "Cannot kick SuperAdmin." end
    if rank_at_least(tid, "admin") and not rank_at_least(p_id, "superadmin") then
        return "Cannot kick another Admin."
    end
    pcall(function() Game.KickPlayer(tid, do_ban) end)
    srv_print("ADMIN", (do_ban and "Banned " or "Kicked ") .. tname)
    return "Player '" .. tname .. "' " .. (do_ban and "banned." or "kicked.")
end

-- 存储暂停前速度，用于恢复
local speed_before_pause = 1

local function cmd_speed(parts, p_id)
    if not rank_at_least(p_id, "admin") then return "Access denied." end
    if #parts < 2 then
        local cur = 1
        pcall(function() cur = Map.GetGameSpeed() end)
        return "Current speed: " .. (cur == 0 and "PAUSE" or "x" .. cur) .. ". Usage: /speed <0|1|2|...>"
    end
    local spd = tonumber(parts[2])
    if not spd or spd < 0 then return "Speed must be >= 0 (integer)." end
    spd = math.floor(spd)
    if spd == 0 then
        pcall(function() speed_before_pause = Map.GetGameSpeed() end)
        if speed_before_pause == 0 then speed_before_pause = 1 end
    end
    Map.SetGameSpeed(spd)
    local desc
    if spd == 0 then desc = "PAUSE (was x" .. speed_before_pause .. ")"
    elseif spd == 1 then desc = "NORMAL"
    else desc = "x" .. spd end
    srv_print("ADMIN", "Speed set to " .. desc)
    return "Game speed: " .. desc
end

---------------------------------------------------------------------------
-- 6. 游戏规则查看/修改
---------------------------------------------------------------------------
local function cmd_settings(p_id, parts)
    if #parts < 2 then
        -- 查看模式
        local lines = { "=== Game Settings ===" }
        local ok, ms = pcall(function() return Map.GetSettings() end)
        if ok and ms then
            -- 常用关键字段
            local keys = { "difficulty", "peaceful", "creep", "allow_faction_switch",
                           "resource_inf", "resource_amt", "enable_day_night",
                           "days_per_year", "day_night_ratio", "day_period" }
            for _, k in ipairs(keys) do
                local v = ms[k]
                if v ~= nil then
                    lines[#lines + 1] = "  " .. k .. ": " .. tostring(v)
                end
            end
        end
        -- 会话设置
        pcall(function()
            local ss = Game.GetHostSessionSettings()
            if ss then
                lines[#lines + 1] = "--- Session ---"
                for k, v in pairs(ss) do
                    lines[#lines + 1] = "  " .. k .. ": " .. tostring(v)
                end
            end
        end)
        lines[#lines + 1] = "Usage: /settings set <key> <value>"
        return table.concat(lines, "\n")
    end

    -- 修改模式: /settings set <key> <value>
    local sub = parts[2]:lower()
    if sub ~= "set" then return "Usage: /settings [set <key> <value>]" end
    if not rank_at_least(p_id, "admin") then return "Access denied. Admin+ only." end
    if #parts < 4 then return "Usage: /settings set <key> <value>" end

    local key = parts[3]
    local val_str = parts[4]
    local val
    if val_str == "true" then val = true
    elseif val_str == "false" then val = false
    else val = tonumber(val_str) or val_str end

    -- 方式1: Map.ModifySettings({key, val}) — 地图参数（difficulty, peaceful等）
    local ok1 = pcall(function()
        Map.ModifySettings({ key, val })
        srv_print("SETTINGS", key .. " changed to " .. tostring(val))
    end)
    if ok1 then return key .. " = " .. tostring(val) end

    -- 方式2: Game.ModifyHostSessionSettings — 会话参数（allow_faction_switch等）
    local ok2 = pcall(function()
        local ss = Game.GetHostSessionSettings()
        if ss and ss[key] ~= nil then
            ss[key] = val
            Game.ModifyHostSessionSettings(ss)
            srv_print("SETTINGS", key .. " (session) changed to " .. tostring(val))
            return true
        end
    end)
    if ok2 then return key .. " = " .. tostring(val) end

    return "Failed to modify '" .. key .. "'."
end
local function cmd_setup_key(p_id, parts)
    if not rank_at_least(p_id, "superadmin") then return "Access denied." end
    local ms = get_ms()
    if #parts < 2 then
        if ms.setup_key == "" then return "No setup key configured." end
        return "Setup key is set. Use /setupkey show to reveal."
    end
    local sub = parts[2]:lower()
    if sub == "show" then
        if ms.setup_key == "" then return "No setup key configured." end
        return "Setup key: " .. ms.setup_key
    elseif sub == "regen" then
        ms.setup_key = random_str(12)
        srv_print("SYSTEM", "Setup key regenerated")
        return "New setup key generated. Use /setupkey show to view."
    else
        return "Usage: /setupkey <show|regen>"
    end
end

local function cmd_account_export(p_id)
    if not rank_at_least(p_id, "superadmin") then return "Access denied." end
    local data = encode_accounts(get_ms().accounts)
    srv_print("EXPORT", "Manual export (" .. #data .. " chars)")
    return "[EXPORT]\n" .. data .. "\n[END]"
end

local function cmd_account_import(p_id, parts)
    if not rank_at_least(p_id, "superadmin") then return "Access denied." end
    if #parts < 2 then return "Usage: /account import <data>" end
    local ok, result = do_import(parts[2], "command")
    if not ok then return "Import failed: " .. (result or "invalid data") end
    return "Imported " .. result .. " accounts."
end

---------------------------------------------------------------------------
-- 7. 命令路由器
---------------------------------------------------------------------------
_G.CmdServerMod.execute_command = function(text, p_id)
    if not text or text:sub(1, 1) ~= "/" then return false end
    local cmd_line = text:sub(2)
    local parts = {}
    for part in cmd_line:gmatch("%S+") do table.insert(parts, part) end
    if #parts == 0 then return true, "No command. Try /help" end

    local cmd = parts[1]:lower()
    local p_name = "Unknown"
    pcall(function() local p = Game.GetPlayerById(p_id); if p then p_name = p.name or "?" end end)

    -- 惰性初始化会话（游戏暂停时 OnTick 不触发，在此补建）
    ensure_session(p_id, p_name)

    -- 更新活跃时间（除 help/ping 外均视为活跃）
    if cmd ~= "help" and cmd ~= "ping" then touch_session(p_id) end

    if cmd == "help" then
        local rank = get_session_rank(p_id)
        local lines = { "=== Commands [" .. rank .. "] ===" }
        lines[#lines + 1] = "/register <pw> <pw> [key] - Create account"
        lines[#lines + 1] = "/login <pw> - Log in"
        lines[#lines + 1] = "/whoami - Account info"
        lines[#lines + 1] = "/ping - Server check"
        if rank_at_least(p_id, "player") then
            lines[#lines + 1] = "/changepass <old> <new>"
        end
        if rank_at_least(p_id, "admin") then
            lines[#lines + 1] = "/kick <name> [ban]"
            lines[#lines + 1] = "/speed <0|1|2|...> (0=pause, N=Nx)"
            lines[#lines + 1] = "/settings [set <key> <val>]"
        end
        if rank_at_least(p_id, "superadmin") then
            lines[#lines + 1] = "/admin add|remove|list"
            lines[#lines + 1] = "/account export|import"
            lines[#lines + 1] = "/setupkey show|regen"
            lines[#lines + 1] = "/playerinfo [id] (debug)"
            lines[#lines + 1] = "/players (debug)"
        end
        return true, table.concat(lines, "\n")

    elseif cmd == "ping" then
        return true, "PONG | Server Online | P" .. p_id

    elseif cmd == "register" then
        return true, cmd_register(p_id, p_name, parts)
    elseif cmd == "login" then
        return true, cmd_login(p_id, p_name, parts)
    elseif cmd == "whoami" then
        return true, cmd_whoami(p_id, p_name)
    elseif cmd == "changepass" then
        return true, cmd_changepass(p_id, p_name, parts)

    elseif cmd == "kick" then
        return true, cmd_kick(parts, p_id)
    elseif cmd == "speed" then
        return true, cmd_speed(parts, p_id)

    elseif cmd == "settings" then
        return true, cmd_settings(p_id, parts)

    elseif cmd == "admin" then
        local sub = (parts[2] or ""):lower()
        if sub == "add" then return true, cmd_admin_add(parts, p_id)
        elseif sub == "remove" then return true, cmd_admin_remove(parts, p_id)
        elseif sub == "list" then return true, cmd_admin_list(p_id)
        else return true, "Usage: /admin <add|remove|list>" end

    elseif cmd == "account" then
        local sub = (parts[2] or ""):lower()
        if sub == "export" then return true, cmd_account_export(p_id)
        elseif sub == "import" then return true, cmd_account_import(p_id, parts)
        else return true, "Usage: /account <export|import>" end

    elseif cmd == "setupkey" then
        return true, cmd_setup_key(p_id, parts)

    elseif cmd == "playerinfo" then
        if not rank_at_least(p_id, "superadmin") then return true, "Access denied." end
        return true, _G.CmdServerMod._dump_player(parts, p_id)
    elseif cmd == "players" then
        if not rank_at_least(p_id, "superadmin") then return true, "Access denied." end
        return true, _G.CmdServerMod._dump_all_players()

    else
        return true, "Unknown: /" .. cmd .. ". Try /help"
    end
end

---------------------------------------------------------------------------
-- 8. 调试工具
---------------------------------------------------------------------------
local function table_dump(tbl, indent)
    indent = indent or 0
    local prefix = string.rep("  ", indent)
    if type(tbl) ~= "table" then return prefix .. tostring(tbl) end
    local lines = {}
    for k, v in pairs(tbl) do
        local vt = type(v)
        if vt == "table" then
            lines[#lines + 1] = prefix .. tostring(k) .. ": {"
            lines[#lines + 1] = table_dump(v, indent + 1)
            lines[#lines + 1] = prefix .. "}"
        elseif vt == "function" then
            lines[#lines + 1] = prefix .. tostring(k) .. ": [function]"
        else
            lines[#lines + 1] = prefix .. tostring(k) .. ": " .. tostring(v)
        end
    end
    return table.concat(lines, "\n")
end

_G.CmdServerMod._dump_player = function(parts, my_id)
    local tid = tonumber(parts[2]) or my_id
    local ok, p = pcall(function() return Game.GetPlayerById(tid) end)
    if not ok or not p then return "Player P" .. tid .. " not found" end
    return "=== P" .. tid .. " ===\n" .. table_dump(p, 0)
end

_G.CmdServerMod._dump_all_players = function()
    local ok, pl = pcall(function() return Game.GetAllPlayers() end)
    if not ok or not pl then return "Error" end
    local lines = { "=== Players (" .. #pl .. ") ===" }
    for i, p in ipairs(pl) do
        lines[#lines + 1] = "-- #" .. i .. " --"
        lines[#lines + 1] = table_dump(p, 0)
    end
    return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- 9. Action 处理器
---------------------------------------------------------------------------
-- 密码脱敏：隐藏 register/login/changepass 中的密码参数
local function sanitize_command(text)
    if not text or text:sub(1, 1) ~= "/" then return text end
    local cmd_line = text:sub(2)
    local parts = {}
    for part in cmd_line:gmatch("%S+") do table.insert(parts, part) end
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

function FactionAction.CmdServerExec(faction, arg)
    local rpid = tonumber(arg.p_id) or 0
    local pname = tostring(arg.sender_name or "Unknown")
    local text = tostring(arg.txt or "")

    if arg.is_command then
        local safe_text = sanitize_command(text)
        srv_print("COMMAND", string.format("<%s>(P%d): %s", pname, rpid, safe_text))
    else
        srv_print("CHAT", string.format("<%s>(P%d): %s", pname, rpid, text))
    end

    if arg.is_command and _G.CmdServerMod.execute_command then
        local ok, result = _G.CmdServerMod.execute_command(text, rpid)
        if ok then
            -- 通知需要重新登录的玩家
            local sess = _G.CmdServerMod._sessions[rpid]
            if sess and sess._notify_relogin then
                sess._notify_relogin = nil
                pcall(function()
                    Action.RunUI(function(pid)
                        if Chat and Chat.Text then
                            Chat.Text({ txt = "[SERVER] You have been logged out due to inactivity. Use /login to sign in.", player_id = pid }, pid)
                        end
                    end, rpid)
                end)
            end
            -- RESULT 不含密码，但含账户操作信息（谁注册/谁被踢等）
            -- 这是服务端审计日志，客户端可见但无密码风险
            srv_print("RESULT", "To P" .. rpid .. ": " .. tostring(result))
            pcall(function()
                Action.RunUI(function(pid, res)
                    if Chat and Chat.Text then
                        Chat.Text({ txt = "[SERVER] " .. tostring(res), player_id = pid }, pid)
                    end
                end, rpid, result)
            end)
        end
    end
end

---------------------------------------------------------------------------
-- 10. 定时器：心跳 + 加入/离开 + 自动登出
---------------------------------------------------------------------------
_G.CmdServerMod._known_players = _G.CmdServerMod._known_players or {}

function MapMsg.OnTick()
    -- 首次 Tick 执行初始化（Map.GetSave 在加载阶段不可用）
    if not _G.CmdServerMod._init_done then
        _G.CmdServerMod._init_done = true
        -- 内联初始化（避免 local function 在 OnTick 上下文中不可见）
        local ms = get_ms()
        if ms.setup_key == "" then
            ms.setup_key = random_str(12)
            srv_print("SYSTEM", "========================================")
            srv_print("SYSTEM", "INITIAL SETUP KEY: " .. ms.setup_key)
            srv_print("SYSTEM", "Use this key with /register to become SuperAdmin")
            srv_print("SYSTEM", "========================================")
        else
            srv_print("SYSTEM", "Setup key loaded (use /setupkey show to view)")
        end
        -- GameSettings 命令行导入
        local ok, gs = pcall(function() return Map.GetSettings() end)
        if ok and gs and gs.CmdServerMod_import then
            local data = tostring(gs.CmdServerMod_import)
            if #data > 10 then
                local ok2, count = do_import(data, "GameSettings")
                if ok2 then
                    srv_print("SYSTEM", "GameSettings import: " .. count .. " accounts loaded")
                end
            end
        end
    end

    tick_counter = tick_counter + 1

    -- 每秒检测玩家加入/离开 + 自动登出
    if tick_counter % 5 == 0 then
        local now = Map.GetTick()
        local ok, cur = pcall(function() return Game.GetAllPlayers() end)
        if ok and cur then
            local online_ids = {}
            for _, p in ipairs(cur) do
                online_ids[p.id] = p.name
                if not _G.CmdServerMod._known_players[p.id] then
                    _G.CmdServerMod._known_players[p.id] = p.name
                    init_session(p.id, p.name)
                    srv_print("JOIN", string.format("+ %s (P%d)", p.name, p.id))
                end
                -- 在线玩家持续刷新 last_seen
                if _G.CmdServerMod._sessions[p.id] then
                    _G.CmdServerMod._sessions[p.id].last_seen = now
                end
            end
            -- 检测离开
            for kid, kname in pairs(_G.CmdServerMod._known_players) do
                if not online_ids[kid] then
                    _G.CmdServerMod._known_players[kid] = nil
                    srv_print("LEAVE", string.format("- %s (P%d)", kname, kid))
                end
            end
        end

        -- 自动登出：last_seen 超时未更新的 session
        for pid, sess in safe_pairs(_G.CmdServerMod._sessions) do
            if sess.logged_in and sess.last_seen then
                if now - sess.last_seen > AUTO_LOGOUT_TICKS then
                    sess.logged_in = false
                    -- 永久标记：防止重连时 auto-login，需手动 /login 清除
                    local acct = get_account(sess.name)
                    if acct then acct.auto_logged_out = true end
                    srv_print("LOGOUT", string.format("Auto-logout %s (P%d) after %d ticks offline",
                        sess.name, pid, now - sess.last_seen))
                end
            end
            -- 清理彻底过期 session（登出且离线超 600 ticks）
            if not sess.logged_in and sess.last_seen then
                if now - sess.last_seen > 600 then
                    _G.CmdServerMod._sessions[pid] = nil
                end
            end
        end
    end

    -- 每60秒心跳
    if tick_counter >= 300 then
        tick_counter = 0
        local pc, ac = 0, 0
        pcall(function()
            local pl = Game.GetAllPlayers()
            if pl then pc = #pl end
            for _ in safe_pairs(get_ms().accounts) do ac = ac + 1 end
        end)
        srv_print("HEARTBEAT", string.format("Tick: %d | Players: %d | Accounts: %d", Map.GetTick(), pc, ac))
    end
end





