-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 流程事件：战斗 / 大回合 / 一次出手 ============================
--
-- 赛尔号一局对战的外层时间轴（时机类的定义见 core/events/gameflow.lua）：
--
--   GameEvent.Battle    BattleStart 时机 → 循环 Round 直到分出胜负 → BattleEnd 时机
--     GameEvent.Round   round+1 → TurnStart / TurnReady 时机 → 双方各选一个行动
--                       → 按"先制度 → 速度 → 座位"排序 → DecidePriority 时机
--                       → 逐个 GameEvent.Turn → TurnEnd / AfterTurnEnd 时机 → 胜负判定
--       GameEvent.Turn  BeforeAttack / AttackStart 时机 → GameEvent.UseSkill（见 useskill.lua）
--                       → AttackReady / Attack / AfterAttack / AttackEnd 时机
--
-- 事件树（每个流程事件都有 parent，"这次伤害是哪次出手引起的"就是顺着它问）：
--
--   Battle ─ Round ─┬─ Turn ─ UseSkill ─ Damage ─ ChangeHp
--                   └─ Turn ─ UseSkill ─ Damage ─ ChangeHp
--
-- 和 freekill（三国杀）的"轮 / 回合 / 阶段"不同：赛尔号**没有**判定区、手牌、
-- 出牌 / 弃牌阶段，所以这里只有"战斗 / 大回合 / 一次出手"三层，没有 Phase 事件、
-- 没有 DrawInitial（不发牌）。一个大回合 = 双方各行动一次。
--
-- 流程事件只管**怎么一步步走完**；"这一刻谁想插一脚"一律通过
-- `logic:trigger(时机类, target, data)` 交给时机系统（触发器表在 GameLogic.skill_table）。
-- 所以本文件里看不到任何具体技能或效果，只有触发点。
--
-- 怎么跑起来：`GameEvent.Battle:create(logic, { logic = logic }):exec()`。
-- 子事件用下面的 `runEvent()`：有事件泵（`logic:pushEvent` / `logic:resumeEvent`）时走
-- `exec()`（能停下来等 Request），没有泵时同步跑 `main()`。详见 runEvent 的注释。
--
-- 还没接的东西（都留了 TODO，见各自调用点）：选技能 / 选目标的 Request、换精灵、
-- 逃跑、异常状态的回合递减（那个挂着 AfterTurnEnd 的触发器就行）。

local EV = require "core.events"

-- GameEvent 基类（流程事件）。正常由 server/events/init.lua 先挂成全局；
-- 单独 require 本文件（测试脚本）时补一次，和 core/rng.lua 补 `class` 是一个意思。
GameEvent = rawget(_G, "GameEvent") or require "server.gameevent"

--- 战斗 / 回合流程的时机：BattleStart / TurnStart / TurnReady / DecidePriority /
--- TurnEnd / AfterTurnEnd / BattleEnd
local G = EV.gameflow

--- 攻击 / 伤害流程的时机：BeforeAttack / AttackStart / … / AttackEnd
local A = EV.attack

-- ---------------------------- 小工具 ----------------------------
--
-- gameflow / useskill / hp 三个流程文件**各自带一份**同样的小工具（认数据、认战局、
-- 跑子事件）。这么做是有意的：三个文件要能被单独 require、单独测（见文件末尾的返回表），
-- 而 hp 是最低层——为这几个 helper 抽一个公共模块，要么让 hp 反过来 require gameflow
-- （层次颠倒），要么再插一层加载顺序。三份内容保持一致，改的时候一起改。

--- 这个值像不像"战局"（GameLogic / BattleLogic）：能 `trigger(时机, ...)` 就算。
--- 给下面"从几种 create 形状里认出哪个参数是战局"用。
---@param v any
---@return boolean
local function isLogic(v)
  return type(v) == "table" and type(v.trigger) == "function"
end

--- 取流程事件的数据表（顺便认出战局）。
--
-- 基类（server/gameevent.lua）的参数顺序正在来回改，所以这里对**四种形状**都兼容：
--   * `create(logic, data)` —— 当前基类 `initialize(event, room, ...)` 的写法：
--     `ev.room = logic`、`ev.logic = logic`、`ev.data = data`
--   * `create(data, logic)` —— README §5.7 写的写法（data 在前）：当前基类下
--     `ev.data` 会变成那个 logic（这里靠 isLogic 认出来丢掉），数据落在 `ev.room` 上
--   * 上面两种在**老 freekill 基类**（`initialize(event, ...)`）下都会变成
--     `ev.data = { a, b }`：这里拆开，并认出哪个是战局
--   * `create(data)` —— 数据被当成"战局容器"，落在 `ev.room` 上
-- 关键在：本目录的流程数据**都自带 `logic` 字段**，所以怎么传都能把战局找回来。
---@param ev GameEvent
---@return table? data @ 流程事件的数据
---@return GameLogic? logic_arg @ 顺带认出来的战局（没有就是 nil）
local function eventData(ev)
  local data = ev.data

  -- 成对形状 `{ a, b }`：谁是战局看谁像战局，另一个就是数据
  if type(data) == "table" and not isLogic(data) and getmetatable(data) == nil
    and rawget(data, "logic") == nil and rawget(data, 1) ~= nil then
    local a, b = data[1], data[2]
    if isLogic(a) then return b, a end
    return a, b
  end

  -- 正常形状：ev.data 就是数据（"空表"和"是战局"的都不算，见下面两条兜底）
  if type(data) == "table" and not isLogic(data) and next(data) ~= nil then
    return data, nil
  end

  -- 数据被当成"战局容器"塞进 ev.room 了（create 只传一个参数的那种写法）
  if type(ev.room) == "table" and not isLogic(ev.room) then return ev.room, nil end
  return data, nil
end

--- 从流程事件上取战局（GameLogic / BattleLogic），找不到就明确报错。
--
-- 依次找：成对表里那个像战局的 → ev.logic（基类会填）→ data.logic → ev.room 本身
-- → ev.room.logic → 全局 RoomInstance.logic（freekill 时代的老兜底）。
---@param ev GameEvent
---@return GameLogic logic @ 战局
---@return table? data @ 顺便把数据取出来（省一次 eventData）
local function eventLogic(ev)
  local data, logic_arg = eventData(ev)
  local logic
  if isLogic(logic_arg) then
    logic = logic_arg
  elseif isLogic(ev.logic) then
    logic = ev.logic
  elseif type(data) == "table" and isLogic(data.logic) then
    logic = data.logic
  elseif isLogic(ev.room) then
    logic = ev.room
  elseif type(ev.room) == "table" and isLogic(ev.room.logic) then
    logic = ev.room.logic
  else
    local room = rawget(_G, "RoomInstance")
    if room ~= nil and isLogic(room.logic) then logic = room.logic end
  end

  if logic == nil then
    error("流程事件找不到战局：create 的参数 / ev.logic / data.logic / ev.room 里都没有能 trigger 的对象", 3)
  end
  return logic, data
end

--- 打一条事件通知。有 `logic:notify`（GameLogic 的协议出口）就走它，没有就退到日志。
---@param logic GameLogic
---@param evt table @ 形如 `{ type = "HpChanged", ... }`
local function notify(logic, evt)
  if type(logic.notify) == "function" then
    return logic:notify(evt)
  end
  Log.info(("🎮 %s"):format(tostring(evt.type)))
end

--- 这只精灵倒下了没。战局自己的实现是权威（GameLogic:isFainted），
--- 没有（测试桩 / 别的战局实现）就按 `fainted` 标记和血量自己判。
---@param logic GameLogic
---@param pet Pet
---@return boolean
local function isFainted(logic, pet)
  if type(logic.isFainted) == "function" then return logic:isFainted(pet) end
  return pet.fainted == true or (pet.hp or 0) <= 0
end

--- 还站得住的精灵。出手排序和胜负判定都用它。
---@param logic GameLogic
---@return Pet[]
local function aliveActors(logic)
  if type(logic.getActors) == "function" then return logic:getActors() end
  local ret = {}
  for _, pet in ipairs(logic.pets or {}) do
    if not isFainted(logic, pet) then table.insert(ret, pet) end
  end
  return ret
end

--- 给 source 挑一个目标：对面第一个还活着的。
--
-- TODO: 换精灵接上之后这里要改——赛尔号的目标指的是"对面的位置"，对面那只倒了得看
--       换上来的是谁（现在是就近挑一只活着的）。
---@param logic GameLogic
---@param source Pet
---@return Pet? target @ 对面全灭了就是 nil
local function pickTarget(logic, source)
  if type(logic.pickTarget) == "function" then return logic:pickTarget(source) end
  local enemy
  if source.side == 1 then
    enemy = logic.sides and logic.sides[2]
  else
    enemy = logic.sides and logic.sides[1]
  end
  for _, pet in ipairs(enemy or {}) do
    if not isFainted(logic, pet) then return pet end
  end
  return nil
end

--- 剩余 PP。战局把 PP 记在 `logic.pp[pet][技能名]` 上并给了 getPP / usePP，
--- 有就用它的（PP 这本账只该有一个地方记）；没有就自己读那张表。
---@param logic GameLogic
---@param pet Pet
---@param skill Skill|string
---@return integer
local function getPP(logic, pet, skill)
  if type(logic.getPP) == "function" then return logic:getPP(pet, skill) end
  local name = type(skill) == "string" and skill or skill.name
  return (logic.pp and logic.pp[pet] and logic.pp[pet][name]) or 0
end

--- 结束战斗。GameLogic:finishGame 是它的正式实现（还会记 win_reason）；
--- 没有这个方法就直接写状态字段。
---@param logic GameLogic
---@param winner integer? @ 1 / 2；平局是 nil
---@param reason string @ all_fainted / draw / max_rounds
local function finish(logic, winner, reason)
  if type(logic.finishGame) == "function" then return logic:finishGame(winner, reason) end
  logic.game_over = true
  logic.winner = winner
  logic.win_reason = reason
end

--- 胜负判定：一边全灭就结束；两边同时全灭算平局（winner 为 nil）。
---@param logic GameLogic
---@return boolean game_over
local function checkGameOver(logic)
  local alive = {}
  for _, pet in ipairs(logic.pets or {}) do
    -- 没有分边的精灵（数据不完整）按 0 记，免得 `alive[nil] = true` 直接报错
    if not isFainted(logic, pet) then alive[pet.side or 0] = true end
  end
  if not alive[1] and not alive[2] then
    finish(logic, nil, "draw")
  elseif not alive[2] then
    finish(logic, 1, "all_fainted")
  elseif not alive[1] then
    finish(logic, 2, "all_fainted")
  end
  return logic.game_over == true
end

--- 默认决策：挑第一个"能打（伤害技）且有 PP"的技能，目标挑对面第一个活着的。
--
-- TODO: 接 Request（AskForAction，真的让玩家 / AI 选）之后换成问出来的行动。
--       GameLogic:pickAction 里是同一份规则的旧实现（直接循环时代），
--       流程事件接上之后以这里为准。
---@param logic GameLogic
---@param source Pet
---@return Skill? skill @ 没得打就是 nil
---@return Pet? target
local function decideAction(logic, source)
  for _, skill in ipairs(source:getSkills()) do
    if skill:isDamaging() and getPP(logic, source, skill) > 0 then
      return skill, pickTarget(logic, source)
    end
  end
  -- 没有可用的伤害技（PP 空了 / 只带属性技）：这一手先空过。
  -- TODO: 赛尔号这里是"用挣扎"或者"换精灵"，接上之前只记一条 ActionSkipped。
  return nil, nil
end

--- 出手顺序的比较函数：技能先制度大者先 → 速度高者先 → 座位小者先。
--
-- 座位那一条是为了**确定性**：同样的输入永远得到同样的顺序（见 core/rng.lua 开头）。
-- TODO: 同速时实机是随机一边先手（待核对）。要随机的话得走 logic.rng，不能碰 math.random。
---@param a table @ `{ source, skill, target }`
---@param b table
---@return boolean
local function compareAction(a, b)
  local pa = a.skill and a.skill:getPriority() or -math.huge
  local pb = b.skill and b.skill:getPriority() or -math.huge
  if pa ~= pb then return pa > pb end

  local sa = a.source and a.source:getStat("speed") or 0
  local sb = b.source and b.source:getStat("speed") or 0
  if sa ~= sb then return sa > sb end

  return ((a.source and a.source.seat) or 0) < ((b.source and b.source.seat) or 0)
end

--- 按时机给定的出手顺序重排行动表。
--
-- DecidePriority 时机的作用就是让效果改顺序（改先制度、改速度、这回合不许出手都挂它），
-- 所以触发完之后要按 order 真的重排一遍。order 里没提到的行动放到最后，一个都不丢。
---@param actions table[] @ `{ source, skill, target }` 数组
---@param order GameObject[]? @ 行动者数组（DecidePriorityData.order）
---@return table[] actions @ 排好序的数组（没给 order 就原样返回）
local function applyOrder(actions, order)
  if type(order) ~= "table" or #order == 0 then return actions end

  local by_source, used = {}, {}
  for _, action in ipairs(actions) do by_source[action.source] = action end

  local ret = {}
  for _, actor in ipairs(order) do
    local action = by_source[actor]
    if action ~= nil and not used[action] then
      table.insert(ret, action)
      used[action] = true
    end
  end
  for _, action in ipairs(actions) do
    if not used[action] then table.insert(ret, action) end
  end
  return ret
end

--- 跑一个子流程事件（一次出手、一次用技能、一次伤害……）。
--
-- 有事件泵（`logic:pushEvent` / `logic:resumeEvent`，见 server/gameevent.lua 的
-- `GameEvent:exec` 和它 yield 出去的那个 `"__newEvent"`）时走 `exec()`：事件能中途停下来
-- 等（等玩家下指令、等动画播完）。泵还没接上时直接同步跑 `prepare()` / `main()`——
-- GameLogic 的直接循环和测试脚本走的就是这条路径（没有泵的 `exec()` 会 yield 到协程
-- 外面，直接报 "attempt to yield from outside a coroutine"）。
---@param tp GameEvent @ 事件类（GameEvent.Round / GameEvent.Turn / …）
---@param data table @ 事件数据
---@param logic GameLogic? @ 战局（有泵时 exec() 用它；同步路径下它就是 create 的第一个参数）
---@return GameEvent ev @ 跑完（或建好）的事件实例
local function runEvent(tp, data, logic)
  -- 参数顺序按当前基类（initialize(event, room, ...)）：战局在前、数据在后。
  -- 反过来写（README §5.7 的 data 在前）也认，见上面的 eventData。
  local ev = tp:create(logic, data)
  if ev.exec ~= nil and logic ~= nil and type(logic.getCurrentEvent) == "function"
    and type(logic.pushEvent) == "function" and type(logic.resumeEvent) == "function" then
    ev:exec()
    return ev
  end

  -- prepare() 返回真值 = 这个事件不用跑（freekill 语义）
  if type(ev.prepare) == "function" and ev:prepare() then return ev end
  ev:main()
  -- clear / exit / extra_exit 归事件泵和清场事件管，同步路径不需要
  return ev
end

-- ============================ 一局战斗 ============================

--- 一局战斗的数据。
---@class BattleFlowData
---@field public logic GameLogic @ 战局（主入口：一切都是从它身上拿的）
---@field public max_rounds integer? @ 回合上限（不写就用战局自己的；两个都没有就是无限）
---@field public winner integer? @ 结束后由 main 填上：1 / 2，平局为 nil
---@field public reason string? @ 结束原因：all_fainted / draw / max_rounds

--- 一局战斗（根流程事件）。赛尔号没有"开局摸牌"这类准备动作，所以 BattleStart 之后
--- 直接就是回合循环。
---@class GameEvent.Battle : GameEvent
---@field public data BattleFlowData
local Battle = GameEvent:subclass("GameEvent.Battle")

function Battle:__tostring()
  return ("<Battle #%d>"):format(self.id or -1)
end

function Battle:main()
  local logic, data = eventLogic(self)
  data = data or {}

  -- 1. 战斗开始
  logic:trigger(G.BattleStart, nil, BattleStartData:new{})

  -- 2. 回合循环：分出胜负为止（或者撞上回合上限）
  local max_rounds = data.max_rounds or logic.max_rounds or math.huge
  while not logic.game_over do
    if (logic.round or 0) >= max_rounds then
      finish(logic, nil, "max_rounds")
      break
    end

    runEvent(GameEvent.Round, { logic = logic }, logic)

    -- Round 自己会判胜负；这里再兜一次，免得 Round 被打断 / 抛异常时循环转不出去
    if not logic.game_over then checkGameOver(logic) end
  end

  -- 3. 战斗结束
  logic:trigger(G.BattleEnd, nil, BattleEndData:new{
    winner = logic.winner,
    reason = logic.win_reason,
  })
  data.winner = logic.winner
  data.reason = logic.win_reason
  return logic.winner
end

-- ============================ 一个大回合 ============================

--- 一个大回合的数据。
---@class RoundFlowData
---@field public logic GameLogic @ 战局
---@field public turn_number integer? @ 第几个大回合（main 里 +1 之后填上）

--- 一个大回合：双方各选一个行动 → 定先后手 → 逐个出手 → 收尾。
---@class GameEvent.Round : GameEvent
---@field public data RoundFlowData
local Round = GameEvent:subclass("GameEvent.Round")

function Round:__tostring()
  local data = eventData(self) or {}
  return ("<Round %d #%d>"):format(data.turn_number or 0, self.id or -1)
end

function Round:main()
  local logic, data = eventLogic(self)
  data = data or {}

  -- 大回合号 +1：Battle 只管循环，"现在是第几回合"在回合开始时定
  logic.round = (logic.round or 0) + 1
  data.turn_number = logic.round
  local td = TurnData:new{ turn_number = logic.round }

  -- 回合开始 / 回合就绪
  -- TODO: core/events 里 TurnReady 的语义是"双方都选完了，即将进入出手阶段"，
  --       等选技能接上 Request（下面那步会停下来等）之后要把它挪到选完行动之后。
  logic:trigger(G.TurnStart, nil, td)
  logic:trigger(G.TurnReady, nil, td)

  -- 双方各选一个行动（默认决策；一个能打的技能都没有也会占一个位置，记 ActionSkipped）
  local actions = {}
  for _, actor in ipairs(aliveActors(logic)) do
    local skill, target = decideAction(logic, actor)
    table.insert(actions, { source = actor, skill = skill, target = target })
  end

  -- 出手顺序：技能先制度 → 速度 → 座位
  table.sort(actions, compareAction)

  local order = {}
  for _, action in ipairs(actions) do table.insert(order, action.source) end

  local dp = DecidePriorityData:new{ actions = actions, order = order }
  logic:trigger(G.DecidePriority, nil, dp)
  -- 时机里可以对 actions / order 动手（改先制度、改速度的效果都挂在这里），
  -- 以时机之后的顺序为准
  local queue = applyOrder(dp.actions or actions, dp.order)

  -- 逐个出手。每一次都要重判胜负和"还站不站得住"：先手那方可能已经把对面打倒了
  for _, action in ipairs(queue) do
    if logic.game_over then break end
    runEvent(GameEvent.Turn, { logic = logic, action = action, turn_number = logic.round }, logic)
    checkGameOver(logic)
  end

  -- 回合收尾（持续效果、异常状态的回合递减挂在 AfterTurnEnd 的触发器上）
  logic:trigger(G.TurnEnd, nil, td)
  logic:trigger(G.AfterTurnEnd, nil, td)
  checkGameOver(logic)
  return logic.game_over
end

-- ============================ 一次出手 ============================

--- 一次出手的数据。
---@class TurnFlowData
---@field public logic GameLogic @ 战局
---@field public action table @ 本回合选定的行动：`{ source, skill, target }`
---@field public turn_number integer? @ 第几个大回合
---@field public attack AttackData? @ 这次出手的攻击数据（main 里填上，转发给 UseSkill）

--- 一只精灵的一次出手：攻击前后的时机在这里，中间那次"用技能"是 UseSkill 子事件。
--
-- 注意两层时间轴别混：TurnStart / TurnEnd 是**大回合**的时机（在 Round 里触发），
-- 一次出手自己只有 attack.lua 里那 11 个时机。
---@class GameEvent.Turn : GameEvent
---@field public data TurnFlowData
local Turn = GameEvent:subclass("GameEvent.Turn")

function Turn:__tostring()
  local data = eventData(self) or {}
  local action = data.action or {}
  return ("<Turn %s by %s #%d>"):format(
    tostring(action.skill and action.skill.name),
    tostring(action.source and action.source.name),
    self.id or -1)
end

function Turn:main()
  local logic, data = eventLogic(self)
  data = data or {}
  local action = data.action or {}
  local source, skill, target = action.source, action.skill, action.target

  if source == nil or skill == nil then
    -- 没选到技能（PP 空了之类的），这一手空过
    notify(logic, { type = "ActionSkipped", source = source })
    return false
  end

  -- 出手前先看还站不站得住：被前面的行动打倒的这一手就没有了
  if isFainted(logic, source) then
    notify(logic, { type = "ActionSkipped", source = source, reason = "fainted" })
    return false
  end

  -- 目标没了（被前面的行动打倒）：先就近改打对面第一个活着的。
  -- TODO: 赛尔号这里其实是"对手换精灵上场"（目标指对面的位置），换精灵接上后要按位置重取。
  if target == nil or isFainted(logic, target) then
    target = pickTarget(logic, source)
    if target == nil then
      notify(logic, { type = "ActionSkipped", source = source, reason = "no_target" })
      return false
    end
  end

  local attack = AttackData:new{
    source = source, target = target, skill = skill,
    hits = 1, damage = 0, missed = false, crit = false,
    logic = logic,
  }
  data.attack = attack

  logic:trigger(A.BeforeAttack, target, attack)
  if attack.prevented then
    -- 出手被防止（封印 / 完全抵挡）：后面那串时机一个都不再问
    notify(logic, { type = "AttackPrevented", source = source, target = target, skill = skill })
    return false
  end
  logic:trigger(A.AttackStart, target, attack)

  -- 用技能：命中判定 → 连击 → 每一击走伤害流程 → 扣 PP → 附加效果（见 useskill.lua）。
  -- 这次技能一共打掉多少血记在 attack.damage 上（各击累加）。
  runEvent(GameEvent.UseSkill, attack, logic)

  -- 攻击收尾的时机。打空（attack.missed）时这几个时机**照样**触发——
  -- 挂在它们上面的效果要自己看 attack.missed 决定要不要生效。
  -- 注意扣血已经在 UseSkill 里发生了（赛尔号是"用技能就当场结算"），
  -- 所以这里的 Attack 时机是给"命中之后"的反伤 / 附加效果用的（见 core/events/attack.lua）。
  -- TODO: 打空时到底该不该走这三个时机（还是只走 AttackEnd）待与实机核对。
  logic:trigger(A.AttackReady, target, attack)
  logic:trigger(A.Attack, target, attack)
  logic:trigger(A.AfterAttack, target, attack)
  logic:trigger(A.AttackEnd, target, attack)
  return true
end

-- ---------------------------- 挂到 GameEvent 上 ----------------------------

-- 全局赋值风格和 core/ 一致：`GameEvent.X` 就是流程事件的入口。
-- 子事件之间在运行期按全局名字互相找（UseSkill 里要找 GameEvent.Damage 那样），
-- 所以每个文件 require 进来时就顺手挂好；init.lua 作为加载入口再收口一遍（幂等）。
GameEvent.Battle = Battle
GameEvent.Round = Round
GameEvent.Turn = Turn

return {
  Battle = Battle,
  Round = Round,
  Turn = Turn,
}
