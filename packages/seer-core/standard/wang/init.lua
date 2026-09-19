-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ standard/wang：王·雷伊 / 王·盖亚 ============================
--
-- 这是 standard/ 下的**新增入口**（不替换 standard/init.lua 的旧演示包）：
-- 先加载 lua/seer.lua，再 dofile 本文件，会注册两个种族、全部技能与对应效果，
-- 并造出两只 100 级精灵，返回：
--
--   effects  —— 效果名 -> Effect
--   skills   —— 技能编号 -> Skill（含参考技能）
--   species  —— 王·雷伊 / 王·盖亚 的 PetSpecies
--   pets     —— { [1] = 王·雷伊, [2] = 王·盖亚 }（顺序和 test_min 的分边一致）
--   fifth    —— { leiyi = 19734, gaiya = 30158 }（第五技能，挂在 Pet.fifth 上）
--
-- ---------------------------- 官方数据 ----------------------------
--
-- 王·雷伊：图鉴 3142，电，种族值 体力151/攻击130/防御110/特攻70/特防109/速度130
-- 王·盖亚：图鉴 3242，战斗，种族值 体力156/攻击130/防御105/特攻70/特防104/速度125
--
-- ---------------------------- 「最后学会的四个」怎么选（本版口径）------------------------
--
-- 用户原话的字面读法：**学习等级最高的四个非第五技能**。依据原始技能串
--（Lead 从 biligame action=raw 逐条核实）：
--
--   王·雷伊：…19731-90-1;24970-91-1;19732-92;24971-93-1;19733-94-1;30122-0-追加;19734-95-第五
--   王·盖亚：…30155-71-1;25183-72-1;30156-73;25184-74-1;30157-75-1;30185-0-追加;30158-76-第五
--
--（每条 `技能ID-学习等级`，`追加` 是追加技能、`第五` 是第五技能，二者都不占普通四格）
--
-- 取等级最高的四个非第五技能：
--
--   王·雷伊 = 19733 寰宇雷神断(94) / 24971 传承王意(93) / 19732 惊颤霹雳(92) / 24970 万鸣齐闪(91)
--   王·盖亚 = 30157 威斗天罡破(75) / 25184 不败之境(74) / 30156 极度冲刺(73) / 25183 战霸天下(72)
--
-- 第五技能不占四格，用 Pet 的 `fifth` 字段单独挂：
--
--   王·雷伊 fifth = 19734 王·万霆朝宗（95）    王·盖亚 fifth = 30158 王·圣勇战意（76）
--
-- 上一版按「3 个本系主技能 + 追加技能」取到的 19731 金翼剑轮(90)、30122 王·联盟审判[追加]、
-- 30155 天威力破(71)、30185 王·联盟审判[追加] 现在**降级为参考技能**：不占四格、不挂载，
-- 但定义与效果实现都保留在 skills.lua / effects.lua，供 test_min 的确定性检查使用。

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

-- 四技能：学习等级最高的四个非第五技能。
local leiyiSkills = {
  skills[19733], skills[24971], skills[19732], skills[24970],
}
local gaiyaSkills = {
  skills[30157], skills[25184], skills[30156], skills[25183],
}

-- 配点（学习力）与性格不是图鉴数据：给王·雷伊体力+防御（性格"大胆"：防御+10%/攻击-10%）、
-- 王·盖亚体力+防御（性格"马虎"：特攻+10%/攻击-10%）。目的是让演示与自动测试的场景在
-- 任意随机种子下都稳定：被高威力技能打时不至于一回合暴毙，也让 test_min 剧本里的四个技能
-- 与第五技能都能真的走到，不因一次致命一击提前结束。
local leiyi = Seer:createPet{
  id = 1, species = leiyiSpecies, level = 100, nature = "大胆",
  evs = { hp = 252, defense = 252 }, skills = leiyiSkills,
  fifth = skills[19734],
}
local gaiya = Seer:createPet{
  id = 2, species = gaiyaSpecies, level = 100, nature = "马虎",
  evs = { hp = 252, defense = 252 }, skills = gaiyaSkills,
  fifth = skills[30158],
}

return {
  effects = effects,
  skills = skills,
  species = { leiyi = leiyiSpecies, gaiya = gaiyaSpecies },
  leiyiSkills = leiyiSkills,
  gaiyaSkills = gaiyaSkills,
  fifth = { leiyi = skills[19734], gaiya = skills[30158] },
  -- 参考技能（不占四格、未挂载，效果仍在 effects 与 skills 里可用）：
  referenceSkillIds = { 19731, 30122, 30155, 30185 },
  pets = { leiyi, gaiya },
  leiyi = leiyi,
  gaiya = gaiya,
}
