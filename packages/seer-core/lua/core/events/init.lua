-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 时机数据基类 + 时机清单 ============================
--
-- 时机（TriggerEvent）的 data 统一是 TriggerData 的子类：它是个"数据口袋"，
-- 结算链上各个时机可以往里读字段、改字段（伤害值、命中、被防止……）。
--
-- 本文件干三件事：
--   1. 定义 TriggerData 基类；
--   2. 把具体时机类（gameflow.lua / attack.lua）require 进来；
--   3. 按战斗流程的先后顺序汇总成一张清单返回，供注册层（server/battle/timing.lua）
--      遍历注册，也方便排文档 / 协议。
--
-- 加载顺序注意：本文件引用全局 `TriggerEvent`，所以 `core.trigger_event.lua`
-- 必须先于本文件加载（它会把 TriggerEvent 挂成全局）。

---@class TriggerData: Object
---@field private _data any
TriggerData = class("TriggerData")

function TriggerData:initialize(spec)
  self._data = spec or {}
end

function TriggerData:__index(k)
  if k == "_data" then return rawget(self, k) end
  return self._data[k]
end

function TriggerData:__newindex(k, v)
  if k == "_data" then return rawset(self, k, v) end
  if not self._data then return rawset(self, k, v) end
  self._data[k] = v
end

local gameflow = require "core.events.gameflow"
local attack = require "core.events.attack"

--- 全部时机类，按战斗流程的先后顺序排列（每个元素是类，不是实例）。
---@type TriggerEvent[]
local TIMINGS = {
  gameflow.BattleStart,
  gameflow.TurnStart,
  gameflow.TurnReady,
  gameflow.DecidePriority,
  attack.BeforeAttack,
  attack.AttackStart,
  attack.DamageParamCalculate,
  attack.BeforeDamageCalculate,
  attack.DamageCalculate,
  attack.AfterDamageCalculate,
  attack.FinalDamageCalculate,
  attack.AttackReady,
  attack.Attack,
  attack.AfterAttack,
  attack.AttackEnd,
  gameflow.TurnEnd,
  gameflow.AfterTurnEnd,
  gameflow.BattleEnd,
}

return {
  TriggerData = TriggerData,
  timings = TIMINGS,
  gameflow = gameflow,
  attack = attack,
}
