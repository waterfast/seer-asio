-- SPDX-License-Identifier: GPL-3.0-or-later
-- 能力等级操作必须区分原因：弱化抵消强化不是“消强”，解弱也不是强化。
-- 这里仅定义数据与时机；BattleRoom 是等级写入和前后时机分发的入口。

---@alias StatStageOperation 'change'|'clear_positive'|'clear_negative'|'reverse'
---@class StatStageChangeData: TriggerData
---@field target Pet @ 发生等级变化的精灵
---@field source GameObject? @ 来源，允许无来源的场地/规则效果
---@field reason string? @ 技能或效果名称
---@field operation StatStageOperation @ 操作类型，免弱/免消强可据此分别判断
---@field changes table<string, integer> @ 请求的等级增量；前置效果可修改或删除某项
---@field before table<string, integer> @ 实际写入前的等级快照
---@field after table<string, integer> @ 实际写入后的等级快照
---@field actual table<string, integer> @ 实际非零变化，经过上下限修正
---@field prevented boolean @ 前置效果设为 true 可取消整个操作
---@field success boolean @ 至少一项实际变化才为 true
StatStageChangeData = TriggerData:subclass("StatStageChangeData")

---@param spec table @ { target, source?, changes?, operation?, reason? }
function StatStageChangeData:initialize(spec)
  spec = spec or {}
  local changes = {}
  for field, delta in pairs(spec.changes or {}) do changes[field] = delta end
  TriggerData.initialize(self, {
    target = spec.target, source = spec.source, reason = spec.reason,
    operation = spec.operation or "change", changes = changes,
    before = {}, after = {}, actual = {}, prevented = false, success = false,
  })
end

---@class BeforeStatStageChange: TriggerEvent
local BeforeStatStageChange = TriggerEvent:subclass("BeforeStatStageChange")
---@class AfterStatStageChange: TriggerEvent
local AfterStatStageChange = TriggerEvent:subclass("AfterStatStageChange")
---@class BeforePositiveStatStagesClear: TriggerEvent
local BeforePositiveStatStagesClear = TriggerEvent:subclass("BeforePositiveStatStagesClear")
---@class AfterPositiveStatStagesClear: TriggerEvent
local AfterPositiveStatStagesClear = TriggerEvent:subclass("AfterPositiveStatStagesClear")
---@class BeforeNegativeStatStagesClear: TriggerEvent
local BeforeNegativeStatStagesClear = TriggerEvent:subclass("BeforeNegativeStatStagesClear")
---@class AfterNegativeStatStagesClear: TriggerEvent
local AfterNegativeStatStagesClear = TriggerEvent:subclass("AfterNegativeStatStagesClear")
-- 反转先保留独立时机与 operation='reverse' 的数据契约：
-- changes 为目标等级的相反数减原等级（即 -2 * 原等级）。本次不提供 Room 反转函数。
---@class BeforeStatStagesReverse: TriggerEvent
local BeforeStatStagesReverse = TriggerEvent:subclass("BeforeStatStagesReverse")
---@class AfterStatStagesReverse: TriggerEvent
local AfterStatStagesReverse = TriggerEvent:subclass("AfterStatStagesReverse")

return {
  BeforeStatStageChange = BeforeStatStageChange,
  AfterStatStageChange = AfterStatStageChange,
  BeforePositiveStatStagesClear = BeforePositiveStatStagesClear,
  AfterPositiveStatStagesClear = AfterPositiveStatStagesClear,
  BeforeNegativeStatStagesClear = BeforeNegativeStatStagesClear,
  AfterNegativeStatStagesClear = AfterNegativeStatStagesClear,
  BeforeStatStagesReverse = BeforeStatStagesReverse,
  AfterStatStagesReverse = AfterStatStagesReverse,
}
