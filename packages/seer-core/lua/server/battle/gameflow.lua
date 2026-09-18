-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 回合相关的流程事件 ============================
--
-- 本文件是 freekill-core `ltk/server/events/gameflow.lua` 的移植版。
-- 那边定义的是"一局是怎么走完的"：`Round`（一轮）→ `Turn`（一个角色的回合）
-- → `Phase`（回合里的阶段：判定/摸牌/出牌/弃牌）。
--
-- ---------------------------- 赛尔号的"回合"长什么样 ----------------------------
--
-- 三国杀的"回合"是**一个角色**的行动，里面再分好几个固定阶段（摸牌、出牌、弃牌）。
-- 赛尔号不是这样：一个"回合"= 双方各出一只精灵、各用一次技能，两边**同时**决定，
-- 然后按"先制度 → 速度"排个序依次结算。所以对应关系是：
--
--   freekill Round  →  本项目 Round    一大回合：双方各行动一次
--   freekill Turn   →  本项目 Turn     一只精灵的一次行动
--   freekill Phase  →  （没有对应物）  赛尔号的行动里没有"固定阶段"这套结构
--
-- 所以这里**没有**移植 Phase。硬套一个 Phase 只会发明出游戏里不存在的概念；
-- 行动内部要做的事（能不能动、用什么技能、结算、收尾）直接写在 Turn 的三个阶段里。
--
-- 出手顺序（先制度 + 速度）放在 `Round:buildTurnOrder` 里，这是赛尔号规则的一部分：
-- **双方先各自选好技能**（所以要问两次，而不是轮到自己才问），
-- 然后先制度高的先动，同先制度比速度，速度也一样就比座位号（保证确定性）。
--
-- ---------------------------- 和 freekill 的差异 ----------------------------
--
--   * 没有 Phase（见上）。
--   * `BattleLogic:run()`（一局的主循环）写在本文件而不是独立的事件类里。
--     freekill 把它放在"游戏模式"类里（`GameMode:run`）；本项目还没有模式概念，
--     就放在离回合流程最近的这里。等真有多模式了，把它挪进模式类即可。
--   * 一回合结束的条件由 `logic.game_over` 判断（freekill 用的是 `room.game_finished`）。

-- ============================ 一次技能使用 ============================

---@class GameEvent.UseSkill: GameEvent
---@field public data SkillUseData
local UseSkill = GameEvent:subclass("GameEvent.UseSkill")

function UseSkill:__tostring()
  local data = self.data
  return ("<UseSkill %s by %s #%d>"):format(
    data.skill and data.skill.name or "?", tostring(data.source), self.id)
end

--- 用一次技能：这是"一只精灵做了什么"的完整流程。
--- 对照 freekill 的 `GameEvent.UseCard`（结构一样：先用时机问一遍能不能用、
--- 再判定、再结算效果）。伤害是**嵌套**进来的子事件，不是函数调用。
function UseSkill:main()
  local data = self.data
  local logic = self.room.logic
  local source, target, skill = data.source, data.target, data.skill

  if source == nil or skill == nil then return false end
  if source:isFainted() then return false end

  -- 目标默认按技能的 target 规则挑
  if target == nil and skill:getTarget() == "enemy" then
    target = (source:getEnemyTeam())[1]
    data.target = target
  end

  -- 1) 能不能用。两层：
  --    先做**硬性检查**（PP 够不够、被没被封印、技能自己的适用条件满足没有）——
  --    这些不满足就是"用不出来"，连时机都不该触发；
  --    再让 BeforeUseSkill 时机有机会插一脚（被无效化之类）。
  --
  --    原因（no_pp / sealed / forbidden / condition）要一路带到播报里：
  --    客户端得能显示"为什么这个技能是灰的"，而不是只知道自己没点动。
  local usable, unusable_reason, unusable_text = skill:checkUsable(source)
  if not usable then
    data.prevented = true
    data.prevent_reason = unusable_reason
    data.prevent_text = unusable_text
    logic:notify{
      type = "SkillUnusable", source = source.seat, skill = skill.name,
      reason = unusable_reason, text = unusable_text,
    }
    logic:breakEvent(false)
  end

  logic:trigger(SeerTiming.BeforeUseSkill, source, data)
  if data.prevented then
    logic:breakEvent(false)
  end

  -- 3) 先播报"谁用了什么"，**再**结算。
  --
  --    顺序很重要：客户端要先把技能名/动画放出来，伤害数字才跟着跳。
  --    如果等结算完再报，玩家会先看到掉血、后看到"使用了XX"——顺序反了。
  --    （连击次数也在这里报：它是"这一击打几下"，属于技能本身的形状。）
  local hits = 1
  if skill:isDamaging() and target then
    hits = skill:getHits(source, target, logic)
  end
  logic:notify{
    type = "UseSkill",
    source = source.seat,
    name = source.name,
    skill = skill.name,
    target = target and target.seat or nil,
    hits = hits,
    fifth = source:isFifthSkill(skill.name),
  }

  -- 2) 命中判定。属性技也要判命中（雷祭的命中只有 50%）。
  --
  --    注意播报（上面那段）在判定**之前**：打空了也得让客户端先看到
  --    "XX 使用了 YY"，然后才是"打空了"——不然一次 miss 在界面上就是凭空消失。
  local hit_data = HitCheckData:create{
    source = source,
    target = target,
    skill = skill,
    accuracy = skill:getAccuracy(source, target),
  }

  logic:trigger(SeerTiming.BeforeHitCheck, source, hit_data)

  local hit
  if hit_data.blocked then
    hit = false
  elseif hit_data.sure_hit or hit_data.accuracy == nil then
    hit = true
  else
    -- 命中判定必须用本局的确定性随机数发生器，否则回放对不上
    hit = logic.rng:chance(hit_data.accuracy)
  end
  hit_data.hit = hit

  logic:trigger(SeerTiming.AfterHitCheck, source, hit_data)

  if not hit then
    data.missed = true
    logic:notify{ type = "SkillMissed", source = source.seat, skill = skill.name }
    logic:trigger(SeerTiming.SkillMissed, source, hit_data)
    -- 打空了就直接结束：**附加效果一个都不该生效**。
    -- 这个"结构性保证"很重要——不然每个效果都要自己记得判断命中。
    return false
  end

  local ctx = {
    source = source,
    target = target,
    skill = skill,
    damage = 0,
    hits = 0,
    crit = false,
    missed = false,
    extra = {},
  }
  data.ctx = ctx

  -- 4) **前置效果**：必须在伤害算出来之前跑的那批（增伤就是它）。
  --    它们往 ctx 里写东西（`ctx.power_multiplier`），伤害公式再读。
  --    注意 ctx 必须在**这一步之前**就建好——前置效果的 condition 也要读它
  --    （"自身 HP 小于一半时增伤"就是读 ctx.source 的）。
  local effects = skill:createEffects(source, target)
  for _, effect in ipairs(effects) do
    if effect.phase == "before" then
      logic:applyEffect(effect, ctx)
    end
  end

  -- 5) 伤害：插一个子事件，走完整的伤害流程，走完再回来。
  --
  --    **连击**是"打 N 次、每次都独立结算"，不是"伤害乘 N"——
  --    因为减伤、护盾、免疫、以及"每次命中都判定暴击"都是逐次生效的。
  --
  --    这一节同时把结果的上下文（打了多少、几下、有没有暴击）攒进 ctx，
  --    后面那串效果才能写出"吸取造成伤害的一半"这种**按结果算**的效果。
  if skill:isDamaging() and target then
    ctx.hits = hits

    for _ = 1, hits do
      local r = logic:damage{
        source = source,
        target = target,
        skill = skill,
        category = skill.category,
        element = skill:getElement(source),
        reason = skill.name,
        power_multiplier = ctx.power_multiplier,
      }
      ctx.damage = ctx.damage + r.damage
      ctx.crit = ctx.crit or r.crit
      -- 目标中途倒下就没必要继续打了（剩下的几段作废）
      if target:isFainted() then break end
    end

    data.damage_result = {
      damage = ctx.damage,
      hits = hits,
      crit = ctx.crit,
    }
  end

  -- 6) **后置效果**（默认的那批）：挂印记、改能力、吸取、按结果算的东西……
  --    顺序就是 spec 里写的顺序——"先弱化再打"和"先打再弱化"是不同的技能。
  for _, effect in ipairs(effects) do
    if effect.phase ~= "before" then
      logic:applyEffect(effect, ctx)
    end
  end

  logic:trigger(SeerTiming.AfterUseSkill, source, data)
  return true
end

function UseSkill:desc()
  return {
    type = "#UseSkill",
    event = self.class.name,
    source = self.data.source and self.data.source.seat or nil,
    target = self.data.target and self.data.target.seat or nil,
    skill = self.data.skill and self.data.skill.name or nil,
  }
end

-- ============================ 一只精灵的一次行动 ============================

---@class GameEvent.Turn: GameEvent
---@field public data TurnData
local Turn = GameEvent:subclass("GameEvent.Turn")

function Turn:__tostring()
  local data = self.data
  return ("<Turn %s by %s #%d>"):format(
    data.who and data.who.name or "?", tostring(data.reason), self.id)
end

--- 行动前：能不能动。
--- 麻痹/睡眠/冰冻/害怕就是在这里把这次行动掐掉的（状态的"行动前"处理器）。
--- 返回 true = 跳过整个事件（连栈都不进），这正是 freekill `Turn:prepare` 的用法。
function Turn:prepare()
  local data = self.data
  local pet = data.who
  local logic = self.room.logic

  if pet == nil or pet:isFainted() then return true end

  -- 这个时机同时充当 freekill 的 PreTurnStart/BeforeTurnStart
  local prevented = logic:beginAction(pet, data.move)
  if prevented then
    data.prevented = true
    logic:notify{
      type = "ActionPrevented",
      pet = pet.seat,
      name = pet.name,
      reason = data.prevent_reason,
    }
    return true
  end
  return nil
end

function Turn:main()
  local data = self.data
  local logic = self.room.logic
  local pet = data.who

  logic:notify{ type = "TurnStart", pet = pet.seat, name = pet.name, round = self.room.logic.round }
  logic:trigger(SeerTiming.TurnStart, pet, data)

  -- 这一回合决定用的技能（在 Round 阶段就已经问好了，见 buildTurnOrder）
  local move = data.move
  if move == nil then
    -- 没技能可用、或者玩家点了一个用不出来的技能：把原因一起播出去，
    -- 客户端才能提示"这个技能现在用不了"（否则玩家会以为点了没反应）。
    logic:notify{
      type = "NoAction", pet = pet.seat, name = pet.name,
      skill = data.reject and data.reject.name or nil,
      reason = data.reject and data.reject.reason or nil,
      text = data.reject and data.reject.text or nil,
    }
    return false
  end

  -- 用技能 = 插一个子事件。嵌套之后，"这次伤害是谁用技能造成的"只要
  -- 顺着 parent 链往上找就一定找得到（`getMostRecentEvent(GameEvent.UseSkill)`）。
  local use = GameEvent.UseSkill:create(SkillUseData:create{
    source = pet,
    target = data.target,
    skill = move,
  }, self.room)
  use:exec()

  return true
end

--- 行动收尾。
--- 放在 `clear()`（而不是 main 末尾）是因为**被打断的行动也要收尾**：
--- 被 kill 的事件的 main 后半段和 exit 都不会执行，只有 clear 一定会跑。
--- 对应 freekill 把 `fk.TurnEnd` 放在 `Turn:clear` 里。
function Turn:clear()
  local data = self.data
  local logic = self.room.logic
  local pet = data.who
  if pet == nil then return end

  logic:trigger(SeerTiming.TurnEnd, pet, data, self.interrupted)
  logic:trigger(SeerTiming.AfterAction, pet, ActionData:create{ actor = pet })
  logic:notify{ type = "TurnEnd", pet = pet.seat, name = pet.name }
end

-- ============================ 一大回合 ============================

---@class GameEvent.Round: GameEvent
---@field public data TurnData
local Round = GameEvent:subclass("GameEvent.Round")

function Round:__tostring()
  return ("<Round %d #%d>"):format(self.data and self.data.round or 0, self.id)
end

--- 一大回合：双方各行动一次。
function Round:main()
  local logic = self.room.logic
  local data = self.data or TurnData:create{}
  self.data = data

  -- 回合的"开始/结束"这两件事由 logic:startRound / logic:endRound 负责
  -- （编号 +1、首回合的 GameStart、RoundStart/RoundEnd 时机、
  --   以及**持续效果与异常状态的回合递减**）。
  --
  -- 为什么不在这个事件里直接写：这些是"回合的语义"，不是"回合的流程"。
  -- 放在 logic 里，`logic:endRound()` 就能被单独调用（自测、调试、将来做
  -- "跳过动画直接结算"之类），而且不会出现"两处各写一遍、其中一处忘了递减"。
  -- startRound 里含"回合上限"的安全阀，返回 false 表示这一局到点了
  if not logic:startRound() then return false end
  data.round = logic.round

  self:action()

  logic:endRound()
  return true
end

--- 本回合的出手顺序。
---
--- 赛尔号的规则是"双方先各自选技能，再按先制度/速度排"。所以这里分两步走：
---   1. **每轮开始时挨个问"你这回合用什么技能"**（`logic:askForAction`，
---      底层是一次 `Request.AskForAction`：谁答、怎么等、超时怎么办都在那边），
---      把答案记下来；
---   2. 按 (先制度降序, 速度降序, 座位升序) 排出出手顺序。
---
--- 第 2 步的"座位升序"听起来多余，但它是**确定性的保险**：速度也一样、
--- 先制度也一样的时候，如果顺序取决于 `pairs` 的遍历顺序，同一局重放就会
--- 出现两种结果（架构文档 §2.3）。
---@return TurnData[]
function Round:buildTurnOrder()
  local logic = self.room.logic
  local alive = logic:getAlivePets()
  local order = {}

  for _, pet in ipairs(alive) do
    local move, target, reject = logic:askForAction(pet)
    table.insert(order, TurnData:create{
      round = logic.round,
      turn = 0,
      who = pet,
      move = move,
      target = target,
      reject = reject,
      reason = "game_rule",
    })
  end

  table.sort(order, function(a, b)
    local pa = a.move and a.move:getPriority() or 0
    local pb = b.move and b.move:getPriority() or 0
    if pa ~= pb then return pa > pb end
    -- 速度直接读字段：pet.speed 里已经含了性格修正和能力等级（麻痹降速也在里面）
    local sa = a.who.speed
    local sb = b.who.speed
    if sa ~= sb then return sa > sb end
    return (a.who.seat or 0) < (b.who.seat or 0)
  end)

  return order
end

function Round:action()
  local logic = self.room.logic
  local order = self:buildTurnOrder()

  for _, turn_data in ipairs(order) do
    if logic.game_over then break end

    -- 轮到某人时他已经倒下了（被前面的人打死了）：这次行动直接跳过
    if not turn_data.who:isFainted() then
      GameEvent.Turn:create(turn_data, self.room):exec()
    end
  end
end

-- ============================ 一局的主循环 ============================

--- 一局对战的主循环。由根事件 `GameEvent.Game:main()` 调用。
---
--- freekill 把这个循环写在"游戏模式"类里（`GameMode:run`）；本项目还没有模式概念，
--- 就先放在离回合流程最近的这里。等真有多模式了，原样挪走即可。
function BattleLogic:run()
  while not self.game_over do
    local round = GameEvent.Round:create(TurnData:create{ round = self.round }, self.room)
    local interrupted = round:exec()
    if interrupted then
      -- 整轮被打断（一般是打完了）——不能死循环，走人
      break
    end
  end

  self:notify{ type = "RunFinished", winner = self.winner, round = self.round }
  return self.winner
end

GameEvent.UseSkill = UseSkill
GameEvent.Turn = Turn
GameEvent.Round = Round

return { UseSkill = UseSkill, Turn = Turn, Round = Round }
