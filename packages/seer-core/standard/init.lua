-- SPDX-License-Identifier: GPL-3.0-or-later
-- 最小战斗示例入口；先加载 lua/seer.lua，再执行本文件。
-- 依次通过 Seer API 注册效果、技能、种族和精灵实例，返回可直接交给房间的双方精灵。
-- 每次执行都会创建新的局内精灵，技能/效果名及 id 相同的引擎条目会被重新注册。

local effects = {
  damage_up = dofile(Seer:resolvePath("standard/effects/damage_up.lua")),
  attack_up = dofile(Seer:resolvePath("standard/effects/attack_up.lua")),
  recover_hp = dofile(Seer:resolvePath("standard/effects/recover_hp.lua")),
}
local createSkills = dofile(Seer:resolvePath("standard/skills/init.lua"))
local skills = createSkills(effects)
effects.thunder_awakening = dofile(Seer:resolvePath("standard/effects/thunder_awakening.lua"))
local awakening = dofile(Seer:resolvePath("standard/skills/thunder_awakening.lua"))(effects.thunder_awakening)
-- 雷伊以雷神觉醒替换第二槽演示强攻，盖亚保留四个原演示技能。
local leiyiSkills = { skills[1], awakening, skills[3], skills[4] }

-- 沿用项目原 standard/species.lua 的种族编号、属性和种族值。
local leiyiSpecies = Seer:addSpecies{
  id = 70, name = "雷伊", elements = { "电" },
  base_stats = { hp = 71, attack = 108, defense = 70, sp_attack = 101, sp_defense = 77, speed = 105 },
}
local gaiyaSpecies = Seer:addSpecies{
  id = 261, name = "盖亚", elements = { "战斗" },
  base_stats = { hp = 105, attack = 119, defense = 87, sp_attack = 96, sp_defense = 78, speed = 105 },
}
local leiyi = Seer:createPet{ id = 1, species = leiyiSpecies, level = 100, skills = leiyiSkills }
local gaiya = Seer:createPet{ id = 2, species = gaiyaSpecies, level = 100, skills = skills }

return {
  effects = effects,
  skills = skills,
  pets = { leiyi, gaiya },
  awakening = awakening,
}
