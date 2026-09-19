-- SPDX-License-Identifier: GPL-3.0-or-later
-- 从仓库根目录运行：lua5.4 tests/effect_dispatch_test.lua
-- 直接加载核心类，避免依赖正在迁移的图鉴包及完整 RPC/项目测试。
package.path = "packages/seer-core/lua/lib/?.lua;packages/seer-core/lua/?.lua;packages/seer-core/lua/?/init.lua;" .. package.path
class = require "middleclass"
Util = require "core.util"
Log = require "core.log"
Log.min_level = "error"
Rng = require "core.rng"
require "core.trigger_event"
local EV = require "core.events"
local A, G = EV.attack, EV.gameflow
local GameObject = require "core.gameobject"
local Effect = require "core.effect.effect"
local Skill = require("core.skill").Skill
local Pets = require "core.pet"
local Unit = require "core.unit"
local BattleRoom = require "server.battleroom"
local GameLogic = require "server.gamelogic"
local species = Pets.PetSpecies:new{
  name = "测试种族", elements = { "普通" },
  base_stats = { hp = 100, attack = 80, defense = 80, sp_attack = 80, sp_defense = 80, speed = 80 },
}
local function pet(name, skills)
  return Pets.Pet:new{ name = name, species = species, level = 50, skills = skills }
end
local function battle(skills)
  local left, right = pet("左", skills), pet("右", {})
  local units = { Unit:new{ pets = { left } }, Unit:new{ pets = { right } } }
  local logic = GameLogic:new{ units = units, max_rounds = 0, rng_seed = 123 }
  logic.on_notify = function() end
  return logic, left, right, units
end
local count = 0
local function check(name, fn)
  fn()
  count = count + 1
  print("ok - " .. name)
end

check("开局登记双方对象，过滤时机且同优先级保序", function()
  local logic, left, right, units = battle({})
  local owners = {}
  local effect = Effect:new{ id = "start", timing = G.BattleStart, on_use = function(_, ctx)
    assert(ctx.room == logic.room and ctx.event.data == ctx.data)
    assert(ctx.source == nil and ctx.effect_source == ctx.owner)
    owners[#owners + 1] = ctx.owner
  end }
  for _, owner in ipairs({ logic.room, units[1], left, units[2], right }) do owner:addEffect(effect) end
  left:addEffect(Effect:new{ id = "irrelevant", timing = A.AfterAttack,
    can_trigger = function() error("其他时机不应检测") end })
  logic:run()
  assert(logic.skill_table == nil)
  assert(#owners == 5 and owners[1] == logic.room and owners[2] == units[1])
  assert(owners[3] == left and owners[4] == units[2] and owners[5] == right)
  assert(logic.event_log[1].handler:count() == 5)
  logic:registerEffectSources()
  assert(#logic.room:getEffectSources() == 4)
end)

check("当前技能贯穿攻击全部时机，携带技能及后续回合不泄漏", function()
  local calls = {}
  local skill = Skill:new{ name = "本次", power = 40 }
  for _, timing in pairs(A) do
    skill:addEffect(Effect:new{ id = timing.name, timing = timing, on_use = function(_, ctx)
      calls[timing] = (calls[timing] or 0) + 1
      assert(ctx.owner == ctx.source and ctx.effect_source == skill and ctx.skill == skill)
      assert(ctx.data ~= nil)
      if timing == A.BeforeDamageCalculate then ctx.data.power = 0 end
    end })
  end
  local unused = Skill:new{ name = "未使用", power = 40, effects = {
    Effect:new{ id = "unused", timing = A.AfterAttack, on_use = function() error("携带不等于常驻") end },
  } }
  local logic, left, right = battle({ skill, unused })
  logic:registerEffectSources()
  local before = right.hp
  logic:doAttack(left, skill, right)
  for _, timing in pairs(A) do assert(calls[timing] == 1, timing.name) end
  assert(before - right.hp <= 3, "公式前的修改必须进入伤害计算")
  local _, event = logic:trigger(A.AfterAttack, right, AttackData:new{ source = left, skill = skill })
  assert(event.handler:count() == 0, "只有显式动作上下文才能注入技能")
end)

check("挂载/卸载下次触发生效，当前快照保持不变", function()
  local logic = battle({})
  local weather = GameObject:new{ name = "天气" }
  logic.room:registerEffectSource(weather)
  local calls = {}
  local later = Effect:new{ id = "later", timing = G.TurnStart, on_use = function() calls[#calls + 1] = "later" end }
  local removed = Effect:new{ id = "removed", timing = G.TurnStart, on_use = function() calls[#calls + 1] = "removed" end }
  local first = Effect:new{ id = "first", priority = 10, timing = G.TurnStart, on_use = function(_, ctx)
    assert(ctx.owner == weather)
    weather:addEffect(later)
    weather:removeEffect(removed)
    calls[#calls + 1] = "first"
  end }
  weather:addEffect(removed)
  weather:addEffect(first)
  logic:trigger(G.TurnStart, nil, TurnData:new{})
  assert(table.concat(calls, ",") == "first,removed")
  calls = {}
  logic:trigger(G.TurnStart, nil, TurnData:new{})
  assert(table.concat(calls, ",") == "first,later")
  logic.room:unregisterEffectSource(weather)
  local _, event = logic:trigger(G.TurnStart)
  assert(event.handler:count() == 0)
end)

check("嵌套触发独立 owner/event，共享 data，取消代价和打断有效", function()
  local logic, left, right = battle({})
  logic:registerEffectSources()
  local outer_ctx
  right:addEffect(Effect:new{ id = "inner", timing = G.TurnEnd, on_use = function(_, ctx)
    assert(ctx.owner == right and ctx.event ~= outer_ctx.event)
    ctx.owner = nil
  end })
  left:addEffect(Effect:new{ id = "outer", timing = G.TurnStart, priority = 20, on_use = function(_, ctx)
    outer_ctx = ctx
    logic:trigger(G.TurnEnd)
    assert(ctx.owner == left)
    ctx.data.value = 7
  end })
  left:addEffect(Effect:new{ id = "cancel", timing = G.TurnStart, priority = 10,
    on_cost = function() return false end, on_use = function() error("代价取消") end })
  right:addEffect(Effect:new{ id = "break", timing = G.TurnStart, priority = 1, on_use = function(_, ctx)
    assert(ctx.owner == right and ctx.data.value == 7)
    return true
  end })
  right:addEffect(Effect:new{ id = "after-break", timing = G.TurnStart,
    on_use = function() error("打断后不再执行") end })
  local broken, event = logic:trigger(G.TurnStart, nil, TurnData:new{})
  assert(broken and event.break_reason == "break")
end)

check("独立挂载表、共享定义按拥有者执行且不跨局", function()
  local shared = Effect:new{ id = "shared", timing = G.TurnStart, on_use = function(_, ctx)
    ctx.owner.times = (ctx.owner.times or 0) + 1
  end }
  local spec = { effects = { shared } }
  local a, b = Unit:new(spec), Unit:new(spec)
  a:removeEffect(shared)
  assert(#b:getEffects() == 1 and #spec.effects == 1)
  a:addBuff(shared)
  assert(a:getBuff("shared") == shared and a:getBuffs() == a:getEffects())
  local first = battle({})
  first.room:registerEffectSource(a)
  first.room:registerEffectSource(b)
  first:trigger(G.TurnStart)
  assert(a.times == 1 and b.times == 1)
  local second = battle({})
  local _, event = second:trigger(G.TurnStart)
  assert(event.handler:count() == 0)
end)

check("未命中仍结算结束效果，攻击前打断阻止攻击", function()
  local ended, after = 0, 0
  local skill = Skill:new{ name = "打空", power = 40, accuracy = 1, effects = {
    Effect:new{ id = "end", timing = A.AttackEnd, on_use = function(_, ctx)
      assert(ctx.data.missed); ended = ended + 1
    end },
    Effect:new{ id = "hit", timing = A.AfterAttack, on_use = function() after = after + 1 end },
  } }
  local logic, left, right = battle({ skill })
  logic.rng.chance = function() return false end
  logic:doAttack(left, skill, right)
  assert(ended == 1 and after == 0 and right.hp == right.max_hp)
  skill:addEffect(Effect:new{ id = "stop", timing = A.BeforeAttack, on_use = function() return true end })
  logic:doAttack(left, skill, right)
  assert(ended == 1 and right.hp == right.max_hp)
end)

check("Session 使用 BattleRoom 和真实玩家分组", function()
  local old_seer = Seer
  Seer = { setLogic = function() end }
  local Session = require "server.session"
  local function spec(name) return { name = name, species = species, level = 50 } end
  local session = Session.create(987, { seed = 123, players = {
    { playerId = 101, pets = { spec("一") } },
    { playerId = 202, pets = { spec("二"), spec("三") } },
  } })
  assert(session.room:isInstanceOf(BattleRoom))
  assert(#session.logic:getSide(1) == 1 and #session.logic:getSide(2) == 2)
  assert(session.room:getUnits()[2]:getId() == 202)
  assert(session.room:getLogic() == session.logic)
  assert(session.room:seatOf(session.pets[3]) == 3 and session.pets[3].side == 2)
  session.logic.max_rounds = 0
  session.logic:run()
  assert(#session.room:getEffectSources() == 5)
  assert(#Session.serializeLog(session.logic.event_log) == 2)
  Session.sessions[987] = nil
  Seer = old_seer
end)

print(("effect_dispatch_test: %d passed"):format(count))
