-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ standard/wang：王·雷伊 / 王·盖亚 ============================
--
-- 这是 standard/ 下的**新增入口**（不替换 standard/init.lua 的旧演示包）：
-- 先加载 lua/seer.lua，再 dofile 本文件，会注册两个种族、八个技能与对应效果，
-- 并造出两只 100 级精灵，返回：
--
--   effects  —— 效果名 -> Effect
--   skills   —— 技能编号 -> Skill
--   species  —— 王·雷伊 / 王·盖亚 的 PetSpecies
--   pets     —— { [1] = 王·雷伊, [2] = 王·盖亚 }（顺序和 test_min 的分边一致）
--
-- ---------------------------- 官方数据 ----------------------------
--
-- 王·雷伊：图鉴 3142，电，种族值 体力151/攻击130/防御110/特攻70/特防109/速度130
-- 王·盖亚：图鉴 3242，战斗，种族值 体力156/攻击130/防御105/特攻70/特防104/速度125
--
-- ---------------------------- 「最后学会的四个」怎么选 ----------------------------
--
-- 依据 Lead 从 biligame 原始技能串核实的结论：
--
--   王·雷伊：…20363-85;20364-86;19729-87;19730-88;24969-89;19731-90-1;24970-91-1;
--            19732-92;24971-93-1;19733-94-1;30122-0-追加;19734-95-第五
--   王·盖亚：…17493-61;30155-71-1;25183-72-1;30156-73;25184-74-1;30157-75-1;
--            30185-0-追加;30158-76-第五
--
-- 两只精灵都各只有 3 个普通技能格，另各有一个「追加」技能与一个「第五」技能
-- （追加与第五都不占普通四格）。所以四个主要技能取：
--
--   王·雷伊 = 19733 寰宇雷神断(94) + 19732 惊颤霹雳(92) + 19731 金翼剑轮(90) + 30122 王·联盟审判(追加)
--   王·盖亚 = 30157 威斗天罡破(75) + 30156 极度冲刺(73) + 30155 天威力破(71) + 30185 王·联盟审判(追加)
--
-- 24970 万鸣齐闪(91)、24971(93) 等带 -1 标记的条目按 Lead 判定作为参考技能，
-- 不占四格；第五技能 19734 / 30158 的 wiki 数据未核实（名称/数值都缺），
-- 这里**不挂 fifth**，也不编造数值，见 docs/unimplemented-effects.md。

local effects = dofile(Seer:resolvePath("standard/wang/effects.lua"))
local createSkills = dofile(Seer:resolvePath("standard/wang/skills.lua"))
local skills = createSkills(effects)

local leiyiSpecies = Seer:addSpecies{
  id = 3142, name = "王·雷伊", elements = { "电" },
  base_stats = { hp = 151, attack = 130, defense = 110, sp_attack = 70, sp_defense = 109, speed = 130 },
}
local gaiyaSpecies = Seer:addSpecies{
  id = 3242, name = "王·盖亚", elements = { "战斗" },
  base_stats = { hp = 156, attack = 130, defense = 105, sp_attack = 70, sp_defense = 104, speed = 125 },
}

-- 技能顺序：三个普通技能 + 追加技能（追加占第 4 格）。
local leiyiSkills = {
  skills[19733], skills[19732], skills[19731], skills[30122],
}
local gaiyaSkills = {
  skills[30157], skills[30156], skills[30155], skills[30185],
}

-- 配点（学习力）不是图鉴数据：这里给王·雷伊体力+防御、王·盖亚体力，
-- 让演示与自动测试的场景在任意随机种子下都稳定（被高威力技能打时不至于一回合暴毙，
-- 也让"下2回合必致命"有足够回合数跑完）。
local leiyi = Seer:createPet{
  id = 1, species = leiyiSpecies, level = 100,
  evs = { hp = 252, defense = 252 }, skills = leiyiSkills,
}
local gaiya = Seer:createPet{
  id = 2, species = gaiyaSpecies, level = 100, evs = { hp = 252 }, skills = gaiyaSkills,
}

return {
  effects = effects,
  skills = skills,
  species = { leiyi = leiyiSpecies, gaiya = gaiyaSpecies },
  leiyiSkills = leiyiSkills,
  gaiyaSkills = gaiyaSkills,
  pets = { leiyi, gaiya },
  leiyi = leiyi,
  gaiya = gaiya,
}
