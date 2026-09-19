-- SPDX-License-Identifier: GPL-3.0-or-later
-- 从仓库根目录执行：lua tests/battleroom_test.lua
-- 只加载本次修改所需模块，避免引入尚在重构的完整战斗流程。
package.path = "packages/seer-core/lua/?.lua;packages/seer-core/lua/lib/?.lua;" .. package.path
class = require "middleclass"
local GameObject = require "core.gameobject"
local Effect = require "core.effect.effect"
local BattleRoom = require "server.battleroom"

local first = GameObject:new{ id = "first" }
local second = GameObject:new{ id = "second" }
local room = BattleRoom:new{ id = 7, pets = { first, second } }
local other = BattleRoom:new{}
local effect = Effect:new{ id = "weather" }

-- 空载体也须登记；同名效果定义可在不同对象上挂载并保持独立生命周期。
assert(room:registerEffectSource(first))
assert(not room:registerEffectSource(first))
assert(not room:registerEffectSource(room))
assert(room:addObjectEffect(second, effect))
assert(first:addEffect(effect))
assert(room:getEffectSources()[1]:getEffects()[1] == effect)
assert(room:getEffectSources()[2] == second)
assert(not room:addObjectEffect(second, effect))
local sources = room:getEffectSources()
sources[1] = nil
assert(room:getEffectSources()[1] == first)
assert(room:removeObjectEffect(first, effect))
assert(#first:getEffects() == 0 and second:getEffects()[1] == effect)
assert(room:getEffectSources()[1] == first)
assert(room:unregisterEffectSource(first))
assert(not room:unregisterEffectSource(first))
assert(room:getEffectSources()[1] == second)
assert(room:addEffect(effect))
assert(room:getEffects()[1] == effect and #other:getEffects() == 0)
assert(#other:getEffectSources() == 0)

-- 局内数据、通知、协议座位不跨房间泄漏，也不改写精灵自身的座位。
room:setTag("flag", false)
assert(room:getTag("flag") == false and other:getTag("flag") == nil)
room:removeTag("flag")
assert(room:getTag("flag") == nil)
first.seat, second.seat = 1, 1
assert(room:seatOf(first) == 1 and room:seatOf(second) == 2)
assert(second.seat == 1 and room:seatOf(nil) == nil)
other.pets = { first, second }
assert(other:seatOf(second) == 2)
assert(room:getAlivePets() == room:getPets())
local actors = { second }
local logic = { getActors = function() return actors end }
room:setLogic(logic)
assert(room:getLogic() == logic and room:getAlivePets() == actors)
local event1, event2 = { kind = "start" }, { kind = "end" }
room:notifyPlayers(event1)
room:notifyPlayers(event2)
local events = room:drainEvents()
assert(events[1] == event1 and events[2] == event2)
assert(#room:drainEvents() == 0 and #other.events == 0)
room:notifyPlayers(event1)
assert(#events == 2 and #room.events == 1)

print("battleroom_test: ok")
