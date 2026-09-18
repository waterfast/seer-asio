-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 战斗时机表（Timing） ============================
--
-- 这里定义战斗里所有**时机**（Timing 的子类）和它们各自的**数据类**
-- （TriggerData 的子类）。写法完全照 freekill 的 `ltk/core/events/*.lua`：
--
--   1. 先写数据类 + 它的"改数值"方法（`changeDamage` / `preventDamage` …）；
--   2. 再写时机类，用 `---@field data XxxData` 把数据类型写具体；
--   3. 需要"这件事不用再问了"的时机，重写 `breakCheck`；
--   4. 最后登记进 Seer，并挂到全局 `SeerTiming` 上供 effect.lua 按名字取。
--
-- 一个时机 = 一次"谁来插一脚"的询问机会。所以时机的**粒度**就是这套系统的
-- 表达力上限：效果想"在对手出手前降低他的攻击"，就必须存在
-- `BeforeAction` 这个时机。下面的划分按"结算的自然停顿点"来定，不按技能来定。
--
-- 结算链的顺序（以一次攻击为例）：
--
--   BeforeUseSkill        决定要用这个技能了（可以被打断/无效化）
--     BeforeHitCheck      命中判定前（可以改命中率 / 必中 / 必闪）
--     AfterHitCheck       命中判定后（未命中就到这里为止）
--       PreDamage         伤害开始算（可以"防止伤害"）
--       DetermineDamage   伤害数值定下来了（改数值的主战场：克制/减半/加成）
--       Damage            伤害真的扣了血
--       Damaged           受击方视角结算后（反伤、静电麻痹都在这）
--       DamageFinished    整条伤害链结束（breakCheck 在这里放行）
--     AfterUseSkill       技能结算完
--
-- `breakCheck` 的作用就是让这条链在"伤害已经被防止"时**提前刹住**，
-- 不要继续走后面的时机会（否则会出现"伤害为 0 却触发了反伤"这种怪事）。

-- ============================ 体力变化 ============================

---@class HpChangedDataSpec
---@field public who Pet @ 体力变化的那只精灵
---@field public num integer @ 变化量，可正可负
---@field public kind? string @ 变化的**种类**："damage" / "recover" / "loseHp"。
--- 注意它和 `reason` 是两回事：kind 是程序判断用的枚举（"这是不是一次伤害"），
--- reason 是给人看的文案（"雷光拳"）。混成一个字段就会出现
--- "想按种类判断、结果拿到的是技能名"这种静默错误。
---@field public reason? string @ 变化原因（技能名/效果名/状态名），给人看
---@field public source? Pet @ 来源
---@field public prevented? boolean

---@class HpChangedData: HpChangedDataSpec, TriggerData
HpChangedData = TriggerData:subclass("HpChangedData")
HpChangedData.spec_required = { "who", "num" }

---@class HpChangedEvent: Timing
---@field public data HpChangedData
local HpChangedEvent = Timing:subclass("HpChangedEvent")

--- 体力变化前 / 后
Seer:registerTiming("BeforeHpChanged", HpChangedEvent:subclass("BeforeHpChanged"))
Seer:registerTiming("HpChanged", HpChangedEvent:subclass("HpChanged"))

-- ============================ 伤害 ============================

---@class DamageDataSpec
---@field public source? Pet @ 攻击方
---@field public target Pet @ 受击方
---@field public damage integer @ 伤害值（各时机都在改它）
---@field public category? SkillCategory @ 物理/特殊（烧伤减半、反射类效果要判它）
---@field public element? string @ 伤害属性
---@field public skill? Skill @ 造成伤害的技能
---@field public reason? string @ 伤害原因（固定伤害/异常状态伤害会写状态名）
---@field public effectiveness? number @ 克制倍率（记下来给客户端显示"效果拔群"）
---@field public crit? boolean @ 是不是暴击
---@field public stab? boolean @ 有没有本系加成
---@field public is_fixed? boolean @ 是不是固定伤害（不吃克制/暴击）
---@field public is_status_damage? boolean @ 是不是异常状态造成的伤害（中毒掉血等）
---@field public prevented? boolean @ 伤害是否被防止

---@class DamageData: DamageDataSpec, TriggerData
DamageData = TriggerData:subclass("DamageData")
DamageData.spec_required = { "target", "damage" }

--- 改伤害值。降到 1 以下就等于"这次伤害没了"，顺手标成 prevented。
--- （这条和 freekill 的 DamageData:changeDamage 语义一致）
---@param num integer @ 变化量，负数表示减伤
function DamageData:changeDamage(num)
  self.damage = self.damage + num
  if self.damage < 1 then
    self:preventDamage()
  end
end

--- 防止本次伤害
function DamageData:preventDamage()
  self.damage = 0
  self.prevented = true
end

--- 把伤害改成一个固定值（"改成固定伤害 X 点"这类效果）
---@param num integer
function DamageData:setDamage(num)
  self.damage = math.max(0, math.floor(num))
  if self.damage == 0 then
    self.prevented = true
  end
end

---@class DamageEvent: Timing
---@field public data DamageData
local DamageEvent = Timing:subclass("DamageEvent")

--- 伤害链上的各个时机
Seer:registerTiming("PreDamage", DamageEvent:subclass("PreDamage"))
Seer:registerTiming("DetermineDamage", DamageEvent:subclass("DetermineDamage"))
Seer:registerTiming("Damage", DamageEvent:subclass("Damage"))
Seer:registerTiming("Damaged", DamageEvent:subclass("Damaged"))
local DamageFinished = DamageEvent:subclass("DamageFinished")
Seer:registerTiming("DamageFinished", DamageFinished)

--- 伤害被防止或已经归零之后，这条链上"还没发生"的时机会不该再问。
--- 这是照抄 freekill `DamageEvent:breakCheck` 的写法——
--- 它是整套 breakCheck 机制最重要的一个用例。
function DamageEvent:breakCheck()
  return not self:isInstanceOf(DamageFinished) and (self.data.damage < 1 or self.data.prevented)
end

-- ============================ 回复 ============================

---@class RecoverDataSpec
---@field public target Pet @ 回血的那只精灵
---@field public num integer @ 回复量
---@field public source? Pet @ 来源
---@field public reason? string
---@field public prevented? boolean

---@class RecoverData: RecoverDataSpec, TriggerData
RecoverData = TriggerData:subclass("RecoverData")
RecoverData.spec_required = { "target", "num" }

---@param num integer
function RecoverData:changeRecover(num)
  self.num = self.num + num
  if self.num < 1 then
    self:preventRecover()
  end
end

function RecoverData:preventRecover()
  self.num = 0
  self.prevented = true
end

---@class RecoverEvent: Timing
---@field public data RecoverData
local RecoverEvent = Timing:subclass("RecoverEvent")

Seer:registerTiming("BeforeRecover", RecoverEvent:subclass("BeforeRecover"))
Seer:registerTiming("Recover", RecoverEvent:subclass("Recover"))

-- ============================ 命中判定 ============================

---@class HitCheckDataSpec
---@field public source Pet @ 出手方
---@field public target Pet @ 目标
---@field public skill Skill @ 正在用的技能
---@field public accuracy? integer @ 命中率（nil = 必中）；各时机可改它
---@field public sure_hit? boolean @ 是否必中
---@field public hit? boolean? @ 判定结果（BeforeHitCheck 阶段是 nil，判定后写 true/false）
---@field public blocked? boolean? @ 是否被"必闪/守住"之类挡下

---@class HitCheckData: HitCheckDataSpec, TriggerData
HitCheckData = TriggerData:subclass("HitCheckData")
HitCheckData.spec_required = { "source", "target", "skill" }

--- 让这次攻击必定命中
function HitCheckData:setSureHit()
  self.sure_hit = true
  self.accuracy = nil
end

--- 让这次攻击必定不中
function HitCheckData:forceMiss()
  self.hit = false
  self.blocked = true
end

---@class HitCheckEvent: Timing
---@field public data HitCheckData
local HitCheckEvent = Timing:subclass("HitCheckEvent")

Seer:registerTiming("BeforeHitCheck", HitCheckEvent:subclass("BeforeHitCheck"))
Seer:registerTiming("AfterHitCheck", HitCheckEvent:subclass("AfterHitCheck"))
Seer:registerTiming("SkillMissed", HitCheckEvent:subclass("SkillMissed"))

--- 已经判定"没打中"之后，后面改命中率的时机就没意义了
function HitCheckEvent:breakCheck()
  if self:isInstanceOf(SeerTiming.BeforeHitCheck) then return false end
  return self.data.hit == false and not self:isInstanceOf(SeerTiming.SkillMissed)
end

-- ============================ 使用技能 ============================

---@class SkillUseDataSpec
---@field public source Pet @ 使用者
---@field public target? Pet @ 目标
---@field public skill Skill @ 技能
---@field public prevented? boolean @ 技能是否被无效化/中断
---@field public prevent_reason? string @ 被拦住的原因（见 Skill.Unusable；时机里被无效化时也可能是别的词）
---@field public prevent_text? string @ 给玩家看的一句话
---@field public triggered_by? Skill @ 由哪个特性/效果引发（比如"追加一击"）

---@class SkillUseData: SkillUseDataSpec, TriggerData
SkillUseData = TriggerData:subclass("SkillUseData")
SkillUseData.spec_required = { "source", "skill" }

--- 拦住这次技能使用。带上原因，客户端才知道该怎么显示。
---@param reason? string
---@param text? string
function SkillUseData:preventSkill(reason, text)
  self.prevented = true
  if reason ~= nil then self.prevent_reason = reason end
  if text ~= nil then self.prevent_text = text end
end

---@class SkillUseEvent: Timing
---@field public data SkillUseData
local SkillUseEvent = Timing:subclass("SkillUseEvent")

Seer:registerTiming("BeforeUseSkill", SkillUseEvent:subclass("BeforeUseSkill"))
Seer:registerTiming("AfterUseSkill", SkillUseEvent:subclass("AfterUseSkill"))

--- 技能已经被无效化了，"使用后"的时机就不该再问
function SkillUseEvent:breakCheck()
  if self:isInstanceOf(SeerTiming.AfterUseSkill) then return false end
  return self.data.prevented == true
end

-- ============================ 行动 ============================

---@class ActionDataSpec
---@field public actor Pet @ 本回合要行动的那只精灵
---@field public prevented? boolean @ 是否无法行动（麻痹/睡眠/冰冻/害怕）
---@field public prevent_reason? string @ 因为什么动不了（状态键）
---@field public move? Skill @ 本回合决定用的技能

---@class ActionData: ActionDataSpec, TriggerData
ActionData = TriggerData:subclass("ActionData")
ActionData.spec_required = { "actor" }

function ActionData:preventAction(reason)
  self.prevented = true
  self.prevent_reason = reason
end

---@class ActionEvent: Timing
---@field public data ActionData
local ActionEvent = Timing:subclass("ActionEvent")

Seer:registerTiming("BeforeAction", ActionEvent:subclass("BeforeAction"))
Seer:registerTiming("AfterAction", ActionEvent:subclass("AfterAction"))

-- ============================ 能力等级 ============================

---@class StatChangeDataSpec
---@field public target Pet
---@field public stages table<string, integer> @ 每项的变化量，如 `{ atk = -1 }`
---@field public source? Pet
---@field public reason? string
---@field public prevented? boolean
---@field public actual? table<string, integer> @ 实际生效的变化量（被 ±6 上限吃掉的不算）

---@class StatChangeData: StatChangeDataSpec, TriggerData
StatChangeData = TriggerData:subclass("StatChangeData")
StatChangeData.spec_required = { "target", "stages" }

function StatChangeData:preventStatChange()
  self.prevented = true
end

---@class StatChangeEvent: Timing
---@field public data StatChangeData
local StatChangeEvent = Timing:subclass("StatChangeEvent")

Seer:registerTiming("BeforeStatChange", StatChangeEvent:subclass("BeforeStatChange"))
Seer:registerTiming("StatChanged", StatChangeEvent:subclass("StatChanged"))

function StatChangeEvent:breakCheck()
  if self:isInstanceOf(SeerTiming.StatChanged) then return false end
  return self.data.prevented == true
end

-- ============================ 印记（含异常状态）============================
--
-- 异常状态是"弱化类/控制类印记"，所以时机也按**印记**命名：
-- 挂的时候过一次、摘的时候过一次。这样增益印记（护盾、强化）走的是同一条路，
-- 将来要写"清除身上所有印记"这类效果只需要一个时机。

---@class MarkDataSpec
---@field public target Pet @ 印记挂在谁身上
---@field public key string @ 印记的键（"burn" / "shield" …）
---@field public source? Pet @ 谁挂的
---@field public turns? integer
---@field public prevented? boolean

---@class MarkData: MarkDataSpec, TriggerData
MarkData = TriggerData:subclass("MarkData")
MarkData.spec_required = { "target", "key" }

--- 防止这个印记被挂上（免疫中毒之类）
function MarkData:preventMark()
  self.prevented = true
end

---@class MarkEvent: Timing
---@field public data MarkData
local MarkEvent = Timing:subclass("MarkEvent")

Seer:registerTiming("BeforeMarkApply", MarkEvent:subclass("BeforeMarkApply"))
Seer:registerTiming("MarkApplied", MarkEvent:subclass("MarkApplied"))
Seer:registerTiming("MarkRemoved", MarkEvent:subclass("MarkRemoved"))

function MarkEvent:breakCheck()
  if self:isInstanceOf(SeerTiming.MarkApplied) or self:isInstanceOf(SeerTiming.MarkRemoved) then
    return false
  end
  return self.data.prevented == true
end

-- ============================ 回合流程 ============================

---@class TurnDataSpec
---@field public round integer @ 第几大回合
---@field public turn integer @ 第几次行动
---@field public who? Pet @ 这次行动是谁的
---@field public move? Skill @ 这一回合决定用的技能
---@field public target? Pet @ 目标
---@field public reason? string @ 为什么会有这次行动（"game_rule" 等）
---@field public reject? table @ 玩家选的技能被拒时的 `{ name, reason, text }`（见 logic:askForAction）

---@class TurnData: TurnDataSpec, TriggerData
TurnData = TriggerData:subclass("TurnData")

---@class TurnEvent: Timing
---@field public data TurnData
local TurnEvent = Timing:subclass("TurnEvent")

Seer:registerTiming("RoundStart", TurnEvent:subclass("RoundStart"))
Seer:registerTiming("RoundEnd", TurnEvent:subclass("RoundEnd"))
Seer:registerTiming("TurnStart", TurnEvent:subclass("TurnStart"))
Seer:registerTiming("TurnEnd", TurnEvent:subclass("TurnEnd"))

-- ============================ 上场 / 下场 ============================

---@class SwitchDataSpec
---@field public pet Pet @ 换上/换下的精灵
---@field public from? Pet @ 换下来的那只
---@field public forced? boolean @ 是不是被迫换（倒下后补位）

---@class SwitchData: SwitchDataSpec, TriggerData
SwitchData = TriggerData:subclass("SwitchData")
SwitchData.spec_required = { "pet" }

---@class SwitchEvent: Timing
---@field public data SwitchData
local SwitchEvent = Timing:subclass("SwitchEvent")

Seer:registerTiming("PetSwitchedIn", SwitchEvent:subclass("PetSwitchedIn"))
Seer:registerTiming("PetSwitchedOut", SwitchEvent:subclass("PetSwitchedOut"))

-- ============================ 倒下 / 胜负 ============================

---@class FaintDataSpec
---@field public pet Pet @ 倒下的精灵
---@field public source? Pet @ 谁打倒的

---@class FaintData: FaintDataSpec, TriggerData
FaintData = TriggerData:subclass("FaintData")
FaintData.spec_required = { "pet" }

---@class FaintEvent: Timing
---@field public data FaintData
local FaintEvent = Timing:subclass("FaintEvent")

Seer:registerTiming("BeforePetFaint", FaintEvent:subclass("BeforePetFaint"))
Seer:registerTiming("PetFainted", FaintEvent:subclass("PetFainted"))

---@class GameOverDataSpec
---@field public winner? integer @ 获胜阵营（nil = 平局）
---@field public reason? string @ 结束原因："all_fainted" / "surrender" / "timeout"

---@class GameOverData: GameOverDataSpec, TriggerData
GameOverData = TriggerData:subclass("GameOverData")

---@class GameOverEvent: Timing
---@field public data GameOverData
Seer:registerTiming("GameOver", Timing:subclass("GameOverEvent"))

---@class GameStartDataSpec
---@field public pets Pet[] @ 参战的所有精灵

---@class GameStartData: GameStartDataSpec, TriggerData
GameStartData = TriggerData:subclass("GameStartData")

---@class GameStartEvent: Timing
---@field public data GameStartData
Seer:registerTiming("GameStart", Timing:subclass("GameStartEvent"))

return true
