-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 增益印记类 ============================
--
-- 增益印记（护盾、强化、加速……）和异常状态是**同一个基类**（Mark），
-- 只是"对谁好"不同。放在同一个体系里的好处很具体：
--
--   * 回合数递减、叠层、挂在谁身上、能被清除、能被 UI 展示 —— 一份实现；
--   * `logic:cureStatus` **只清弱化类/控制类**（`Mark.STATUS_TYPES`），
--     所以"解毒"不会顺手把护盾也拆了；
--   * 面板上要列"身上有什么"时，两类东西在一块儿，不用拼两个表。
--
-- 和异常状态类的差别：增益印记没有"默认每回合掉血/掐掉行动"这种类别行为，
-- 每一个的机制都不一样（护盾是抵挡、强化是改数值、加速是改速度……），
-- 所以 `Buff.register` 只补默认值（类型、不叠加），具体机制靠
-- `triggers`（被动钩子）、`stat_multipliers`（持续倍率）或 `effects`（挂上那一刻）。
--
-- 具体玩法自己造的增益印记（"本次战斗电系伤害翻倍"这类）应该注册在**扩展包里**
-- （`lua/specs/<包名>/marks.lua`），核心只放通用到哪儿都成立的那几个。

--- 增益印记基类。
---@class BuffMark: Mark
BuffMark = Mark:subclass("BuffMark")

function BuffMark:initialize(key, opts)
  Mark.initialize(self, key, opts)
  if self.def.mark_type ~= Mark.TYPE.BUFF then
    error(("增益印记 %s 的类型必须是 buff，收到 %s"):format(key, tostring(self.def.mark_type)), 2)
  end
end

function BuffMark:isBuff() return true end
function BuffMark:isStatus() return false end

---@return string @ "增益类"
function BuffMark:getClassName() return Mark.TYPE_NAME[Mark.TYPE.BUFF] end

--- 增益印记模块。`Mark.Buff` 就是它。
---@class BuffModule
local Buff = {
  class = BuffMark,
}

--- 注册一个增益印记。
---@param key string
---@param def MarkDef
---@return MarkDef
function Buff.register(key, def)
  def = def or {}
  def.mark_type = Mark.TYPE.BUFF
  def.max_stacks = def.max_stacks or 1
  Mark._register(key, def)
  return def
end

---@param key string
---@return MarkDef?
function Buff.get(key) return Mark.defs[key] end

---@param key string
---@return boolean
function Buff.is(key) return Mark.isBuffKey(key) end

-- ============================ 内置的增益印记 ============================
--
-- 这两个是**通用例子**，同时也是"增益印记也是印记"的证明：
-- 它们除了 `mark_type` 和具体钩子之外，和异常状态没有任何结构上的区别。

--- 护盾：抵挡下一次受到的攻击，然后自己消失。
--- 演示了两件事：`triggers` 挂在**受击方**身上改伤害；"用完即走"用 removeMark("consumed")。
Buff.register("shield", {
  name = "护盾",
  desc = "增益类印记：抵挡下一次受到的攻击，3 回合内没被打到就自己消失",
  duration = 3,
  triggers = {
    [Mark.timing("DetermineDamage")] = {
      priority = 0,
      on_trigger = function(trig, timing_obj, target, pet, data)
        local mark = trig.mark
        if data.target ~= mark.pet then return false end
        data:preventDamage()
        mark.logic:removeMark(mark.pet, mark.key, "consumed")
        return false
      end,
    },
  },
})

--- 强化印记：攻击与特攻 ×1.5。
--- 它一行触发器都不用写——`stat_multipliers` 由 `pet:recalcStats()` 直接算进字段。
Buff.register("empower", {
  name = "强化印记",
  desc = "增益类印记：攻击与特攻提升到 1.5 倍，持续 3 回合",
  duration = 3,
  stat_multipliers = { attack = 1.5, sp_attack = 1.5 },
})

return Buff
