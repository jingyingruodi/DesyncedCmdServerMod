# Desynced Command Console (v1.9.4)

[English](#english) | [中文](#中文)

A server-side command console and account/authority system for Desynced dedicated
servers. It logs player chat and commands to the server console and provides a
password-protected rank system with admin commands.

---

## English

### Features

- **Server-side monitoring** — player chat and commands are printed to the
  dedicated-server console.
- **Account system** — `/register` + `/login` with hashed passwords; players who
  do not log in keep playing with the lowest rank (`guest`).
- **Authority first** — every command is validated on the server. The command
  channel uses `Action.SendFromPlayer` → `PlayerAction`, so the player id comes
  from the engine and **cannot be spoofed by the client**.
- **Private feedback** — results are delivered only to the player who ran the
  command, via `Action.RunUI` + `Chat.Text`.
- **Confidentiality** — `/account export` and `/setupkey show` never go through
  `print` (which is mirrored to every client's debug log).
- **Pause-safe** — initialisation is idempotent and also runs on the command
  path, so it works even when the simulation is paused and `OnTick` never fires.
- **Crash-safe** — `MapMsg.OnTick` is fully wrapped in `pcall`; a mod error can
  never affect the engine.

### Commands

| Command | Description | Rank |
| :--- | :--- | :--- |
| `/help` `/ping` | list commands / check server | 0 guest |
| `/register <pw> <pw> [setupkey]` | create an account (with the setup key → superadmin) | guest |
| `/login <pw>` | log in | guest |
| `/whoami` | account info | guest |
| `/changepass <old> <new>` | change password | player |
| `/kick <name> [ban]` | kick / ban | admin |
| `/speed <0\|1\|2\|…>` | game speed (0 = pause) | admin |
| `/settings [set <key> <val>]` | view / change game rules | admin |
| `/admin add\|remove\|list` | manage admins | superadmin |
| `/account export\|import` | migrate accounts between saves | superadmin |
| `/setupkey show\|regen` | manage the bootstrap key | superadmin |
| `/playerinfo [id]` `/players` `/diag` | diagnostics | superadmin |

Ranks: `guest < player < admin < superadmin`.

### Becoming the first superadmin

Either pass the setup key on the server command line (**recommended** — it is then
never printed anywhere):

```
DesyncedServer.exe save.desynced … -SetupKey=<your-key>
```

then `/register <pw> <pw> <your-key>` in game.

Or let the mod generate one; it is printed once to the server console.
⚠️ That console line is mirrored to every client's debug log, so register the
first superadmin immediately (or use `-SetupKey=`).

### Server launch flags

- ✅ `-logsteam -moddev -log`
- ❌ **Do not use `-NOSTEAM`** — on Wine/Proton it makes the server hang silently.

### Known limitations

- Accounts are keyed by **player display name**. The engine does not expose a
  stable identity (no SteamID), so automatic login cannot be made safe; players
  are required to `/login` on every connection (`AUTO_LOGIN = false`).
- `Game.KickPlayer` is documented as *"only available to the host of a locally
  running server"*; on a dedicated server it may have no effect. The mod reports
  that honestly instead of pretending success.
- `/settings set` only accepts runtime-safe keys. World-generation keys
  (`seed`, `elevation_params_*`, `blight_threshold`, …) are refused because
  changing them after the game has started breaks the game or desyncs clients.

---

## 中文

一个专为 Desynced **专用服务器**打造的服务端命令台与账号权限系统：
把玩家聊天与指令记录到服务器后台，并提供带密码的权限体系与管理指令。

### 核心特性

- **服务端监控**：玩家对话与指令实时打印到专用服务器控制台。
- **账号系统**：`/register` + `/login`，密码哈希存储；未登录玩家仍可游玩，权限最低。
- **权威执行**：指令全部在服务端校验。指令通道用 `Action.SendFromPlayer` →
  `PlayerAction`，**player id 由引擎提供，客户端无法冒充**。
- **私密反馈**：结果只通过 `Action.RunUI` + `Chat.Text` 送回指令发起者本人。
- **机密不外泄**：`/account export` 与 `/setupkey show` 绝不走 `print`
  （`print` 会同步到所有客户端调试日志）。
- **暂停兼容**：初始化是幂等的，并且在指令入口也会兜底调用，
  所以即使模拟暂停、`OnTick` 不触发也能正常工作。
- **不拖垮引擎**：`MapMsg.OnTick` 整体包了 `pcall`，模组出错绝不影响服务器。

### 指令

| 指令 | 说明 | 所需权限 |
| :--- | :--- | :--- |
| `/help` `/ping` | 指令列表 / 探活 | 0 访客 |
| `/register <密码> <密码> [密钥]` | 注册（带 setup key 即为超管） | 访客 |
| `/login <密码>` | 登录 | 访客 |
| `/whoami` | 查看账号信息 | 访客 |
| `/changepass <旧> <新>` | 改密码 | player |
| `/kick <名字> [ban]` | 踢人 / 封禁 | admin |
| `/speed <0\|1\|2\|…>` | 游戏速度（0 = 暂停） | admin |
| `/settings [set <键> <值>]` | 查看 / 修改游戏规则 | admin |
| `/admin add\|remove\|list` | 管理管理员 | 超管 |
| `/account export\|import` | 跨存档迁移账号 | 超管 |
| `/setupkey show\|regen` | 管理引导密钥 | 超管 |
| `/playerinfo [id]` `/players` `/diag` | 诊断 | 超管 |

权限等级：`guest < player < admin < superadmin`。

### 成为第一个超管

推荐在服务端命令行直接指定密钥（此路径下**密钥绝不会被打印**）：

```
DesyncedServer.exe save.desynced … -SetupKey=<你的密钥>
```

然后游戏内 `/register <密码> <密码> <你的密钥>`。

不加参数时模组会随机生成一个并打印到服务端控制台一次 ——
⚠️ 那一行会同步到所有客户端调试日志，请注册完第一个超管后改用 `-SetupKey=`。

### 服务器启动参数

- ✅ `-logsteam -moddev -log`
- ❌ **不要用 `-NOSTEAM`** —— 在 Wine/Proton 下会让服务器静默挂住（实测）。

### 已知限制

- 账号以**玩家显示名**为键。引擎没有暴露稳定身份（无 SteamID），
  因此自动登录无法做到安全，默认要求每次连接手动 `/login`（`AUTO_LOGIN = false`）。
- `Game.KickPlayer` 文档限定「仅本地会话的 host 可用」，专用服务器上可能无效；
  模组会如实回报，不再谎报成功。
- `/settings set` 只接受运行期安全的键；世界生成类键（`seed`、
  `elevation_params_*`、`blight_threshold` 等）会被拒绝 —— 开局后改它们会让
  游戏崩溃或客户端不同步。

---

## Project structure

- `data/main.lua` — core logic (Simulation layer)
- `ui/main.lua` — UI interceptor, forwards input as a player action
- `def.json` — mod definition
- `AI_RULES.md` — guidelines for AI contributors
- `startServer.ps1` / `startServer.bat` — **not part of the mod**; these were the
  dedicated server's launcher scripts carried in during the v1.8.0 recovery.
  (`startServer.bat` is known-broken — see the recovery notes.)

**Author**: jingyingruodi (镜影若滴) · **License**: MIT
