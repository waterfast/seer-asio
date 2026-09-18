-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 流程事件基类 GameEvent ============================
--
-- 本文件是 freekill-core `lua/server/gameevent.lua` 的移植版。
--
-- ---------------------------- 这一层是干什么的 ----------------------------
--
-- 战斗里有**两层**事件，它们是上下层关系，不是继承关系：
--
--   GameEvent（本文件）—— **流程**。一件事怎么一步步走完：
--       "一个大回合"、"某只精灵的一次行动"、"一次伤害结算"、"一次技能使用"。
--       它是**协程**，所以能干三件时机做不到的事：
--         * 中途**停下来等**（等客户端回话、等动画播完再继续）；
--         * **插入子事件**（打伤害的过程中触发"倒下"子流程，走完再回来接着算）；
--         * **被打断**（有人打断这次结算 → 整条链上的事件一起被 kill）。
--
--   Timing（core/timing.lua）—— **时机**。在流程走到某一步时问一遍
--       "这一刻谁想插一脚"，同步问完就走。
--
-- 关系是：`GameEvent:main()` 里调 `logic:trigger(某个时机, ...)`。
-- 反过来说，**时机的粒度是表达力上限，而流程事件是时间轴**：
--   没有"行动"这个流程事件，就没有"行动开始/结束"这两个时机。
--
-- ---------------------------- 和 freekill 的差异 ----------------------------
--
--   1. freekill 用一个全局 `RoomInstance` 找房间；这里用 `Seer:getLogic().room`
--      （同一个进程里只有一局对战，这个前提和 freekill 一致，只是不靠全局变量传）。
--   2. freekill 的 `self.event` 字段存的就是事件类（老代码里是字符串）；
--      本项目直接用 middleclass 的 `self.class`，少一份重复的真相。
--   3. freekill 还保留了 `GameEvent.functions/prepare_funcs/...` 这套"按字符串注册
--      函数"的兼容层（老写法）。本项目是全新代码，不需要兼容层，所以
--      `prepare/main/clear/exit` 就是普通的可重写方法。
--   4. freekill 用 `mt.__eq` 让"派生类和基类相等"（好让 `findParent` 按基类查得到）。
--      这里改成显式的 `GameEvent.isType(a, b)`：== 的行为应该一眼看得懂，
--      不该因为"某个类是事件的派生类"就突然变成返回 true。
--   5. freekill 的 `desc/getDesc` 要做颜色、翻译、牌名渲染（那是三国杀 UI 的事）。
--      这里只提供结构化的 `desc()`，怎么渲染是 C++ / 客户端的事。

---@class GameEvent: Object
---@field public id integer @ 事件编号，随时间递增（和 Timing 的编号是两套）
---@field public end_id integer @ 对应结束号；整段没插过子事件时等于自己的 id
---@field public room any @ 战局房间
---@field public data any @ 事件数据（一般是 TriggerData 的子类实例）
---@field public parent GameEvent? @ 父事件（栈里的上一层）
---@field public extra_clear function[] @ 清场时要额外执行的函数
---@field public extra_exit function[] @ 结束时额外执行的函数
---@field public exec_ret any @ main() 的返回值
---@field public status string @ ready / running / exiting / dead
---@field public interrupted boolean @ 是不是被中断结束的（被防止、被杀）
---@field public killed boolean @ 是否"被杀"（终止一切结算）
GameEvent = class("GameEvent")

---@param klass GameEvent @ 事件类（冒号调 create 时自动传入）
---@param data? any
---@param room? any @ 省略则取当前战局（Seer:getLogic().room）
function GameEvent:initialize(klass, data, room)
  room = room or (Seer:getLogic() and Seer:getLogic().room)
  if room == nil then
    error("创建流程事件时找不到战局：先建好 BattleLogic，或者显式传 room", 2)
  end
  self.room = room
  self.data = data

  self.id = -1
  self.end_id = -1
  self.parent = nil
  self.exec_ret = nil
  self.status = "ready"
  self.interrupted = false
  self.killed = false

  self.extra_clear = Util.DummyTable
  self.extra_exit = Util.DummyTable
end

---@return string
function GameEvent:__tostring()
  return ("<%s #%d>"):format(self.class.name, self.id)
end

-- ============================ 类级工具 ============================

--- 造一个事件实例并拿到它（不会自动执行——执行要显式 `:exec()`）。
--- 用法：`GameEvent.Turn:create(TurnData:new{...}):exec()`
function GameEvent.static:create(data, room)
  return self:new(self, data, room)
end

--- 找到"最接近 GameEvent 的基类"。
--- 用途：`event_recorder` 按基类分表——同一个家族（比如所有伤害类）的派生事件
--- 共享一张表，查基类才能把所有派生事件一起捞出来。
function GameEvent.static:getBaseClass()
  if self == GameEvent then return GameEvent end
  if self.super == nil or self.super == GameEvent then return self end
  return self.super:getBaseClass()
end

--- 判断一个事件类是不是某个类型（含派生类）。
--- 显式版：`GameEvent.isType(DerivedDamage, GameEvent.Damage)` == true
---@param klass GameEvent
---@param event_type GameEvent
---@return boolean
function GameEvent.static:isType(event_type)
  if self == event_type then return true end
  if type(event_type) ~= "table" or self.isSubclassOf == nil then return false end
  return self:isSubclassOf(event_type)
end

-- ============================ 四个可重写阶段 ============================
--
-- 一次流程事件的生命周期：
--   prepare()  —— 进栈**之前**。返回 true = 这次不做了（整个事件跳过，连栈都不进）
--   main()     —— 进栈之后跑的主体。可以在里面 `logic:trigger(...)`、插子事件、等回话
--   clear()    —— 事件结束时由**清场事件**（ClearEvent）调用，是收尾的地方
--   exit()     —— main 正常跑完之后执行（**被 kill 的事件不会走这里**，所以
--                 必须发生的事要写在 clear() 里，那是本项目照抄 freekill 的重要细节）

---@return boolean? skipped
function GameEvent:prepare() return nil end

function GameEvent:main() return nil end

function GameEvent:clear() return nil end

function GameEvent:exit() return nil end

---@param f function
function GameEvent:addCleaner(f)
  if self.extra_clear == Util.DummyTable then self.extra_clear = {} end
  table.insert(self.extra_clear, f)
end

---@param f function
function GameEvent:addExitFunc(f)
  if self.extra_exit == Util.DummyTable then self.extra_exit = {} end
  table.insert(self.extra_exit, f)
end

---@param f function
function GameEvent:prependExitFunc(f)
  if self.extra_exit == Util.DummyTable then self.extra_exit = {} end
  table.insert(self.extra_exit, 1, f)
end

--- 结构化描述（给日志/客户端用）。怎么渲染是 C++ 的事。
---@return table
function GameEvent:desc()
  return { type = "#GameEvent", event = self.class.name }
end

-- ============================ 在事件树里找东西 ============================

--- 顺着 parent 链往上找第一个某类型的事件。
--- 这是**唯一**可靠的"我现在是在哪件事里面"的查询方式：比如"这次伤害是不是
--- 由某张牌的使用引起的"，就是 `logic:getCurrentEvent():findParent(GameEvent.UseSkill)`。
---@param event_type GameEvent
---@param include_self? boolean @ 默认 false（只找父事件）
---@param depth? integer @ 最多往上找几层
---@return GameEvent?
function GameEvent:findParent(event_type, include_self, depth)
  if include_self and GameEvent.isType(self.class, event_type) then return self end
  if depth == 0 then return nil end
  local e = self.parent
  local level = 1
  while e do
    if GameEvent.isType(e.class, event_type) then return e end
    if depth and level >= depth then break end
    e = e.parent
    level = level + 1
  end
  return nil
end

--- 在 [from, to] 区间里按 id 找至多 n 个符合条件的事件。
--- 二分只是为了在事件很多（几千条）时别退化成线性扫描，逻辑和线性版一致。
local function bin_search(events, from, to, n, func)
  local left, right = 1, #events
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
        if from >= id_left then break end
        right = mid - 1
      else
        left = mid + 1
      end
    end
  end

  for i = mid, #events do
    local v = events[i]
    if v.id > to then break end
    if func(v) then table.insert(ret, v) end
    if #ret >= n then break end
  end
  return ret
end

--- 在本事件（含它插入的所有子事件）的时间区间里，找至多 n 个某类型的事件。
--- 这就是"这一回合里发生过几次伤害"这类查询的实现。
---@param event_type GameEvent
---@param n? integer @ 默认 1
---@param func? function @ 过滤：fun(e) -> boolean
---@param end_event? GameEvent @ 区间终点，默认延伸到本事件结束
---@return GameEvent[]
function GameEvent:searchEvents(event_type, n, func, end_event)
  local logic = self.room.logic
  local events = logic.event_recorder[event_type] or Util.DummyTable
  local from = self.id
  local to = end_event and end_event.id or self.end_id
  -- end_id 还是 -1 说明本事件还没结束，那就找到"目前最后一条"为止
  if to < 0 then to = logic.current_event_id end
  n = n or 1
  func = func or Util.TrueFunc

  if #events < 6 then
    local ret = {}
    for _, v in ipairs(events) do
      if v.id >= from and v.id <= to and func(v) then
        table.insert(ret, v)
      end
      if #ret >= n then break end
    end
    return ret
  end
  return bin_search(events, from, to, n, func)
end

-- ============================ 执行 ============================

--- 执行本事件。
---
--- **注意这是"挂起"，不是"跑完"**：它会 yield 回事件管理器（BattleLogic:start），
--- 由管理器来 resume。所以调用它的永远是一段正在运行的协程。
--- 返回值只有等整段流程真正跑完、由管理器 resume 回来之后才拿得到。
---@return boolean interrupted, any exec_ret
function GameEvent:exec()
  local logic = self.room.logic
  if self.status ~= "ready" then return true end

  self.parent = logic:getCurrentEvent()

  -- prepare 在进栈之前跑：返回 true 表示"这次不做了"，整个事件连栈都不进
  if self:prepare() then return true end

  logic:pushEvent(self)

  self._co = coroutine.create(function() return self:main() end)
  self.status = "running"

  -- 把控制权交回事件管理器（`__newEvent` = "我插了一个子事件，请去调它"）
  coroutine.yield(self, "__newEvent")

  -- 走到这里说明 main 正常跑完了（被 kill 的事件协程会被直接 close，不会到这儿）
  Util.Pcall(self.exit, self)
  for _, f in ipairs(self.extra_exit) do
    Util.Pcall(f, self)
  end

  return self.interrupted, self.exec_ret
end

--- 主动结束自己："这个事件不用再往下走了"。
--- 调用之后本事件会一路退栈（会被 kill 的语义接管）。
function GameEvent:shutdown()
  if self.status ~= "running" then return end
  coroutine.yield(self, "__breakEvent")
end

-- ============================ 两个通用事件 ============================

--- 根事件：整个战局的最外层。
--- 它一跑起来，`logic:run()` 就开始推进对局；它结束 = 这一局结束。
---@class GameEvent.Game: GameEvent
local Game = GameEvent:subclass("GameEvent.Game")

function Game:main()
  local room = self.room
  room.game_started = true
  self.room.logic:run()
end

--- 清场事件：每个事件结束时都要过一遍它。
--- 它**不可被打断**——它就是把事情收了尾、把栈退掉的那个人。
---@class GameEvent.ClearEvent: GameEvent
---@field public data GameEvent @ 要清场的那个事件
local ClearEvent = GameEvent:subclass("GameEvent.ClearEvent")

function ClearEvent:main()
  local event = self.data
  local logic = self.room.logic

  -- 收尾：clear() 是"必须发生的事"（exit() 对被杀的事件不会跑）
  Util.Pcall(event.clear, event)
  for _, f in ipairs(event.extra_clear) do
    Util.Pcall(f, event)
  end

  -- 给这段事件补一个"结束号"：
  --   如果整段里插过子事件，结束号就是当前最大号 +1（区间 [id, end_id] 包住所有子事件）；
  --   没插过就是自己的号。searchEvents 的区间查询靠它。
  local end_id = logic.current_event_id + 1
  if event.id ~= end_id - 1 then
    logic.all_game_events[end_id] = event.class
    logic.current_event_id = end_id
    event.end_id = end_id
  else
    event.end_id = event.id
  end

  -- 按身份把自己和它清理的那个事件摘下来。
  -- 不用 `pop()` 的原因见 Util.Stack:remove 的注释：清场事件跑 clear() 时
  -- 可能又插进来一串新事件，那时栈顶已经不是自己了。
  logic.game_event_stack:remove(event)
  logic.cleaner_stack:remove(self)
end

GameEvent.Game = Game
GameEvent.ClearEvent = ClearEvent

return GameEvent
