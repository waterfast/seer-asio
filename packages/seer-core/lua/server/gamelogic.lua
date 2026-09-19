-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 战斗逻辑（GameLogic）============================
--
-- 参考 freekill-core 的 `lua/server/gamelogic.lua`（GameLogic）。它只干一件事：
-- 把一局战斗"怎么走完"串起来——`run()` 就是整局的主循环。
--
-- run() 分三段（对应 freekill 的 GameEvent.Game:main → Round → Turn 流程，
-- 但赛尔号没有手牌/阶段，直接一个循环就够了）：
--
--   1. 导入双方精灵：把 opts.pets 里的精灵分好边、装好战斗状态（体力等）；
--   2. 加载技能到时机表：把每只精灵技能上的时机钩子（triggers）登记进 skill_table；
--   3. 游戏循环：BattleStart → 每个大回合（TurnStart / TurnReady / DecidePriority
--      → 双方各出手一次 → TurnEnd / AfterTurnEnd）→ BattleEnd，分出胜负。
--
-- 时机（TriggerEvent）是同步的"这一刻谁想插一脚"，这里只负责**按顺序触发**它们；
-- 真正挂在时机上的触发器（技能特性 / 效果 / 印记）后续再装。18 个时机类都在
-- core/events 里定义（全局数据类 + require 返回的类表），这里 require 进来直接用，
-- 不需要单独的 timing 注册文件。
--
-- 本文件假设环境已由 seer.lua（或测试脚本）备好：`class`（middleclass）、
-- `Util` / `Log` / `Rng`，以及全局的 `Skill` / `Pet` / `TriggerEvent` 与
-- 数据类（BattleStartData / TurnData / DecidePriorityData / AttackData /
-- DamageData / BattleEndData）。

local EV = require "core.events"
local Elements = require "core.elements"

local G = EV.gameflow   -- BattleStart/TurnStart/TurnReady/DecidePriority/TurnEnd/AfterTurnEnd/BattleEnd
local A = EV.attack     -- BeforeAttack/AttackStart/DamageParamCalculate/.../AttackEnd

---@class GameLogic: Object
---@field public pets Pet[] @ 参战精灵（平铺数组）
---@field public sides table<integer, Pet[]> @ 两边精灵：sides[1] / sides[2]
---@field public skill_table table<TriggerEvent, table> @ 时机类 -> 触发器列表（时机表）
---@field public rng Rng @ 确定性随机数
---@field public round integer @ 当前大回合数
---@field public game_over boolean
---@field public winner integer? @ 获胜方（1/2），平局为 nil
---@field public win_reason string? @ all_fainted / max_rounds
GameLogic = class("GameLogic")

---@param opts table
---  opts.pets    Pet[] | Pet[][] @ 平铺数组（对半分边）或 `{ {side1...}, {side2...} }`
---  opts.sides   Pet[][]? @ 显式给两边（优先于 opts.pets 的分边）
---  opts.rng_seed integer|string? @ 随机种子（没有 opts.rng 时用）
---  opts.rng     Rng? @ 已构造好的随机数发生器
---  opts.max_rounds integer? @ 回合上限，默认 999
---  opts.room    any? @ 战局容器（freekill 兼容位，可留空）
function GameLogic:initialize(opts)
  opts = opts or {}
  self.room = opts.room
  self.rng = opts.rng or Rng:new(opts.rng_seed or 0)
  self.max_rounds = opts.max_rounds or 999

  -- ---- 1. 导入双方精灵 ----
  self.sides = opts.sides or self:_defaultSides(opts.pets or {})
  self.pets = {}
  for _, side in ipairs(self.sides) do
    for _, pet in ipairs(side) do
      table.insert(self.pets, pet)
    end
  end

  -- 时机表 / 事件记录
  self.skill_table = {}            -- 时机类 -> 触发器数组
  self.current_timing_id = 0
  self.event_log = {}

  -- 战斗状态（临时挂在 pet 上；正式的"当前体力/濒死"状态层后续再收口）
  self.pp = {}                     -- pet -> { 技能名 -> 剩余 PP }
  for _, pet in ipairs(self.pets) do
    pet.max_hp = pet:getStat("hp") -- 能力值里的 hp 当作初始满血
    pet.hp = pet.max_hp
    pet.fainted = false
    self.pp[pet] = {}
    for _, sk in ipairs(pet:getSkills()) do
      self.pp[pet][sk.name] = sk:getPP()
    end
  end

  self.round = 0
  self.game_over = false
  self.winner = nil
  self.win_reason = nil
end

-- opts.pets 分边：嵌套数组直接用，平铺数组对半分
function GameLogic:_defaultSides(pets)
  local side1, side2 = {}, {}
  if type(pets[1]) == "table" and type(pets[1][1]) == "table" then
    side1, side2 = pets[1] or {}, pets[2] or {}
  else
    local half = math.ceil(#pets / 2)
    for i, p in ipairs(pets) do
      if i <= half then table.insert(side1, p) else table.insert(side2, p) end
    end
  end
  for i, p in ipairs(side1) do p.side = 1; p.seat = i end
  for i, p in ipairs(side2) do p.side = 2; p.seat = i end
  return { side1, side2 }
end

-- ============================ 时机表 ============================

--- 把一个技能的时机钩子（skill.triggers）登记进时机表。
---@param skill Skill
---@param owner Pet @ 拥有这个技能的精灵（触发器的"我代表谁"）
function GameLogic:addTriggerSkill(skill, owner)
  for timing_class, spec in pairs(skill.triggers or {}) do
    self.skill_table[timing_class] = self.skill_table[timing_class] or {}
    table.insert(self.skill_table[timing_class], {
      skill = skill,
      owner = owner,
      priority = spec.priority or 0,
      can_trigger = spec.can_trigger,
      on_trigger = spec.on_trigger,
    })
  end
end

--- 触发一个时机：创建 TriggerEvent，按优先级跑一遍挂在上面的触发器。
---@param timing_class TriggerEvent @ 时机类（G.BattleStart / A.BeforeAttack ...）
---@param target GameObject?
---@param data TriggerData?
---@return boolean broken @ 是否被打断
---@return TriggerEvent ev
function GameLogic:trigger(timing_class, target, data)
  local ev = timing_class:new(self, target, data)
  table.insert(self.event_log, ev)

  local triggers = self.skill_table[timing_class]
  if triggers and #triggers > 0 then
    -- 优先级降序，同级按技能名排序（保证顺序确定）
    local sorted = {}
    for _, tr in ipairs(triggers) do table.insert(sorted, tr) end
    table.sort(sorted, function(a, b)
      if a.priority ~= b.priority then return a.priority > b.priority end
      return (a.skill and a.skill.name or "") < (b.skill and b.skill.name or "")
    end)

    for _, tr in ipairs(sorted) do
      local ok = tr.can_trigger == nil
        or tr.can_trigger(tr.skill, ev, target, tr.owner, data)
      if ok then
        local broken = tr.on_trigger(tr.skill, ev, target, tr.owner, data)
        if broken then
          ev.broken = true
          ev.break_reason = tr.skill and tr.skill.name
          break
        end
      end
    end
  end

  return ev.broken == true, ev
end

-- ============================ 查询 / 行动 ============================

--- 双方所有还活着的精灵（出手排序、胜负判定都用它）
---@return Pet[]
function GameLogic:getActors()
  local ret = {}
  for _, p in ipairs(self.pets) do
    if not self:isFainted(p) then table.insert(ret, p) end
  end
  return ret
end

function GameLogic:isFainted(pet)
  return pet.fainted or (pet.hp or 0) <= 0
end

---@param side integer @ 1 或 2
---@return Pet[]
function GameLogic:getSide(side)
  return self.sides[side] or {}
end

--- 默认决策：挑第一个"能打且有 PP"的技能，目标挑对面第一个活着的。
---（接 Request 之前先用这个把循环跑通，TODO）
function GameLogic:pickAction(source)
  local skill = nil
  for _, sk in ipairs(source:getSkills()) do
    if sk:isDamaging() and self:getPP(source, sk) > 0 then
      skill = sk
      break
    end
  end
  if not skill then return nil, nil end
  local target = self:pickTarget(source)
  return skill, target
end

function GameLogic:pickTarget(source)
  local enemy = (source.side == 1) and self.sides[2] or self.sides[1]
  for _, p in ipairs(enemy or {}) do
    if not self:isFainted(p) then return p end
  end
  return nil
end

function GameLogic:getPP(pet, skill)
  local name = type(skill) == "string" and skill or skill.name
  return (self.pp[pet] and self.pp[pet][name]) or 0
end

function GameLogic:usePP(pet, skill, n)
  n = n or 1
  local name = type(skill) == "string" and skill or skill.name
  if self.pp[pet] then
    self.pp[pet][name] = math.max(0, (self.pp[pet][name] or 0) - n)
  end
end

-- ============================ 伤害 / 体力 ============================

--- 凑伤害参数（威力/攻防/本系/克制/暴击/随机）。
---@return DamageData
function GameLogic:calcParams(source, target, skill)
  local element = skill:getElement() or source:getPrimaryElement()
  local physical = skill:isPhysical()
  local attack = source:getStat(physical and "attack" or "sp_attack")
  local defense = target:getStat(physical and "defense" or "sp_defense")

  local multiplier = 1
  if element then
    multiplier = Elements.getMultiplier(element, target:getElements())
  end

  -- 本系加成：技能属性 == 使用者的属性之一
  local stab = 1
  if element then
    for _, e in ipairs(source:getElements()) do
      if e == element then stab = 1.5; break end
    end
  end

  -- 暴击：crit_rate 每级 6.25%（简化，TODO 与实机核对）
  local crit_rate = skill:getCritRate() or 0
  local crit = crit_rate > 0 and self.rng:chance(6.25 * crit_rate) or false

  local random = self.rng:random(85, 100) / 100   -- 0.85 ~ 1.0

  return DamageData:new{
    source = source, target = target, skill = skill,
    power = skill:getPower() or 0,
    category = skill:getCategory(),
    element = element,
    attack = attack, defense = defense,
    stab = stab, multiplier = multiplier,
    crit = crit, random = random,
    damage = 0, prevented = false,
  }
end

--- 套伤害公式（系数待与实机核对）。
---@param dmg DamageData
---@return integer
function GameLogic:damageFormula(dmg)
  local level = dmg.source:getLevel() or 50
  local base = math.floor((2 * level / 5 + 2) * dmg.power * dmg.attack / dmg.defense / 50 + 2)
  local damage = base
  damage = damage * (dmg.stab or 1)
  damage = damage * (dmg.multiplier or 1)
  if dmg.crit then damage = damage * 1.5 end
  damage = damage * (dmg.random or 1)
  return math.max(1, math.floor(damage))
end

--- 唯一改血的地方。num 可正可负。
---@return integer actual @ 实际变化量
function GameLogic:changeHp(target, num, reason)
  local before = target.hp
  target.hp = math.max(0, math.min(target.max_hp or target.hp, target.hp + num))
  local actual = target.hp - before
  if target.hp <= 0 then target.fainted = true end
  self:notify{ type = "HpChanged", target = target, before = before, after = target.hp, num = actual, reason = reason }
  return actual
end

--- 回血（拒绝给已倒下的精灵回血，避免"无限复活"）。
function GameLogic:recover(target, num, reason)
  if self:isFainted(target) then return 0 end
  return self:changeHp(target, num, reason or "recover")
end

-- ============================ 一回合 / 一次攻击 ============================

--- 一次攻击：命中判定 → 连击 → 每击走伤害链 → 扣 PP。
function GameLogic:doAttack(source, skill, target)
  local data = AttackData:new{
    source = source, target = target, skill = skill,
    hits = 1, damage = 0, missed = false, crit = false,
  }

  self:trigger(A.BeforeAttack, target, data)
  if data.prevented then return end
  self:trigger(A.AttackStart, target, data)

  -- 命中判定（nil / <=0 = 必中）
  local acc = skill:getAccuracy()
  if acc and acc > 0 and not self.rng:chance(acc) then
    data.missed = true
    self:notify{ type = "SkillMissed", source = source, target = target, skill = skill }
    self:trigger(A.AttackEnd, target, data)
    return
  end

  -- 连击次数（整数或函数，上限 20 防死循环）
  local hits = skill:getHits()
  local n = 1
  if type(hits) == "number" then
    n = hits
  elseif type(hits) == "function" then
    n = hits(skill, source, target, self)
  end
  n = math.max(1, math.min(math.floor(n or 1), 20))

  for i = 1, n do
    if self:isFainted(target) then break end
    local dmg = self:calcParams(source, target, skill)

    self:trigger(A.DamageParamCalculate, target, dmg)
    self:trigger(A.BeforeDamageCalculate, target, dmg)
    dmg.damage = self:damageFormula(dmg)      -- DamageCalculate 的核心动作
    self:trigger(A.DamageCalculate, target, dmg)
    self:trigger(A.AfterDamageCalculate, target, dmg)
    self:trigger(A.FinalDamageCalculate, target, dmg)

    if dmg.prevented or dmg.damage < 1 then
      self:notify{ type = "DamagePrevented", source = source, target = target, skill = skill }
    else
      self:changeHp(target, -dmg.damage, skill.name)
      data.damage = data.damage + dmg.damage
      data.crit = data.crit or dmg.crit
    end
  end

  self:usePP(source, skill, 1)

  self:trigger(A.AttackReady, target, data)
  self:trigger(A.Attack, target, data)
  self:trigger(A.AfterAttack, target, data)
  self:trigger(A.AttackEnd, target, data)
end

--- 一个大回合：双方选行动 → 定先后手 → 逐个出手 → 收尾。
function GameLogic:doRound()
  local td = TurnData:new{ turn_number = self.round }
  self:trigger(G.TurnStart, nil, td)
  self:trigger(G.TurnReady, nil, td)

  -- 双方各选一个行动
  local actions = {}
  for _, actor in ipairs(self:getActors()) do
    local skill, target = self:pickAction(actor)
    table.insert(actions, { source = actor, skill = skill, target = target })
  end

  -- 决定出手顺序：技能先制度 → 速度 → 座位
  table.sort(actions, function(a, b)
    local pa = a.skill and a.skill:getPriority() or -math.huge
    local pb = b.skill and b.skill:getPriority() or -math.huge
    if pa ~= pb then return pa > pb end
    local sa, sb = a.source:getStat("speed"), b.source:getStat("speed")
    if sa ~= sb then return sa > sb end
    return (a.source.seat or 0) < (b.source.seat or 0)
  end)

  local order = {}
  for _, a in ipairs(actions) do table.insert(order, a.source) end
  self:trigger(G.DecidePriority, nil, DecidePriorityData:new{ actions = actions, order = order })

  -- 逐个出手
  for _, action in ipairs(actions) do
    if self.game_over then break end
    if not self:isFainted(action.source) then
      if action.skill and action.target then
        self:doAttack(action.source, action.skill, action.target)
      else
        self:notify{ type = "ActionSkipped", source = action.source }
      end
    end
    self:updateGameOver()
  end

  self:trigger(G.TurnEnd, nil, td)
  self:trigger(G.AfterTurnEnd, nil, td)
  self:updateGameOver()
end

-- ============================ 主循环 ============================

function GameLogic:updateGameOver()
  local alive = {}
  for _, p in ipairs(self.pets) do
    if not self:isFainted(p) then alive[p.side] = true end
  end
  if not alive[1] and not alive[2] then
    self:finishGame(nil, "draw")
  elseif not alive[2] then
    self:finishGame(1, "all_fainted")
  elseif not alive[1] then
    self:finishGame(2, "all_fainted")
  end
end

function GameLogic:finishGame(winner, reason)
  self.game_over = true
  self.winner = winner
  self.win_reason = reason
end

---@return table @ { winner, reason, round }
function GameLogic:getResult()
  return { winner = self.winner, reason = self.win_reason, round = self.round }
end

--- 整局主循环。返回 `{ winner, reason, round }`。
function GameLogic:run()
  -- ===== 1. 导入双方精灵（分边/体力状态已在 initialize 完成）=====
  if #(self.sides[1] or {}) == 0 or #(self.sides[2] or {}) == 0 then
    error("GameLogic:run 需要双方各至少一只精灵", 2)
  end

  -- ===== 2. 加载技能到时机表 =====
  for _, pet in ipairs(self.pets) do
    for _, skill in ipairs(pet:getSkills()) do
      self:addTriggerSkill(skill, pet)
    end
  end

  -- ===== 3. 游戏循环 =====
  self:trigger(G.BattleStart, nil, BattleStartData:new{})
  while not self.game_over do
    if self.round >= self.max_rounds then
      self:finishGame(nil, "max_rounds")
      break
    end
    self.round = self.round + 1
    self:doRound()
  end
  self:trigger(G.BattleEnd, nil, BattleEndData:new{ winner = self.winner, reason = self.win_reason })
  return self:getResult()
end

-- ============================ 通知（占位）============================

--- 打一条事件。真协议后面再接；测试可用 on_notify 抓事件做断言。
function GameLogic:notify(evt)
  if type(self.on_notify) == "function" then
    self.on_notify(self, evt)
  else
    Log.info(("🎮 %s"):format(tostring(evt.type)))
  end
end

return GameLogic
