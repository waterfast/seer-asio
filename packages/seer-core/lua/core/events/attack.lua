-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 攻击 / 伤害流程时机 ============================
--
-- 一次已命中的攻击：BeforeAttack → AttackStart → 每击伤害链 → AfterAttack → AttackEnd。
-- 每击：DamageParamCalculate → CriticalChanceCalculate → BeforeDamageCalculate
-- → DamageCalculate → AfterDamageCalculate → FinalDamageCalculate → AttackReady
-- → BeforeDamage → HP 变化链 → AfterDamage → DamageResolved → Attack。
-- 暴击破防在扣血后、AfterDamage 前；AfterAttack 在整次连击结束后执行一次。
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

--- 攻击公式的最终数值修正；之后 BeforeDamage / BeforeHpChange 仍能减免，actual 才是实际扣血。
---@class FinalDamageCalculate: TriggerEvent
---@field data DamageData
local FinalDamageCalculate = TriggerEvent:subclass("FinalDamageCalculate")

--- 攻击就绪（伤害值已定，即将真正命中/扣血）。
---@class AttackReady: TriggerEvent
---@field data AttackData
local AttackReady = TriggerEvent:subclass("AttackReady")

--- 本击伤害已经提交后的攻击时机，data.damage 为累计攻击实际伤害。
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
