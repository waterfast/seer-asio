-- SPDX-License-Identifier: GPL-3.0-or-later
-- 同步技能流程；GameLogic:useSkill 与 GameEvent.UseSkill 共用此实现。
-- 先确认使用、扣一次 PP、判命中；属性技只结算 SkillUsed，攻击技再进入攻击/伤害链。
local EV = require "core.events"
local U, A = EV.useskill, EV.attack
local GameEvent = rawget(_G, "GameEvent") or require "server.gameevent"

---@param logic GameLogic
---@param source Pet
---@param skill Skill
---@param target Pet?
---@return SkillUseData
local function run(logic, source, skill, target)
  if skill:getTarget() == "self" then target = source end
  local data = SkillUseData:new{
    source = source, target = target, skill = skill,
    prevented = false, missed = false, success = false,
  }
  if logic:isFainted(source) or target == nil or logic:isFainted(target) or logic:getPP(source, skill) <= 0 then
    data.prevented = true
    return data
  end
  local action = { source = source, skill = skill }
  if logic:trigger(U.BeforeSkillUse, target, data, action) or data.prevented then
    data.prevented = true
    return data
  end
  -- 已经使用就消耗 PP，未命中也不会退还。
  logic:usePP(source, skill, 1)
  logic:notify{ type = "SkillUsed", source = source, target = target, skill = skill.name }
  local accuracy = skill:getAccuracy()
  if accuracy and accuracy > 0 then
    accuracy = math.min(100, accuracy * logic:getAccuracyMultiplier(source))
    data.missed = not logic.rng:chance(accuracy)
  end
  if data.missed then
    logic:notify{ type = "SkillMissed", source = source, target = target, skill = skill.name }
    if not skill:isStatus() then
      local attack = AttackData:new{ source = source, target = target, skill = skill,
        hits = 0, damage = 0, missed = true, crit = false }
      data.attack = attack
      logic:trigger(A.AttackEnd, target, attack, action)
    end
  else
    if logic:trigger(U.SkillUsed, target, data, action) then data.prevented = true end
    if not data.prevented then
      -- 以技能类别判断，零威力攻击也可能通过效果设定伤害下限。
      if not skill:isStatus() then
        data.attack = logic:resolveAttack(source, skill, target)
        data.success = not data.attack.prevented
      else
        data.success = true
      end
    end
  end
  logic:trigger(U.AfterSkillUse, target, data, action)
  return data
end

---@class GameEvent.UseSkill: GameEvent
---@field data SkillUseData|AttackData
local UseSkill = GameEvent:subclass("GameEvent.UseSkill")

--- 流程事件入口只转发，不再保留第二套公式和 PP 账本。
function UseSkill:main()
  local data = self.data
  local result = run(self.logic, data.source, data.skill, data.target)
  self.data = result
  return result.success
end
GameEvent.UseSkill = UseSkill
return { UseSkill = UseSkill, run = run }
