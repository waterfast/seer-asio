-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 攻击 / 伤害流程时机 ============================
--
-- 一次已命中的攻击：BeforeAttack → AttackStart → 每击伤害链 → AfterAttack → AttackEnd。
-- 每击：DamageParamCalculate → CriticalChanceCalculate → BeforeDamageCalculate
-- → DamageCalculate → AfterDamageCalculate → FinalDamageCalculate → AttackReady
-- → 扣血 / 暴击破防 → Attack。AfterAttack 在整次连击结束后执行一次。
-- 命中和 PP 属于 UseSkill；未命中只保留 AttackEnd 收尾，不进入伤害链。
--
-- ---------------------------- 数据类 ----------------------------

--- 一次攻击的数据（BeforeAttack ~ AttackEnd 共用）。
---@class AttackData: TriggerData
---@field public source GameObject @ 攻击方（通常是精灵）
---@field public target GameObject @ 目标（通常是精灵）
---@field public skill Skill @ 使用的技能
---@field public missed boolean @ 是否打空
---@field public crit boolean @ 是否暴击
---@field public hits integer @ 一共打了几下（连击）
---@field public damage integer @ 本次攻击造成的总伤害（各击累加）
---@field public prevented boolean? @ 取消当前攻击
---@field public damage_data DamageData? @ 当前这一击伤害结算的数据
AttackData = TriggerData:subclass("AttackData")

--- 一次伤害结算的数据（DamageParamCalculate ~ FinalDamageCalculate 共用）。
---@class DamageData: TriggerData
---@field public source GameObject @ 伤害来源
---@field public target GameObject @ 受击目标
---@field public skill Skill @ 造成伤害的技能
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
DamageData = TriggerData:subclass("DamageData")

--- 防止本次伤害（伤害归零）。
function DamageData:preventDamage()
  self.damage = 0
  self.prevented = true
end

-- ---------------------------- 时机类 ----------------------------

--- 攻击发动前（伤害还没开始算）。
---@class BeforeAttack: TriggerEvent
---@field data AttackData
local BeforeAttack = TriggerEvent:subclass("BeforeAttack")

--- 攻击开始。
---@class AttackStart: TriggerEvent
---@field data AttackData
local AttackStart = TriggerEvent:subclass("AttackStart")

--- 伤害参数计算（把威力/攻防/克制/本系/暴击/随机凑齐）。
---@class DamageParamCalculate: TriggerEvent
---@field data DamageData
local DamageParamCalculate = TriggerEvent:subclass("DamageParamCalculate")

--- 命中后、致命判定之前。效果通过 data.crit_chance 修改概率，不污染共享技能。
---@class CriticalChanceCalculate: TriggerEvent
---@field data DamageData
local CriticalChanceCalculate = TriggerEvent:subclass("CriticalChanceCalculate")

--- 伤害公式计算之前（参数还可以改）。
---@class BeforeDamageCalculate: TriggerEvent
---@field data DamageData
local BeforeDamageCalculate = TriggerEvent:subclass("BeforeDamageCalculate")

--- 伤害公式计算（套公式得出基础伤害）。
---@class DamageCalculate: TriggerEvent
---@field data DamageData
local DamageCalculate = TriggerEvent:subclass("DamageCalculate")

--- 伤害公式计算之后（基础伤害还可以改）。
---@class AfterDamageCalculate: TriggerEvent
---@field data DamageData
local AfterDamageCalculate = TriggerEvent:subclass("AfterDamageCalculate")

--- 最终伤害确定（所有修正都结算完，这个值就是实际要扣的血）。
---@class FinalDamageCalculate: TriggerEvent
---@field data DamageData
local FinalDamageCalculate = TriggerEvent:subclass("FinalDamageCalculate")

--- 攻击就绪（伤害值已定，即将真正命中/扣血）。
---@class AttackReady: TriggerEvent
---@field data AttackData
local AttackReady = TriggerEvent:subclass("AttackReady")

--- 攻击命中（真正结算伤害 / 扣血）。
---@class Attack: TriggerEvent
---@field data AttackData
local Attack = TriggerEvent:subclass("Attack")

--- 攻击命中之后（反伤、附加效果等在这里）。
---@class AfterAttack: TriggerEvent
---@field data AttackData
local AfterAttack = TriggerEvent:subclass("AfterAttack")

--- 攻击结束（这一击收工）。
---@class AttackEnd: TriggerEvent
---@field data AttackData
local AttackEnd = TriggerEvent:subclass("AttackEnd")

return {
  BeforeAttack = BeforeAttack,
  AttackStart = AttackStart,
  DamageParamCalculate = DamageParamCalculate,
  CriticalChanceCalculate = CriticalChanceCalculate,
  BeforeDamageCalculate = BeforeDamageCalculate,
  DamageCalculate = DamageCalculate,
  AfterDamageCalculate = AfterDamageCalculate,
  FinalDamageCalculate = FinalDamageCalculate,
  AttackReady = AttackReady,
  Attack = Attack,
  AfterAttack = AfterAttack,
  AttackEnd = AttackEnd,
}
