-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 流程事件（GameEvent）============================
--
-- freekill-core `lua/server/game_event.lua` 的移植：一套**协程**式的流程框架，
-- 和 core/trigger_event.lua 的"时机"是两层东西：
--
--   TriggerEvent（时机）  —— 同步。某一刻"谁想插一脚"，按优先级问一遍就返回。
--   GameEvent（流程事件） —— 协程。某件事"怎么一步步走完"，能停下等、能被打断。
--
-- ---------------------------- 当前状态（必读）----------------------------
--
-- ⚠ 本文件现在**只是能 require**，还没有接进战斗流程：重构后的 `GameLogic:run()`
--   是直接循环跑完整局的（见 server/gamelogic.lua），没有走 GameEvent 这套栈。
--   要真的用起来，GameLogic 上还缺 freekill 那套支撑（见下面各处的 TODO）：
--     logic:getCurrentEvent() / logic:pushEvent(e) / logic:resumeEvent(...)
--     logic.game_event_stack / logic.cleaner_stack / logic.event_recorder
--     logic.all_game_events / logic.current_event_id
--   这些在原 BattleLogic 里有、在新的 GameLogic 上**还没有**，所以下面凡是用到
--   它们的地方都做了"有就用、没有就退化"的处理，不会当场炸。
--
-- ---------------------------- 清掉了什么 ----------------------------
--
-- 这份文件原来带着大量 freekill（三国杀）的东西，本项目里**不存在**，已删除：
--
--   * `RoomInstance`（全局房间单例）—— 改成由调用方显式传"战局容器"（见 initialize）；
--   * `Fk`（全局引擎）—— `Fk:currentRoom()` / `Fk:translate` / `Fk:getCardById`
--     全是三国杀那套，连带整个 `parseMsg`（把 LogMessage 渲染成人话）一起删了；
--   * `Card` / `ServerPlayer` / `general` / `deputyGeneral` / `seat#` —— 同上；
--   * `Pcall` → 标准库 `pcall`（原来那个是 freekill 的全局包装）。
--
-- TODO：日志文本渲染（getDesc）现在退化成最朴素的输出，等本项目的
--   日志/回放格式定下来之后再重写一份。

---@class GameEvent: Object
---@field public id integer @ 事件的id，随着时间推移自动增加并分配给新事件
---@field public end_id integer @ 事件的对应结束id，如果整个事件中未插入事件，那么end_id就是自己的id
---@field public room any @ 战局容器：GameLogic，或会话层给的 room 适配器
---@field public logic any @ 逻辑层（= room.logic；若 room 本身就是 GameLogic，则就是它）
---@field public event any @ 该事件对应的EventType，现已改为对应的class
---@field public data any @ 事件的附加数据，视类型而定
---@field public parent GameEvent @ 事件的父事件（栈中的上一层事件）
---@field public extra_clear fun(self:GameEvent)[] @ 事件结束时执行的自定义函数列表
---@field public extra_exit fun(self:GameEvent)[] @ 事件结束后执行的自定义函数
---@field public exec_ret boolean? @ exec函数的返回值，可能不存在
---@field public status string @ ready, running, exiting, dead
---@field public interrupted boolean @ 事件是否是因为被中断而结束的，可能是防止事件或者被杀
---@field public killed boolean @ 事件因为终止一切结算而被中断（所谓的“被杀”）
---@field public desc fun(self:GameEvent):table @ 描述（纯数据，渲染交出去）
local GameEvent = class("GameEvent")

---@type (fun(self: GameEvent): boolean?)[]
GameEvent.prepare_funcs = {}

---@type (fun(self: GameEvent): boolean?)[]
GameEvent.functions = {}

---@type (fun(self: GameEvent): boolean?)[]
GameEvent.cleaners = {}

---@type (fun(self: GameEvent): boolean?)[]
GameEvent.exit_funcs = {}

local dummyFunc = Util.DummyFunc

---@param event any @ 事件类型（已经是 class，见文件头）
---@param room? any @ 战局容器：GameLogic，或会话层给的 room 适配器
---   （原来是全局 `RoomInstance`——那是 freekill 的房间单例，本项目没有）
function GameEvent:initialize(event, room, ...)
  self.id = -1
  self.end_id = -1
  self.room = room
  -- logic 的取法对两种调用方都成立：
  --   * 传进来的是会话层的 room 适配器（`room.logic` 是 GameLogic）→ 取它；
  --   * 直接传 GameLogic（它自己没有 .logic 字段）→ 就是它。
  self.logic = (type(room) == "table" and room.logic) or room
  -- for compat
  self.event = event
  ---@diagnostic disable-next-line
  -- self.event = self.class
  self.data = { ... }
  if #self.data == 1 then self.data = self.data[1] end
  self.status = "ready"
  self.interrupted = false

  self.extra_clear = Util.DummyTable
  self.extra_exit = Util.DummyTable
end

---@generic T
---@param self T
---@return T
function GameEvent.create(self, ...)
  if self.class then error('cannot use "create()" by event instances') end
  return self:new(self, ...)
end

-- 获取最接近GameEvent的基类
---@return GameEvent
function GameEvent.getBaseClass(self, ...)
  if self.class then error('cannot use "getBaseClass()" by event instances') end
  if self.super == GameEvent or self == GameEvent then
    return self
  end
  return self.super:getBaseClass()
end

function GameEvent.static:subclassed(subclass)
  local mt = getmetatable(subclass)
  -- 适配老代码event == GameEvent.Turn之类的奇技淫巧，危险性待评估
  -- 这样若某个模式启用派生类修改逻辑，那么findParent之类的基于父类也能找
  mt.__eq = function(a, b)
    if not a.super or not b.super then return false end
    return rawequal(a, b) or a:isSubclassOf(b) or b:isSubclassOf(a)
  end
end

function GameEvent:__tostring()
  return string.format("<%s #%d>",
    type(self.event == "string") and self.event or self.class.name, self.id)
end

--- LogMessage形式的描述
---@return LogMessage
function GameEvent:desc()
  return { type = "#GameEvent" }-- .. (type(self.event == "string") and self.event or self.class.name)
end

-- TODO：这里原来是 freekill 的 `parseMsg`——把 LogMessage 渲染成带颜色、
-- 带武将名/卡牌名的中文串（`Fk:currentRoom` / `getPlayerById` / `Fk:translate` /
-- `Fk:getCardById` / general / deputyGeneral 全是三国杀那套，本项目里都不存在，
-- 已整块删除）。本项目的日志/回放文本格式还没定，先退化成"把 desc 的数据直接转字符串"。
--- 获得描述（纯数据 → 字符串）
---@return string
function GameEvent:getDesc()
  local d = self:desc()
  if type(d) == "table" then
    local parts = {}
    for _, k in ipairs({ "type", "from", "to", "arg", "arg2", "arg3" }) do
      if d[k] ~= nil then table.insert(parts, ("%s=%s"):format(k, tostring(d[k]))) end
    end
    return #parts > 0 and table.concat(parts, " ") or tostring(self)
  end
  return tostring(d)
end

function GameEvent:prepare()
  return (GameEvent.prepare_funcs[self.event] or dummyFunc)(self)
end

function GameEvent:main()
  return (GameEvent.functions[self.event] or dummyFunc)(self)
end

function GameEvent:clear()
  return (GameEvent.cleaners[self.event] or dummyFunc)(self)
end

function GameEvent:exit()
  return (GameEvent.exit_funcs[self.event] or dummyFunc)(self)
end

function GameEvent:addCleaner(f)
  if self.extra_clear == Util.DummyTable then
    self.extra_clear= {}
  end
  table.insert(self.extra_clear, f)
end

function GameEvent:addExitFunc(f)
  if self.extra_exit== Util.DummyTable then
    self.extra_exit= {}
  end
  table.insert(self.extra_exit, f)
end

function GameEvent:prependExitFunc(f)
  if self.extra_exit== Util.DummyTable then
    self.extra_exit= {}
  end
  table.insert(self.extra_exit, 1, f)
end

-- 找第一个与此事件有继承关系的特定事件
---@generic T: GameEvent
---@param eventType T @ 事件类型
---@param includeSelf boolean? @ 是否包括本事件
---@param depth? integer @ 搜索深度
---@return T?
function GameEvent:findParent(eventType, includeSelf, depth)
  if includeSelf and self.event == eventType then return self end
  if depth == 0 then return nil end
  local e = self.parent
  local l = 1
  while e do
    if e.event == eventType then return e end
    if depth and l >= depth then break end
    e = e.parent
    l = l + 1
  end
  return nil
end

-- 找n个id介于from和to之间的事件。
---@param events GameEvent[] @ 事件数组
---@param from integer @ 起始id
---@param to integer @ 终止id
---@param n integer @ 最多找多少个
---@param func fun(e: GameEvent): boolean? @ 过滤用的函数
---@return GameEvent[] @ 找到的符合条件的所有事件，最多n个但不保证有n个
local function bin_search(events, from, to, n, func)
  local left = 1
  local right = #events
  local mid
  local ret = {}

  if from < events[1].id then
    mid = 1
  elseif from > events[right].id then
    return ret
  else
    while true do
      if left > right then return ret end
      mid = (left + right) // 2
      local id = events[mid].id
      local id_left = mid == 1 and -math.huge or events[mid - 1].id

      if from <= id then
        if from >= id_left then
          break
        end
        right = mid - 1
      else
        left = mid + 1
      end
    end
  end

  for i = mid, #events do
    local v = events[i]
    if v.id <= to and func(v) then
      table.insert(ret, v)
    end
    if #ret >= n then break end
  end

  return ret
end

-- 从某个区间中，找出类型符合且符合func函数检测的至多n个事件。
---@generic T: GameEvent
---@param eventType T @ 要查找的事件类型
---@param n integer @ 最多找多少个
---@param func fun(e: T): boolean? @ 过滤用的函数
---@param endEvent? GameEvent @ 区间终止点，默认为本事件结束
---@return T[] @ 找到的符合条件的所有事件，最多n个但不保证有n个
function GameEvent:searchEvents(eventType, n, func, endEvent)
  -- TODO(流程栈未移植)：`event_recorder` / `all_game_events` 是原 BattleLogic 上的
  -- 事件记录表，新的 GameLogic 还没有（它现在是直接循环，不走 GameEvent）。
  -- 这里做"有就用、没有就返回空"的退化处理，免得一调就炸。
  local logic = self.logic
  if logic == nil or logic.event_recorder == nil then
    Log.warning("GameEvent:searchEvents 需要 logic.event_recorder（本项目尚未移植），返回空结果")
    return {}
  end
  local events = logic.event_recorder[eventType] or Util.DummyTable
  local from = self.id
  local to = endEvent and endEvent.id or self.end_id
  if math.abs(to) == 1 then to = #(logic.all_game_events or {}) end
  n = n or 1
  func = func or Util.TrueFunc

  local ret
  if #events < 6 then
    ret = {}
    for _, v in ipairs(events) do
      if v.id >= from and v.id <= to and func(v) then
        table.insert(ret, v)
      end
      if #ret >= n then break end
    end
  else
    ret = bin_search(events, from, to, n, func)
  end

  return ret
end

function GameEvent:exec()
  local logic = self.logic
  if self.status ~= "ready" then return true end

  -- TODO(流程栈未移植)：`getCurrentEvent` / `pushEvent` / `resumeEvent` 与事件栈
  -- （game_event_stack / cleaner_stack）都在原 BattleLogic 上，新的 GameLogic
  -- （server/gamelogic.lua，直接循环跑整局）还没有它们。没有栈就没法挂事件，
  -- 所以这里明确报错而不是装作没事——调用方现在本来也还没有地方调它。
  if logic == nil or type(logic.getCurrentEvent) ~= "function"
    or type(logic.pushEvent) ~= "function" then
    error("GameEvent:exec 需要 logic:getCurrentEvent()/pushEvent()（事件栈尚未移植到 GameLogic）", 2)
  end

  self.parent = logic:getCurrentEvent()

  if self:prepare() then return true end

  logic:pushEvent(self)

  local co = coroutine.create(function() return self:main() end)
  self._co = co
  self.status = "running"

  coroutine.yield(self, "__newEvent")
  -- 事件的处理流程请看GameLogic:resumeEvent

  pcall(self.exit, self)
  for _, f in ipairs(self.extra_exit) do
    if type(f) == "function" then
      pcall(f, self)
    end
  end

  return self.interrupted, self.exec_ret
end

function GameEvent:shutdown()
  if self.status ~= "running" then return end
  -- yield to self and break
  coroutine.yield(self, "__breakEvent")
end

-- 应该也是两个通用event

---@class GameEvent.Game : GameEvent
local Game = GameEvent:subclass("GameEvent.Game")

function Game:__tostring()
  -- 原来打的是 `Fk:currentRoom():getSettings('gameMode')`（freekill 的三国杀模式名）。
  -- 本项目没有 Fk，也没有"模式"这个概念，退化成一个能表示身份的串。
  return string.format("<Game %s #%d>",
    self.logic ~= nil and tostring(self.logic) or "?", self.id)
end

function Game:main()
  -- 原来这里是 room.game_started / room:doBroadcastNotify("StartGame") /
  -- room.logic:run()——前两个是 freekill 的房间接口，本项目没有。
  -- 等价物就是"把战局交给 GameLogic 跑"（失败原因/胜负由 logic 自己记）。
  local room = self.room
  if type(room) == "table" and rawget(room, "game_started") ~= nil then
    room.game_started = true
  end
  self.logic:run()
end

---@class GameEvent.ClearEvent : GameEvent
---@field data GameEvent
local ClearEvent = GameEvent:subclass("GameEvent.ClearEvent")
function ClearEvent:main()
  local event = self.data
  local logic = self.logic
  -- 不可中断
  pcall(event.clear, event)
  for _, f in ipairs(event.extra_clear) do
    if type(f) == "function" then pcall(f, event) end
  end

  -- TODO(流程栈未移植)：`current_event_id` / `all_game_events` / `game_event_stack` /
  -- `cleaner_stack` 都是原 BattleLogic 的事件栈，新的 GameLogic 上还没有（见 exec 的 TODO）。
  -- 没有栈就没法出栈，所以这里退化：只把 event.end_id 收成自己，栈的部分跳过。
  if logic == nil or type(logic.game_event_stack) ~= "table" then
    Log.warning("ClearEvent:main 需要 logic 的事件栈（尚未移植），跳过出栈")
    event.end_id = event.id
    return
  end

  local end_id = logic.current_event_id + 1
  if event.id ~= end_id - 1 then
    logic.all_game_events[end_id] = event.event
    logic.current_event_id = end_id
    event.end_id = end_id
  else
    event.end_id = event.id
  end

  logic.game_event_stack:pop()
  logic.cleaner_stack:pop()
end

GameEvent.Game = Game
GameEvent.ClearEvent = ClearEvent

return GameEvent
