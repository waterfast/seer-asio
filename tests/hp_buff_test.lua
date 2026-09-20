-- SPDX-License-Identifier: GPL-3.0-or-later
-- 最小战斗规则回归：lua tests/hp_buff_test.lua（从仓库根目录）。无网络、无完整项目启动。
local S = dofile('packages/seer-core/lua/seer.lua')
Log.min_level = 'error'
local E = require 'core.events'
local H, A, G, B = E.hp, E.attack, E.gameflow, E.buff
local species = S.PetSpecies:new{
  name = 'HP测试种族', elements = { '普通' },
  base_stats = { hp = 200, attack = 80, defense = 80, sp_attack = 80, sp_defense = 80, speed = 80 },
}
local function battle(skills)
  local left = S.Pet:new{ name = '左', species = species, level = 100, skills = skills or {} }
  local right = S.Pet:new{ name = '右', species = species, level = 100 }
  local logic = S.GameLogic:new{ pets = { left, right }, max_rounds = 4, rng_seed = 123 }
  logic.on_notify = function() end
  logic:registerEffectSources()
  logic.round = 1
  return logic, logic.room, left, right
end
local function watch(object, timing, use, priority)
  local effect = S.Effect:new{ id = timing.name, timing = timing, priority = priority,
    on_use = function(_, ctx) return use(ctx) end }
  object:addEffect(effect)
  return effect
end
local passed = 0
local function check(name, fn)
  fn()
  passed = passed + 1
  print('ok - ' .. name)
end

check('固定伤害、回复、直接改血分别触发规则时机，共用 HP 链', function()
  local logic, room, left, right = battle()
  local names = {}
  for _, timing in ipairs{ H.BeforeDamage, H.BeforeHpChange, H.AfterHpChange, H.AfterDamage,
    H.DamageResolved, H.BeforeRecover, H.AfterRecover, A.BeforeAttack } do
    watch(room, timing, function(ctx)
      names[#names + 1] = timing.name
      assert(ctx.source == left and ctx.target == right)
    end)
  end
  local damage = room:damage{ source = left, target = right, kind = 'fixed', damage = 30 }
  assert(damage.actual == 30 and damage.hp_change.parent == damage)
  assert(table.concat(names, ',') == 'BeforeDamage,BeforeHpChange,AfterHpChange,AfterDamage,DamageResolved')
  names = {}
  local heal = room:recover{ source = left, target = right, num = 10 }
  assert(heal.actual == 10)
  assert(table.concat(names, ',') == 'BeforeRecover,BeforeHpChange,AfterHpChange,AfterRecover')
  names = {}
  assert(room:changeHp{ source = left, target = right, num = -7 }.actual == -7)
  assert(table.concat(names, ',') == 'BeforeHpChange,AfterHpChange')
  assert(right.hp == right.max_hp - 27)
end)

check('数值向零取整、零请求与满血回复不制造 HP 变化', function()
  local logic, room, _, right = battle()
  local changed = 0
  watch(room, H.AfterHpChange, function() changed = changed + 1 end)
  assert(logic:damage{ target = right, damage = 0.5 }.actual == 0)
  assert(room:changeHp{ target = right, num = -0.5 }.actual == 0)
  assert(room:recover{ target = right, num = 20 }.actual == 0)
  assert(changed == 0)
  assert(not pcall(function() room:changeHp{ target = right, num = math.huge } end))
end)

check('禁疗、伤害免疫、锁血分别在各自前置时机生效', function()
  local _, room, left, right = battle()
  room:changeHp{ target = right, num = -100 }
  watch(right, H.BeforeRecover, function(ctx) ctx.data.prevented = true end)
  assert(room:recover{ target = right, source = left, num = 80 }.actual == 0)
  local shield = watch(right, H.BeforeDamage, function(ctx) ctx.data:preventDamage() end)
  assert(room:damage{ target = right, damage = 100 }.actual == 0)
  right:removeEffect(shield)
  watch(right, H.BeforeHpChange, function(ctx)
    ctx.data.num = math.max(ctx.data.num, 1 - ctx.target.hp)
  end)
  assert(room:damage{ target = right, damage = 99999 }.actual == right.max_hp - 101)
  assert(right.hp == 1 and not right.fainted)
  assert(room:changeHp{ target = right, num = -100 }.actual == 0)
end)

check('嵌套前置改血不丢失，后置回血不污染原伤害 actual', function()
  local _, room, left, right = battle()
  room:changeHp{ target = right, num = -100 }
  watch(right, H.BeforeHpChange, function(ctx)
    if ctx.data.kind == 'damage' then room:recover{ source = left, target = right, num = 10 } end
  end)
  watch(right, H.AfterHpChange, function(ctx)
    if ctx.data.kind == 'damage' then room:recover{ source = left, target = right, num = 5 } end
  end)
  local data = room:damage{ source = left, target = right, damage = 30 }
  assert(data.actual == 30 and data.hp_change.actual == -30)
  assert(data.hp_change.before == right.max_hp - 90)
  assert(data.hp_change.after == right.max_hp - 120)
  assert(right.hp == right.max_hp - 115)
end)

check('过量伤害取实际值，归零只触发一次，普通回复不复活', function()
  local logic, room, _, right = battle()
  local zeros, deaths = 0, 0
  watch(right, H.HpReducedToZero, function(ctx)
    zeros = zeros + 1
    assert(ctx.data.after == 0 and ctx.owner.fainted)
  end)
  logic.on_notify = function(_, evt) if evt.type == 'PetFainted' then deaths = deaths + 1 end end
  local damage = room:damage{ target = right, kind = 'percent', damage = 99999 }
  assert(damage.actual == right.max_hp and right.hp == 0)
  assert(room:damage{ target = right, damage = 10 }.actual == 0)
  assert(room:recover{ target = right, num = 100 }.actual == 0)
  assert(room:changeHp{ target = right, num = 100 }.actual == 0)
  assert(zeros == 1 and deaths == 1)
end)

check('反伤可独立结算，不继承触发它的技能候选效果', function()
  local skill = S.Skill:new{ name = '测试攻击', power = 40, accuracy = 0 }
  local logic, room, left, right = battle{ skill }
  local seen = 0
  watch(skill, H.BeforeDamage, function(ctx) seen = seen + 1; assert(ctx.data.kind == 'attack') end)
  watch(right, H.AfterDamage, function(ctx)
    if ctx.data.target == right and not ctx.data.parent_reflection then
      local data = room:damage{ source = right, target = left, kind = 'fixed', damage = 17,
        parent = ctx.data, parent_reflection = true, skill = skill }
      assert(data.actual == 17)
    end
  end)
  local result = logic:useSkill(left, skill, right)
  assert(result.attack.damage > 0 and left.hp == left.max_hp - 17 and seen == 1)
end)

check('攻击调用统一伤害入口，AttackReady 在改血之前', function()
  local skill = S.Skill:new{ name = '两击', power = 30, accuracy = 0, hits = 2 }
  local logic, room, left, right = battle{ skill }
  local calls, ready, after = 0, 0, 0
  local damage = logic.damage
  function logic:damage(data, action, callback)
    calls = calls + 1
    return damage(self, data, action, callback)
  end
  watch(skill, A.AttackReady, function(ctx)
    ready = ready + 1
    assert(ctx.data.damage_data.damage > 0)
    assert(right.hp == right.max_hp - ctx.data.damage)
  end)
  watch(skill, H.AfterDamage, function(ctx) after = after + ctx.data.actual end)
  local use = logic:useSkill(left, skill, right)
  assert(calls == 2 and ready == 2 and use.attack.hits == 2)
  assert(after == use.attack.damage and right.max_hp - right.hp == after)
  assert(logic:getPP(left, skill) == skill:getPP() - 1)
end)

check('零威力攻击仍可定义伤害下限，属性技不制造攻击', function()
  local attack = S.Skill:new{ name = '伤害下限', category = S.Skill.Physical, power = 0, accuracy = 0 }
  local status = S.Skill:new{ name = '回复', category = S.Skill.Status, power = 0, accuracy = 0, target = 'self' }
  local logic, room, left, right = battle{ attack, status }
  watch(attack, A.FinalDamageCalculate, function(ctx) ctx.data.damage = 80 end)
  watch(status, E.useskill.SkillUsed, function(ctx) ctx.room:recover{ target = ctx.owner, num = 10 } end)
  assert(logic:useSkill(left, attack, right).attack.damage == 80)
  room:changeHp{ target = left, num = -20 }
  local result = logic:useSkill(left, status, left)
  assert(result.success and result.attack == nil and left.hp == left.max_hp - 10)
end)

check('通知只携带技能名称和 buff 标识，不暴露循环对象图', function()
  local skill = S.Skill:new{ name = '通知测试', power = 20, accuracy = 0 }
  local logic, room, left, right = battle{ skill }
  local seen = 0
  logic.on_notify = function(_, event)
    if event.skill ~= nil then assert(type(event.skill) == 'string') end
    if event.buff ~= nil then assert(type(event.buff) == 'string'); seen = seen + 1 end
  end
  local buff = room:addBuff(left, { id = '通知buff' })
  logic:useSkill(left, skill, right)
  room:recover{ target = right, source = left, num = 5, skill = skill }
  room:removeBuff(buff)
  assert(seen == 2)
end)

check('GameEvent 包装与房间入口共用结果', function()
  local logic, _, _, right = battle()
  local event = GameEvent.Damage:create(logic, { target = right, kind = 'fixed', damage = 20 })
  assert(event:main() and event.data.actual == 20)
  event = GameEvent.Recover:create(logic, { target = right, num = 7 })
  assert(event:main() and event.data.actual == 7)
  assert(right.hp == right.max_hp - 13)
end)

check('共享 Effect 的 buff 状态隔离，刷新与到期不串拥有者', function()
  local logic, room, left, right = battle()
  local turn = S.Effect:new{ id = '计数', timing = G.TurnEnd, on_use = function(_, ctx)
    assert(ctx.effect_source == ctx.buff and ctx.owner == ctx.buff.owner)
    ctx.buff.state.count = ctx.buff.state.count + 1
  end }
  local spec = { id = 'counter', duration = 3, effects = { turn }, state = { count = 0, nested = {} } }
  local a, b = room:addBuff(left, spec), room:addBuff(right, spec)
  a.state.nested.value = 1
  assert(b.state.nested.value == nil and spec.state.nested.value == nil)
  function logic:pickAction() end
  logic:doRound()
  assert(a.state.count == 1 and b.state.count == 1)
  logic.round = 2
  local refreshed = room:addBuff(left, spec)
  assert(not a.active and refreshed ~= a and #room:getBuffs(left) == 1)
  logic:doRound()
  logic.round = 3
  logic:doRound()
  assert(not b.active and b.state.count == 3 and refreshed.active)
  logic.round = 4
  logic:doRound()
  assert(not refreshed.active and refreshed.state.count == 3 and #room:getBuffs(left) == 0)
end)

check('下两回合、房间 buff、驱散分类和解除回调', function()
  local logic, room, left = battle()
  local seen, removed = 0, 0
  local effect = S.Effect:new{ id = '下两回合', timing = G.TurnStart, on_use = function() seen = seen + 1 end }
  local on_remove = S.Effect:new{ id = '解除', timing = B.AfterBuffRemove,
    can_trigger = function(_, ctx) return ctx.data.buff == ctx.buff end,
    on_use = function(_, ctx) assert(ctx.data.reason == 'expired'); removed = removed + 1 end }
  local buff = room:addBuff(room, { id = 'weather', start_round = 2, duration = 2, effects = { effect, on_remove } })
  logic:trigger(G.TurnStart)
  logic.round = 2; logic:trigger(G.TurnStart)
  logic.round = 3; logic:trigger(G.TurnStart); room:expireBuffs(3)
  logic.round = 4; logic:trigger(G.TurnStart)
  assert(seen == 2 and removed == 1 and not buff.active)
  room:addBuff(left, { id = 'a', category = 'turn' })
  room:addBuff(left, { id = 'b', category = 'turn', dispellable = false })
  room:addBuff(left, { id = 'c', category = 'shield' })
  assert(room:dispelBuffs(left, 'turn') == 1 and #room:getBuffs(left) == 2)
  room:clearBattleBuffs()
  assert(#room:getBuffs(left) == 0)
end)

check('被移除的 buff 不执行旧队列中的后续效果，添加/移除均可被防止', function()
  local logic, room, left = battle()
  local called = 0
  local first = S.Effect:new{ id = 'consume', timing = G.TurnStart, priority = 10,
    on_use = function(_, ctx) room:removeBuff(ctx.buff, 'consumed') end }
  local second = S.Effect:new{ id = 'stale', timing = G.TurnStart,
    on_use = function() called = called + 1 end }
  room:addBuff(left, { id = 'consume', effects = { first, second } })
  logic:trigger(G.TurnStart)
  assert(called == 0 and #room:getBuffs(left) == 0)
  local blocker = watch(room, B.BeforeBuffAdd, function(ctx) ctx.data.prevented = true end)
  assert(room:addBuff(left, { id = 'blocked' }) == nil)
  room:removeEffect(blocker)
  local buff = room:addBuff(left, { id = 'protected', duration = 1 })
  watch(room, B.BeforeBuffRemove, function(ctx) ctx.data.prevented = true end)
  assert(room:dispelBuffs(left) == 0 and buff.active)
  room:expireBuffs(1)
  assert(not buff.active, '自然到期不能被驱散保护永久留住')
end)

check('能力等级上下限、消强/解弱时机与伤害基础公式', function()
  local logic, room, left, right = battle()
  local seen = {}
  for _, timing in ipairs{ E.stat_stage.BeforeStatStageChange, E.stat_stage.BeforePositiveStatStagesClear,
    E.stat_stage.AfterStatStageChange, E.stat_stage.AfterPositiveStatStagesClear } do
    watch(room, timing, function() seen[#seen + 1] = timing.name end)
  end
  room:changeStatStages(left, { attack = 9, defense = -9, speed = 2 })
  assert(left:getStatStage('attack') == 6 and left:getStatStage('defense') == -6)
  assert(logic:getEffectiveStat(left, 'attack') == left:getStat('attack') * 4)
  assert(logic:getEffectiveStat(left, 'defense') == left:getStat('defense') / 4)
  seen = {}
  assert(room:clearPositiveStatStages(left).success)
  assert(table.concat(seen, ',') == 'BeforeStatStageChange,BeforePositiveStatStagesClear,AfterStatStageChange,AfterPositiveStatStagesClear')
  assert(left:getStatStage('defense') == -6)
  room:clearNegativeStatStages(left)
  assert(left:getStatStage('defense') == 0)
  local data = DamageData:new{ source = left, target = right, power = 100, attack = 200,
    defense = 100, stab = 1.5, multiplier = 1, random = 1, crit = false }
  assert(logic:damageFormula(data) == 255)
  data.crit = true; assert(logic:damageFormula(data) == 510)
  data.crit_resistance = 0.25; assert(logic:damageFormula(data) == 382)
  data.power, data.attack, data.defense, data.multiplier, data.crit = 1, 602, 393, 0.5, false
  data.random = 217 / 255; assert(logic:damageFormula(data) == 1)
  data.random = 1; assert(logic:damageFormula(data) == 2)
  data.multiplier = 0; assert(logic:damageFormula(data) == 0)
end)

check('雷神觉醒使用统一 buff，当前回合起持续三回合；第五技能 PP 自动初始化', function()
  local awakening = dofile('packages/seer-core/standard/effects/thunder_awakening.lua')
  local skill = S.Skill:new{ name = '测试觉醒', category = S.Skill.Status, accuracy = 0, target = 'self', effects = { awakening } }
  local logic, room, left, right = battle{ skill }
  logic:useSkill(left, skill, left)
  assert(left:getStatStage('attack') == 2 and left:getStatStage('speed') == 2)
  local buff = room:getBuff(left, 'standard_thunder_awakening')
  assert(buff and buff:getRemainingRounds(1) == 3)
  for round = 1, 4 do
    logic.round = round
    local data = DamageData:new{ source = left, target = right, crit_chance = 6.25 }
    logic:trigger(A.CriticalChanceCalculate, right, data)
    assert(data.crit_chance == (round <= 3 and 100 or 6.25))
    room:expireBuffs(round)
  end
  local fifth = S.Skill:new{ name = '第五', power = 10, pp = 5 }
  local pet = S.Pet:new{ species = species, fifth = fifth }
  local another = S.GameLogic:new{ pets = { pet, right } }
  assert(another:getPP(pet, fifth) == 5)
end)

print(('hp_buff_test: %d passed'):format(passed))
