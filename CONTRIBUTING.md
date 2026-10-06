# Contributing to Command Console Mod

⚠️ **Before contributing**, please read [ARCHITECTURE_WARNING.md](ARCHITECTURE_WARNING.md) to understand current limitations and architectural issues.

Thank you for your interest in contributing! This guide explains how to contribute code, report issues, and work with the project.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Code Style Guide](#code-style-guide)
- [Testing Requirements](#testing-requirements)
- [Submitting Changes](#submitting-changes)
- [AI-Assisted Development](#ai-assisted-development)

---

## Code of Conduct

- Be respectful and inclusive
- Provide constructive feedback
- Report security issues privately (don't open public issues for vulnerabilities)
- No harassment, discrimination, or hate speech

---

## Getting Started

### Prerequisites

- Desynced (version 1.0.17604 or later)
- Lua knowledge (not required but helpful)
- Git

### Setup

1. **Fork and Clone**:
   ```bash
   git clone https://github.com/your-username/CmdServerMod.git
   cd CmdServerMod
   ```

2. **Install mod for testing**:
   - Copy to Desynced mods folder (see README.md)
   - Enable in game mod list
   - Test with `/help`

3. **Read the docs**:
   - README.md (user perspective)
   - [ARCHITECTURE_WARNING.md](ARCHITECTURE_WARNING.md) (architecture overview)
   - DEVELOPMENT.md (technical architecture)
   - EXTENSION_GUIDE.lua (code examples)

---

## Development Workflow

### Important Notes on Architecture

- ⚠️ Current implementation uses **client-filtering** architecture
- 🔴 **Do NOT implement** permission/admin features without fixing architecture first
- 💡 See [ARCHITECTURE_WARNING.md](ARCHITECTURE_WARNING.md) and [ARCHITECTURE_PROBLEMS_ANALYSIS.md](ARCHITECTURE_PROBLEMS_ANALYSIS.md) for details
- 🚀 v1.1 will fix architecture issues - coordinate with maintainers before starting permission work

### Branch Strategy

- **`main`**: Stable, released version (protected branch)
- **`dev`**: Development branch for integration
- **`feature/xxx`**: Feature branches (e.g., `feature/set-command`)
- **`fix/xxx`**: Bug fix branches (e.g., `fix/chatting-lag`)

### Workflow Steps

1. **Create feature branch from `dev`**:
   ```bash
   git checkout dev
   git pull origin dev
   git checkout -b feature/my-feature
   ```

2. **Make changes**:
   - Edit code
   - Test locally in game
   - Commit frequently with clear messages

3. **Commit messages** (format):
   ```
   type: short description

   Longer explanation if needed.
   References: issue #123
   ```

   Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

   Examples:
   ```
   feat: add /echo command for testing
   fix: filter command results correctly in multiplayer
   docs: update DEVELOPMENT.md architecture section
   ```

4. **Push and create PR**:
   ```bash
   git push origin feature/my-feature
   ```
   Then on GitHub: Create PR against `dev` branch

5. **Review and merge**:
   - Wait for code review
   - Address feedback
   - Merge to `dev`

6. **Release** (maintainers only):
   - Merge `dev` → `main`
   - Tag version: `v1.0.2`
   - Update `def.json` version_code

---

## Code Style Guide

### Lua Formatting

**Indentation**: 2 spaces (NOT tabs)

```lua
-- Good
local function my_function()
    if condition then
        do_something()
    end
end

-- Bad (4 spaces or tabs)
local function my_function()
    if condition then
        do_something()
    end
end
```

**Naming Conventions**:
- Functions: `snake_case`
- Variables: `snake_case`
- Constants: `UPPER_CASE`
- Classes/tables: `PascalCase` (if applicable)

```lua
local command_count = 0
local BUFFER_SIZE = 1024

local function register_command(name, handler)
    -- ...
end
```

**Line Length**: Keep under 100 characters when possible

**Comments**:
- Use `--` for single line comments
- Use `--[[...]]` for multi-line
- Comment WHY, not WHAT (code shows what)

```lua
-- Good: explains the intent
-- Check if player is valid before executing command
if not Game.IsLocalPlayer(player_id) then
    return
end

-- Bad: just repeats code
-- If player_id is not local, return
if not Game.IsLocalPlayer(player_id) then
    return
end
```

**Spacing**:
```lua
-- Good
local x = 1
local function foo(a, b)
    return a + b
end

-- Bad
local x=1
local function foo(a,b)
    return a+b
end
```

### File Structure

```lua
-- ============================================================================
-- Section header
-- ============================================================================

local config = { ... }
local state = { ... }

-- Helper functions
local function helper1() ... end
local function helper2() ... end

-- Main logic
local function main_function() ... end

-- Initialization
print("[CmdServerMod] Loading...")
```

### Error Handling

Always wrap risky operations:

```lua
-- Good
local success, result = pcall(function()
    return Map.GetSettings()
end)

if not success then
    output_to_chat("Error: " .. tostring(result))
    return
end

-- Use result safely...

-- Bad
local result = Map.GetSettings()  -- Could crash!
return result.some_property       -- Unsafe
```

---

## Testing Requirements

### Manual Testing Checklist

Before submitting a PR, test:

- [ ] **Single-player game**:
  - [ ] Command executes without errors
  - [ ] Output appears in chat
  - [ ] Normal chat still works

- [ ] **Multiplayer game** (2+ players):
  - [ ] Player A executes command
  - [ ] Only Player A sees result in chat
  - [ ] Player B does NOT see the command result
  - [ ] Normal chat is visible to everyone
  - [ ] No chat lag or crashes

- [ ] **Edge cases**:
  - [ ] Invalid command: `/invalidcmd` → Shows error
  - [ ] Wrong arguments: `/settings foo bar` → Shows help
  - [ ] Empty arguments: `/help` → Shows command list
  - [ ] Long output: `/settings` on large map → All text visible
  - [ ] Special characters: `/test é 中文` → Handles correctly

### Debug Logging

Enable in `simulation/main.lua`:
```lua
local config = {
    command_prefix = "/",
    debug_log = true  -- Set to true
}
```

Check game log for errors. Logs should show:
- `[CmdServerMod]` - Module load
- `[CHAT-LOG]` - Chat input
- `[CMD-EXECUTED]` - Command run
- `[CMD-UI]` - Result filtering

### Performance Testing

- [ ] Running mod does not cause noticeable lag
- [ ] Chat messages appear immediately (< 100ms)
- [ ] No memory leaks (check memory use after 1 hour gameplay)

---

## Submitting Changes

### PR Guidelines

**Title format**:
```
[feature/fix] Short description
```

Examples:
```
[feature] Add /echo command
[fix] Filter command results in multiplayer
[docs] Update API documentation
```

**Description template**:
```markdown
## Description
What does this PR do?

## Motivation
Why is this change needed?

## Testing
- [x] Tested in single-player
- [x] Tested in multiplayer (2 players)
- [x] No console errors
- [x] Command output correct

## Related Issues
Closes #123
```

**Code Review Checklist**:
- [ ] Code follows style guide
- [ ] No hardcoded values (use config)
- [ ] Error handling included
- [ ] Comments explain complex logic
- [ ] No commented-out code left
- [ ] Tests pass
- [ ] Docs updated if needed

---

## AI-Assisted Development

This project welcomes AI-assisted development (using GitHub Copilot, ChatGPT, Claude, etc.).

### Guidelines for AI-Generated Code

1. **Label AI code**:
   ```lua
   -- generated with AI: GitHub Copilot [description of what was generated]
   local function foo()
       ...
   end
   -- /generated
   ```

2. **Always review**:
   - Don't accept AI code without reading it
   - Verify it matches style guide
   - Check for edge cases AI might miss
   - Test thoroughly

3. **Document assumptions**:
   ```lua
   -- AI generated this; assumes Game.IsLocalPlayer exists (verified in Desynced API)
   ```

4. **Security review**:
   - Check for injection vulnerabilities
   - Verify no data is exposed unintentionally
   - Ensure multiplayer safety (no player-crossing logic)

5. **Use AI for**:
   - Boilerplate code (repetitive patterns)
   - Documentation (drafting comments)
   - Test cases (edge case ideas)
   - Refactoring suggestions (but review carefully!)

6. **Don't use AI for**:
   - Core game logic without full review
   - Security-sensitive code without expert review
   - Features you don't understand yet

### Example AI Disclosure

```markdown
## AI Assistance Used

- ChatGPT (GPT-4): Generated error handling pattern for command parser
  - Reviewed for: correctness, style compliance, edge cases
  - Modifications: Changed error message format to match project style
```

---

## Reporting Issues

### Bug Reports

Please include:
- **Desynced version**: (e.g., 1.0.17604)
- **Mod version**: (from def.json)
- **Steps to reproduce**: Clear, numbered steps
- **Expected vs actual**: What should happen vs what did
- **Logs**: Game log excerpt (look for `[CmdServerMod]` lines)
- **Screenshots**: If visual issue

### Feature Requests

Please include:
- **Use case**: Why is this needed?
- **Expected behavior**: How would it work?
- **Alternatives**: Other ways to solve this?
- **Additional context**: Any relevant info

---

## Questions?

- **Documentation unclear?** Open an issue
- **Need help?** Start a Discussion
- **Found a bug?** Open an Issue
- **Have an idea?** Open a Discussion or Issue with `[feature-request]` tag

---

## License

By contributing, you agree your code will be licensed under MIT License.

Happy coding! 🚀
