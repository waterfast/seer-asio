-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 时机（TriggerEvent）============================
--
-- 一个"时机"：战斗流程走到某个时刻（回合开始、出手、伤害结算……）时，
-- 所有挂在它上面的触发器会被依次问一遍"你要不要插一脚"。
--
-- 注意分清两层（详见 packages/seer-core/README.md §4）：
--   * TriggerEvent（时机）  —— 同步。某一刻"谁想插一脚"，按优先级问一遍就返回。
--   * GameEvent（流程事件） —— 协程。某件事"怎么一步步走完"，能停下等、能打断。
-- 这里是**时机**，对应 freekill 的 `ltk/core/trigger_event.lua`。
--
-- 本文件定义时机数据与辅助方法；GameLogic:trigger 收集本时机效果，
-- EffectHandler 按优先级同步结算并设置 broken。GameEvent 仍负责流程层的协程。
--
-- 与 freekill 的差异：`target` 不再是 ServerPlayer（三国杀的"角色"），而是
-- GameObject（赛尔号里"精灵/道具/场地物件"的统一基类），见 core/gameobject.lua。

---@class TriggerEvent: Object
---@field public id integer @ 时机编号（每次触发递增）
---@field public handler EffectHandler? @ 本次时机的效果集（用于调试）
---@field public logic GameLogic @ 所属战局
---@field public target GameObject? @ 这次时机"对准"的对象（谁掉血、谁行动……）
---@field public data TriggerData @ 时机的附加数据（各时机有自己的 data 类）
---@field public skill_data table<string, table<string, any>> @ 某个技能在这个时机范围内的私有数据
---@field public finished_skills string[] @ 已经发动完的技能，不再重复检测
---@field public invoked_times table<string, integer> @ 单个技能在单个时机内发动过的次数
---@field public refresh_only boolean? @ 这次触发是否只执行 refresh（被打断后收尾用）
---@field public broken boolean? @ 是否被防止 / 打断了
---@field public break_reason string? @ 被谁打断的（技能名）
TriggerEvent = class("TriggerEvent")

---@param logic GameLogic
---@param target GameObject?
---@param data TriggerData?
function TriggerEvent:initialize(logic, target, data)
  self.logic = logic
  self.target = target
  self.data = data
  if logic and logic.current_timing_id ~= nil then
    logic.current_timing_id = logic.current_timing_id + 1
    self.id = logic.current_timing_id
  else
    self.id = nil
  end

  self.skill_data = {}
  self.finished_skills = {}
  self.invoked_times = {}
end

--- 某个技能在这个时机内的私有数据（例如"这次伤害里我已经改过几次数值"）。
---@param skill Skill
---@param k string
---@param v any
function TriggerEvent:setSkillData(skill, k, v)
  local name = skill.name
  self.skill_data[name] = self.skill_data[name] or {}
  self.skill_data[name][k] = v
end

---@param skill Skill
---@param k string
function TriggerEvent:getSkillData(skill, k)
  local name = skill.name
  return self.skill_data[name] and self.skill_data[name][k]
end

--- 这个时机是否应该被打断（默认否）。伤害类时机在伤害归零/被防止时会覆盖它返回 true。
---@return boolean
function TriggerEvent:breakCheck()
  return false
end

return TriggerEvent
