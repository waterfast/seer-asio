-- SPDX-License-Identifier: GPL-3.0-or-later
-- 伤害是 HP 减少的原因之一。回复、直接流失体力同样经过 HP 时机，且不伪造攻击。
-- 前置时机可改数值或 prevented；后置时机仅报告已提交的结果，不能撤销写入。

--- 一次伤害结算的数据（计算、伤害前后及 DamageResolved 共用）。
---@class DamageData: TriggerData
---@field public source GameObject? @ 伤害来源
---@field public target GameObject @ 受击目标
---@field public skill Skill? @ 造成伤害的技能
---@field public power integer @ 有效威力（各类威力修正都算进去之后）
---@field public category string @ 伤害类别：Skill.Physical / Skill.Special
---@field public element string @ 伤害属性（决定克制与本系）
---@field public attack integer @ 攻击方本次使用的攻击数值（物攻或特攻）
---@field public defense integer @ 受击方本次使用的防御数值（物防或特防）
---@field public stab number @ 本系加成倍率
---@field public multiplier number @ 属性克制倍率
---@field public crit boolean @ 是否暴击
---@field public crit_chance number @ 致命概率百分数，0..100，CriticalChanceCalculate 可修改
---@field public crit_resistance number @ 致命伤害减免比例，默认 0
---@field public index integer? @ 当前击数
---@field public random number @ 整数随机数 217..255 除以 255
---@field public damage integer @ 当前伤害值（结算链上被各时机修改）
---@field public prevented boolean @ 伤害是否被防止（归零 / 免疫 / 抵挡）
---@field kind string @ attack / fixed / percent；后两者由调用方提供数值，不套攻击公式
---@field actual integer @ 实际扣血，独立于申请伤害 damage，过量伤害不计入 actual
---@field reason string?
---@field parent TriggerData? @ 嵌套伤害的来源事件（反伤等按此避免重复触发）
---@field hp_change HpChangeData?

DamageData = TriggerData:subclass("DamageData")

--- 防止本次伤害（伤害归零）。
function DamageData:preventDamage()
  self.damage = 0
  self.prevented = true
end

---@class HpChangeData: TriggerData
---@field target Pet
---@field source GameObject?
---@field skill Skill?
---@field num integer @ 请求变化量；伤害只能非正，回复只能非负
---@field kind string @ damage / recover / direct
---@field reason string?
---@field parent TriggerData? @ 所属 DamageData / RecoverData
---@field before integer @ 提交前 HP，包含前置时机内嵌套操作的结果
---@field after integer @ 本次提交后 HP；后置效果再次改血不改写此快照
---@field actual integer @ after - before
---@field prevented boolean
HpChangeData = TriggerData:subclass("HpChangeData")

---@class RecoverData: TriggerData
---@field target Pet
---@field source GameObject?
---@field skill Skill?
---@field num integer @ 请求回复量
---@field actual integer @ 实际回复量，不含后置效果造成的变化
---@field reason string?
---@field parent TriggerData?
---@field hp_change HpChangeData?
---@field prevented boolean
RecoverData = TriggerData:subclass("RecoverData")

local timings = {}
-- BeforeDamage 在计算完成后、HP 写入前：固定伤害、百分比伤害也经过它。
-- AfterDamage 仅在 actual > 0 时触发；DamageResolved 报告一次完整尝试（包括被防止）。
-- HpReducedToZero 是 actual < 0 且 after == 0 的结果时机，此时目标已倒下。
for _, name in ipairs{
  "BeforeDamage", "AfterDamage", "DamageResolved", "BeforeRecover", "AfterRecover",
  "BeforeHpChange", "AfterHpChange", "HpReducedToZero",
} do timings[name] = TriggerEvent:subclass(name) end
return timings
