-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 效果处理器（EffectHandler）============================
--
-- 管"一批 Effect 怎么收集、排序、筛选、执行"。它是 Effect 系统的 dispatcher /
-- executor：候选池在这里，怎么触发也在这里。
--
-- 职责边界（重要，别越界）：
--   * EffectHandler 只决定"候选池怎么执行"；
--   * BattleLogic（调用方）决定"哪些 Effect 有资格进候选池"——用
--     `addEffects(owner, effects)` 一把把往里喂：当前技能的效果、被动技能的效果、
--     身上的持续效果、buff 的效果……Handler 不知道、也不该知道这些效果从哪来。
--
--     换句话说：**不要**写 `EffectHandler:collectAllEffects(battle, pet, skill)`
--     然后让 handler 自己去翻 pet.skills / pet.feature / weather / buff 这些——
--     那样它会和整个 Battle 系统死死耦合在一起。
--
-- 依赖方向：
--     BattleLogic → EffectHandler → Effect
--   别反过来让 EffectHandler 依赖 BattleLogic，否则 Effect 模块会越来越难复用。
--
-- 用法：
--   local handler = EffectHandler:new()
--   handler:addEffects(pet, skill.effects)          -- 当前使用的技能
--   handler:addEffects(pet, pet:getPassiveSkills()) -- 携带的被动技能（按各家实现取名）
--   handler:addEffects(pet, pet:getEffects())       -- 身上的持续效果
--   handler:trigger(SeerTiming.AfterSkillUse, ctx)
--
-- 队列里每一项是 `{ owner = ..., effect = ... }`。owner 是"这个效果属于谁"（通常是
-- 一只精灵，也可能是 buff / 天气 / 技能本身），要"对谁生效"就从 entry.owner 或
-- ctx 里取。handler 本身不解释 owner。

---@class EffectHandler: Object
---@field public queue table[] @ `{ owner = any, effect = Effect }` 的数组（候选池）
EffectHandler = class("EffectHandler")

function EffectHandler:initialize()
  self.queue = {}
end

--- 往候选池里加一批效果。
---@param owner any @ 这批效果属于谁（精灵 / buff / 天气 / 技能本身……）
---@param effects Effect[]? @ 效果数组；nil / 空表都安全
function EffectHandler:addEffects(owner, effects)
  for _, effect in ipairs(effects or {}) do
    table.insert(self.queue, { owner = owner, effect = effect })
  end
end

--- 加单个效果（addEffects 的语法糖）。
---@param owner any
---@param effect Effect?
function EffectHandler:addEffect(owner, effect)
  if effect ~= nil then
    table.insert(self.queue, { owner = owner, effect = effect })
  end
end

--- 执行候选池里"挂在 `timing` 上、且 `canTrigger` 通过"的效果。
--
-- 排序：按优先级**从高到低**（高优先级先触发）。这与引擎里 skill_table / 印记触发器
-- 的"优先级降序"保持一致；`priority` 目前还不是 Effect 的正式字段（读到 nil 按 0），
-- 等 Effect 加上 priority 字段后这里自动生效。
--
-- 时机匹配：`effect:getTiming() == timing`，两边得是**同一个对象**（同是时机类、或
-- 同是字符串）；一个效果没写 timing（nil）就永远不匹配。
--
-- 结算顺序照 Effect 的契约：先 `canTrigger` 问够不够格，再 `cost` 付代价，
-- 最后 `use` 真结算。
---@param timing TriggerEvent|string @ 时机（SeerTiming.Xxx，或同名字符串）
---@param ctx table @ 结算上下文（原样传给 canTrigger / cost / use）
function EffectHandler:trigger(timing, ctx)
  table.sort(self.queue, function(a, b)
    return (a.effect.priority or 0) > (b.effect.priority or 0)
  end)

  for _, entry in ipairs(self.queue) do
    local effect = entry.effect
    if effect:getTiming() == timing and effect:canTrigger(ctx) then
      effect:cost(ctx)
      effect:use(ctx)
    end
  end
end

--- 清空候选池（同一个 handler 复用，比如一个回合里多次结算）。
function EffectHandler:clear()
  self.queue = {}
end

---@return integer @ 候选池里还剩几个效果
function EffectHandler:count()
  return #self.queue
end

return EffectHandler
