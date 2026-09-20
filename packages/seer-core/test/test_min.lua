-- SPDX-License-Identifier: GPL-3.0-or-later
-- 交互模式：lua5.4 packages/seer-core/test/test_min.lua [种子]
-- 最小自动验证：lua5.4 packages/seer-core/test/test_min.lua --auto [种子]
-- 测试对象：王·雷伊（玩家） vs 王·盖亚（自动），走 standard/wang/init.lua 标准包。
-- 不接入 RPC、不改写生产层输入流程；固定玩家操作王·雷伊，王·盖亚在交互模式下自动选招。
--
-- 本版技能集合 = 「学习等级最高的四个非第五技能」+ 第五技能（Pet.fifth）：
--   王·雷伊 = 19733 寰宇雷神断 / 24971 传承王意 / 19732 惊颤霹雳 / 24970 万鸣齐闪 + 19734 第五
--   王·盖亚 = 30157 威斗天罡破 / 25184 不败之境 / 30156 极度冲刺 / 25183 战霸天下 + 30158 第五
-- 上一版四个技能（19731 金翼剑轮 / 30122 / 30155 天威力破 / 30185）转为参考技能：
-- 不占格、不挂载，但效果实现保留，下面的实验室检查继续用它们。
local script = debug.getinfo(1, "S").source:sub(2)
local root = script:match("^(.*)/test/test_min%.lua$") or "."
local S = dofile(root .. "/lua/seer.lua")
local standard = dofile(root .. "/standard/wang/init.lua")
S.Seer:postLoad()
local automatic = arg[1] == "--auto"
local seed
if automatic then seed = arg[2] else seed = arg[1] end
seed = tonumber(seed) or seed or 123

local wangLeiyi, wangGaiya = standard.pets[1], standard.pets[2]
local effects, skills = standard.effects, standard.skills

-- ============================ 效果与流程的确定性检查 ============================
-- 随机命中/暴击会让"整局对打"的断言偶尔失效，所以把每条效果的**结算数学**单独
-- 在一个独立实验室战局里验一遍：直接调用效果定义（白盒，但断言确定），
-- 免疫那条走真实的 logic:useSkill 攻击流程（黑盒，王·盖亚的极度冲刺是必中）。
local labLeiyi, labGaiya, labLogic, labRoom

local function buildLab()
  labLeiyi = S.Seer:createPet{
    id = 91, name = "实验室王·雷伊", species = standard.species.leiyi, level = 100,
    evs = { hp = 252 }, skills = standard.leiyiSkills, fifth = standard.fifth.leiyi,
  }
  labGaiya = S.Seer:createPet{
    id = 92, name = "实验室王·盖亚", species = standard.species.gaiya, level = 100,
    evs = { hp = 252 }, skills = standard.gaiyaSkills, fifth = standard.fifth.gaiya,
  }
  labRoom = S.BattleRoom:new{ id = 2, pets = { labLeiyi, labGaiya } }
  labLogic = S.GameLogic:new{ room = labRoom, rng_seed = 7, max_rounds = 10 }
  labLogic:registerEffectSources()
end

--- 直接调某个效果的定义，ctx 只填这个效果真正读的字段。
local function applyEffect(effect, owner, source, data)
  local ctx = { logic = labLogic, room = labRoom, owner = owner, source = source, data = data }
  if effect:canTrigger(ctx) then effect:use(ctx) end
  return ctx
end

local function damageData(source, target, skill, damage)
  return DamageData:new{ source = source, target = target, skill = skill, damage = damage, prevented = false }
end

--- 把所有能力等级清零（实验室里几条检查互相独立，避免上一条的正/负等级串场）。
local function resetStages(pet)
  local changes = {}
  for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do
    local stage = pet:getStatStage(field)
    if stage ~= 0 then changes[field] = -stage end
  end
  if next(changes) ~= nil then labRoom:changeStatStages(pet, changes, labLeiyi, "测试重置") end
end

--- 实验室检查清单；任何一条不成立就报错。
local function checkEffects()
  -- ① 金翼剑轮（参考技能）：免疫下 1 次受到的攻击（真实攻击流程，命中即整体取消并消耗）
  local immuneEvents = 0
  function labLogic:on_notify(evt)
    if evt.type == "AttackImmune" then immuneEvents = immuneEvents + 1 end
  end
  effects.guard_grant:use{ logic = labLogic, room = labRoom, source = labLeiyi, owner = labLeiyi }
  assert(labLeiyi.wang_immune_attacks == 1, "金翼剑轮应挂上 1 次免疫")
  local useData = labLogic:useSkill(labGaiya, skills[30156], labLeiyi)
  assert(useData.attack and useData.attack.prevented, "免疫应整体取消这次攻击")
  assert(labLeiyi.wang_immune_attacks == nil, "免疫次数应在消耗后清零")
  assert(labLeiyi.hp == labLeiyi.max_hp, "被免疫的攻击不应该造成伤害")
  assert(immuneEvents == 1, "免疫应发一条 AttackImmune 通知")

  -- ② 惊颤霹雳：整次攻击后单独造成 500 固定伤害；过量扣血受目标剩余 HP 限制。
  local savedMax, savedHp = labGaiya.max_hp, labGaiya.hp
  labGaiya.max_hp, labGaiya.hp = 5000, 5000
  local fixed = 0
  function labLogic:on_notify(evt)
    if evt.type == "Damage" and evt.kind == "fixed" then fixed = fixed + evt.damage end
  end
  local attack = labLogic:resolveAttack(labLeiyi, skills[19732], labGaiya)
  assert(fixed == 500, "惊颤霹雳应独立结算 500 固定伤害")
  assert(5000 - labGaiya.hp == attack.damage + 500, "攻击伤害与附加伤害不能混算")
  labGaiya.max_hp, labGaiya.hp = savedMax, savedHp
  local dmg

  -- ③ 威斗天罡破：对手负等级总和 ×10%（速度 -6 -> 1.6 倍）
  labRoom:changeStatStages(labGaiya, { speed = -6 }, labLeiyi, "测试")
  dmg = damageData(labLeiyi, labGaiya, skills[30157], 1000)
  applyEffect(effects.weidou_boost, labLeiyi, labLeiyi, dmg)
  assert(dmg.damage == 1600, "威斗天罡破增伤应为 1 + 6×10%，实际 " .. tostring(dmg.damage))
  labRoom:clearNegativeStatStages(labGaiya, labLeiyi, "测试")
  assert(labGaiya:getStatStage("speed") == 0, "测试用的负等级应已清掉")

  -- ④ 天威力破（参考技能）：伤害不足 280 的边界（279 触发 / 280 不触发）
  local atk = AttackData:new{ source = labLeiyi, target = labGaiya, skill = skills[30155], damage = 279 }
  assert(effects.tianwei_mark:canTrigger{ logic = labLogic, owner = labLeiyi, source = labLeiyi, data = atk },
    "279 点伤害应触发必致命标记")
  atk.damage = 280
  assert(not effects.tianwei_mark:canTrigger{ logic = labLogic, owner = labLeiyi, source = labLeiyi, data = atk },
    "280 点伤害不应触发必致命标记")

  -- ⑤ 王·联盟审判[追加]（参考技能）：下一次攻击伤害 +100%，且一次性标记用完即摘
  labGaiya.wang_damage_double = { logic = labLogic }
  labGaiya:addEffect(effects.damage_double)
  dmg = damageData(labGaiya, labLeiyi, skills[30185], 400)
  applyEffect(effects.damage_double, labGaiya, labGaiya, dmg)
  assert(dmg.damage == 800, "追加版王·联盟审判应让下一次伤害翻倍，实际 " .. tostring(dmg.damage))
  assert(labGaiya.wang_damage_double == nil, "翻倍标记应被消耗")
  for _, mounted in ipairs(labGaiya:getEffects()) do
    assert(mounted ~= effects.damage_double, "翻倍效果用完应摘掉")
  end

  -- ⑥ 传承王意（24971）：全属性+1；自身当前体力低于对手时翻倍
  resetStages(labLeiyi)
  labLeiyi.hp, labGaiya.hp = 100, labGaiya.max_hp
  applyEffect(effects.chuancheng_boost, labLeiyi, labLeiyi, nil)
  for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do
    assert(labLeiyi:getStatStage(field) == 2,
      "体力低于对手时传承王意应全属性+2，实际 " .. field .. " = " .. labLeiyi:getStatStage(field))
  end
  resetStages(labLeiyi)
  labLeiyi.hp, labGaiya.hp = labLeiyi.max_hp, 100
  applyEffect(effects.chuancheng_boost, labLeiyi, labLeiyi, nil)
  for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do
    assert(labLeiyi:getStatStage(field) == 1,
      "体力不低于对手时传承王意应全属性+1，实际 " .. field .. " = " .. labLeiyi:getStatStage(field))
  end
  resetStages(labLeiyi)
  labGaiya.hp = labGaiya.max_hp

  -- ⑦ 不败之境（25184）：全属性+1；体力高于最大体力 1/2 时翻倍（恰好一半不算）
  labLeiyi.hp = labLeiyi.max_hp
  applyEffect(effects.bubai_boost, labLeiyi, labLeiyi, nil)
  for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do
    assert(labLeiyi:getStatStage(field) == 2, "满血时不败之境应全属性+2，实际 " .. field)
  end
  resetStages(labLeiyi)
  labLeiyi.hp = math.floor(labLeiyi.max_hp / 2)
  applyEffect(effects.bubai_boost, labLeiyi, labLeiyi, nil)
  for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do
    assert(labLeiyi:getStatStage(field) == 1, "恰好半血时不败之境应全属性+1，实际 " .. field)
  end
  resetStages(labLeiyi)
  labLeiyi.hp = labLeiyi.max_hp

  -- ⑧ 极度冲刺（30156）：反转自身能力下降（组合近似）；正等级与 0 不动
  resetStages(labLeiyi)
  labRoom:changeStatStages(labLeiyi, { speed = -3, attack = -1, defense = 2 }, labGaiya, "测试弱化")
  applyEffect(effects.jidu_reverse, labLeiyi, labLeiyi, nil)
  assert(labLeiyi:getStatStage("speed") == 3, "极度冲刺应把速度 -3 反转为 +3")
  assert(labLeiyi:getStatStage("attack") == 1, "极度冲刺应把攻击 -1 反转为 +1")
  assert(labLeiyi:getStatStage("defense") == 2, "反转不应动正等级")
  -- 没有负等级时再按一次：不产生任何变化
  resetStages(labLeiyi)
  applyEffect(effects.jidu_reverse, labLeiyi, labLeiyi, nil)
  for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do
    assert(labLeiyi:getStatStage(field) == 0, "没有负等级时反转应无变化，实际 " .. field)
  end

  -- ⑨ 万鸣齐闪（24970）：同样是反转换作
  resetStages(labLeiyi)
  labRoom:changeStatStages(labLeiyi, { sp_attack = -2 }, labGaiya, "测试弱化")
  applyEffect(effects.wanming_reverse, labLeiyi, labLeiyi, nil)
  assert(labLeiyi:getStatStage("sp_attack") == 2, "万鸣齐闪应把特攻 -2 反转为 +2")
  resetStages(labLeiyi)

  -- ⑩ 万鸣齐闪增伤数学：每处于**一种**能力提升状态 +10%（两项 -> ×1.2；等级数不算）
  resetStages(labLeiyi)
  labRoom:changeStatStages(labLeiyi, { attack = 2, defense = 1 }, labLeiyi, "测试强化")
  dmg = damageData(labLeiyi, labGaiya, skills[24970], 260)
  applyEffect(effects.wanming_stage_boost, labLeiyi, labLeiyi, dmg)
  assert(dmg.damage == 312,
    "万鸣齐闪应把 260 按两项能力提升 ×1.2 = 312（不是按等级总和 3 项），实际 " .. tostring(dmg.damage))
  resetStages(labLeiyi)

  -- ⑪ 第五技能共同段：伤害不出现微弱（(0,1) 抬回 1；0 与 2 不动）
  dmg = DamageData:new{ source = labLeiyi, target = labGaiya, skill = skills[19734],
    damage = 0, multiplier = 0.5, prevented = false }
  applyEffect(effects.fifth_no_weak, labLeiyi, labLeiyi, dmg)
  assert(dmg.multiplier == 1, "0.5 倍微弱应被抬成 1 倍普通")
  dmg.multiplier = 0.25
  applyEffect(effects.fifth_no_weak, labLeiyi, labLeiyi, dmg)
  assert(dmg.multiplier == 1, "0.25 倍双属性微弱应被抬成 1 倍普通")
  dmg.multiplier = 2
  applyEffect(effects.fifth_no_weak, labLeiyi, labLeiyi, dmg)
  assert(dmg.multiplier == 2, "克制倍率不应被改动")
  dmg.multiplier = 0
  applyEffect(effects.fifth_no_weak, labLeiyi, labLeiyi, dmg)
  assert(dmg.multiplier == 0, "免疫（0 倍）不应被改动")

  -- ⑫ 王·万霆朝宗（19734）：未击败对手则自身全属性+1
  resetStages(labLeiyi)
  labGaiya.hp, labGaiya.fainted = labGaiya.max_hp, false
  atk = AttackData:new{ source = labLeiyi, target = labGaiya, skill = skills[19734], damage = 100, hits = 1 }
  applyEffect(effects.wanting_survive, labLeiyi, labLeiyi, atk)
  for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do
    assert(labLeiyi:getStatStage(field) == 1, "未击败对手时应全属性+1，实际 " .. field)
  end
  resetStages(labLeiyi)
  labGaiya.hp, labGaiya.fainted = 0, true -- 已击败：不触发
  applyEffect(effects.wanting_survive, labLeiyi, labLeiyi, atk)
  for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do
    assert(labLeiyi:getStatStage(field) == 0, "已击败对手时不应再强化，实际 " .. field)
  end
  labGaiya.hp, labGaiya.fainted = labGaiya.max_hp, false

  -- ⑬ 王·圣勇战意（30158）：吸取对手能力提升状态（对手清正等级、自己得同额）
  resetStages(labLeiyi)
  resetStages(labGaiya)
  labRoom:changeStatStages(labLeiyi, { attack = 2, speed = 1 }, labGaiya, "测试强化")
  atk = AttackData:new{ source = labGaiya, target = labLeiyi, skill = skills[30158], damage = 100, hits = 1 }
  applyEffect(effects.shengyong_steal, labGaiya, labGaiya, atk)
  assert(labLeiyi:getStatStage("attack") == 0 and labLeiyi:getStatStage("speed") == 0,
    "被吸取的一方应失去能力提升")
  assert(labGaiya:getStatStage("attack") == 2 and labGaiya:getStatStage("speed") == 1,
    "吸取的一方应获得同额能力提升")
  resetStages(labLeiyi)
  resetStages(labGaiya)
end

-- ============================ 主战局 ============================
buildLab()
checkEffects()

local room = S.BattleRoom:new{ id = 1, pets = standard.pets }
local logic = S.GameLogic:new{ room = room, rng_seed = seed, max_rounds = 50 }
S.Seer:setLogic(logic)
local usedSkillIds, fifthSeen = {}, {}
local buffSeen = {}
local roundSkillOrder, chosenRound = {}, 1

local function chooseTarget(source, skill)
  return skill:getTarget() == "self" and source or logic:pickTarget(source)
end

local function printPet(pet)
  print(("%s：HP %d/%d，攻击 %+d，防御 %+d，速度 %+d"):format(
    pet.name, pet.hp, pet.max_hp, pet:getStatStage("attack"), pet:getStatStage("defense"), pet:getStatStage("speed")))
end

--- 普通四格 + 第五技能：第五技能不占格，但演示里应当能选。
local function selectableSkills(source)
  local ret = {}
  for _, skill in ipairs(source:getSkills()) do ret[#ret + 1] = skill end
  local fifth = source:getFifthSkill()
  if fifth ~= nil then ret[#ret + 1] = fifth end
  return ret
end

local function byId(source, id)
  for _, skill in ipairs(selectableSkills(source)) do
    if skill.id == id then return skill end
  end
  return nil
end

local function idOfName(source, name)
  for _, skill in ipairs(selectableSkills(source)) do
    if skill.name == name then return skill.id end
  end
  return nil
end

-- 自动剧本（按回合；nil = 本回合不出手）。排序依据：
--   * 王·雷伊先手（速度 130 > 125），连续两回合传承王意把能力堆到 +4（r2 那次是
--     "体力低于对手故翻倍"）；王·盖亚的 30157 / 30156 / 30158 三段伤害必须发生在
--     它自己 25184 之前，免得多出来的攻击强化放大伤害；
--   * 王·盖亚的 30158（吸取能力提升）会把王·雷伊的能力提升吸走，正好让王·雷伊
--     后面的攻击不强化，保证王·盖亚能撑到自己第五个技能；
--   * 王·雷伊的两次攻击（王·万霆朝宗 / 寰宇雷神断）分开放，中间让王·盖亚用 25184
--     把防御补回来（致命一击会清掉正防御等级），避免提前击杀；
--   * 王·雷伊的 19732（+500 固定伤害）是收尾技，放在最后一个出手。
--   r1 王·雷伊传承王意 / 王·盖亚威斗天罡破
--   r2 王·雷伊传承王意（再堆一层）/ 王·盖亚极度冲刺
--   r3 王·雷伊万鸣齐闪（先制3）/ 王·盖亚第五王·圣勇战意（吸走王·雷伊的强化）
--   r4 王·雷伊跳过 / 王·盖亚战霸天下
--   r5 王·雷伊跳过 / 王·盖亚不败之境
--   r6 王·雷伊第五王·万霆朝宗 / 王·盖亚跳过
--   r7 王·雷伊跳过 / 王·盖亚不败之境（补回被致命一击清掉的防御）
--   r8 王·雷伊寰宇雷神断 / 王·盖亚跳过
--   r9 王·雷伊惊颤霹雳（+500 固定伤害收尾）/ 王·盖亚跳过
local AUTO_PLAN = {
  [1] = { 24971, 30157 },
  [2] = { 24971, 30156 },
  [3] = { 24970, 30158 },
  [4] = { nil, 25183 },
  [5] = { nil, 25184 },
  [6] = { 19734, nil },
  [7] = { nil, 25184 },
  [8] = { 19733, nil },
  [9] = { 19732, nil },
}

function logic:pickAction(source)
  chosenRound = self.round
  local petSkills = source:getSkills()
  if automatic then
    local plan = AUTO_PLAN[self.round]
    local index = source == wangLeiyi and 1 or 2
    local skill = plan and plan[index] and byId(source, plan[index])
    if skill and self:getPP(source, skill) > 0 then return skill, chooseTarget(source, skill) end
    if plan and plan[index] == nil then return nil, nil end
    -- 剧本走完或没 PP：退回第一个可用技能
    for _, other in ipairs(petSkills) do
      if self:getPP(source, other) > 0 then return other, chooseTarget(source, other) end
    end
    return nil, nil
  end
  if source == wangGaiya then
    -- 简单对手：按顺序轮换技能（含第五技能）；无 PP 则尝试下一项。
    local choices = selectableSkills(source)
    for offset = 0, #choices - 1 do
      local skill = choices[(self.round + offset - 1) % #choices + 1]
      if self:getPP(source, skill) > 0 then return skill, chooseTarget(source, skill) end
    end
    return nil, nil
  end

  print(("\n—— 第 %d 回合 ——"):format(self.round))
  printPet(wangLeiyi)
  printPet(wangGaiya)
  local choices = selectableSkills(source)
  local usable = false
  for index, skill in ipairs(choices) do
    local pp = self:getPP(source, skill)
    usable = usable or pp > 0
    print(("%d. %s [%s] PP %d/%d%s%s"):format(index, skill.name,
      skill:isStatus() and "属性" or "攻击", pp, skill:getPP(),
      skill == source:getFifthSkill() and "（第五技能）" or "",
      skill.desc and (" — " .. skill.desc) or ""))
  end
  if not usable then print("技能 PP 已用尽，本回合无法行动。") return nil, nil end
  while true do
    io.write("选择王·雷伊的技能编号（q 退出）：")
    io.flush()
    local input = io.read("*l")
    if input == nil or input:match("^%s*[qQ]%s*$") then
      self:finishGame(nil, "user_exit")
      return nil, nil
    end
    local index = tonumber(input)
    local skill = index and math.type(index) == "integer" and choices[index] or nil
    if skill and self:getPP(source, skill) > 0 then return skill, chooseTarget(source, skill) end
    print("请输入有效编号，并选择还有 PP 的技能。")
  end
end

function logic:on_notify(event)
  if event.type == "SkillUsed" then
    local id = idOfName(event.source, event.skill)
    if id ~= nil then usedSkillIds[id] = true end
    local fifth = event.source:getFifthSkill()
    if fifth ~= nil and id == fifth.id then fifthSeen[event.source] = true end
    local order = roundSkillOrder[chosenRound]
    if order == nil then order = {}; roundSkillOrder[chosenRound] = order end
    table.insert(order, event.skill)
    print(("%s 使用 %s → %s"):format(event.source.name, event.skill, event.target.name))
  elseif event.type == "HpChanged" then
    print(("  %s HP %d → %d（%+d，%s）"):format(event.target.name, event.before, event.after, event.num, event.reason))
  elseif event.type == "StatStagesChanged" then
    if event.reason == "传承王意·全属性强化" and (event.changes.attack or 0) > 0 then buffSeen.chuancheng = true end
    if event.reason == "不败之境·全属性强化" and (event.changes.attack or 0) > 0 then buffSeen.bubai = true end
    local changes = {}
    for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do
      if event.changes[field] then changes[#changes + 1] = ("%s %+d"):format(field, event.changes[field]) end
    end
    print(("  %s 能力变化：%s（%s）"):format(event.target.name, table.concat(changes, "，"), event.reason or event.operation))
  elseif event.type == "Damage" then
    if event.crit then print("  致命一击！") end
  elseif event.type == "AttackImmune" then
    print(("  %s 免疫了 %s 的 %s"):format(event.target.name, event.source.name, event.skill))
  elseif event.type == "DamagePrevented" then
    print(("  %s 的伤害被免疫。"):format(event.target.name))
  elseif event.type == "ActionSkipped" then
    print(("  %s 本回合未出手。"):format(event.source.name))
  elseif event.type == "SkillMissed" then
    print("  技能未命中。")
  end
end

print("王·雷伊（玩家） vs 王·盖亚（自动） | 种子 " .. tostring(seed))
local result = logic:run()
print(("\n结果：%s（%s），%d 回合"):format(
  result.winner and standard.pets[result.winner].name .. "获胜" or "战斗结束", result.reason, result.round))
printPet(wangLeiyi)
printPet(wangGaiya)
if automatic then
  -- 剧本把 8 个普通技能与两个第五技能都真的用了一遍
  for _, id in ipairs({ 19733, 24971, 19732, 24970, 30157, 25184, 30156, 25183 }) do
    assert(usedSkillIds[id], "剧本应真实用到技能 " .. tostring(id))
  end
  assert(fifthSeen[wangLeiyi], "王·雷伊的第五技能应在剧本里出手")
  assert(fifthSeen[wangGaiya], "王·盖亚的第五技能应在剧本里出手")
  -- 万鸣齐闪先制 3：它所在的那一回合必须最先出手
  local wanmingFirst = false
  for _, order in pairs(roundSkillOrder) do
    if order[1] == "万鸣齐闪" then wanmingFirst = true end
  end
  assert(wanmingFirst, "万鸣齐闪先制 3 应在所在回合先手")
  -- 两个新强化技（传承王意 / 不败之境）确实留下了正等级
  assert(buffSeen.chuancheng, "传承王意应结算出攻击正等级")
  assert(buffSeen.bubai, "不败之境应结算出攻击正等级")
  print("test_min: PASS")
end
