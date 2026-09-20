-- SPDX-License-Identifier: GPL-3.0-or-later
-- 使用技能与造成伤害是两层流程；属性技能只运行技能时机，不进入伤害公式。
---@class SkillUseData: TriggerData
---@field source Pet
---@field target Pet
---@field skill Skill
---@field prevented boolean @ 前置时机取消使用，不扣 PP
---@field missed boolean @ 已扣 PP 但命中失败
---@field success boolean @ 技能命中并完成生效阶段
---@field attack AttackData? @ 攻击技能的结算数据
SkillUseData = TriggerData:subclass("SkillUseData")

---@class BeforeSkillUse: TriggerEvent
local BeforeSkillUse = TriggerEvent:subclass("BeforeSkillUse")
---@class SkillUsed: TriggerEvent @ 命中成功后；属性技能的效果挂在这里
local SkillUsed = TriggerEvent:subclass("SkillUsed")
---@class AfterSkillUse: TriggerEvent @ 使用结束，包括未命中；效果自行检查 success/missed
local AfterSkillUse = TriggerEvent:subclass("AfterSkillUse")

return { BeforeSkillUse = BeforeSkillUse, SkillUsed = SkillUsed, AfterSkillUse = AfterSkillUse }
