-- SPDX-License-Identifier: GPL-3.0-or-later
-- 交互模式：lua5.4 packages/seer-core/test/test_min.lua [种子]
-- 最小自动验证：lua5.4 packages/seer-core/test/test_min.lua --auto [种子]
-- 测试对象：王·雷伊（玩家） vs 王·盖亚（自动），走 standard/wang/init.lua 标准包。
-- 不接入 RPC、不改写生产层输入流程；固定玩家操作王·雷伊，王·盖亚在交互模式下自动选招。
local script = debug.getinfo(1, "S").source:sub(2)
local root = script:match("^(.*)/test/test_min%.lua$") or "."
local S = dofile(root .. "/lua/seer.lua")
local standard = dofile(root .. "/standard/wang/init.lua")
S.Seer:postLoad()
local automatic = arg[1] == "--auto"
local seed = automatic and arg[2] or arg[1]
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
    evs = { hp = 252 }, skills = standard.leiyiSkills,
  }
  labGaiya = S.Seer:createPet{
    id = 92, name = "实验室王·盖亚", species = standard.species.gaiya, level = 100,
    evs = { hp = 252 }, skills = standard.gaiyaSkills,
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

--- 实验室检查清单；任何一条不成立就报错。
local function checkEffects()
  -- ① 金翼剑轮：免疫下 1 次受到的攻击（真实攻击流程，命中即整体取消并消耗）
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

  -- ② 惊颤霹雳：公式后追加 500 固定伤害（直接调效果：100 -> 600）
  local dmg = damageData(labLeiyi, labGaiya, skills[19732], 100)
  applyEffect(effects.shock_flat, labLeiyi, labLeiyi, dmg)
  assert(dmg.damage == 600, "惊颤霹雳应附加 500 固定伤害，实际 " .. tostring(dmg.damage))

  -- ②b 再走一次真实攻击流程，从扣血结果上看 +500：
  --     把实验室盖亚体力临时拉高，避免致死时 changeHp 把实际扣血压成剩余体力。
  local savedMax, savedHp = labGaiya.max_hp, labGaiya.hp
  labGaiya.max_hp, labGaiya.hp = 5000, 5000
  labLogic:resolveAttack(labLeiyi, skills[19732], labGaiya)
  local dealt = 5000 - labGaiya.hp
  assert(dealt >= 500, "惊颤霹雳整次攻击扣血应 >= 500（含固定伤害），实际 " .. tostring(dealt))
  labGaiya.max_hp, labGaiya.hp = savedMax, savedHp

  -- ③ 威斗天罡破：对手负等级总和 ×10%（速度 -6 -> 1.6 倍）
  labRoom:changeStatStages(labGaiya, { speed = -6 }, labLeiyi, "测试")
  dmg = damageData(labLeiyi, labGaiya, skills[30157], 1000)
  applyEffect(effects.weidou_boost, labLeiyi, labLeiyi, dmg)
  assert(dmg.damage == 1600, "威斗天罡破增伤应为 1 + 6×10%，实际 " .. tostring(dmg.damage))
  labRoom:clearNegativeStatStages(labGaiya, labLeiyi, "测试")
  assert(labGaiya:getStatStage("speed") == 0, "测试用的负等级应已清掉")

  -- ④ 天威力破：伤害不足 280 的边界（279 触发 / 280 不触发）
  local atk = AttackData:new{ source = labLeiyi, target = labGaiya, skill = skills[30155], damage = 279 }
  assert(effects.tianwei_mark:canTrigger{ logic = labLogic, owner = labLeiyi, source = labLeiyi, data = atk },
    "279 点伤害应触发必致命标记")
  atk.damage = 280
  assert(not effects.tianwei_mark:canTrigger{ logic = labLogic, owner = labLeiyi, source = labLeiyi, data = atk },
    "280 点伤害不应触发必致命标记")

  -- ⑤ 王·联盟审判[追加]：下一次攻击伤害 +100%，且一次性标记用完即摘
  labGaiya.wang_damage_double = { logic = labLogic }
  labGaiya:addEffect(effects.damage_double)
  dmg = damageData(labGaiya, labLeiyi, skills[30185], 400)
  applyEffect(effects.damage_double, labGaiya, labGaiya, dmg)
  assert(dmg.damage == 800, "追加版王·联盟审判应让下一次伤害翻倍，实际 " .. tostring(dmg.damage))
  assert(labGaiya.wang_damage_double == nil, "翻倍标记应被消耗")
  for _, mounted in ipairs(labGaiya:getEffects()) do
    assert(mounted ~= effects.damage_double, "翻倍效果用完应摘掉")
  end
end

-- ============================ 主战局 ============================
buildLab()
checkEffects()

local room = S.BattleRoom:new{ id = 1, pets = standard.pets }
local logic = S.GameLogic:new{ room = room, rng_seed = seed, max_rounds = 50 }
S.Seer:setLogic(logic)
local immuneSeen, gaiyaCritSeen = 0, false

local function chooseTarget(source, skill)
  return skill:getTarget() == "self" and source or logic:pickTarget(source)
end

local function printPet(pet)
  print(("%s：HP %d/%d，攻击 %+d，防御 %+d，速度 %+d"):format(
    pet.name, pet.hp, pet.max_hp, pet:getStatStage("attack"), pet:getStatStage("defense"), pet:getStatStage("speed")))
end

local function byId(source, id)
  for _, skill in ipairs(source:getSkills()) do
    if skill.id == id then return skill end
  end
  return nil
end

-- 自动剧本（按回合；nil = 本回合不出手）：
--   r1 王·雷伊金翼剑轮挂免疫、王·盖亚普攻撞免疫；
--   r2 王·盖亚天威力破（先制3）打出 <280 伤害，挂"下2回合必致命"；
--   r3 王·盖亚天威力破（先制3）必定致命，王·雷伊惊颤霹雳（+500 固定伤害）收尾。
local AUTO_PLAN = {
  [1] = { 19731, 30156 },
  [2] = { nil, 30155 },
  [3] = { 19732, 30155 },
}

function logic:pickAction(source)
  local petSkills = source:getSkills()
  if automatic then
    local plan = AUTO_PLAN[self.round]
    local id = plan and plan[source == wangLeiyi and 1 or 2]
    local skill = id and byId(source, id)
    if skill and self:getPP(source, skill) > 0 then return skill, chooseTarget(source, skill) end
    if plan and plan[source == wangLeiyi and 1 or 2] == nil then return nil, nil end
    -- 剧本走完或没 PP：退回第一个可用技能
    for _, other in ipairs(petSkills) do
      if self:getPP(source, other) > 0 then return other, chooseTarget(source, other) end
    end
    return nil, nil
  end
  if source == wangGaiya then
    -- 简单对手：按顺序轮换技能；无 PP 则尝试下一项。
    for offset = 0, #petSkills - 1 do
      local skill = petSkills[(self.round + offset - 1) % #petSkills + 1]
      if self:getPP(source, skill) > 0 then return skill, chooseTarget(source, skill) end
    end
    return nil, nil
  end

  print(("\n—— 第 %d 回合 ——"):format(self.round))
  printPet(wangLeiyi)
  printPet(wangGaiya)
  local usable = false
  for index, skill in ipairs(petSkills) do
    local pp = self:getPP(source, skill)
    usable = usable or pp > 0
    print(("%d. %s [%s] PP %d/%d%s"):format(index, skill.name,
      skill:isStatus() and "属性" or "攻击", pp, skill:getPP(), skill.desc and (" — " .. skill.desc) or ""))
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
    local skill = index and math.type(index) == "integer" and petSkills[index] or nil
    if skill and self:getPP(source, skill) > 0 then return skill, chooseTarget(source, skill) end
    print("请输入有效编号，并选择还有 PP 的技能。")
  end
end

function logic:on_notify(event)
  if event.type == "SkillUsed" then
    print(("%s 使用 %s → %s"):format(event.source.name, event.skill, event.target.name))
  elseif event.type == "HpChanged" then
    print(("  %s HP %d → %d（%+d，%s）"):format(event.target.name, event.before, event.after, event.num, event.reason))
  elseif event.type == "StatStagesChanged" then
    local changes = {}
    for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do
      if event.changes[field] then changes[#changes + 1] = ("%s %+d"):format(field, event.changes[field]) end
    end
    print(("  %s 能力变化：%s（%s）"):format(event.target.name, table.concat(changes, "，"), event.reason or event.operation))
  elseif event.type == "Damage" then
    if event.crit then print("  致命一击！") end
    if event.source == wangGaiya and event.crit then gaiyaCritSeen = true end
  elseif event.type == "AttackImmune" then
    immuneSeen = immuneSeen + 1
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
  assert(gaiyaCritSeen, "天威力破伤害不足 280 后，下两回合的攻击必须致命一击")
  assert(immuneSeen >= 1, "金翼剑轮的免疫应在整局里至少结算一次")
  print("test_min: PASS")
end
