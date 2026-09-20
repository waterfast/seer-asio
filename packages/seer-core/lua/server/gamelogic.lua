-- SPDX-License-Identifier: GPL-3.0-or-later
-- 战斗流程由 run 串联，所有时机统一由 trigger 创建本次 EffectHandler 结算。
-- 效果挂在 GameObject 上；开局只登记双方对象，不把效果复制到逻辑层的全局索引。

local EV = require "core.events"
local Elements = require "core.elements"
local EffectHandler = require "core.effect.effect_handler"
local Unit = require "core.unit"
local BattleRoom = require "server.battleroom"
local UseSkillFlow = require "server.events.useskill"
local HpFlow = require "server.events.hp"

local G = EV.gameflow   -- BattleStart/TurnStart/TurnReady/DecidePriority/TurnEnd/AfterTurnEnd/BattleEnd
local A = EV.attack     -- BeforeAttack/AttackStart/DamageParamCalculate/.../AttackEnd

---@class GameLogic: Object
---@field public pets Pet[] @ 参战精灵（平铺数组）
---@field public sides table<integer, Pet[]> @ 两边精灵：sides[1] / sides[2]
---@field public units Unit[] @ 双方玩家；效果由玩家自己挂载
---@field public room BattleRoom @ 局内对象与信息容器
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
---  opts.units   Unit[]? @ 显式玩家对象，优先于 sides/pets
---  opts.room    BattleRoom? @ 省略时自动创建房间
function GameLogic:initialize(opts)
  opts = opts or {}
  self.room = opts.room or BattleRoom:new()
  self.rng = opts.rng or Rng:new(opts.rng_seed or 0)
  self.max_rounds = opts.max_rounds or 999

  -- ---- 1. 导入双方精灵 ----
  local units = opts.units
  if units == nil and #self.room.units > 0 then units = self.room.units end
  local sides = opts.sides
  if units ~= nil then
    sides = {}
    for i, unit in ipairs(units) do sides[i] = unit:getPets() end
  end
  self.sides = sides or self:_defaultSides(opts.pets or self.room.pets)
  for side, pets in ipairs(self.sides) do
    for seat, pet in ipairs(pets) do pet.side = side; pet.seat = seat end
  end
  self.units = units or {
    Unit:new{ id = 1, pets = self.sides[1] },
    Unit:new{ id = 2, pets = self.sides[2] },
  }
  self.pets = {}
  for _, side in ipairs(self.sides) do
    for _, pet in ipairs(side) do
      table.insert(self.pets, pet)
    end
  end

  self.room.logic = self
  self.room.units = self.units
  self.room.pets = self.pets

  -- 只保存时机记录，不持有全局效果或触发器索引。
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
    local fifth = pet:getFifthSkill()
    if fifth then self.pp[pet][fifth.name] = fifth:getPP() end
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

-- ============================ 时机与效果 ============================

--- 登记双方的常驻效果来源。重复调用按对象去重，不重复挂载效果。
--- 当前流程让所有存活精灵行动，因此登记双方全部精灵；出战/替补规则后续单独实现。
--- 技能不在这里登记，它的效果仅由当前攻击上下文临时提供。
function GameLogic:registerEffectSources()
  for _, unit in ipairs(self.units) do
    self.room:registerEffectSource(unit)
    for _, pet in ipairs(unit:getPets()) do
      self.room:registerEffectSource(pet)
    end
  end
end

--- 从对象自己的挂载表中筛出本时机的效果，不把其他时机放入 handler。
--- 同一个挂载对象被多个入口引用时只收集一次；不同拥有者可以共用同一效果定义。
---@param timing TriggerEvent @ 时机类
---@param ctx EffectContext
---@return EffectHandler
function GameLogic:buildEffectHandler(timing, ctx)
  local handler = EffectHandler:new()
  local seen = {}
  local function collect(object, owner)
    if object == nil or seen[object] then return end
    seen[object] = true
    for _, effect in ipairs(object:getEffects()) do
      if effect:getTiming() == timing then
        handler:addEffect(owner or object, effect, object)
      end
    end
    for _, buff in ipairs(self.room:getBuffs(object)) do
      if buff:isEffective(self.round) then
        for _, effect in ipairs(buff:getEffects()) do
          if effect:getTiming() == timing then handler:addEffect(owner or object, effect, buff, buff) end
        end
      end
    end
  end

  -- 固定收集顺序，同优先级按这个顺序执行：当前技能、房间、登记的常驻对象。
  collect(ctx.skill, ctx.source)
  -- 解除后的实例已从拥有者摘除，但仍需观察自己的解除原因（如护罩消失后触发效果）。
  if timing == EV.buff.AfterBuffRemove and ctx.data and ctx.data.buff then
    local removed = ctx.data.buff
    for _, effect in ipairs(removed:getEffects()) do
      if effect:getTiming() == timing then handler:addEffect(removed.owner, effect, removed, removed, true) end
    end
  end
  collect(self.room)
  for _, object in ipairs(self.room:getEffectSources()) do collect(object) end
  return handler
end

--- 唯一时机入口：创建事件 → 收集匹配效果 → 同步结算。
--- 保留原来的 target/data 和 broken/event 返回协议。action 只由当前技能流程显式传入，
--- 不保存为 logic 的临时字段，因此嵌套攻击和回合时机不会误用上一次技能的效果。
---@param timing_class TriggerEvent @ 时机类（SeerTiming.Xxx）
---@param target GameObject?
---@param data TriggerData?
---@param action table? @ 本次动作的 { source, skill }，仅在该动作的时机里生效
---@return boolean broken
---@return TriggerEvent event
function GameLogic:trigger(timing_class, target, data, action)
  local event = timing_class:new(self, target, data)
  table.insert(self.event_log, event)
  local ctx = {
    logic = self, room = self.room, event = event, timing = timing_class,
    target = target, data = data,
    source = action and action.source or (data and data.source),
    skill = action and action.skill,
    damage = data and data.damage,
  }
  event.handler = self:buildEffectHandler(timing_class, ctx)
  event.handler:resolve(ctx)
  return event.broken == true, event
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

--- 默认决策：挑第一个有 PP 的技能，按技能目标规则选择目标。
---（接 Request 之前先用这个把循环跑通，TODO）
function GameLogic:pickAction(source)
  local skill = nil
  for _, sk in ipairs(source:getSkills()) do
    if self:getPP(source, sk) > 0 then
      skill = sk
      break
    end
  end
  if not skill then return nil, nil end
  local target = skill:getTarget() == "self" and source or self:pickTarget(source)
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

--- 战斗有效能力值：正等级乘 (2+n)/2，负等级乘 2/(2-n)。面板保持不变。
--- 命中等级使用独立规则，不能传入此函数；赛尔号没有独立闪避能力等级。
---@param pet Pet
---@param field string @ attack/defense/sp_attack/sp_defense/speed
---@return number
function GameLogic:getEffectiveStat(pet, field)
  local stage = pet:getStatStage(field)
  local multiplier = stage >= 0 and (2 + stage) / 2 or 2 / (2 - stage)
  return pet:getStat(field) * multiplier
end

--- 命中正等级每级增加 50%；现代页游负等级使用专用表，不套攻防倍率。
---@param pet Pet
---@return number
function GameLogic:getAccuracyMultiplier(pet)
  local stage = pet:getStatStage("accuracy")
  if stage >= 0 then return 1 + stage * 0.5 end
  return ({ 0.85, 0.70, 0.55, 0.45, 0.35, 0.25 })[-stage]
end

--- 准备单击参数。致命判定在 CriticalChanceCalculate 之后进行，允许临时效果改概率。
--- crit_rate 沿用旧 Skill 的“额外致命值”语义：基础 1/16，每点额外增加 1/16。
---@return DamageData
function GameLogic:calcParams(source, target, skill)
  local element = skill:getElement() or source:getPrimaryElement()
  local physical = skill:isPhysical()
  local attack = self:getEffectiveStat(source, physical and "attack" or "sp_attack")
  local defense = self:getEffectiveStat(target, physical and "defense" or "sp_defense")
  local multiplier = element and Elements.getMultiplier(element, target:getElements()) or 1
  local stab = 1
  if element then
    for _, own_element in ipairs(source:getElements()) do
      if own_element == element then stab = 1.5; break end
    end
  end
  return DamageData:new{
    source = source, target = target, skill = skill,
    power = skill:getPower() or 0, category = skill:getCategory(), element = element,
    attack = attack, defense = defense, stab = stab, multiplier = multiplier,
    crit = false, crit_chance = math.max(0, math.min(100, (1 + (skill:getCritRate() or 0)) * 100 / 16)),
    crit_resistance = 0, random = self.rng:random(217, 255) / 255,
    damage = 0, prevented = false,
  }
end

--- 普通攻击的裸伤公式。先算等级/威力/攻防/本系/克制，再取随机浮动，最后算致命。
--- 取整位置按公开页游实测记录，依据和未验证边界见 docs/battle-rules.md。
--- 未引入套装、宝石、穿甲或变威力专用分支，不能宣称覆盖完整实机伤害系统。
---@param dmg DamageData
---@return integer
function GameLogic:damageFormula(dmg)
  if dmg.prevented or dmg.power <= 0 or (dmg.multiplier or 1) == 0 then return 0 end
  assert(dmg.defense > 0, "伤害计算的防御必须大于 0")
  local level = dmg.source:getLevel()
  local base = ((level * 0.4 + 2) * dmg.power * dmg.attack / dmg.defense / 50 + 2)
    * (dmg.stab or 1) * (dmg.multiplier or 1)
  local damage = math.floor(math.floor(base) * (dmg.random or 1))
  if dmg.crit then
    damage = math.floor(damage * (1 - (dmg.crit_resistance or 0))) * 2
  end
  return math.max(1, damage)
end

--- 兼容数值式调用，返回实际变化量和完整数据。新效果优先用 room 的结构化接口。
function GameLogic:changeHp(target, num, reason, source)
  local data = HpFlow.changeHp(self, HpChangeData:new{
    target = target, num = num, reason = reason, source = source,
  })
  return data.actual, data
end

function GameLogic:recover(target, num, reason, source)
  local data = HpFlow.recover(self, RecoverData:new{
    target = target, num = num, reason = reason, source = source,
  })
  return data.actual, data
end

--- 统一伤害入口。第三个参数仅供 resolveAttack 发计算完成后的 AttackReady。
---@return DamageData
function GameLogic:damage(data, action, ready)
  if not data.isInstanceOf or not data:isInstanceOf(DamageData) then data = DamageData:new(data) end
  return HpFlow.damage(self, data, action, ready)
end

-- ============================ 一回合 / 一次攻击 ============================

--- 一次完整技能使用：属性技能与攻击技能共用命中、PP 和技能时机。
---@return SkillUseData
function GameLogic:useSkill(source, skill, target)
  return UseSkillFlow.run(self, source, skill, target)
end

--- 兼容旧调用入口，统一转发技能流程；不再维护另一套 PP/命中逻辑。
---@return SkillUseData
function GameLogic:doAttack(source, skill, target)
  return self:useSkill(source, skill, target)
end

--- 已经命中的攻击技能。只负责伤害，不重复判命中或扣 PP。
--- AttackReady 位于扣血之前，Attack 位于扣血之后，整次攻击只触发一次 AfterAttack。
---@return AttackData
function GameLogic:resolveAttack(source, skill, target)
  local action = { source = source, skill = skill }
  local data = AttackData:new{
    source = source, target = target, skill = skill,
    hits = 0, damage = 0, missed = false, crit = false, prevented = false,
  }
  local function emit(timing, value)
    local broken = self:trigger(timing, target, value, action)
    if broken then value.prevented = true end
    return broken or value.prevented
  end
  if emit(A.BeforeAttack, data) or emit(A.AttackStart, data) then
    self:trigger(A.AttackEnd, target, data, action)
    return data
  end
  local hits = skill:getHits()
  if type(hits) == "function" then hits = hits(skill, source, target, self) end
  local count = math.max(1, math.min(math.floor(hits or 1), 20))
  for index = 1, count do
    if self:isFainted(source) or self:isFainted(target) then break end
    local dmg = DamageData:new{ source = source, target = target, skill = skill,
      kind = "attack", index = index, parent = data }
    data.damage_data = dmg
    self:damage(dmg, action, function()
      return emit(A.AttackReady, data)
    end)
    if dmg.actual > 0 then
      data.damage = data.damage + dmg.actual
      data.crit = data.crit or dmg.crit
      data.hits = data.hits + 1
      self:trigger(A.Attack, target, data, action)
    end
    if data.prevented then break end
  end
  if not data.prevented then self:trigger(A.AfterAttack, target, data, action) end
  self:trigger(A.AttackEnd, target, data, action)
  return data
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
    local sa, sb = self:getEffectiveStat(a.source, "speed"), self:getEffectiveStat(b.source, "speed")
    if sa ~= sb then return sa > sb end
    return self.room:seatOf(a.source) < self.room:seatOf(b.source)
  end)

  local order = {}
  for _, a in ipairs(actions) do table.insert(order, a.source) end
  self:trigger(G.DecidePriority, nil, DecidePriorityData:new{ actions = actions, order = order })

  -- 逐个出手
  for _, action in ipairs(actions) do
    if self.game_over then break end
    if not self:isFainted(action.source) then
      if action.skill and action.target then
        self:useSkill(action.source, action.skill, action.target)
      else
        self:notify{ type = "ActionSkipped", source = action.source }
      end
    end
    self:updateGameOver()
  end

  self:trigger(G.TurnEnd, nil, td)
  self:trigger(G.AfterTurnEnd, nil, td)
  self.room:expireBuffs(self.round)
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

  -- ===== 2. 在 BattleStart 之前登记双方对象（效果已经挂在各自对象上）=====
  self:registerEffectSources()

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
  self.room:clearBattleBuffs()
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
