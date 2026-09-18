-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 命令行处理器：单机版 ============================
--
-- **单机版就这么来的**：同一份战斗流程、同一套 `Request`，只把"谁答"换成了终端。
--
--   RpcHandler   把请求包发给 C++/Unity，挂起等人点（联机）
--   CliHandler   把选项打到终端，读一行字符串（单机，本文件）
--
-- 因为换的只是这一层，所以"单机能跑通 = 联机也能跑通"：
-- 联机时唯一多出来的事情是"网络往返"，而往返本身已经被 `Request:ask` 的
-- 等待循环 + `logic:resume` 处理掉了。
--
-- ---------------------------- 输入格式 ----------------------------
--
--   `1`           用第 1 个技能，目标默认（对面第一只）
--   `2 3`         用第 2 个技能，打 3 号座位的精灵
--   `电击光束`     直接写技能名
--   `a` / `auto`  交给 AI 兜底（用这个请求的默认答复）
--   `?` / `help`  打印玩法说明
--   `q` / `quit`  退出（返回"取消"，单机主循环看到就结束程序）
--   `[[回车]]`     选第一个能用的技能
--
-- 输入/输出都是**可注入**的（`opts.input` / `opts.output`），
-- 所以单测里可以喂一串预设输入跑完整局，不用真的开终端——
-- 见 `tests/test_core.lua` 的「单机版：命令行选择技能」那一节。

---@class CliHandler: RequestHandler
---@field public input fun(prompt: string): string? @ 读一行（默认 io.read）
---@field public output fun(text: string) @ 写一行（默认 print）
---@field public quit boolean @ 玩家按了 q
---@field public history string[] @ 打过的问题（测试/复盘用）
CliHandler = RequestHandler:subclass("CliHandler")

---@param opts? table @ `{ logic, input, output, banner }`
function CliHandler:initialize(opts)
  opts = opts or {}
  RequestHandler.initialize(self, opts)
  self.input = opts.input or function() return io.read() end
  self.output = opts.output or print
  self.quiet = opts.quiet or false
  -- 玩家按 q 时要做的事（单机主程序用它把这一局收尾）
  self.on_quit = opts.on_quit
  self.quit = false
  self.history = {}
end

--- 把请求打到终端，然后读一行解析成答复。
--- 注意它是**同步阻塞**的（`io.read` 会等玩家敲回车），所以不挂起协程——
--- 单机版里"等玩家"就是等在这里，整局流程照旧往下走。
function CliHandler:send(request, pet)
  local payload = request:toJson(pet)
  table.insert(self.history, payload)

  self:printRequest(request, pet, payload)

  -- 解析失败就重问（而不是瞎猜一个答复，那样玩家会以为"点了没反应"）
  for _ = 1, 100 do
    local line = self.input(self:promptText(payload))
    local reply = self:parse(line, request, pet, payload)
    if reply ~= nil then
      self.replies[pet] = reply
      return
    end
  end
  Log.warning("命令行输入连续 100 次都不合法，改用默认答复")
end

---@param payload table
---@return string
function CliHandler:promptText(payload)
  return ("%s> "):format(payload.name or "?")
end

---@param text string
function CliHandler:print(text)
  if not self.quiet then self.output(text) end
end

--- 把这次询问渲染成人能读的样子
---@param request Request
---@param pet Pet
---@param payload table
function CliHandler:printRequest(request, pet, payload)
  if self.quiet then return end
  local out = self.output
  local logic = self.logic

  if payload.kind == "AskForAction" then
    out("")
    out(("── 第 %d 回合 · 轮到 %s（%s %d/%d）──")
      :format(logic and logic.round or 0, pet.name,
        pet.species and pet.species.name or "", pet.hp, pet.max_hp))
    local lines = {}
    for i, name in ipairs(payload.skills or {}) do
      local sk = Seer:getSkill(name)
      local desc = ""
      if sk then
        local parts = {}
        if (sk:getPower() or 0) > 0 then table.insert(parts, ("威力%d"):format(sk:getPower())) end
        if sk.category == Skill.Status then table.insert(parts, "属性") end
        if sk:getPriority() ~= 0 then table.insert(parts, ("先制%+d"):format(sk:getPriority())) end
        table.insert(parts, ("PP %d"):format(pet:getPP(name)))
        if payload.fifth == name then table.insert(parts, "第五技能") end
        if sk.desc then table.insert(parts, sk.desc) end
        desc = "  " .. table.concat(parts, "，")
      end
      table.insert(lines, ("  [%d] %s%s"):format(i, name, desc))
    end
    out(table.concat(lines, "\n"))

    for _, u in ipairs(payload.unusable or {}) do
      out(("      （%s 现在用不了：%s）"):format(u.name, u.text or u.reason or "不可用"))
    end
    out("  输入编号选技能（可加目标座位，如 `2 3`），a = 交给 AI，? = 帮助，q = 退出")

  elseif payload.kind == "AskForChoice" then
    out("")
    out(("── %s：%s"):format(pet.name, tostring(payload.prompt or "请选择")))
    for i, choice in ipairs(payload.choices or {}) do
      out(("  [%d] %s"):format(i, tostring(choice)))
    end
  else
    out(("── %s 在问：%s"):format(pet.name, tostring(payload.kind)))
  end
end

--- 解析一行输入 → 答复。返回 nil 表示"没读懂，再问一次"。
---@param line string?
---@param request Request
---@param pet Pet
---@param payload table
---@return any
function CliHandler:parse(line, request, pet, payload)
  line = (line or ""):gsub("^%s+", ""):gsub("%s+$", "")

  -- 直接回车 = 第一个能用的技能（最省事的默认操作）
  if line == "" then
    return self:pickByIndex(1, nil, pet, payload)
  end

  local lower = line:lower()
  if lower == "q" or lower == "quit" or lower == "exit" then
    self.quit = true
    self:print("  （退出）")
    -- 通知主程序"玩家不想玩了"（没有回调也不影响流程，只是当作这一手取消）
    if type(self.on_quit) == "function" then self.on_quit() end
    return Request.CANCEL
  end
  if lower == "a" or lower == "auto" or lower == "ai" then
    local reply = request:getDefaultReply(pet)
    self:print("  （交给 AI 决定）")
    return reply
  end
  if line == "?" or lower == "help" then
    self:printHelp()
    return nil
  end

  if payload.kind == "AskForChoice" then
    local idx = tonumber(line)
    if idx ~= nil then return self:pickChoice(idx, payload) end
    -- 也允许直接写选项内容
    for _, choice in ipairs(payload.choices or {}) do
      if tostring(choice) == line then return choice end
    end
    return nil
  end

  -- `2 3`：技能编号 + 目标座位
  local skill_part, target_part = line:match("^(%S+)%s+(%S+)$")
  if skill_part == nil then skill_part = line end
  local idx = tonumber(skill_part)
  local target_seat = target_part and tonumber(target_part) or nil
  if idx ~= nil then
    return self:pickByIndex(idx, target_seat, pet, payload)
  end

  -- 直接写技能名（写错了要说清楚，别当没听见）
  for _, name in ipairs(payload.skills or {}) do
    if name == line then
      return { skill = name, target = target_seat }
    end
  end
  self:print(("  （没有叫 %q 的可用技能，输入 ? 看用法）"):format(line))
  return nil
end

---@param idx integer
---@param target_seat integer?
---@param pet Pet
---@param payload table
---@return table?
function CliHandler:pickByIndex(idx, target_seat, pet, payload)
  local name = (payload.skills or {})[idx]
  if name == nil then
    self:print(("  （没有第 %d 个技能，输入 ? 看用法）"):format(idx))
    return nil
  end
  return { skill = name, target = target_seat }
end

---@param idx integer
---@param payload table
---@return any
function CliHandler:pickChoice(idx, payload)
  local choice = (payload.choices or {})[idx]
  if choice == nil then
    self:print(("  （没有第 %d 个选项）"):format(idx))
    return nil
  end
  return choice
end

function CliHandler:printHelp()
  self:print([[
  怎么玩：
    [编号]        用第 N 个技能（编号见上面那个列表），默认打对面第一只
    [编号] [座位]  用第 N 个技能打指定座位的精灵，比如 `2 3`
    [技能名]      直接写技能名也行
    a             交给 AI 帮你决定（超时/托管走的就是这条）
    ?             看这份说明
    q             退出（这一手当作"不出手"）
  回车           选第一个能用的技能]])
end

return CliHandler
