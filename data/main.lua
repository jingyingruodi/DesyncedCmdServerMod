-- Desynced Command Console - Core Logic (v1.9.0)
-- 职责：外置存储 + 随机密钥 + 自动登出 + 权限系统 + 密码脱敏 + 暂停兼容
--
-- v1.9.0 变更（每条都有代码级或游戏源码级证据，详见 notes/接手现状与发现.md）：
--   1. setup key 改用幂等 ensure_init()，并在指令入口兜底调用
--      原来只在 OnTick 首帧生成 —— 模拟不推进（暂停/无人连接）时全服无人能注册超管
--   2. 机密结果（/account export、/setupkey show）不再走 srv_print。
--      Simulation 层 print 会同步到所有客户端调试日志（用户 2026-07 的客户端日志已证实），
--      原实现等于把账户数据与 setup key 广播给全服 → 拿到 key 即可提权
--   3. setup key 支持服务器命令行 -SetupKey=xxx 注入（推荐）；此路径下**绝不打印**
--   4. /settings set 改为「白名单 + 回读比对」判成败，并拒绝世界生成类键
--      （原来用 pcall 判成功，未知键也报成功；会话设置分支还是死代码）
--   5. 指令通道 FactionAction → PlayerAction：player_id 由引擎提供，客户端无法冒充
--   6. 存档读写改用 Map.GetSave() 的 mod 专属子表（原来多套一层）
--   7. KickPlayer 不再 pcall 吞错后谎报成功

local package = ...
_G.CmdServerMod = _G.CmdServerMod or {}
local version = "1.9.5"
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

-- 私有结果标记：命令返回 (true, text, SECRET) 表示该文本**不得**进入会广播的 print，
-- 只能通过 Action.RunUI 私聊给发起者。（Simulation 层 print 会同步到所有客户端日志）
local SECRET = {}

-- 从服务器命令行读取 -SetupKey=xxx
-- 这是唯一「不泄露」的 setup key 注入方式：命令行只有服务器运维能看到。
local function setup_key_from_cmdline()
    local ok, args = pcall(function() return Game.GetCommandLineArguments() end)
    if not ok or type(args) ~= "string" then return nil end
    local v = args:match("%-SetupKey=([%w_%-]+)") or args:match("%-setupkey=([%w_%-]+)")
    if v and #v >= 4 then return v end
    return nil
end

srv_print("CmdServerMod", "Data Layer Booting v" .. version)

---------------------------------------------------------------------------
-- 1. 数据访问层 (Map.GetSave 存档内持久化，跨存档用 /account export/import)
---------------------------------------------------------------------------
-- Map.GetSave() 无参时，对「不含当前 scenario 的 mod」返回本 mod 的专属子表
-- parent.mods[mod_id]，因此直接用它的字段即可，不必再套一层。
local function get_ms()
    local save = Map.GetSave()
    -- 一次性迁移：v1.8.0 曾写到 save.CmdServerMod.*
    if type(save.CmdServerMod) == "table" then
        local old = save.CmdServerMod
        if old.accounts and not save.accounts then save.accounts = old.accounts end
        if old.setup_key and old.setup_key ~= "" and not save.setup_key then
            save.setup_key = old.setup_key
        end
        save.CmdServerMod = nil
    end
    if not save.accounts then save.accounts = {} end
    if not save.setup_key then save.setup_key = "" end
    return save
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
    -- 用「登录成功时认证过的账号名」，而不是当前显示名 ——
    -- 否则玩家改名后权限会跟着漂移
    local acct = get_account(sess.acct_name or sess.name)
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
    local sess = _G.CmdServerMod._sessions[p_id]
    if sess and sess.name == p_name then
        sess.last_seen = Map.GetTick()
    else
        sess = { name = p_name, acct_name = nil, logged_in = false, last_seen = Map.GetTick() }
        _G.CmdServerMod._sessions[p_id] = sess
    end
    if sess.logged_in then return end

    local acct = get_account(p_name)
    if not acct then return end

    if acct.auto_logged_out then
        -- 曾被自动登出，需手动 /login
        sess._notify_relogin = true
        srv_print("LOGIN", string.format("%s (P%d) was auto-logged out, manual /login required", p_name, p_id))
        return
    end

    -- ★ 自动登录必须同时满足「账号存在」**和**「账号绑定的 player id 与当前一致」。
    -- 只看名字是严重的认证漏洞：任何玩家只要把自己改名成别人的名字，
    -- 就会在 init_session 里被自动登录成对方（无需密码）。
    if acct.bound_player_id ~= p_id then
        srv_print("LOGIN", string.format(
            "%s (P%d) 未自动登录：账号已绑定到另一个 player id，需手动 /login", p_name, p_id))
        sess._notify_relogin = true
        return
    end

    if not AUTO_LOGIN then
        -- 默认路径：即使名字和 player id 都对上了，也要求手动 /login
        sess._notify_relogin = true
        srv_print("LOGIN", string.format("%s (P%d) 已注册账号，等待手动 /login", p_name, p_id))
        return
    end

    sess.logged_in = true
    sess.acct_name = p_name
    srv_print("LOGIN", string.format("%s (P%d) auto-logged as [%s]", p_name, p_id, acct.rank or "player"))
end

-- 已认证的账号名（改名不改变已登录身份）
local function my_account_name(p_id, p_name)
    local sess = get_session(p_id)
    if sess and sess.logged_in and sess.acct_name then return sess.acct_name end
    return p_name
end
_G.CmdServerMod._my_account_name = my_account_name

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

-- 模拟速率：游戏本体 data/instructions.lua 里写明 "5 simulation ticks per second"
local TICKS_PER_SECOND = 5

-- ★ 自动登录开关（默认关闭，且**不建议**在没有稳定身份前打开）
-- 原因：Desynced 没有向模组暴露 SteamID 之类的稳定身份。可用的只有
--   (a) 玩家显示名 —— 谁都能改名冒充；
--   (b) player.id  —— 会被回收再利用。
-- 现有 API 里 player 对象只有 id / name / faction_id / ready / is_local / is_host，
-- 所以「自动登录」在当前版本下**无法做到安全**。默认强制每次连接 /login。
-- 将来若引擎暴露了稳定账号标识，把这个开关打开并改用该标识即可。
local AUTO_LOGIN = false

-- 各种周期（原来的 5 / 150 / 300 / 600 都是从这个 5 推出来的魔数）
local PRESENCE_CHECK_TICKS = TICKS_PER_SECOND          -- 每秒检查一次在线状态
local AUTO_LOGOUT_TICKS    = 30 * TICKS_PER_SECOND     -- 离线 30 秒自动登出
local SESSION_GC_TICKS     = 120 * TICKS_PER_SECOND    -- 登出且离线 2 分钟后回收 session
local HEARTBEAT_TICKS      = 60 * TICKS_PER_SECOND     -- 每 60 秒心跳
-- 注意：若将来引擎改了这个速率，这里要同步改（已列为待实测项）

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
-- 3.5 运行期诊断（用于在真实服务器上确认引擎行为）
---------------------------------------------------------------------------
-- 输出**只含结构与计数，绝不含任何值**（账号哈希、setup key 都不会出现），
-- 因此可以安全地进服务端控制台（那份日志会同步到所有客户端调试日志）。
-- 触发方式：
--   * 服务器命令行带 -CmdServerMod_Diag  → 首个 OnTick 自动打印一次
--   * 游戏内 /diag（仅超管）
local function collect_diag()
    local lines = {}
    local function add(k, fn)
        local ok, v = pcall(fn)
        lines[#lines + 1] = k .. "=" .. (ok and tostring(v) or ("ERR:" .. tostring(v)))
    end
    add("version", function() return version end)
    add("tick", function() return Map.GetTick() end)
    add("is_simulation", function() return Map.IsSimulation() end)
    add("net_mode", function() return Game.GetNetMode() end)
    add("dedicated", function() return select(2, Game.GetMultiplayerSession()) end)
    add("speed", function() return Map.GetGameSpeed() end)
    add("players", function() return #Game.GetAllPlayers() end)
    -- ★ 必须脱敏：命令行里可能带 -SetupKey=<密钥>，而诊断输出会进服务端控制台
    add("args", function()
        local a = tostring(Game.GetCommandLineArguments())
        a = a:gsub("[%-/][Ss]etup[Kk]ey=%S+", "-SetupKey=***")
        return a
    end)

    -- 存档结构：只列键名与类型
    local ok, save = pcall(function() return Map.GetSave() end)
    if not ok then
        lines[#lines + 1] = "GetSave=ERR:" .. tostring(save)
        return lines
    end
    if type(save) ~= "table" then
        lines[#lines + 1] = "GetSave=type(" .. type(save) .. ")"
        return lines
    end
    local ks, n_accounts, has_key = {}, 0, false
    -- 注意：不要用 pcall 去包 pairs —— pcall 只保留第一个返回值，
    -- 泛型 for 会拿到 (next, nil) 从而报 "table expected, got nil"。
    -- safe_pairs 对 table 原样返回 pairs 的三个值，对非 table 返回空迭代器。
    for k, v in safe_pairs(save) do ks[#ks + 1] = tostring(k) .. ":" .. type(v) end
    table.sort(ks)
    if type(save.accounts) == "table" then
        for _ in safe_pairs(save.accounts) do n_accounts = n_accounts + 1 end
    end
    if type(save.setup_key) == "string" and #save.setup_key > 0 then has_key = true end
    lines[#lines + 1] = "save_keys=[" .. table.concat(ks, ", ") .. "]"
    lines[#lines + 1] = "accounts=" .. n_accounts
    lines[#lines + 1] = "setup_key_present=" .. tostring(has_key)
    -- v1.8.0 曾把数据写在 save.CmdServerMod 下；如果它还在，说明**嵌套表确实被持久化了**
    if type(save.CmdServerMod) == "table" then
        local ks2 = {}
        for k, v in safe_pairs(save.CmdServerMod) do
            ks2[#ks2 + 1] = tostring(k) .. ":" .. type(v)
        end
        table.sort(ks2)
        lines[#lines + 1] = "LEGACY_nested_keys=[" .. table.concat(ks2, ", ") .. "]"
    end
    return lines
end
_G.CmdServerMod._collect_diag = collect_diag

local function diag_requested()
    local ok, args = pcall(function() return Game.GetCommandLineArguments() end)
    return ok and type(args) == "string" and args:find("CmdServerMod_Diag", 1, true) ~= nil
end

-- 现场调试开关：true 时，每个服务器进程在首个 tick 自动打印一次 collect_diag()。
-- 只在「需要抓现场数据」的阶段临时打开，**正式发布应保持 false**
-- （输出本身无害：只有结构、计数和命令行，不含任何机密）。
local STARTUP_DIAG = true   -- ★ 现场诊断构建：抓完数据后必须改回 false

-- 是否要自动打印：命令行开关 -CmdServerMod_Diag，或上面的现场调试开关
local function diag_auto_enabled()
    return STARTUP_DIAG or diag_requested()
end

---------------------------------------------------------------------------
-- 3.6 幂等初始化（必须在游戏已开始之后调用；Map.GetSave 在此之前不可用）
---------------------------------------------------------------------------
-- 既从 MapMsg.OnTick 调用，也从指令入口调用 —— 因为游戏暂停/无人连接时 OnTick 不触发，
-- 而 setup key 只在初始化时生成，否则 /register 会永远返回「Server initializing」，
-- 全服没有人能成为超管。
local function ensure_init()
    if _G.CmdServerMod._init_done then return true end
    local ok, err = pcall(function()
        local ms = get_ms()

        if ms.setup_key == "" then
            local from_cmd = setup_key_from_cmdline()
            if from_cmd then
                ms.setup_key = from_cmd
                srv_print("SYSTEM", "Setup key loaded from command line (-SetupKey). It is never printed.")
            else
                ms.setup_key = random_str(12)
                -- ⚠️ 下面这一行会同步到所有客户端调试日志。这是 bootstrap 的固有代价：
                -- 在拿到第一个超管之前，运维必须能看到 key。拿到后请勿再用 /setupkey show，
                -- 或直接用 -SetupKey= 启动以免出现这一行。
                srv_print("SYSTEM", "========================================================")
                srv_print("SYSTEM", "INITIAL SETUP KEY: " .. ms.setup_key)
                srv_print("SYSTEM", "Register immediately, or restart with -SetupKey=<key> to avoid printing.")
                srv_print("SYSTEM", "========================================================")
            end
        else
            srv_print("SYSTEM", "Setup key loaded from save.")
        end

        -- GameSettings 命令行导入
        local ok_gs, gs = pcall(function() return Map.GetSettings() end)
        if ok_gs and gs and gs.CmdServerMod_import then
            local data = tostring(gs.CmdServerMod_import)
            if #data > 10 then
                local ok_imp, count = do_import(data, "GameSettings")
                if ok_imp then
                    srv_print("SYSTEM", "GameSettings import: " .. tostring(count) .. " accounts loaded")
                end
            end
        end
    end)
    if not ok then
        -- 典型：Unable to access save table before game has started —— 下次再试
        if os.getenv and os.getenv("CmdServerMod_DEBUG") then
            srv_print("DEBUG", "ensure_init deferred: " .. tostring(err))
        end
        return false
    end
    _G.CmdServerMod._init_done = true

    -- 命令行要求诊断时，在首个 tick 自动打印一次运行期事实（只含结构，无值）
    if diag_auto_enabled() and not _G.CmdServerMod._diag_done then
        _G.CmdServerMod._diag_done = true
        pcall(function() srv_print("DIAG", table.concat(collect_diag(), " | ")) end)
    end
    return true
end

-- 供调试/测试使用
_G.CmdServerMod._ensure_init = ensure_init

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

    set_account(p_name, {
        hash = hash_password(pw), rank = rank, created = Map.GetTick(),
        bound_player_id = p_id,   -- 自动登录的身份锚点（见 init_session）
    })
    local sess = _G.CmdServerMod._sessions[p_id]
    if sess then
        sess.logged_in = true
        sess.acct_name = p_name
    end
    touch_session(p_id)
    return "Registered! Name: " .. p_name .. " | Rank: " .. rank
end

local function cmd_login(p_id, p_name, parts)
    if #parts < 2 then return "Usage: /login <password>" end
    local acct = get_account(p_name)
    if not acct then return "Account not found. Use /register." end
    if acct.hash ~= hash_password(parts[2]) then return "Incorrect password." end
    local sess = _G.CmdServerMod._sessions[p_id]
    if sess then
        sess.logged_in = true
        sess.acct_name = p_name
    end
    acct.auto_logged_out = false            -- 手动登录成功，清除自动登出标记
    acct.bound_player_id = p_id             -- 密码已验证过，把绑定刷新到本次连接
    set_account(p_name, acct)
    touch_session(p_id)
    return "Welcome, " .. p_name .. "! Rank: [" .. (acct.rank or "player") .. "]"
end

local function cmd_changepass(p_id, p_name, parts)
    if not rank_at_least(p_id, "player") then return "Login required." end
    if #parts < 3 then return "Usage: /changepass <old> <new>" end
    local acct = get_account(my_account_name(p_id, p_name))
    if not acct then return "Account error." end
    if acct.hash ~= hash_password(parts[2]) then return "Old password incorrect." end
    if #parts[3] < 3 then return "New password must be >= 3 chars." end
    acct.hash = hash_password(parts[3])
    set_account(p_name, acct)
    touch_session(p_id)
    return "Password changed."
end

local function cmd_whoami(p_id, p_name)
    local sess = get_session(p_id)
    local acct_name = my_account_name(p_id, p_name)
    local acct = get_account(acct_name)
    local rank = acct and (acct.rank or "player") or "guest"
    local status = (sess and sess.logged_in) and "Logged in" or "Not logged in"
    return string.format("%s | %s | Rank: %s | P_ID: %d | display: %s",
        acct_name, status, rank, p_id, p_name)
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

    -- 不要 pcall 吞错后谎报成功。文档明确 KickPlayer「only available to the host of a
    -- locally running session」，专用服务器上很可能是空操作，所以要复查结果。
    local ok, err = pcall(function() Game.KickPlayer(tid, do_ban) end)
    if not ok then
        srv_print("ADMIN", "KickPlayer failed: " .. tostring(err))
        return "Kick failed: " .. tostring(err)
    end

    local still_online = false
    pcall(function()
        for _, p in ipairs(Game.GetAllPlayers()) do
            if p.id == tid then still_online = true; break end
        end
    end)

    if still_online then
        srv_print("ADMIN", "KickPlayer had no effect (host-only API?) for " .. tname)
        return "Kick was accepted but '" .. tname .. "' is still online "
            .. "(Game.KickPlayer only works for the host of a locally running session)."
    end
    srv_print("ADMIN", (do_ban and "Banned " or "Kicked ") .. tname .. " (by P" .. tostring(p_id) .. ")")
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
    if not spd or spd < 0 then return "Speed must be >= 0 (integer, 0 = pause)." end
    spd = math.floor(spd)
    -- 上界：本体自己用 0/1/2/5/10；超出引擎会拒绝。这里先挡一道，并且不用裸调用。
    local MAX_SPEED = 32
    if spd > MAX_SPEED then
        return string.format("Speed must be between 0 and %d (0 = pause).", MAX_SPEED)
    end
    if spd == 0 then
        pcall(function() speed_before_pause = Map.GetGameSpeed() end)
        if speed_before_pause == 0 then speed_before_pause = 1 end
    end
    local ok_set, err_set = pcall(function() Map.SetGameSpeed(spd) end)
    if not ok_set then
        return "SetGameSpeed failed: " .. tostring(err_set)
    end
    local desc
    if spd == 0 then desc = "PAUSE (was x" .. speed_before_pause .. ")"
    elseif spd == 1 then desc = "NORMAL"
    else desc = "x" .. spd end
    srv_print("ADMIN", "Speed set to " .. desc .. " (by P" .. tostring(p_id) .. ")")
    return "Game speed: " .. desc
end

---------------------------------------------------------------------------
-- 6. 游戏规则查看/修改
---------------------------------------------------------------------------
-- 只允许改动「运行期安全」的键。其余一律拒绝：
--   文档 Map.ModifySettings 明确警告：影响世界生成或太阳模拟的设置在开局后修改会导致
--   游戏崩溃或不同步（seed / elevation_params_* / blight_threshold / plateau_level /
--   landscape / resource_* / enable_day_night / day_period / days_per_year ...）。
local MAP_SETTING_ALLOW = {
    peaceful = true, creep = true, difficulty = true, disable_minigames = true,
}
-- 会话设置（Game.GetHostSessionSettings），不是地图设置
local SESSION_SETTING_ALLOW = {
    allow_faction_switch = true, disable_client_save = true, behavior_limit = true,
}

-- 用「改前改后回读比对」判定成败。
-- 原来用 pcall 的返回值判定是不可靠的：Map.ModifySettings 对未知键既不报错也不生效。
local function apply_map_setting(key, val)
    local ok, before = pcall(function() return Map.GetSettings()[key] end)
    if not ok then return false, "Map.GetSettings() unavailable" end
    if before == nil then return false, "'" .. key .. "' is not a map setting" end
    local ok2, err = pcall(function() Map.ModifySettings(key, val) end)
    if not ok2 then return false, tostring(err) end
    local ok3, after = pcall(function() return Map.GetSettings()[key] end)
    if not ok3 then return false, "cannot read back the setting" end
    if after == val then return true end
    pcall(function() Map.ModifySettings(key, before) end) -- 回滚
    return false, string.format("engine kept %s (asked for %s)", tostring(after), tostring(val))
end

local function apply_session_setting(key, val)
    local ok, ss = pcall(function() return Game.GetHostSessionSettings() end)
    if not ok or type(ss) ~= "table" then return false, "session settings unavailable" end
    if ss[key] == nil then return false, "'" .. key .. "' is not a session setting" end
    local before = ss[key]
    local ok2, err = pcall(function() Game.ModifyHostSessionSettings({ [key] = val }) end)
    if not ok2 then return false, tostring(err) end
    local ok3, ss2 = pcall(function() return Game.GetHostSessionSettings() end)
    if ok3 and type(ss2) == "table" and ss2[key] == val then return true end
    pcall(function() Game.ModifyHostSessionSettings({ [key] = before }) end) -- 回滚
    return false, "engine rejected the change"
end

-- 格式化一个设置值（表格只显示类型，避免刷屏）
local function fmt_setting(v)
    local t = type(v)
    if t == "table" then return "{table}" end
    if t == "string" then return v end
    return tostring(v)
end

-- 列出某个设置表的全部键（排序、带可写标记、限长）
local function list_settings(title, tbl, allow, max_lines)
    local lines = { title }
    if type(tbl) ~= "table" then
        -- 引擎可能把它做成 userdata：那就退回白名单键（索引是安全的）
        for k in pairs(allow) do
            local ok, v = pcall(function() return tbl[k] end)
            if ok and v ~= nil then
                lines[#lines + 1] = "  " .. k .. " = " .. fmt_setting(v) .. (allow[k] and " *" or "")
            end
        end
        if #lines == 1 then lines[#lines + 1] = "  (不可枚举，且白名单键也读不到)" end
        return lines
    end
    local ks = {}
    for k in safe_pairs(tbl) do ks[#ks + 1] = tostring(k) end
    table.sort(ks)
    for i, k in ipairs(ks) do
        if max_lines and i > max_lines then
            lines[#lines + 1] = "  … 以及另外 " .. (#ks - max_lines) .. " 项"
            break
        end
        local v = tbl[k]
        lines[#lines + 1] = "  " .. k .. " = " .. fmt_setting(v) .. (allow[k] and " *" or "")
    end
    if #ks == 0 then lines[#lines + 1] = "  (空)" end
    return lines
end

local function cmd_settings(p_id, parts)
    if #parts < 2 then
        -- 查看模式：**列出全部键**（只读安全），带 * 的才是可改的。
        -- 原实现只列 4 个地图键 + 3 个会话键，管理员看不到全貌。
        local ok, ms = pcall(function() return Map.GetSettings() end)
        local lines = list_settings("=== Game Settings (map) ===",
            ok and ms or nil, MAP_SETTING_ALLOW, 60)
        local ok2, ss = pcall(function() return Game.GetHostSessionSettings() end)
        local slines = list_settings("=== Session Settings ===",
            ok2 and ss or nil, SESSION_SETTING_ALLOW, 30)
        for _, l in ipairs(slines) do lines[#lines + 1] = l end
        lines[#lines + 1] = "* = 可用 /settings set <key> <value> 修改；其余为只读"
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

    local is_map = MAP_SETTING_ALLOW[key] == true
    local is_session = SESSION_SETTING_ALLOW[key] == true
    if not is_map and not is_session then
        return "'" .. key .. "' is not runtime-changeable. Allowed: "
            .. "peaceful, creep, difficulty, disable_minigames (map); "
            .. "allow_faction_switch, disable_client_save, behavior_limit (session)"
    end

    -- 会话键优先走会话 API：allow_faction_switch 这类键**不在** Map.GetSettings() 里
    local order = is_session and { apply_session_setting, apply_map_setting }
                             or  { apply_map_setting, apply_session_setting }
    local last_err
    for _, fn in ipairs(order) do
        local ok, err = fn(key, val)
        if ok then
            srv_print("SETTINGS", key .. " = " .. tostring(val) .. " (by P" .. tostring(p_id) .. ")")
            return key .. " = " .. tostring(val)
        end
        last_err = err
    end
    return "Failed to modify '" .. key .. "': " .. tostring(last_err)
end

local function cmd_setup_key(p_id, parts)
    if not rank_at_least(p_id, "superadmin") then return "Access denied." end
    local ms = get_ms()
    if #parts < 2 then
        if ms.setup_key == "" then return "No setup key configured." end
        return "Setup key is set. Use /setupkey show to reveal it privately."
    end
    local sub = parts[2]:lower()
    if sub == "show" then
        if ms.setup_key == "" then return "No setup key configured." end
        -- ★ 机密：不能走 srv_print（会同步给所有客户端）
        srv_print("SECRET", "P" .. tostring(p_id) .. " revealed the setup key (value withheld from log)")
        return "Setup key: " .. ms.setup_key, SECRET
    elseif sub == "regen" then
        ms.setup_key = random_str(12)
        srv_print("SYSTEM", "Setup key regenerated by P" .. tostring(p_id))
        return "New setup key generated. Use /setupkey show to view it privately.", SECRET
    else
        return "Usage: /setupkey <show|regen>"
    end
end

local function cmd_account_export(p_id)
    if not rank_at_least(p_id, "superadmin") then return "Access denied." end
    local data = encode_accounts(get_ms().accounts)
    -- ★ 机密：账户数据绝不能进入会广播的 print
    srv_print("SECRET", "P" .. tostring(p_id) .. " exported accounts (" .. #data .. " chars, withheld)")
    return "[EXPORT]\n" .. data .. "\n[END]", SECRET
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

    -- ★ 兜底初始化：OnTick 可能永不触发（暂停 / run_without_players=false 且无人连接），
    -- 那时 setup key 就不存在，/register 会永远返回 "Server initializing"，全服没人能当超管。
    ensure_init()

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
            lines[#lines + 1] = "/diag (engine/save diagnostics)"
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
        if sub == "export" then
            local text_out, secret = cmd_account_export(p_id)
            return true, text_out, secret
        elseif sub == "import" then return true, cmd_account_import(p_id, parts)
        else return true, "Usage: /account <export|import>" end

    elseif cmd == "setupkey" then
        local text_out, secret = cmd_setup_key(p_id, parts)
        return true, text_out, secret

    elseif cmd == "playerinfo" then
        if not rank_at_least(p_id, "superadmin") then return true, "Access denied." end
        return true, _G.CmdServerMod._dump_player(parts, p_id)
    elseif cmd == "players" then
        if not rank_at_least(p_id, "superadmin") then return true, "Access denied." end
        return true, _G.CmdServerMod._dump_all_players()

    elseif cmd == "diag" then
        -- 运行期诊断：确认引擎行为（存档表语义、净模式、tick 等）。
        -- 输出只含结构与计数，不含任何机密，所以也可以安全进服务端控制台。
        if not rank_at_least(p_id, "superadmin") then return true, "Access denied." end
        local ok, lines = pcall(collect_diag)
        local text
        if ok then text = table.concat(lines, "\n")
        else text = "diag failed: " .. tostring(lines) end
        pcall(function() srv_print("DIAG", "requested by P" .. tostring(p_id) .. " | " ..
            table.concat(ok and lines or { tostring(lines) }, " | ")) end)
        return true, text

    else
        return true, "Unknown: /" .. cmd .. ". Try /help"
    end
end

---------------------------------------------------------------------------
-- 8. 调试工具
---------------------------------------------------------------------------
-- ⚠️ 引擎对象（player / entity / Chat 表 ...）很可能是 **userdata**。
-- 2026-03 的会话就是因为用 pairs() 遍历 Chat userdata 崩的：
--   bad argument #1 to 'for iterator' (table expected, got userdata)
-- 所以这里一律：先试 pairs，失败就退回「已知字段白名单」。
local PLAYER_FIELDS = { "id", "name", "faction_id", "ready", "is_local", "is_host" }

local function player_summary(p)
    local lines = {}
    local seen = {}
    for _, k in ipairs(PLAYER_FIELDS) do
        local ok, v = pcall(function() return p[k] end)
        if ok and v ~= nil then
            seen[k] = true
            lines[#lines + 1] = "  " .. k .. " = " .. tostring(v)
        end
    end
    -- 引擎对象可能是 userdata，甚至可能是带 __pairs 元方法且会抛错的表，
    -- 所以这里把**整个遍历**包进 pcall，而不是只包 pairs 本身。
    if type(p) == "table" then
        pcall(function()
            for k, v in pairs(p) do
                if not seen[k] then
                    lines[#lines + 1] = "  " .. tostring(k) .. " = " .. tostring(v)
                end
            end
        end)
    end
    if #lines == 0 then
        lines[1] = "  (无可读字段；对象类型 = " .. type(p) .. ")"
    end
    return table.concat(lines, "\n")
end

local function table_dump(tbl, indent)
    indent = indent or 0
    local prefix = string.rep("  ", indent)
    if type(tbl) ~= "table" then return prefix .. tostring(tbl) end
    if indent > 3 then return prefix .. "(...)" end
    local lines = {}
    -- 同样要用 safe_pairs：不能用 pcall 包装 pairs（会丢掉 state 与 control）
    for k, v in safe_pairs(tbl) do
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
    return "=== P" .. tid .. " (type=" .. type(p) .. ") ===\n" .. player_summary(p)
end

_G.CmdServerMod._dump_all_players = function()
    local ok, pl = pcall(function() return Game.GetAllPlayers() end)
    if not ok or type(pl) ~= "table" then return "Error: GetAllPlayers unavailable" end
    local lines = { "=== Players (" .. #pl .. ") ===" }
    for i, p in ipairs(pl) do
        lines[#lines + 1] = "-- #" .. i .. " (type=" .. type(p) .. ") --"
        lines[#lines + 1] = player_summary(p)
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

-- ★ v1.9.0：改用 PlayerAction。
-- 引擎签名：function PlayerAction.ACTIONID(player_id, faction, arg)
-- player_id 由引擎提供，**客户端无法冒充**；原来用的 FactionAction 是从 arg 里读
-- 客户端自填的 p_id/sender_name，任何人都能伪造成别人。
function PlayerAction.CmdServerExec(player_id, faction, arg)
    local rpid = tonumber(player_id) or 0
    arg = arg or {}

    -- 名字以服务端为准，不信任客户端传的 sender_name
    local pname = "Unknown"
    pcall(function()
        local p = Game.GetPlayerById(rpid)
        if p then pname = tostring(p.name or "?") end
    end)

    local text = tostring(arg.txt or "")

    if arg.is_command then
        srv_print("COMMAND", string.format("<%s>(P%d): %s", pname, rpid, sanitize_command(text)))
    else
        srv_print("CHAT", string.format("<%s>(P%d): %s", pname, rpid, text))
    end

    if arg.is_command and _G.CmdServerMod.execute_command then
        local ok, result, secret = _G.CmdServerMod.execute_command(text, rpid)
        if ok then
            -- 通知需要重新登录的玩家
            local sess = _G.CmdServerMod._sessions[rpid]
            if sess and sess._notify_relogin then
                sess._notify_relogin = nil
                pcall(function()
                    Action.RunUI(function(pid)
                        if Chat and Chat.Text then
                            Chat.Text({ txt = "[SERVER] 请使用 /login <密码> 登录。", player_id = pid }, pid)
                        end
                    end, rpid)
                end)
            end

            -- ★ 机密结果绝不进入 print（print 会同步到所有客户端调试日志）。
            -- 私密反馈仍然走 Action.RunUI —— 它只在发起该 action 的那个玩家的 UI 上下文执行。
            if secret ~= SECRET then
                srv_print("RESULT", "To P" .. rpid .. ": " .. tostring(result))
            end
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

-- 注意：**不能**再注册一个同名的 FactionAction.CmdServerExec 做兼容。
-- 引擎的 action 名是全局唯一的（同名重复注册会抛 "An action 'CmdServerExec' is already
-- registered"，而且这个错误会中断整个 chunk —— 后面的 MapMsg.OnTick 就永远不会被定义）。
-- 旧客户端用 Action.SendForLocalFaction("CmdServerExec") 时，引擎会自己报类型不匹配：
--   [Action] Received LUA action 'CmdServerExec' of type FactionAction but registered action is type PlayerAction

srv_print("CmdServerMod", "Data Layer Ready v" .. version)

---------------------------------------------------------------------------
-- 10. 定时器：心跳 + 加入/离开 + 自动登出
---------------------------------------------------------------------------
_G.CmdServerMod._known_players = _G.CmdServerMod._known_players or {}

local function on_tick_impl()
    -- 首次 Tick 执行初始化（Map.GetSave 在加载阶段不可用）
    if not _G.CmdServerMod._init_done then
        ensure_init()
    end

    tick_counter = tick_counter + 1

    -- 每秒检测玩家加入/离开 + 自动登出
    if tick_counter % PRESENCE_CHECK_TICKS == 0 then
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
            -- ★ 关键：任何「玩家已不在线」的 session 立即失效。
            -- 不能只依赖下面的 leave 检测 —— 它依赖 _known_players，而玩家完全可能在
            -- 两次检测之间进出（<1 秒），那样 session 会带着 logged_in=true 留下来；
            -- 之后 player id 被回收给另一个人，那人在 init_session 里就会命中早退分支
            -- 直接继承前一个人的登录身份。这里按「当前在线列表」兜底扫描。
            for sid, sess in safe_pairs(_G.CmdServerMod._sessions) do
                if online_ids[sid] == nil and sess.logged_in then
                    sess.logged_in = false
                    sess.acct_name = nil
                    srv_print("LOGOUT", string.format("session P%d 失效（玩家已离线）", sid))
                end
            end

            -- 检测离开
            -- 顺便清理 _known_players（同一 id 会被回收再利用）
            for kid, kname in pairs(_G.CmdServerMod._known_players) do
                if not online_ids[kid] then
                    _G.CmdServerMod._known_players[kid] = nil
                    local sess = _G.CmdServerMod._sessions[kid]
                    if sess then
                        sess.logged_in = false
                        sess.acct_name = nil
                    end
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
                if now - sess.last_seen > SESSION_GC_TICKS then
                    _G.CmdServerMod._sessions[pid] = nil
                end
            end
        end
    end

    -- 每60秒心跳
    if tick_counter >= HEARTBEAT_TICKS then
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

---------------------------------------------------------------------------
-- 11. 顶层兜底
---------------------------------------------------------------------------
-- ★ 教训（2026-10-07 云端实测）：模组在 package:init() 里抛一个错，
-- 竟然会让**存档加载失败、专用服务器直接退出**：
--   Critical error while executing CmdServerMod/data/main.lua:1021 ...
--   [BOOT] Failed to load save game from command line (Error code: 7)
--   [SERVER] Failed to start up dedicated server, shutting down
-- 所以本模组不注册 package:init()（只用 OnTick），并且把 OnTick 整体包进 pcall ——
-- 任何一行出错都只应影响本模组，绝不能影响引擎。
local tick_errors = 0

function MapMsg.OnTick()
    local ok, err = pcall(on_tick_impl)
    if not ok then
        tick_errors = tick_errors + 1
        -- 限流：前 5 次 + 之后每 5 分钟一次，避免刷爆控制台
        if tick_errors <= 5 or tick_errors % (300 * TICKS_PER_SECOND) == 0 then
            srv_print("ERROR", string.format("OnTick 第 %d 次失败: %s", tick_errors, tostring(err)))
        end
    end
end

_G.CmdServerMod._tick_errors = function() return tick_errors end
