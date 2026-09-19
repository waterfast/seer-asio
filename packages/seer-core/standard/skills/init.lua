-- SPDX-License-Identifier: GPL-3.0-or-later
-- 演示技能，名称与编号均为测试数据，不对应官方技能。
-- 四个技能使用相同的攻击数值，区别只在效果组合，便于直接比较结算结果。
-- 当前核心按攻击流程结算，因此强化/回复也作为攻击附带效果演示。
-- 由 standard/init.lua 在注册效果后调用本文件，传入三个效果实例。
---@param effects table<string, Effect>
---@return Skill[]
local function createSkills(effects)
  local definitions = {
    { id = 90001, name = "演示·增伤", effects = { effects.damage_up } },
    { id = 90002, name = "演示·强攻", effects = { effects.attack_up } },
    { id = 90003, name = "演示·回复", effects = { effects.recover_hp } },
    { id = 90004, name = "演示·三效合一",
      effects = { effects.damage_up, effects.attack_up, effects.recover_hp } },
  }
  local skills = {}
  for i, spec in ipairs(definitions) do
    spec.category = Skill.Physical
    spec.element = "普通"
    spec.power = 20
    spec.pp = 20
    spec.accuracy = 0 -- 必中，让最小测试专注于效果组合。
    skills[i] = Seer:createSkill(spec)
  end
  return skills
end

return createSkills
