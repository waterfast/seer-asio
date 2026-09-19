-- SPDX-License-Identifier: GPL-3.0-or-later
-- 命令行最小战斗：lua5.4 packages/seer-core/test/test_min.lua [随机种子]
-- 也可在包目录执行 lua5.4 test/test_min.lua；路径从脚本自身推导。
-- standard 负责注册测试内容；这里仅创建房间、提供自动行动和打印/断言结果。
local script = debug.getinfo(1, "S").source:sub(2)
local root = script:match("^(.*)/test/test_min%.lua$") or "."
local S = dofile(root .. "/lua/seer.lua")
local standard = dofile(root .. "/standard/init.lua")
S.Seer:postLoad() -- 显式加载 standard 后，再打印实际注册数量。
local seed = tonumber(arg[1]) or arg[1] or 123
local pets, skills = standard.pets, standard.skills

-- 通过 Seer 入口创建的内容必须能从引擎按 id 找回，双方技能引用同一套定义。
local effectCount = 0
for _, effect in pairs(standard.effects) do
  assert(S.Seer:getEffectById(effect:getId()) == effect)
  effectCount = effectCount + 1
end
assert(effectCount == 3 and #skills == 4 and #pets == 2)
for i, skill in ipairs(skills) do
  assert(S.Seer:getSkillById(skill:getId()) == skill)
  assert(#skill:getEffects() == (i == 4 and 3 or 1))
end
for _, pet in ipairs(pets) do
  assert(S.Seer:getPetById(pet:getId()) == pet)
  assert(S.Seer:getSpeciesById(pet:getSpecies():getId()) == pet:getSpecies())
  for i, skill in ipairs(skills) do assert(pet:getSkills()[i] == skill) end
  for _, field in ipairs(S.Pet.STAT_STAGE_FIELDS) do assert(pet:getStatStage(field) == 0) end
  local snapshot = pet:getStatStages()
  snapshot.attack = 6
  assert(pet:getStatStage("attack") == 0, "getter 必须返回快照")
end
assert(pets[1].stat_stages ~= pets[2].stat_stages, "双方不能共享能力等级")

-- 双方精灵直接交给 BattleRoom，GameLogic 从房间读取，不经过 RPC 或会话层。
local room = S.BattleRoom:new{ id = 1, pets = pets }
local logic = S.GameLogic:new{ room = room, rng_seed = seed, max_rounds = 8 }
S.Seer:setLogic(logic)
local actions, healing = {}, 0
local initialAttack = { pets[1]:getStat("attack"), pets[2]:getStat("attack") }

-- 测试专用决策：每方按技能栏顺序循环出招，保证单效果和组合效果均实际参战。
-- 默认核心只选第一个可用攻击技，因此测试在实例上提供自己的决策，不修改核心文件。
function logic:pickAction(source)
  local index = (self.round - 1) % #skills + 1
  local skill = source:getSkills()[index]
  local target = self:pickTarget(source)
  assert(self:getPP(source, skill) > 0 and target ~= nil)
  actions[source] = actions[source] or {}
  actions[source][index] = (actions[source][index] or 0) + 1
  print(("回合 %d | %s 使用 %s → %s（攻击等级 %+d）"):format(
    self.round, source:getName(), skill:getName(), target:getName(), source:getStatStage("attack")))
  return skill, target
end

function logic:on_notify(event)
  if event.type == "HpChanged" then
    print(("  %s 体力 %d → %d / %d（%+d，%s）"):format(
      event.target:getName(), event.before, event.after, event.target.max_hp, event.num, event.reason))
    if event.reason == standard.effects.recover_hp:getName() then
      local expected = math.min(math.floor(event.target.max_hp / 3), event.target.max_hp - event.before)
      assert(event.num == expected and expected > 0, "恢复量应为最大体力的 1/3，受满血上限限制")
      healing = healing + 1
    end
  else
    print("  " .. event.type)
  end
end

print(("\n雷伊 vs 盖亚 | 种子 %s | 四技能循环，最多 8 回合"):format(tostring(seed)))
local result = logic:run()
local winner = result.winner and pets[result.winner]:getName() or "平局"
print(("\n结果：%s，原因 %s，共 %d 回合"):format(winner, result.reason, result.round))

-- 用真实事件记录验证最终伤害；基础伤害按同一份随机参数重算，不重复掷骰。
local damageCounts = {}
for _, event in ipairs(logic.event_log) do
  if event.class == S.SeerTiming.AfterDamageCalculate then
    local data = event.data
    local base = logic:damageFormula(data)
    local boosted = data.skill == skills[1] or data.skill == skills[4]
    assert(data.damage == (boosted and math.floor(base * 1.5) or base), "伤害提升比例错误")
    damageCounts[data.skill] = (damageCounts[data.skill] or 0) + 1
  end
end
assert(result.round == 8 and result.reason == "max_rounds")
assert(healing > 0, "必须实际发生体力恢复")
for i, pet in ipairs(pets) do
  for index, skill in ipairs(skills) do
    assert(actions[pet][index] == 2 and damageCounts[skill] == 4, "四个技能都应完整结算")
    assert(logic:getPP(pet, skill) == skill:getPP() - 2)
  end
  assert(pet:getStatStage("attack") == 4, "强攻和组合技各两次，应累计攻击 +4")
  assert(pet:getStat("attack") == initialAttack[i], "能力等级暂不改变面板")
  print(("%s：体力 %d/%d，攻击等级 %+d"):format(pet:getName(), pet.hp, pet.max_hp, pet:getStatStage("attack")))
end

-- 等级封顶与满血/濒死不恢复的边界，仍通过统一 trigger 执行。
local left = pets[1]
local savedHp, savedFainted, savedStage = left.hp, left.fainted, left:getStatStage("attack")
left.stat_stages.attack = S.Pet.STAT_STAGE_MAX
left.hp = left.max_hp
local beforeHealing = healing
logic:trigger(S.SeerTiming.AfterAttack, pets[2], AttackData:new{ source = left }, { source = left, skill = skills[4] })
assert(left:getStatStage("attack") == 6 and healing == beforeHealing)
left.hp, left.fainted = 0, true
logic:trigger(S.SeerTiming.AfterAttack, pets[2], AttackData:new{ source = left }, { source = left, skill = skills[4] })
assert(left.hp == 0 and healing == beforeHealing)
left.hp, left.fainted, left.stat_stages.attack = savedHp, savedFainted, savedStage
print("test_min: PASS（注册、三种效果、组合、能力等级、恢复边界、PP、完整战斗）")
