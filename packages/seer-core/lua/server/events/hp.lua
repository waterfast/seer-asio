-- SPDX-License-Identifier: GPL-3.0-or-later
-- 同步 HP 结算的唯一实现。GameLogic、BattleRoom 和 GameEvent 包装共用这条链。
-- 不在这里判整局胜负：反伤、吸取等嵌套操作先结算完，行动结束再判断胜负。
local EV = require "core.events"
local H, A = EV.hp, EV.attack
local GameEvent = rawget(_G, "GameEvent") or require "server.gameevent"
local M = {}

local function emit(logic, timing, target, data, action)
  if logic:trigger(timing, target, data, action) then data.prevented = true end
  return data.prevented == true
end

local function integer(value)
  assert(type(value) == "number" and value == value and math.abs(value) < math.huge,
    "HP / 伤害数值必须是有限数字")
  local whole = math.modf(value) -- 向零取整，避免 -0.5 被额外扣成 1 点。
  return whole
end

--- 唯一局内 HP 写入点（初始化除外）。不承担伤害公式、回复增益或复活规则。
---@return HpChangeData
function M.changeHp(logic, data, action)
  local target = assert(data.target, "HP 变化需要 target")
  data.kind = data.kind or "direct"
  data.actual, data.before, data.after = 0, target.hp, target.hp
  data.num = integer(data.num)
  if data.num == 0 or logic:isFainted(target) then return data end
  if emit(logic, H.BeforeHpChange, target, data, action) then return data end
  local num = integer(data.num)
  if data.kind == "damage" then num = math.min(0, num)
  elseif data.kind == "recover" then num = math.max(0, num) end
  -- 前置效果可能嵌套改血甚至击倒目标，重新读当前值，不能覆盖嵌套结果。
  data.before, data.after = target.hp, target.hp
  if logic:isFainted(target) then return data end
  data.after = math.max(0, math.min(target.max_hp, data.before + num))
  data.actual = data.after - data.before
  if data.actual == 0 then return data end
  target.hp = data.after
  local fainted = data.before > 0 and data.after == 0
  if fainted then target.fainted = true end
  logic:notify{ type = "HpChanged", target = target, source = data.source, skill = data.skill and data.skill.name,
    before = data.before, after = data.after, num = data.actual, reason = data.reason, kind = data.kind }
  logic:trigger(H.AfterHpChange, target, data, action)
  if fainted then
    logic:trigger(H.HpReducedToZero, target, data, action)
    logic:notify{ type = "PetFainted", target = target, source = data.source, skill = data.skill and data.skill.name,
      reason = data.reason }
  end
  return data
end

--- 回复时机与 HP 时机分层；禁疗在 BeforeRecover，通用锁血在 BeforeHpChange。
---@return RecoverData
function M.recover(logic, data, action)
  local target = assert(data.target, "回复需要 target")
  data.actual = 0
  data.num = math.max(0, integer(data.num))
  if logic:isFainted(target) or data.num == 0 then return data end
  if emit(logic, H.BeforeRecover, target, data, action) then return data end
  local hp = HpChangeData:new{ target = target, source = data.source, skill = data.skill,
    num = math.max(0, integer(data.num)), kind = "recover", reason = data.reason or "recover", parent = data }
  data.hp_change = M.changeHp(logic, hp, action)
  data.actual, data.prevented = hp.actual, hp.prevented == true
  if data.actual > 0 then logic:trigger(H.AfterRecover, target, data, action) end
  return data
end

--- 一次伤害尝试。attack 计算公式；fixed / percent 已由效果提供最终基础数值。
--- action 必须显式传入才能激活当前技能效果；skill 字段只记录来源，避免反伤误用原技能。
--- ready 仅供攻击流程在计算后发 AttackReady，返回 true 取消该击，不引入第二套伤害实现。
---@param ready function? @ 内部攻击流程回调，参数为 DamageData
---@return DamageData
function M.damage(logic, data, action, ready)
  local target = assert(data.target, "伤害需要 target")
  data.kind = data.kind or (data.skill and "attack" or "fixed")
  assert(data.kind == "attack" or data.kind == "fixed" or data.kind == "percent", "未知伤害类别")
  data.actual = 0
  if logic:isFainted(target) then return data end
  if data.kind == "attack" and not data.prevented then
    assert(data.source and data.skill, "攻击伤害需要 source / skill")
    local params = logic:calcParams(data.source, target, data.skill)
    -- 每次都生成新参数；保留来源、parent、击数等本次调用的信息。
    for key, value in pairs(params._data) do data[key] = value end
    if not emit(logic, A.DamageParamCalculate, target, data, action)
      and not emit(logic, A.CriticalChanceCalculate, target, data, action) then
      data.crit = logic.rng:chance(math.max(0, math.min(100, data.crit_chance)))
      if not emit(logic, A.BeforeDamageCalculate, target, data, action) then
        data.damage = logic:damageFormula(data)
        if not emit(logic, A.DamageCalculate, target, data, action)
          and not emit(logic, A.AfterDamageCalculate, target, data, action) then
          emit(logic, A.FinalDamageCalculate, target, data, action)
        end
      end
    end
  end
  data.damage = math.max(0, integer(data.damage or 0))
  if not data.prevented and ready and ready(data) then data.prevented = true end
  if not data.prevented and not emit(logic, H.BeforeDamage, target, data, action) then
    local hp = HpChangeData:new{ target = target, source = data.source, skill = data.skill,
      num = -math.max(0, integer(data.damage)), kind = "damage", parent = data,
      reason = data.reason or (data.skill and data.skill.name) or data.kind }
    data.hp_change = M.changeHp(logic, hp, action)
    data.actual, data.prevented = -hp.actual, hp.prevented == true
  end
  if data.actual > 0 then
    -- 暴击按强化后的防御算完伤害才消除对应防御强化；固定伤害不触发此规则。
    if data.kind == "attack" and data.crit then
      logic.room:clearPositiveStatStages(target, data.source, "致命一击",
        { data.skill:isPhysical() and "defense" or "sp_defense" })
    end
    logic:notify{ type = "Damage", source = data.source, target = target, skill = data.skill and data.skill.name,
      damage = data.actual, crit = data.crit == true, kind = data.kind }
    logic:trigger(H.AfterDamage, target, data, action)
  else
    logic:notify{ type = "DamagePrevented", source = data.source, target = target,
      skill = data.skill and data.skill.name, kind = data.kind }
  end
  logic:trigger(H.DamageResolved, target, data, action)
  return data
end

-- 保留流程事件入口，但只接受当前 GameEvent:create(logic, data) 参数约定。
for name, method in pairs{ Damage = "damage", ChangeHp = "changeHp", Recover = "recover" } do
  local event = GameEvent:subclass("GameEvent." .. name)
  function event:main()
    self.data = self.logic.room[method](self.logic.room, self.data)
    return self.data.actual ~= 0
  end
  GameEvent[name], M[name] = event, event
end
return M
