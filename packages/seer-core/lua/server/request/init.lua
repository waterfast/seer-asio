-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 请求（Request）============================
--
-- 对应 freekill-core 的 `lua/server/request.lua`。它是"**向人提问**"这件事的
-- 完整模型：问谁、问什么、等多久、默认答案是什么、谁先答完、答完了怎么收尾。
--
-- 为什么要单独一个类，而不是到处写 `coroutine.yield`：
--
--   1. **一次询问可能有多个对象**（三国杀里"所有人同时决定是否发动"，
--      赛尔号里"双方各自选这回合的技能"），要记"谁还没答、够不够数了"；
--   2. **一定要有兜底**：有人掉线/超时/AI 托管时，流程不能卡死——
--      所以每个参与者都能预先登记一个**默认答复**，超时就用它；
--   3. **答复要规范化**：取消、没答、抢答失败……这些特殊情况在 `_finish` 里
--      统一成调用方看得懂的值，规则代码不用到处判 `nil`；
--   4. **答复者是谁可以换**：单机命令行、AI、真人客户端（Unity）都只是
--      换一个 `RequestHandler`（见 handler.lua / cli.lua / rpc.lua），
--      游戏流程一行不用改。这就是"接 Unity 也一样跑"的落点。
--
-- 和 freekill 的一处差异：它从 `players[1].room` 反推房间，
-- 我们的 `Pet` 上没有反向引用（故意的：精灵不该知道自己属于哪一局），
-- 所以构造时**显式传 logic**。
--
-- ---------------------------- 三种特殊答复 ----------------------------
--
-- freekill 用三个魔法字符串表示"不是正常答复"，这里照抄（换成常量，别散字面量）：
--
--   Request.NOT_READY       还没答复（内部用，调用方看不到）
--   Request.CANCEL          空串 = 取消。`accept_cancel = true` 时它也算"收到的答复"
--   Request.CANCEL_EXPLICIT 客户端明确点了"取消"
--   Request.FAILED_IN_RACE  抢答失败（已经有人先答了，你这份作废）
--
-- 收尾时这些值都会被 `_finish` 换成"默认答复"或"取消"，所以业务代码只需要判
-- `reply == ""`（取消）和 `reply == nil`（没有答复）。

---@class Request: Object
---@field public logic BattleLogic @ 属于哪一局
---@field public command string @ 询问的类型名（就是发给客户端的 kind）
---@field public players Pet[] @ 参与者（要问的人）
---@field public n integer @ 收到几个"肯定答复"就可以提前结束
---@field public data table<Pet, any> @ 精灵 → 这个人的问题内容（用**精灵对象**当键，seat 可能没分配）
---@field public default_reply table<Pet, any> @ 精灵 → 兜底答复（超时/掉线/AI 托管用）
---@field public result table<Pet, any> @ 精灵 → 规范化之后的答复
---@field public winners Pet[] @ 按答复先后排的"有效答复"者
---@field public overtimes Pet[] @ 超时没答的人
---@field public timeout integer @ 等多少秒（0 = 一直等）
---@field public accept_cancel boolean @ 取消算不算有效答复
---@field public focus_text string? @ "思考中…"那句提示（客户端用来显示焦点）
Request = class("Request")

-- ---------------------------- 常量 ----------------------------

Request.NOT_READY = "__notready"
Request.CANCEL = ""
Request.CANCEL_EXPLICIT = "__cancel"
Request.FAILED_IN_RACE = "__failed_in_race"
--- 外部唤醒时用这个理由表示"超时了"（对应 freekill 的 request_timer）
Request.TIMER_REASON = "request_timer"
--- 等待循环的保险丝：外部一直给不出答复时不要原地打转
Request.MAX_WAIT_ROUNDS = 10000

---@param logic BattleLogic
---@param players Pet|Pet[]
---@param command string
---@param n? integer @ 收到几个有效答复就结束，默认 = 参与者数量
function Request:initialize(logic, players, command, n)
  assert(logic ~= nil, "Request 需要一个战局（logic）")
  -- 允许只传一只精灵（freekill 那边也支持）
  if players ~= nil and players.class ~= nil then players = { players } end
  assert(type(players) == "table" and #players > 0, "Request 至少要有一个参与者")

  self.logic = logic
  self.command = command
  self.players = players
  self.n = n or #players

  self.data = {}
  self.default_reply = {}
  self.result = {}
  self.winners = {}
  self.overtimes = {}

  self.timeout = logic.request_timeout or 0
  self.accept_cancel = false
  self.focus_text = nil
  self.asked = false          -- freekill 叫 _asked
  self.seq = Request._next_seq()
  self.timestamp = os.time()
end

-- 编号只用来给日志/回放区分"这是第几次询问"
Request._seq = 0
function Request._next_seq()
  Request._seq = Request._seq + 1
  return Request._seq
end

function Request:__tostring()
  return ("<Request #%d %s x%d>"):format(self.seq, self.command, #self.players)
end

-- ---------------------------- 登记内容 ----------------------------

--- 给某个参与者登记"你要回答什么"。
---@param pet Pet
---@param data any @ 必须可序列化（要发给客户端/终端）
function Request:setData(pet, data)
  self.data[pet] = data
end

--- 给某个参与者登记**兜底答复**：超时、掉线、AI 托管时用它。
--- 有这一项，流程就永远不会因为"没人答"而卡死。
---@param pet Pet
---@param reply any
function Request:setDefaultReply(pet, reply)
  self.default_reply[pet] = reply
end

---@param pet Pet
---@return any
function Request:getData(pet)
  return self.data[pet]
end

---@param pet Pet
---@return any @ 这个人的兜底答复
function Request:getDefaultReply(pet)
  return self.default_reply[pet]
end

-- ============================ 协议 ============================

--- 把"问这只精灵的那个问题"变成一份**纯数据**。
---
--- 这是**唯一**一处定义请求长相的地方：发给 Unity 的 RPC 包、单机命令行打印的
--- 选项、日志里记的"当时问了什么"，全都出自这里。所以改字段只需要改这一处。
---@param pet? Pet @ 不填 = 当前还没答复的第一个人
---@return table
function Request:toJson(pet)
  pet = pet or self:pendingPet() or self.players[1]
  local payload = table.simpleClone(self.data[pet] or {})
  payload.kind = self.command
  payload.pet = pet.seat
  payload.name = payload.name or pet.name
  payload.seq = self.seq
  payload.timestamp = self.timestamp
  payload.timeout = self.timeout
  payload.n = self.n
  payload.asking = #self.players
  return payload
end

--- 这个答复是不是"取消"
---@param reply any
---@return boolean
function Request.isCancel(reply)
  return reply == Request.CANCEL or reply == Request.CANCEL_EXPLICIT
end

-- ============================ 询问 ============================

--- 当前还没答复的第一个人（按 players 顺序，确定性）
---@return Pet?
function Request:pendingPet()
  for _, pet in ipairs(self.players) do
    if self.result[pet] == nil then return pet end
  end
  return nil
end

--- 取某个人的答复；第一次调用会**触发整个询问**。
--- 这是调用方唯一需要用的方法（对应 freekill 的 `req:getResult(player)`）。
---@param pet Pet
---@return any @ 规范化之后的答复；空串 = 取消
function Request:getResult(pet)
  if not self.asked then self:ask() end
  return self.result[pet]
end

--- 真正去问。流程是 freekill 那个循环的简化版：
---   1. 把问题发给所有参与者（`handler:send`）；
---   2. 轮询谁答了（`handler:takeReply`），答了就记下来；
---   3. 一个都没答上来 → `handler:waitReply` **挂起**，等外面把答复送回来；
---   4. 收够了（`n` 个有效答复）或者所有人都答完了 → `_finish` 收尾。
function Request:ask()
  if self.asked then return end
  self.asked = true
  self.logic.current_request = self

  -- 告诉外面"现在在等这几个人"（freekill 的 notifyMoveFocus）：
  -- 客户端拿它显示"思考中…"的焦点和倒计时；单机版不关心，忽略即可。
  self.logic:notify{
    type = "MoveFocus",
    pets = table.map(self.players, function(p) return p.seat end),
    text = self.focus_text or self.command,
    timeout = self.timeout,
  }

  -- 发出去。就地作答的处理器（AI、脚本化的 CLI）在这一步就有答案了。
  for _, pet in ipairs(self.players) do
    if self.result[pet] == nil then self:sendTo(pet) end
  end

  local rounds = 0
  while true do
    local changed = false

    -- 轮询：谁答了记谁。倒着走，这样移除元素不影响未处理的那些。
    for i = #self.players, 1, -1 do
      local pet = self.players[i]
      if self.result[pet] == nil then
        local reply = self:checkReply(pet)
        if reply ~= nil then
          self:recordReply(pet, reply)
          changed = true
        end
      end
    end

    if #self.winners >= self.n then break end
    if self:pendingPet() == nil then break end

    if not changed then
      if rounds >= Request.MAX_WAIT_ROUNDS then
        Log.warning(("询问 %s 等了 %d 轮都没等到答复，改用默认答复收尾")
          :format(self.command, rounds))
        break
      end
      rounds = rounds + 1
      -- 挂起（只有"真的要等人"的处理器会挂）。答复从 `logic:resume(...)` 回来。
      self:waitReply()
    end
  end

  self:_finish()
  self.logic.current_request = nil
  self.logic.last_request = self
end

-- ---------------------------- 和处理器打交道 ----------------------------

---@param pet Pet
---@return RequestHandler
function Request:handlerFor(pet)
  return self.logic:getRequestHandler(pet)
end

--- 把问题交给这只精灵的答复者
---@param pet Pet
function Request:sendTo(pet)
  local handler = self:handlerFor(pet)
  if type(handler.send) ~= "function" then return end
  handler.pending_pet = pet
  handler:send(self, pet)
end

--- 问一次"答复到了吗"（非阻塞）。
--- 超时那个特殊理由会在这里被吃掉：记进 overtimes，当作"没答"。
---@param pet Pet
---@return any @ nil = 还没答
function Request:checkReply(pet)
  local handler = self:handlerFor(pet)
  local reply = handler:consumeReply(self, pet)
  if reply == nil then return nil end
  if reply == Request.NOT_READY then return nil end
  if reply == Request.TIMER_REASON then
    -- 超时：这个人的答复作废，`_finish` 会给他填默认答复
    table.insert(self.overtimes, pet)
    Log.debug(("%s 的 %s 超时了，用默认答复"):format(pet.name, self.command))
    return Request.FAILED_IN_RACE
  end
  return reply
end

--- 挂起等外面回话。挂起点是**处理器**决定的：
---   * RpcHandler：`coroutine.yield` 出去，等 C++/Unity 调 `logic:resume(reply)`；
---   * CLI：读一行输入（同步阻塞，不挂起）；
---   * AI / 无头：什么都不做（它们在上一步就答完了）。
function Request:waitReply()
  local pet = self:pendingPet()
  if pet == nil then return end
  local handler = self:handlerFor(pet)
  if type(handler.waitReply) ~= "function" then return end
  handler:waitReply(self)
end

--- 记下一个人的答复
---@param pet Pet
---@param reply any
function Request:recordReply(pet, reply)
  self.result[pet] = reply
  if not Request.isCancel(reply) or self.accept_cancel then
    table.insert(self.winners, pet)
  end
end

-- ---------------------------- 收尾 ----------------------------

--- 询问结束：把各种"不是答复"的值规范化成调用方看得懂的东西。
--- 这里是"永远不卡死"的最后一道保险——谁没答上就给他默认答复。
function Request:_finish()
  for _, pet in ipairs(self.players) do
    local reply = self.result[pet]
    if reply == nil or reply == Request.FAILED_IN_RACE then
      -- 超时、掉线、抢答失败：用兜底答复（AI 托管走的就是这条）
      self.result[pet] = self.default_reply[pet] or Request.CANCEL
    elseif reply == Request.CANCEL_EXPLICIT then
      self.result[pet] = self.accept_cancel and Request.CANCEL
        or (self.default_reply[pet] or Request.CANCEL)
    end

    local handler = self:handlerFor(pet)
    if type(handler.finish) == "function" then handler:finish(self) end
  end
end

-- ============================ 常用的几种询问 ============================

--- 问一只精灵"这回合用什么技能"。
---
--- 这是**每轮开始时**的那个询问（对应官方流程"双方各自选技能，再按先制度/速度排"）：
--- 由网络包里的 `skills` 给出候选、`unusable` 说明哪些为什么不能选、
--- `fifth` 告诉客户端第五技能摆哪一格。答复形如 `{ skill = "技能名", target = 座位 }`。
---
--- 兜底答复（超时/AI 托管）：挑一个能打的技能打对面 —— 见 logic:askForAction。
---@param logic BattleLogic
---@param pet Pet
---@param opts table @ `{ skills, unusable, fifth, default_reply, timeout, focus_text }`
---@return Request
function Request.AskForAction(logic, pet, opts)
  local req = Request:new(logic, pet, "AskForAction")
  req:setData(pet, {
    name = pet.name,
    skills = opts.skills,
    unusable = opts.unusable,
    fifth = opts.fifth,
  })
  req:setDefaultReply(pet, opts.default_reply)
  if opts.timeout ~= nil then req.timeout = opts.timeout end
  req.focus_text = opts.focus_text or ("#AskForAction:::" .. pet.name)
  return req
end

--- 问一只精灵在几个选项里挑一个（对应 core 的 `room:askToChoice`）。
--- 答复就是一个字符串（选中的那一项）。
---@param logic BattleLogic
---@param pet Pet
---@param params table @ `{ prompt, choices, default_reply, timeout }`
---@return Request
function Request.AskForChoice(logic, pet, params)
  local req = Request:new(logic, pet, "AskForChoice")
  req:setData(pet, {
    name = pet and pet.name or nil,
    prompt = params.prompt,
    choices = params.choices,
  })
  -- 没给兜底答复就选第一个：决策固定，整局可复现（架构文档 §2.3）
  req:setDefaultReply(pet, params.default_reply
    or (params.choices and params.choices[1] or Request.CANCEL))
  if params.timeout ~= nil then req.timeout = params.timeout end
  req.focus_text = params.prompt
  return req
end

-- ============================ 处理器（谁去答）============================
--
-- 放在最后 require：它们要用上面这个 `Request`（全局），而它们自己也会挂成全局
-- （`RequestHandler` / `AiHandler` / `DefaultHandler` / `CliHandler` / `RpcHandler`）。

local Handler = require "server.request.handler"
RequestHandler = Handler.RequestHandler
AiHandler = Handler.AiHandler
DefaultHandler = Handler.DefaultHandler

CliHandler = require "server.request.cli"
RpcHandler = require "server.request.rpc"

--- 处理器模块的目录（给扩展包和测试用）
Request.Handler = Handler
Request.CliHandler = CliHandler
Request.RpcHandler = RpcHandler

return Request
