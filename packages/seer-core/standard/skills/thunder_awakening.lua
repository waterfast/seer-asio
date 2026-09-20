-- SPDX-License-Identifier: GPL-3.0-or-later
-- 雷神觉醒为属性技能；本项目依用户要求附加三回合致命效果，区别于原图鉴的仅强化版本。
---@param effect Effect
---@return Skill
return function(effect)
  return Seer:createSkill{
    id = 20364, name = "雷神觉醒", category = Skill.Status, target = "self",
    power = 0, pp = 20, accuracy = 0, effects = { effect },
    desc = "攻击、速度等级+2；含当前回合的3回合内暴击率增加100个百分点，重复使用刷新持续时间。",
  }
end
