-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 战场逻辑调度器 ============================
--
-- 对应 freekill-core 的 `GameLogic`（`lua/server/gamelogic.lua`）。它干四件事：
--
--   1. **流程事件管理**（`start` / `pushEvent` / `resumeEvent` / `clearEvent`）：
--      驱动那一堆协程版的 `GameEvent`——回合、行动、伤害、技能使用。
--      **这是整套战斗的引擎**：谁在跑、跑完了没、要不要插子事件、要不要被打断，
--      全在这里定。协程的挂起/恢复、事件栈、清场事件（ClearEvent）都是它的活。
--   2. **时机注册**：谁要挂在哪个时机上（`addTrigger`），并按优先级排好，供
--      `Timing:exec()` 取用。core 里这张表叫 `skill_table` / `skill_priority_table`，
--      这里叫 `trigger_table` / `trigger_priority_table`——因为本项目挂在时机上的
--      不止技能（还有 Effect 变出来的触发器），叫 trigger 更准确。
--   3. **触发时机**：`trigger(时机类, 受动者, 数据)` —— 造 Timing 实例、执行、
--      记录进事件流。
--   4. **结算动作**：`damage` / `recover` / `changeHp` / `doStatChange` / `applyMark`
--      （伤害和回复本身也是流程事件，见 hp.lua）。这些方法把"一次完整结算是由
--      哪几个时机串起来的"封在内部，规则作者不需要知道伤害链有几步。
--
-- 另外它还兜着三件必须集中管理的东西：
--   * **随机数**：`self.rng`。战斗里所有随机都必须从这里拿，绝不能用 math.random，
--     否则回放/断线重连会对不上（架构文档 §2.3）。
--   * **事件流**：`self.event_log`。架构文档 §6 说"事件流本身就能当回放/复盘"，
--     所以流程事件和时机都往这里记一笔（用 `kind` 区分两层）。
--   * **问客户端/等外部回话**：`doRequest` + `askToChoice`。Lua 没有 socket，
--     想让人做选择只能开这个口子，由 C++ 去问（架构文档 §5.3/§5.4）。
--     无客户端（自测）时会走 `request_hook` 就地作答，一步都不用挂起。

--- 事件管理器一轮最多循环多少次（防"调度器原地打转"把进程卡死）
---@class BattleLogic: Object
---@field public room any @ 战斗房间（要能被问 askToChoice、能提供 getAlivePets）
---@field public rng Rng @ 本局专用的确定性随机数发生器
---@field public trigger_table table<Timing, any[]> @ 时机类 --> 触发者数组（已按优先级排好）
---@field public trigger_priority_table table<Timing, number[]> @ 时机类 --> 去重降序的优先级数组
---@field public dynamic_triggers table<string, any> @ 运行时挂上的触发者（效果产生的）
---@field public current_timing_id integer @ **时机**编号计数器（core: current_trigger_event_id）
---@field public current_event_id integer @ **流程事件**编号计数器（core: current_event_id）
---@field public game_event_stack Stack @ 流程事件栈
---@field public cleaner_stack Stack @ 清场事件栈（每个事件结束时都会过一遍）
---@field public all_game_events table @ 编号 --> 流程事件
---@field public event_recorder table @ 事件基类 --> 该家族的所有事件（按 id 有序）
---@field public event_log table[] @ 事件流（两层都记，回放用）
---@field public round integer @ 第几大回合
---@field public turn integer @ 本回合第几次行动
BattleLogic = class("BattleLogic")

--- 事件管理器主循环一轮最多跑多少轮。正常一局顶多几十万轮，这个数字只是"防死循环"的闸，
--- 不是为了限制正常对局——真撞上了说明调度出了 bug，明确报错比卡死一个好。
BattleLogic.MAX_EVENT_LOOP_ITERATIONS = 200000

--- 一局最多打多少个大回合。到顶就判平局——照 freekill 的 999 轮保护，
--- 理由是同一个：万一两个效果互相"再触发一次"，服务器不能一直转下去。
BattleLogic.MAX_ROUNDS = 999

---@param room any @ 战斗房间
---@param opts? table @ `{ seed = 整数或字符串（**必须给**，否则不可回放）, actors = Pet[] }`
function BattleLogic:initialize(room, opts)
  opts = opts or {}
  self.room = room
  if room then room.logic = self end

  -- 种子必须由外面显式给。给了种子，整局就能重放；不给就只是一局普通对战。
  self.seed = opts.seed
  self.rng = Rng:new(opts.seed)

  self.trigger_table = {}
  self.trigger_priority_table = {}
  self.dynamic_triggers = {}

  -- 时机这一层：编号 + 栈
  self.current_timing_id = 0
  self.timing_stack = Util.Stack:new()

  -- 流程事件这一层：编号 + 事件栈 + 清场栈 + 两本账
  self.current_event_id = 0
  self.game_event_stack = Util.Stack:new()
  self.cleaner_stack = Util.Stack:new()
  self.all_game_events = {}
  -- event_recorder 按**基类**分表：同一个家族（所有伤害类）的派生事件共享一张表，
  -- 这样 `searchEvents(GameEvent.Damage, ...)` 能把派生类的事件也一起捞出来。
  -- （core 是用"给类装 __eq"达到同样目的，这里改成在读写时显式归一化，更好懂）
  self.event_recorder = setmetatable({}, {
    __index = function(t, k)
      if GameEvent.isType(k, GameEvent) then k = k:getBaseClass() end
      return rawget(t, k)
    end,
    __newindex = function(t, k, v)
      if GameEvent.isType(k, GameEvent) then k = k:getBaseClass() end
      rawset(t, k, v)
    end,
  })
  self.specific_events_id = {}

  self.event_log = {}
  self.record_events = opts.record_events ~= false
  self.request_hook = opts.request_hook

  -- ---- 询问机制（对应 freekill 的 Request / Room:askToChoice，见 server/request/）----
  -- `request_handlers`：**个别座位单独指定答复者**。单机版就是这么接的——
  -- 人类那只精灵挂 CliHandler，对手那只走 AI，两边共用同一份游戏流程。
  -- 没指定的座位按 getRequestHandler 里的优先级回退（hook → 挂起 → 无头默认）。
  self.request_handlers = {}
  self.request_timeout = opts.request_timeout or 0
  self.current_request = nil      -- 正在问的那件事（Request 对象；freekill 同名）
  self.last_request = nil         -- 上一次问完的（重连/复盘时有用）
  self._ai_handler = nil
  self._rpc_handler = nil
  self._default_handler = nil

  self.actors = opts.actors
  self.round = 0
  self.turn = 0

  Seer:setLogic(self)
end

--- 按名字取一个时机类。
--- 时机由 server/battle/timing.lua 登记进 Seer 并挂到全局 SeerTiming 上。
--- 取不到就告警返回 nil——调用方一律写 `if X then ... end`，
--- 于是"某个时机还没实现"只会让对应流程少一步，而不是把整局打死。
local function E(name)
  local klass = SeerTiming[name]
  if klass == nil then
    Log.warning(("时机 %s 还没注册，相关流程会被跳过"):format(name))
  end
  return klass
end

-- ============================ 流程事件：管理器 ============================
--
-- 这一节是 freekill `GameLogic:start/pushEvent/resumeEvent/clearEvent/...` 的移植。
-- 它是整个战斗的引擎：**所有 GameEvent 都是由这里驱动着跑的**。
--
-- 为什么需要一个"管理器"，而不是让事件自己递归调用？因为事件之间是这种关系：
--
--   * 一个事件跑到一半，可以**插入**一个子事件（打伤害时插入"倒下"流程），
--     子事件走完再回来接着算；
--   * 一个事件可以被**打断**（伤害被防止了 → 整条链上的事件一起作废）；
--   * 一个事件可以**停下来等**（等客户端选技能、等动画播完）。
--
-- 这三件事都不是普通函数调用能表达的，所以事件是**协程**，由管理器统一调度：
-- 每个事件自己 yield 出来说"我要插个子事件 / 我要挂起"，管理器决定下一个跑谁。
-- 事件栈（game_event_stack）就是这个"谁在跑"的账本。
--
-- 清场事件（ClearEvent）是这套机制的关键配角：**每个事件结束时都要过一个清场事件**，
-- 由它来调 `clear()` 并退栈。为什么不让事件自己收尾？因为事件可能是被 kill 的——
-- 协程被直接 close，`main()` 后面的代码根本不会执行。所以"必须发生的事"
-- （退栈、清理标记、补结束号）只能放在一个**不可被打断**的独立事件里做。

--- 开始推进对局。
---
--- 事件管理器跑在一个**独立协程**里，因为"等外部回话"就是用 coroutine.yield 表达的
--- （见 `doRequest`）。所以 `start()` 不是"跑完才返回"，而是"跑到下一次挂起或结束"。
---@return string kind @ `"request"`（在等外部回话）或 `"finished"`（这一局走完了）
function BattleLogic:start()
  if self._manager_co == nil then
    self._manager_co = coroutine.create(function() return self:runEventLoop() end)
  end
  return self:resume()
end

--- 外部把回话送回来（或者只是"继续往下跑"）。
--- 对应 freekill 里最后由 C++ 唤醒 RoomThread 的那一步。
---@param resume_reason? any @ 送给挂起点的值（比如玩家的选择）
---@return string kind
function BattleLogic:resume(resume_reason)
  if self._manager_co == nil or coroutine.status(self._manager_co) == "dead" then
    return "finished"
  end

  local ok, kind, payload = coroutine.resume(self._manager_co, resume_reason)
  if not ok then
    Log.critical("事件管理器出错：", tostring(kind), "\n", debug.traceback(self._manager_co))
    return "error"
  end

  if coroutine.status(self._manager_co) == "dead" then
    self.finished = true
    return "finished"
  end

  -- 管理器挂起了：一定是在等外部回话
  self.pending_request = payload
  return "request"
end

--- 事件管理器主循环。对照 freekill `GameLogic:start()`。
--- 它自己就是"根事件"，由根事件驱动 `logic:run()` 推进整局；
--- 循环体在 `driveEventLoop` 里，与"独立跑一件事"共用。
function BattleLogic:runEventLoop()
  local root = GameEvent.Game:create(nil, self.room)
  self:pushEvent(root)
  root._co = coroutine.create(function() return root:main() end)
  self:driveEventLoop()
  self:notify{ type = "EventLoopDone" }
  return "finished"
end

--- 把一个流程事件压进栈，并登记进两本账。
--- 编号在这里分配——**流程事件的编号和时机的编号是两套**，别混。
---@param event GameEvent
function BattleLogic:pushEvent(event)
  -- 不变式：进栈的事件必须属于本战局。
  -- 单测里同时存在好几个战局，而 `GameEvent:create` 在没有显式传 room 时会退化成
  -- "当前战局"（Seer 上登记的那个）——于是事件会被挂到**别人的**栈上，
  -- 表现是"这件事像没跑一样，然后调度器原地打转"。这种 bug 极难查，
  -- 所以在这里直接把不变式钉死：创建事件一律 `X:create(data, logic.room)`。
  assert(event.room ~= nil and event.room.logic == self,
    ("流程事件 %s 挂到了别的战局上：创建时忘了传 room"):format(tostring(event)))

  self.game_event_stack:push(event)

  self.current_event_id = self.current_event_id + 1
  event.id = self.current_event_id
  self.all_game_events[event.id] = event

  local list = self.event_recorder[event.class]   -- 元表会归一化到基类
  if list == nil then
    list = {}
    self.event_recorder[event.class] = list
  end
  table.insert(list, event)

  self:recordGameEvent(event)
  return event
end

--- 生成一个清场事件并压进清场栈。
--- 注意这里**只创建协程、不 resume**：由主循环按"编号大的先跑"来挑它。
---@param event GameEvent
function BattleLogic:clearEvent(event)
  if event.class == GameEvent.ClearEvent then return end
  if event.status == "exiting" then return end
  event.status = "exiting"

  local ce = GameEvent.ClearEvent:create(event, self.room)
  ce.id = self.current_event_id
  ce._co = coroutine.create(function() return ce:main() end)
  self.cleaner_stack:push(ce)
  return ce
end

--- 恢复一个事件的协程，直到它结束、插入子事件、挂起等回话、或者被打断。
---@param event GameEvent
---@return boolean? interrupted, GameEvent? new_or_break_to
function BattleLogic:resumeEvent(event)
  local co = event._co
  local resume_reason = nil
  local ret, evt

  while true do
    local ok, yield_result, extra = coroutine.resume(co, resume_reason)

    if not ok then
      -- 事件里的代码报错了。当作"被中断结束"处理：不能让一个技能的 bug
      -- 把整个事件栈晾在半空中（架构文档 §2.4 的隔离精神）。
      if not tostring(yield_result):find("__manuallyBreak") then
        Log.critical(tostring(yield_result), "\n", debug.traceback(co), "\n", self:dumpEventStack())
      end

      -- 兜底：协程起不来了（已经死掉之类），就得手动把栈清干净。
      -- 不做这一步的话，主循环会一轮一轮地 resume 一个死协程，原地打转。
      if self.cleaner_stack:remove(event) then
        -- 清场事件本来要干的活（退事件栈）由这里补上
        if event.data ~= nil then
          self.game_event_stack:remove(event.data)
        end
      else
        self.game_event_stack:remove(event)
      end

      ret = true
      break
    end

    if yield_result == "__handleRequest" then
      -- 事件要挂起等外部回话（玩家选技能/确认弹窗）。把控制权交给 C++，
      -- 等它回头 `logic:resume(玩家的选择)` 时，我们再从这里往下走。
      resume_reason = coroutine.yield("__handleRequest", extra)

    elseif type(yield_result) == "table" and yield_result.class
      and yield_result:isInstanceOf(GameEvent) then

      if extra == "__newEvent" then
        -- 插入了子事件：交给主循环去跑它，本事件等它结束后自然被 resume 回来
        ret, evt = false, yield_result
        break
      elseif extra == "__breakEvent" then
        ret, evt = true, yield_result
        if event.class ~= GameEvent.ClearEvent then break end
      end

    elseif yield_result == "__breakEvent" then
      ret = true
      -- 把 `breakEvent(值)` 里那个值记下来：它表示"这件事为什么/以什么结果断的"。
      -- freekill 在这一支里把第二个 yield 值丢掉了，这里顺手接住——
      -- 不接的话 `breakEvent(false)` 的参数就纯粹是写着好看。
      if extra ~= nil then event.exec_ret = extra end
      if event.class ~= GameEvent.ClearEvent then break end

    else
      -- 正常结束：yield 出来的值就是 main() 的返回值
      ret = false
      event.exec_ret = yield_result
      break
    end
  end

  return ret, evt
end

---@return GameEvent? @ 当前正在跑的流程事件（栈顶）
function BattleLogic:getCurrentEvent()
  return self.game_event_stack:top()
end

---@return GameEvent? @ 正在跑的清场事件
function BattleLogic:getCurrentCleaner()
  return self.cleaner_stack:top()
end

---@return integer @ 事件栈深度（用来判断"我现在套了多少层"）
function BattleLogic:getCurrentEventDepth()
  return self.game_event_stack.p
end

--- 在当前事件往上找最近的某类型事件。
--- 用途示例："这次伤害是不是由某次技能使用引起的"。
---@param event_type GameEvent
---@param include_self? boolean
---@return GameEvent?
function BattleLogic:getMostRecentEvent(event_type, include_self)
  local cur = self:getCurrentEvent()
  if cur == nil then return nil end
  return cur:findParent(event_type, include_self == nil and true or include_self)
end

--- 如果当前正在跑的事件刚好是"某技能生效"，返回那个技能名，否则 nil。
--- 对应 freekill 的 `getCurrentSkillName`：技能名要出现在日志/UI 里。
---@return string?
function BattleLogic:getCurrentSkillName()
  local cur = self:getCurrentEvent()
  if cur == nil then return nil end
  if GameEvent.UseSkill and GameEvent.isType(cur.class, GameEvent.UseSkill) then
    local skill = cur.data and cur.data.skill
    if skill == nil then return nil end
    local main = skill.main_skill or skill
    return main.name
  end
  return nil
end

--- 在指定的**历史范围**里找某类型的事件（"本回合发生过几次伤害"）。
--- 范围靠"往上找最近的那个区间事件"来定：回合/行动。
---@param event_type GameEvent
---@param n integer
---@param func? function
---@param scope? GameEvent @ 区间类型，默认 GameEvent.Turn
---@return GameEvent[]
function BattleLogic:getEventsOfScope(event_type, n, func, scope)
  scope = scope or GameEvent.Turn
  local cur = self:getCurrentEvent()
  if cur == nil then return {} end
  local start_event = cur:findParent(scope, true)
  if start_event == nil then return {} end
  return start_event:searchEvents(event_type, n, func)
end

--- 从最近的事件往前逆序找（"上一次造成伤害是谁干的"）。
---@param event_type GameEvent
---@param n integer
---@param func? function
---@param end_id? integer
---@param scope? GameEvent
---@return GameEvent[]
function BattleLogic:getEventsByRule(event_type, n, func, end_id, scope)
  if scope then
    local cur = self:getCurrentEvent()
    local end_event = cur and cur:findParent(scope, true)
    end_id = end_event and end_event.id or 0
  end
  if end_id == nil then
    local cur = self:getCurrentEvent()
    end_id = cur and cur.id or self.current_event_id
  end

  func = func or Util.TrueFunc
  local ret = {}
  local events = self.event_recorder[event_type] or Util.DummyTable
  for i = #events, 1, -1 do
    local e = events[i]
    if e.id <= end_id then break end
    if func(e) then
      table.insert(ret, e)
      if #ret >= n then break end
    end
  end
  return ret
end

--- 从某个事件里"打断到"另一个事件：把中间那些全杀掉。
--- 规则代码里调用它 = "这件事不用再算了"。对应 freekill 的 `breakEvent`。
---@param ret? any
function BattleLogic:breakEvent(ret)
  coroutine.yield("__breakEvent", ret)
end

--- 把事件栈打成字符串（报错时打日志用，出错现场最重要）
---@return string?
function BattleLogic:dumpEventStack()
  local top = self:getCurrentEvent()
  if top == nil then return nil end
  local lines = { "===== 事件栈 =====" }
  local e = top
  while e do
    table.insert(lines, ("  %s"):format(tostring(e)))
    e = e.parent
  end
  table.insert(lines, "==================")
  return table.concat(lines, "\n")
end

-- ============================ 问外人（C++/客户端/命令行/AI） ============================
--
-- 这一节是"**Lua 是大脑、外面是手脚**"的落地点（架构文档 §5.3），
-- 也是 freekill `Request` 机制的移植版：
--
--   Request（server/request/init.lua）  —— 问**什么**：问谁、问几次、默认答复、怎么收尾
--   RequestHandler（同目录 handler.lua）—— **谁去答**：命令行 / AI / 真人客户端
--
-- 游戏流程只管"我要问这件事"，不关心答案从哪来。换一个处理器，
-- 同一份规则就从单机变成联机，从人玩变成 AI 玩——这就是"之后换 Unity 也能跑"。
--
-- 所以这里的方法只有三件事：
--   getRequestHandler(pet)  决定这只精灵由谁答（优先级见下）
--   ask/doRequest           发问 + 等答复
--   requireYieldable()      在"必须挂起但不能挂起"时给一句看得懂的报错

--- 这只精灵的答复者是谁。优先级（从高到低）：
---
---   1. `logic:setRequestHandler(pet, handler)` 单独指定的 ——
---      单机版里"你"的精灵挂 CliHandler，对手挂 AiHandler；
---   2. `logic.request_hook` —— 就地作答的函数（跑 AI/示例/自测用，一步不挂起）；
---   3. `logic.interactive = true` —— **真挂起**，把请求包交给 C++/Unity，等它回话；
---   4. 都没有 —— 无头降级：用请求自己的默认答复（挑一个能打的技能/选第一个选项）。
---
--- 注意 2/3 是每次现查的（不是构造时缓存），因为测试和示例会中途改 `request_hook`。
---@param pet Pet
---@return RequestHandler
function BattleLogic:getRequestHandler(pet)
  if pet ~= nil then
    -- 键既可以是精灵对象本身，也可以是座位号（座位可能还没分配）
    local by_pet = self.request_handlers[pet]
    if by_pet ~= nil then return by_pet end
    if pet.seat ~= nil then
      local by_seat = self.request_handlers[pet.seat]
      if by_seat ~= nil then return by_seat end
    end
  end

  if self.request_hook ~= nil then
    if self._ai_handler == nil or self._ai_handler.fn ~= self.request_hook then
      self._ai_handler = AiHandler:new{ logic = self, fn = self.request_hook }
    end
    return self._ai_handler
  end

  if self.interactive then
    if self._rpc_handler == nil then self._rpc_handler = RpcHandler:new{ logic = self } end
    return self._rpc_handler
  end

  if self._default_handler == nil then
    self._default_handler = DefaultHandler:new{ logic = self }
  end
  return self._default_handler
end

--- 指定某只精灵（或某个座位）由谁来答复。
---@param pet_or_seat Pet|integer
---@param handler? RequestHandler @ 传 nil = 恢复默认优先级
---@return RequestHandler?
function BattleLogic:setRequestHandler(pet_or_seat, handler)
  assert(type(pet_or_seat) == "number" or type(pet_or_seat) == "table",
    "setRequestHandler 需要一只精灵或者座位号")
  if handler ~= nil then handler.logic = handler.logic or self end
  self.request_handlers[pet_or_seat] = handler
  return handler
end

--- 挂起只能在协程里发生。走到这儿说明调用方式不对——直接说清楚怎么改，
--- 而不是抛一句 "attempt to yield from outside a coroutine" 让人猜。
function BattleLogic:requireYieldable()
  if coroutine.isyieldable() then return end
  error("要等玩家输入就只能挂起，而挂起必须在协程里：\n"
    .. "  · 正常打一局请用 logic:start() 推进（它自己会把事件管理器放协程里跑）；\n"
    .. "  · 无头/自测请给 logic.request_hook 一个『就地作答』的函数；\n"
    .. "  · 单机版请给这只精灵挂一个 CliHandler（见 server/request/cli.lua）。", 2)
end

--- 底层挂起点：把一份**可序列化的请求**交出去，等外面把答复送回来。
---
--- 一般不用直接调它：真正在用的是 `Request:ask()` 的等待循环 + `RpcHandler:waitReply`。
--- 保留它是因为"只问一次、不关心默认答复/多人等待"的场合（比如调试）用它最短。
---@param payload table @ 要让外面处理的事情，必须可序列化
---@return any @ 外面的答复（由 logic:resume 送进来）
function BattleLogic:doRequest(payload)
  self:requireYieldable()
  self.pending_request = payload
  local reply = coroutine.yield("__handleRequest", payload)
  self.pending_request = nil
  return reply
end

-- ============================ 时机注册 ============================

-- ============================ 触发者注册 ============================

--- 把一个触发者挂到它声明的时机上。
--- 插入位置是**算出来的**（优先级降序、同优先级按名字升序），不是简单的
--- `table.insert` 追加。这一点比 core 严格：core 直接追加，于是"同优先级谁先"
--- 取决于注册顺序；而注册顺序又可能取决于 `pairs` 遍历顺序（不确定），
--- 结果就是同一份数据在不同进程里可能打出不同的结果。既然 §2.3 要确定性，
--- 那就得让顺序只由数据本身决定。
---@param trig any @ TriggerSkill / EffectTrigger（要有 event / priority / name）
function BattleLogic:addTrigger(trig)
  assert(trig ~= nil, "addTrigger 需要一个触发者")
  local event_klass = trig.timing
  if event_klass == nil then
    Log.warning(("触发者 %s 没有 event，无法注册"):format(tostring(trig.name)))
    return false
  end

  local list = self.trigger_table[event_klass]
  if list == nil then
    list = {}
    self.trigger_table[event_klass] = list
    self.trigger_priority_table[event_klass] = {}
  end

  -- 同一个对象不要挂两次
  if table.indexOf(list, trig) then return false end

  local pos = #list + 1
  for i, other in ipairs(list) do
    local mine = trig.priority or 1
    local theirs = other.priority or 1
    if mine > theirs or (mine == theirs and (trig.name or "") < (other.name or "")) then
      pos = i
      break
    end
  end
  table.insert(list, pos, trig)

  local prio_tab = self.trigger_priority_table[event_klass]
  if not table.contains(prio_tab, trig.priority) then
    table.insert(prio_tab, trig.priority)
    table.sort(prio_tab, function(a, b) return a > b end)
  end

  -- 动态触发者要能被名字找回（Timing:exec 的 askToChoice 只拿得到一个名字）
  if trig.owner ~= nil then
    self.dynamic_triggers[trig.name] = trig
  end
  return true
end

---@param trig any
function BattleLogic:removeTrigger(trig)
  for event_klass, list in pairs(self.trigger_table) do
    if table.removeOne(list, trig) then
      if #list == 0 then
        self.trigger_table[event_klass] = nil
        self.trigger_priority_table[event_klass] = nil
      end
      if trig.owner ~= nil then
        self.dynamic_triggers[trig.name] = nil
      end
      return true
    end
  end
  return false
end

--- 按名字找触发者：先找运行时挂上的（效果），再找全局技能表。
--- core 只有 `Fk.skills[name]` 一步；本项目多了效果产生的触发器，所以多一层。
---@param name string
---@return any?
function BattleLogic:getTrigger(name)
  return self.dynamic_triggers[name] or Seer.skills[name]
end

-- ============================ 把精灵接进战局 ============================

-- ============================ 印记 ============================
--
-- 异常状态和增益印记都走这里。注意**战局不解释印记的效果**——
-- "回合末掉血""行动前动不了"都写在印记自己的触发器里(core/mark/status.lua)，
-- 战局只负责：走时机、落账、通知、以及回合末递减。
--
-- 早先的版本是"每只精灵装三个固定处理器"（行动前/回合末/定伤害各一个），
-- 换成印记自带触发器之后好处很直接：**加一种异常状态不用改战局代码**，
-- 而且增益印记天然走同一条路。

--- 给一只精灵挂一个印记（异常状态或增益印记）。
---@param opts table @ `{ target, mark = "burn", source?, turns? }`
---@return Mark? mark @ 挂上了就返回印记实例；被免疫/已有/未知键都返回 nil
function BattleLogic:applyMark(opts)
  local target = opts.target
  local key = opts.mark or opts.status   -- 两种写法都认
  if target == nil or key == nil then return nil end
  if target:isFainted() then return nil end

  if Mark.defs[key] == nil then
    Log.warning(("没注册过的印记 %q，已忽略"):format(tostring(key)))
    return nil
  end

  -- 已经有了：按定义决定"叠层"还是"什么都不做"
  local exist = target:getMark(key)
  if exist then
    exist:addStack()
    return exist
  end

  local data = MarkData:create{
    target = target,
    key = key,
    source = opts.source,
    turns = opts.turns,
  }

  local BeforeMarkApply = E("BeforeMarkApply")
  if BeforeMarkApply then
    if self:trigger(BeforeMarkApply, target, data) then return nil end
  end
  if data.prevented then return nil end

  -- 造实例要问 `Mark.classOf`：异常状态走 StatusMark 的子类（弱化类/控制类），
  -- 增益印记走 BuffMark。这些子类里有"这一类印记怎么动"的行为
  -- （mark:getTurnEndDamage()、mark:rollsActionBlock()），直接 `Mark:new` 拿不到。
  local mark = Mark.classOf(key):new(key, {
    source = opts.source,
    turns = data.turns,
    extra = opts.extra,     -- 实例私有数据（比如"封住的是哪个技能"）
    logic = self,
  })
  mark:attach(self, target)

  local MarkApplied = E("MarkApplied")
  if MarkApplied then self:trigger(MarkApplied, target, data) end
  return mark
end

--- 摘掉一个印记（会走时机 + 通知）。
---@param target Pet
---@param key string
---@param reason? string @ "expired" / "cured" / "consumed" / "cleared"
---@return boolean removed
function BattleLogic:removeMark(target, key, reason)
  if target == nil then return false end
  local mark = target:getMark(key)
  if mark == nil then return false end

  mark:detach(self, reason)

  local MarkRemoved = E("MarkRemoved")
  if MarkRemoved then
    self:trigger(MarkRemoved, target, MarkData:create{ target = target, key = key })
  end
  return true
end

--- 解除异常状态（只清弱化类/控制类，**不动增益印记**）。
--- 单独一个方法是为了让所有解除路径都走它：该发的通知、该触发的时机只有一份实现。
---@param target Pet
---@param key? string @ 只解除这一个；不填 = 解除全部异常状态
---@return integer cured
function BattleLogic:cureStatus(target, key)
  if target == nil then return 0 end

  local cured = 0
  local keys = key and { key } or target:getStatusKeys()
  for _, k in ipairs(keys) do
    local mark = target:getMark(k)
    if mark ~= nil and mark:isStatus() then
      if self:removeMark(target, k, "cured") then cured = cured + 1 end
    end
  end
  return cured
end

-- ============================ 把精灵接进战局 ============================

--- 把一只精灵的技能和特性挂进本战局。
---
--- **这一步不能省**：技能挂在精灵身上（Pet.skills）只是"它拥有这个技能"，
--- 而"这个技能能在某个时机插一脚"必须显式注册到本战局（`addTrigger`）。
--- core 里对应的是 `GameLogic:addTriggerSkill`，由 Player 在获得技能时调用。
---
--- 注意要连**子对象**一起注册：一个技能在 spec 里写了 `triggers`，骨架会把它拆成
--- 主技能 + `#名字_序号_trig` 的子对象，真正挂在时机上的是子对象。
---@param pet Pet
---@return integer registered @ 注册了几个触发者
function BattleLogic:registerPet(pet)
  -- 普通技能 + **第五技能** + 特性：三者都可能有挂在时机上的钩子，
  -- 少登记一个，那个技能/特性的效果就会静默失效
  local mains = {}
  for _, s in ipairs(pet:getAllSkills()) do table.insert(mains, s) end
  if pet.ability then table.insert(mains, pet.ability) end

  local count = 0
  for _, main in ipairs(mains) do
    -- 主技能自己也可能是个触发者（手写的 TriggerSkill）
    if main:isInstanceOf(TriggerSkill) and main.timing then
      if self:addTrigger(main) then count = count + 1 end
    end
    for _, sub in ipairs(main.related_skills) do
      if sub:isInstanceOf(TriggerSkill) and sub.timing then
        if self:addTrigger(sub) then count = count + 1 end
      end
    end
  end

  return count
end

--- 把一只精灵的触发者全摘掉（换下场/倒下时用）
---@param pet Pet
---@return integer removed
function BattleLogic:unregisterPet(pet)
  local removed = 0
  local function drop(skill)
    for event_klass, list in pairs(self.trigger_table) do
      for i = #list, 1, -1 do
        local trig = list[i]
        if trig:isInstanceOf(TriggerSkill) and trig:getOwnerName() == skill.name then
          table.remove(list, i)
          self.dynamic_triggers[trig.name] = nil
          removed = removed + 1
        end
        if #list == 0 then
          self.trigger_table[event_klass] = nil
          self.trigger_priority_table[event_klass] = nil
        end
      end
    end
  end

  for _, s in ipairs(pet:getAllSkills()) do drop(s) end
  if pet.ability then drop(pet.ability) end

  return removed
end

--- 开局：把场上所有精灵接进战局，并把出手顺序串成环。
---
--- 注意它**不触发任何时机**：这只是"接线"（登记触发者、串环、定敌我）。
--- "对局开始了"是**流程**上的事，由第一轮的 `startRound` 触发 GameStart——
--- 两处都触发就会触发两次（时序类的东西重复触发往往不会立刻报错，
--- 而是变成"某个效果莫名生效了两遍"，很难查）。
---@return integer registered
function BattleLogic:registerAllPets()
  local pets = self:getAlivePets()
  -- 记下"本战局有哪些精灵"（现在只用于调试/自测，getActors 直接用 actors）
  self.all_pets = self.actors or pets
  -- 敌我关系由战局显式给定，不能靠"谁先创建"来猜
  for _, p in ipairs(self.all_pets) do
    p:linkTeams(self.all_pets)
  end
  local count = 0
  for _, p in ipairs(pets) do
    count = count + self:registerPet(p)
  end
  return count
end

-- ============================ 参战单位 ============================

--- 本时机要问哪些精灵：**一份数组快照**（还站着的，按固定顺序）。
---
--- freekill 用的是"环形链 + room.current"（每只精灵身上一个 `next` 指向下一只）。
--- 本项目改成每次取一份数组快照，原因是这里的**嵌套执行**比卡牌游戏更频繁：
--- 一个时机里插进来的伤害流程又会去问一遍所有精灵，而那次会重写 `next`；
--- 外层那个还没走完的 `repeat ... until actor == _actor` 于是踩在一条被改过的链上，
--- 环接不回起点 —— 死循环（本项目的进程就卡住了）。
--- 数组快照是"只读的那一份"，嵌套多少次都不会互相干扰。
---
--- 顺序固定（座位号升序），所以随机性不可能从这里漏进来。
---@return Pet[] @ 快照，可以安全地被嵌套流程"忽略"（外层不受影响）
function BattleLogic:getActors()
  local actors = self.actors
  if actors == nil and self.room and self.room.getAlivePets then
    actors = self.room:getAlivePets()
  end
  if actors == nil then
    -- 退化成 core 的写法：房间自己指的那个"当前单位"
    local cur = self.room and self.room.current
    return cur and { cur } or {}
  end

  local ret = {}
  for _, p in ipairs(actors) do
    if not p:isFainted() then table.insert(ret, p) end
  end
  table.sort(ret, function(a, b) return (a.seat or 0) < (b.seat or 0) end)
  return ret
end

---@return Pet[] @ 还站着的精灵（按确定顺序）
function BattleLogic:getAlivePets()
  local pets = self.actors
  if pets == nil and self.room and self.room.getAlivePets then
    return self.room:getAlivePets()
  end
  if pets == nil then return {} end
  return table.filter(pets, function(p) return not p:isFainted() end)
end

-- ============================ 触发时机 ============================

--- **战斗流程里唯一该被直接调用的入口**。
---@param event_klass Timing @ 时机类（不是实例）
---@param target? Pet @ 受动者
---@param data? TriggerData @ 时机数据
---@param refresh_only? boolean
---@return boolean broken, Timing? ev
function BattleLogic:trigger(event_klass, target, data, refresh_only)
  if not (type(event_klass) == "table" and event_klass.isSubclassOf
    and event_klass:isSubclassOf(Timing)) then
    -- core 在这里也是直接放行：允许规则代码写 `logic:trigger(nil, ...)` 而不炸
    return true, nil
  end

  local ev = event_klass:new(self.room, target, data)
  ev.refresh_only = refresh_only

  -- 注意 push 必须在 exec 之前：exec 里会读 logic:getCurrentEvent()
  -- ——那是**流程事件**栈顶——判断"当前这件事是不是已经被杀了"，
  -- 从而决定是否只做 refresh。所以这里是"时机栈"，那个是"流程事件栈"，
  -- 两层各管各的账本。这也是嵌套触发（回合末中毒掉血）能正确工作的原因。
  self.timing_stack:push(ev)

  -- **先记录再执行**：执行过程中会嵌套触发别的时机（回合末中毒掉血会走一整条
  -- 伤害链），如果等 exec 返回才记录，事件流里嵌套的事件就会排到父事件前面，
  -- 顺序反了。事件流是要拿来回放的（架构文档 §6），顺序必须等于发生顺序。
  local entry = self:recordTiming(ev)

  local ok, broken = pcall(function() return ev:exec() end)
  self.timing_stack:pop()

  if not ok then
    -- 规则代码报错不应该拖垮整局：记下来、当作"这个时机没被打断"继续跑。
    -- 架构文档 §2.4 要的是进程隔离，但一个技能写错就整房崩掉还是太脆。
    Log.critical(("时机 %s 执行出错：%s"):format(event_klass.name, tostring(broken)))
    broken = false
  end

  if entry then entry.broken = broken or false end
  return broken, ev
end

--- 当前正在跑的**时机**（时机栈顶）。
--- 注意别和 `getCurrentEvent()` 搞混：那个是流程事件，这个是时机。
---@return Timing?
function BattleLogic:getCurrentTiming()
  return self.timing_stack:top()
end

--- 把流程事件记进事件流。回放要的是**两层都记**：先知道"发生了哪些事"，
--- 再看"每一步有谁插了一脚"。
---@param event GameEvent
function BattleLogic:recordGameEvent(event)
  if not self.record_events then return nil end
  local entry = {
    kind = "game_event",
    id = event.id,
    name = event.class.name,
    round = self.round,
    turn = self.turn,
    data = event.data and event.data.toTable and event.data:toTable() or nil,
  }
  table.insert(self.event_log, entry)
  return entry
end

--- 把时机记进事件流（回放/复盘/断线重连都要它）。
--- 返回记录项本身，好让调用方在 exec 结束后回填 `broken`。
---@param ev Timing
---@return table? entry
function BattleLogic:recordTiming(ev)
  if not self.record_events then return nil end
  local entry = {
    kind = "timing",
    id = ev.id,
    name = ev.class.name,
    round = self.round,
    turn = self.turn,
    target = ev.target and ev.target.name or nil,
    broken = false,
    data = ev.data and ev.data:toTable() or nil,
  }
  table.insert(self.event_log, entry)
  return entry
end

-- ============================ 问客户端 ============================

--- 让人做一个选择。
---
--- 对应 core 的 `room:askToChoice`。它现在是一个 `Request.AskForChoice`：
--- "问什么"由 Request 描述，"谁答"由这只精灵的 `RequestHandler` 决定——
--- 接客户端时挂起、单机时读终端、跑 AI 时调 hook、都没有就用第一个选项兜底。
---@param pet Pet @ 被问的人
---@param params table @ `{ prompt, choices, trigger_name }`
---@return string? @ 选中的选项；没得选/被取消返回 nil
function BattleLogic:askToChoice(pet, params)
  local choices = params.choices or {}
  if #choices == 0 then return nil end
  -- 没有具体的人可问（比如全局效果）：按老规矩选第一个，决策固定 = 可复现
  if pet == nil then return choices[1] end

  local req = Request.AskForChoice(self, pet, params)
  local reply = req:getResult(pet)
  if Request.isCancel(reply) then return nil end
  return reply
end


--- 造成一次伤害。内部把伤害链串起来，外部只管调它。
---@param opts table
---@field opts.source Pet? @ 攻击方
---@field opts.target Pet @ 受击方
---@field opts.skill Skill? @ 技能
---@field opts.fixed integer? @ 固定伤害
---@field opts.power integer? @ 直接给威力
---@field opts.category SkillCategory?
---@field opts.element string?
---@field opts.reason string? @ 给日志/客户端看的原因
---@field opts.is_status_damage boolean? @ 异常状态伤害
---@field opts.crit_stage integer?
---@return table @ `{ damage, crit, effectiveness, prevented, element, fainted }`
--- 跑一个流程事件。
---
--- 在流程事件/管理器协程里调用时，**直接插进事件树**做一个子事件（freekill 的用法）；
--- 在协程外调用时（单测、工具函数、未来的管理命令），临时起一个协程把它跑完——
--- 于是 `logic:damage{...}` 这类封装从哪儿调都能用。
---
--- 为什么要分这两种情况：流程事件是协程，`exec()` 会 yield 出去。在协程外 yield
--- 会直接报 "attempt to yield from outside a coroutine"，所以必须自己起一个。
---@param event GameEvent
---@return boolean interrupted, any exec_ret
function BattleLogic:runEvent(event)
  if coroutine.isyieldable() then
    return event:exec()
  end
  return self:runEventStandalone(event)
end

--- 独立跑一个流程事件（以及它插入的子事件），用在"协程外调用"的场合。
--- 前提是当前没有别的事件正在跑（事件栈是空的）；否则会把栈上那些没跑完的
--- 事件也一起继续推进，那就不是"单独跑一件事"了。
function BattleLogic:runEventStandalone(event)
  if self.game_event_stack.p > 0 then
    Log.warning("在事件栈非空时独立跑流程事件：会把栈上没跑完的事件一起推进，注意这是不是在你要的场景")
  end

  if event:prepare() then return true end

  self:pushEvent(event)
  event._co = coroutine.create(function() return event:main() end)
  event.status = "running"

  self:driveEventLoop()

  return event.interrupted, event.exec_ret
end

--- 事件管理器主循环的共用部分（`start` 和"独立跑一件事"都走它）。
--- 两层栈都空就返回——对本局来说是"打完了"，对独立跑来说是"这件事跑完了"。
function BattleLogic:driveEventLoop()
  local iterations = 0

  while true do
    iterations = iterations + 1
    if iterations > BattleLogic.MAX_EVENT_LOOP_ITERATIONS then
      -- 调度器原地打转了。宁可明确报错停下，也不要卡死整个房间的 Lua 进程。
      Log.critical(("事件管理器循环超过 %d 轮，强制停止：\n%s")
        :format(BattleLogic.MAX_EVENT_LOOP_ITERATIONS, tostring(self:dumpEventStack())))
      break
    end

    local ne = self:getCurrentEvent()
    local ce = self:getCurrentCleaner()

    -- **两层栈都空**才算没事可做。只判事件栈会漏掉"清场事件还没跑"的情况，
    -- 那会让清场事件永远赖在栈上（下一件事开始时就排到它前面了，它再也不会被处理）。
    if ne == nil and ce == nil then break end

    -- 清场事件和正常事件谁先跑？比编号，编号大的先——它们都是"后发生的事"。
    local e
    if ce ~= nil and (ne == nil or ce.id >= ne.id) then
      e = ce
    else
      e = ne
    end

    if e == ne and e.killed then
      -- 事件被杀：不 resume 它的协程，直接 close（协程里剩下的代码就此作废），
      -- 然后交给清场事件去收尾。这就是"被打断"的实现。
      e.interrupted = true
      self:clearEvent(e)
      coroutine.close(e._co)
      e.status = "dead"
      e = self:getCurrentCleaner()
      -- 清场事件正常一定会建出来；真没有就顺手退栈，别原地打转
      if e == nil then
        self.game_event_stack:remove(ne)
        goto continue
      end
    end

    -- resumeEvent 的返回值解释（照抄 freekill 的注释）：
    --   * false, nil : 正常结束
    --   * true,  nil : 被中断结束
    --   * false, evt : 没结束，插入了一个新事件 evt
    --   * true,  evt : 中断直到 evt（把 evt 上面的事件全杀）
    local ret, evt = self:resumeEvent(e)

    if evt == nil then
      -- 这件事结束了。**退栈不能在这里做**——交给清场事件（ClearEvent）做，
      -- 因为它必须在"事件已经结束"之后、且不可被打断的情况下跑一遍 clear()。
      e.interrupted = ret
      self:clearEvent(e)
      coroutine.close(e._co)
      e.status = "dead"
    elseif ret == true then
      for i = self.game_event_stack.p, 1, -1 do
        local event = self.game_event_stack.t[i]
        event.killed = true
        if event == evt then break end
      end
    end

    ::continue::
  end
  return true
end

-- ============================ 结算动作 ============================
--
-- 这几个方法是**给规则代码用的门面**（对应 freekill 混进 Room 的
-- `HpEventWrappers`：`room:damage` / `room:recover` / `room:changeHp`）。
-- 它们只做两件事：**把参数算成数据对象**、**把数据对象交给对应的流程事件**。
-- 结算的步骤全在 hp.lua / gameflow.lua 里，这里一行步骤都不写——
-- 这样"伤害链有几步"只有一个地方说了算。

--- 造成一次伤害。对应 freekill 的 `room:damage`。
---@param opts table
---@field opts.source Pet? @ 攻击方
---@field opts.target Pet @ 受击方
---@field opts.skill Skill? @ 技能
---@field opts.fixed integer? @ 固定伤害（不吃克制/暴击/本系）
---@field opts.power integer? @ 直接给威力（没有技能对象时）
---@field opts.category SkillCategory?
---@field opts.element string?
---@field opts.reason string? @ 给日志/客户端看的原因
---@field opts.is_status_damage boolean? @ 异常状态伤害
---@field opts.crit_stage integer?
---@field opts.power_multiplier number? @ 增伤倍率（前置效果算出来的）
---@return table @ `{ damage, crit, stab, effectiveness, element, prevented, fainted, data }`
function BattleLogic:damage(opts)
  local target = opts.target
  local result = { damage = 0, crit = false, stab = false, effectiveness = 1, prevented = false }

  if target == nil or target:isFainted() then
    return result
  end

  local calc = Damage.calculate(self, opts, opts.crit_stage)
  result.crit = calc.crit
  result.stab = calc.stab
  result.effectiveness = calc.effectiveness
  result.element = calc.element

  local data = DamageData:create{
    source = opts.source,
    target = target,
    damage = calc.damage,
    category = opts.category or (opts.skill and opts.skill.category),
    element = calc.element,
    skill = opts.skill,
    reason = opts.reason,
    effectiveness = calc.effectiveness,
    crit = calc.crit,
    stab = calc.stab,
    is_fixed = opts.fixed ~= nil,
    is_status_damage = opts.is_status_damage,
  }

  local before = target.hp
  self:runEvent(GameEvent.Damage:create(data, self.room))

  -- 最终数值要从**数据对象**上读，不能从 calc 上读：
  -- 这一路走下来被 DetermineDamage 上的效果改过了（减半、加成、改成固定值）。
  result.damage = math.max(0, before - target.hp)
  result.prevented = data.prevented or false
  result.fainted = target:isFainted()
  result.data = data
  return result
end

--- 回复体力。对应 freekill 的 `room:recover`。
---@param opts table @ `{ target, num, source, reason }`
---@return integer actual @ 实际回了多少（满血、被防止都是 0）
function BattleLogic:recover(opts)
  local target = opts.target
  if target == nil or target:isFainted() then return 0 end

  local data = RecoverData:create{
    target = target,
    num = opts.num or 0,
    source = opts.source,
    reason = opts.reason,
  }

  local before = target.hp
  self:runEvent(GameEvent.Recover:create(data, self.room))
  return math.max(0, target.hp - before)
end

--- 改变体力。**所有**掉血/回血最终都汇到这里（对应 freekill 的 `room:changeHp`）。
--- 正常规则代码不该直接调它，而是调 `damage` / `recover`——它们是"伤害"和"回复"，
--- 各自有各自的提前量；changeHp 只管"体力变了多少"。
---@param pet Pet
---@param num integer @ 变化量（负数是掉血）
---@param kind string @ 变化的种类："damage" / "recover" / "loseHp"
---@param reason_text? string @ 更具体的原因（技能名/效果名），给日志和客户端看
---@param damage_data? DamageData @ 引起这次变化的那次伤害的数据
---@return boolean ok, HpChangedData data
function BattleLogic:changeHp(pet, num, kind, reason_text, damage_data)
  if pet == nil then return false, nil end

  local data = HpChangedData:create{
    who = pet,
    num = num,
    kind = kind,
    reason = reason_text or kind,
    source = damage_data and damage_data.source or nil,
    damage_event = damage_data,
  }

  self:runEvent(GameEvent.ChangeHp:create(data, self.room))
  return not data.prevented, data
end

function BattleLogic:doStatChange(opts)
  local target = opts.target
  local actual = {}
  if target == nil or target:isFainted() then return actual end

  local data = StatChangeData:create{
    target = target,
    stages = opts.stages or {},
    source = opts.source,
    reason = opts.reason,
  }

  local BeforeStatChange = E("BeforeStatChange")
  if BeforeStatChange then
    if self:trigger(BeforeStatChange, target, data) then return actual end
  end
  if data.prevented then return actual end

  for _, k in ipairs(Pet.STAGE_FIELDS) do
    local delta = data.stages[k]
    if delta and delta ~= 0 then
      local applied = target:setStatStage(k, delta)
      if applied ~= 0 then actual[k] = applied end
    end
  end

  if next(actual) ~= nil then
    data.actual = actual
    local StatChanged = E("StatChanged")
    if StatChanged then self:trigger(StatChanged, target, data) end
    self:notify{ type = "StatChanged", target = target.seat, stages = actual, reason = opts.reason }
  end
  return actual
end
--- 让一个效果生效。
--- 技能附带的效果、状态处理器产生的效果都走这里——**入口只有这一个**，
--- 所以"概率判定""附加条件""目标解析"这些横切逻辑只写一遍。
---@param effect Effect
---@param ctx? EffectCtx @ 技能结算上下文（按结果算的效果要读它）
---@return boolean applied
function BattleLogic:applyEffect(effect, ctx)
  return effect:apply(self, ctx)
end
-- ============================ 回合流程的零件 ============================
--
-- 流程事件（gameflow.lua 的 Round / Turn）负责"按什么顺序发生"，
-- 这里提供它要用到的几个零件。别把两者搞混：
--   * 这里（logic）：回合怎么开始/结束、行动能不能做、问玩家要指令；
--   * gameflow.lua：一大回合 → 双方各行动一次 → 每次行动里用一次技能 → 伤害。
--
-- 保留这几个方法还有一个好处：自测时可以直接调它们验证单个环节，
-- 不必每次都从头跑一整局。

--- 一大回合开始：编号 +1、安全阀检查、第一回合还要触发"对局开始"。
---@return boolean ok @ false = 到回合上限了，这一局判平局结束
function BattleLogic:startRound()
  self.round = self.round + 1
  self.turn = 0

  -- 安全阀放在最前面：到顶了就别再跑时机了（不然"结束"和"开始"会一起触发）
  if self.round >= BattleLogic.MAX_ROUNDS then
    self:gameOver(nil, "timeout")
    return false
  end

  local pets = self:getAlivePets()
  local GameStart = E("GameStart")
  if self.round == 1 and GameStart then
    self:trigger(GameStart, pets[1], GameStartData:create{ pets = pets })
  end

  local RoundStart = E("RoundStart")
  if RoundStart then
    self:trigger(RoundStart, pets[1], TurnData:create{ round = self.round, turn = 0 })
  end
  self:notify{ type = "RoundStart", round = self.round }
  return true
end

--- 一大回合结束：跑回合末时机，然后让所有持续效果/异常状态递减回合数。
---
--- 顺序很重要：**先让"回合末"类效果有机会生效**（中毒掉血就是在这个时机里发生的），
--- 再统一递减。反过来的话，刚挂上的效果会当回合就少算一回合。
---@return integer round
function BattleLogic:endRound()
  local RoundEnd = E("RoundEnd")
  if RoundEnd then
    self:trigger(RoundEnd, self:getAlivePets()[1], TurnData:create{
      round = self.round, turn = self.turn,
    })
  end

  self:tickDurations()
  self:notify{ type = "RoundEnd", round = self.round }
  return self.round
end

--- 让场上所有精灵的持续效果与异常状态走一个回合。
function BattleLogic:tickDurations()
  for _, pet in ipairs(self:getAlivePets()) do
    for _, effect in ipairs(pet:getEffects()) do
      effect:tick(self)
    end

    -- 印记逐个走一个回合；到期的摘掉。
    -- "到期"和"被治好"走同一条路（removeMark），所以时机和通知不会两样。
    for _, mark in ipairs(pet:getMarks()) do
      if mark:tick(self) then
        self:removeMark(pet, mark.key, "expired")
      end
    end
  end
end

--- 某只精灵的一次行动开始：这个时机决定"能不能动"。
--- 麻痹/睡眠/冰冻/害怕就是在这里把行动掐掉的（状态处理器，见下）。
---@param pet Pet
---@param move? Skill
---@return boolean prevented
function BattleLogic:beginAction(pet, move)
  self.turn = self.turn + 1
  local data = ActionData:create{ actor = pet, move = move }
  local BeforeAction = E("BeforeAction")
  if BeforeAction then
    self:trigger(BeforeAction, pet, data)
  end
  return data.prevented == true
end

--- 问一只精灵"这回合用什么技能"。
---
--- 这一步是**同时选择**：双方都选好了才排出手顺序（见 `Round:buildTurnOrder`），
--- 所以它不能等到"轮到自己"才问。
---
--- 它现在是一个真正的 `Request`（`Request.AskForAction`）：请求内容、
--- 兜底答复、等待循环、超时/取消的规范化都在 Request 里，这里只负责
--- "把这只精灵的技能整理成选项"和"把答复解析成 (技能, 目标)"。
---
--- **谁答**由这只精灵的处理器决定（`logic:getRequestHandler`），所以同一段代码：
---   * 单机版 → 终端里输入编号（CliHandler）；
---   * 联机版 → 挂起发给 C++/Unity（RpcHandler）；
---   * AI/自测 → 就地算一个（AiHandler / request_hook）；
---   * 都没有 → 用兜底答复（挑一个能打的技能），也就是原来的无头降级。
---@return Skill? move
---@return Pet? target
---@return table? reject @ 拿不到可用技能时带回 `{ name?, reason, text }`，好让流程告诉玩家为什么
function BattleLogic:askForAction(pet)
  if pet == nil or pet:isFainted() then return nil end

  -- 候选是"这只精灵拥有的全部技能"（含第五技能），并且过滤掉现在用不了的，
  -- 同时**记下用不了的原因**一起发出去——客户端要把那些技能摆成灰的，
  -- 还得能说出"PP 不足"还是"被封印"，光给一个可用列表是不够的。
  local usable, unusable = {}, {}
  for _, sk in ipairs(pet:getAllSkills()) do
    local ok, reason, text = sk:checkUsable(pet)
    if ok then
      table.insert(usable, sk)
    else
      table.insert(unusable, { name = sk.name, reason = reason, text = text })
    end
  end

  -- 一个能用的都没有：不用问了，直接把原因交给调用方（它会播一条带原因的 NoAction）
  if #usable == 0 then
    local reason = Skill.Unusable.NO_USABLE_SKILL
    return nil, nil, { reason = reason, text = Skill.UnusableText[reason] }
  end

  -- 兜底答复：超时、掉线、AI 托管时用它。优先挑"能打"的，没有就第一个能用的。
  -- 有这一项，流程就不会因为"没人答"而卡死——这正是 Request 存在的理由之一。
  local auto = table.find(usable, function(s) return s:isDamaging() end) or usable[1]
  local enemy = (pet:getEnemyTeam())[1]

  local req = Request.AskForAction(self, pet, {
    skills = table.map(usable, function(s) return s.name end),
    -- 不可用的技能 + 原因（UI 拿去显示）
    unusable = unusable,
    -- 顺便告诉外面哪个是第五技能，好让 UI 单独摆一个位置。
    -- 这纯粹是**摆位**用的：第五技能和普通技能一样吃 PP、一样走 checkUsable。
    fifth = pet:getFifthSkill() and pet:getFifthSkill().name or nil,
    default_reply = { skill = auto.name, target = enemy and enemy.seat or nil },
  })

  local reply = req:getResult(pet)

  -- 取消（玩家按了 q / 主动取消）：这一回合不出手
  if Request.isCancel(reply) then
    local reason = Skill.Unusable.NO_SKILL_CHOSEN
    return nil, nil, { reason = reason, text = "这回合没有选择技能" }
  end

  reply = type(reply) == "table" and reply or {}
  local move = reply.skill and pet:getSkill(reply.skill) or nil
  local target = nil
  if reply.target ~= nil then
    for _, p in ipairs(pet:getEnemyTeam()) do
      if p.seat == reply.target then target = p end
    end
  end

  -- 玩家点了一个现在用不出来的技能（PP 空了、被封印、条件不满足……）：
  -- **不能闷声不响地跳过这一回合**，要把原因带回去。客户端拿到 NoAction
  -- 事件里的 reason/text 就能提示"这个技能现在用不了"，而不是让玩家觉得点了没反应。
  if move == nil then
    if reply.skill ~= nil then
      local reason = Skill.Unusable.NO_SKILL
      return nil, nil, { name = reply.skill, reason = reason, text = Skill.UnusableText[reason] }
    end
    local reason = Skill.Unusable.NO_SKILL_CHOSEN
    return nil, nil, { reason = reason, text = Skill.UnusableText[reason] }
  end
  local ok, reason, text = move:checkUsable(pet)
  if not ok then
    return nil, nil, { name = move.name, reason = reason, text = text }
  end
  return move, target
end

--- 用技能。它是 `GameEvent.UseSkill` 的门面（对应 freekill 的 `room:useCard`）。
---
--- 返回的是**结算结果**，给调用方（Turn 事件、RPC 层）用；真正的流程在
--- gameflow.lua 里，包括"打空了就不该有附加效果"这类结构性保证。
---@param opts table @ `{ source, target, skill }`
---@return table @ `{ used, missed, prevented, prevent_reason, damage, fainted }`
function BattleLogic:useSkill(opts)
  local source, skill = opts.source, opts.skill
  local result = { used = false, missed = false, prevented = false, damage = 0 }

  if source == nil or skill == nil then return result end

  local data = SkillUseData:create{
    source = source,
    target = opts.target,
    skill = skill,
  }
  self:runEvent(GameEvent.UseSkill:create(data, self.room))

  result.used = not data.prevented
  result.missed = data.missed or false
  result.prevented = data.prevented or false
  -- 被拦住时把原因带回去（no_pp / sealed / forbidden / condition，见 Skill.Unusable）
  result.prevent_reason = data.prevent_reason
  result.prevent_text = data.prevent_text
  result.damage = data.damage_result and data.damage_result.damage or 0
  result.fainted = data.target ~= nil and data.target:isFainted()
  result.data = data

  -- PP 在这里扣：技能"用出去了"才扣，被无效化/打空也扣（和赛尔号一致）
  if result.used then
    source:usePP(skill.name, 1)
  end
  return result
end

-- ============================ 倒下 / 胜负 ============================

--- 一只精灵倒下了：跑倒下时机、清掉身上的东西，然后看这一局是不是结束了。
--- 由 `GameEvent.ChangeHp` 在"体力掉到 0 以下"时调用——所以**任何**来源的掉血
--- 都只有这一条倒下路径，不会出现某种伤害忘了判倒下。
---@param pet Pet
---@param source? Pet
function BattleLogic:onFaint(pet, source)
  if not pet:isFainted() then return false end

  local data = FaintData:create{ pet = pet, source = source }
  -- 倒下就清空身上的一切：持续效果、异常状态、能力等级都不该带进坟里
  -- （不然换上来复活/被复活的精灵会带着上一轮的状态，那是规则漏洞）
  pet:clearEffects()
  pet.marks = {}
  pet:resetStages()

  local BeforePetFaint = E("BeforePetFaint")
  if BeforePetFaint then self:trigger(BeforePetFaint, pet, data) end

  local PetFainted = E("PetFainted")
  if PetFainted then self:trigger(PetFainted, pet, data) end

  self:notify{ type = "PetFainted", pet = pet.seat, name = pet.name }

  self:checkGameOver()
  return true
end

--- 某一方全倒下了就结束
---@return integer? winner
function BattleLogic:checkGameOver()
  local alive = self:getAlivePets()
  if #alive == 0 then
    self:gameOver(nil, "all_fainted")
    return nil
  end

  -- 按阵营分组：只要还剩一个阵营活着就继续
  local sides = {}
  for _, p in ipairs(alive) do
    if p.side ~= nil then sides[p.side] = true end
  end
  local side_count = 0
  local last_side
  for s in pairs(sides) do
    side_count = side_count + 1
    last_side = s
  end

  if side_count <= 1 and last_side ~= nil then
    self:gameOver(last_side, "all_fainted")
    return last_side
  end
  return nil
end

---@param winner? integer
---@param reason? string
function BattleLogic:gameOver(winner, reason)
  if self.game_over then return end
  self.game_over = true
  self.winner = winner

  -- 这一局结束时如果还挂着一次询问，通知答复者**把它撤掉**
  -- （对应 freekill 的 `CancelRequest` 广播）：真人客户端得把询问框关掉，
  -- 否则一个永远等不到答复的框会一直挡在界面上。
  local pending = self.current_request
  if pending ~= nil then
    for _, pet in ipairs(pending.players) do
      local handler = self:getRequestHandler(pet)
      if type(handler.cancel) == "function" then handler:cancel(pending) end
    end
  end

  local data = GameOverData:create{ winner = winner, reason = reason }
  local GameOver = E("GameOver")
  if GameOver then self:trigger(GameOver, nil, data) end

  -- 架构文档 §5.4：一局结束要通知 C++ 去结算战绩、落盘。
  -- Lua 不碰数据库（§7 的边界铁律），只把结果交回去。
  self:notify{ type = "GameOver", winner = winner, reason = reason }
  return data
end

-- ============================ 通知 C++ ============================

--- 把一条事件推给 C++，由它去推给客户端。
--- 对应架构文档 §5.4 的 `notifyPlayers`。Lua 自己没有 socket，
--- 所以这里只负责"攒/转发"，真正的发送是 C++ 的事。
---@param evt table @ 一条可序列化的事件
function BattleLogic:notify(evt)
  evt.round = self.round
  evt.turn = self.turn
  if self.room and self.room.notifyPlayers then
    self.room:notifyPlayers(evt)
  end
  -- 没有房间（无头自测）时不报错：通知是"尽力而为"的旁路，
  -- 绝不能因为它失败而影响战斗结算
  return evt
end

return BattleLogic
