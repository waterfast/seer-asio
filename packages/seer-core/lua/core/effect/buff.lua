-- SPDX-License-Identifier: GPL-3.0-or-later
-- Buff 是效果的局内绑定实例；effects 是共享定义，state / 持续时间属于本实例。
local GameObject = require "core.gameobject"
local Buff = GameObject:subclass("Buff")

--- 仅复制纯数据表；GameObject 等带元表的对象保留引用，避免复制整个战局。
local function copyState(value, seen)
  if type(value) ~= "table" or getmetatable(value) then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local out = {}
  seen[value] = out
  for k, v in pairs(value) do out[k] = copyState(v, seen) end
  return out
end

---@class Buff: GameObject
---@field owner GameObject
---@field source GameObject?
---@field room BattleRoom
---@field state table @ 次数、护盾余量等实例状态；不写入 Effect 定义
---@field category string @ 如 turn / shield / status；分类自身不附带规则
---@field dispellable boolean
---@field active boolean
---@field start_round integer
---@field expires_after_round integer? @ nil 表示永久，直到消耗/移除/战斗结束
---@field duration integer?
---@class BuffSpec: GameObjectSpec
---@field id string @ 同房间同拥有者下的刷新键；不同 id 可以同时存在
---@field source GameObject?
---@field duration integer? @ 正整数；默认包含本回合，永久效果省略
---@field start_round integer? @ 「下 N 回合」传 logic.round + 1
---@field category string? @ 默认 turn
---@field dispellable boolean? @ 默认 true
---@field state table? @ 复制纯数据，不与其他拥有者共用

function Buff:initialize(room, owner, spec)
  assert(type(spec.id) == "string" and spec.id ~= "", "Buff 需要非空字符串 id")
  assert(spec.duration == nil or (math.type(spec.duration) == "integer" and spec.duration > 0),
    "Buff.duration 必须是正整数或 nil")
  GameObject.initialize(self, spec)
  self.room, self.owner, self.source = room, owner, spec.source
  self.category, self.dispellable = spec.category or "turn", spec.dispellable ~= false
  self.state = copyState(spec.state or {})
  self.active = true
  self.duration = spec.duration
  self.start_round = spec.start_round or math.max(1, room.logic.round)
  assert(math.type(self.start_round) == "integer" and self.start_round >= math.max(1, room.logic.round),
    "Buff.start_round 不能早于当前回合")
  self.expires_after_round = spec.duration and (self.start_round + spec.duration - 1) or nil
end

--- 当回合的 TurnEnd / AfterTurnEnd 效果全部执行完毕，再统一到期移除。
function Buff:isEffective(round)
  return self.active and round >= self.start_round
    and (self.expires_after_round == nil or round <= self.expires_after_round)
end

---@return integer? @ 永久效果返回 nil；尚未开始时返回完整持续回合数
function Buff:getRemainingRounds(round)
  if not self.active then return 0 end
  if not self.expires_after_round then return nil end
  return math.max(0, self.expires_after_round - math.max(round, self.start_round) + 1)
end

return Buff
