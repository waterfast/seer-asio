-- SPDX-License-Identifier: GPL-3.0-or-later
-- 一次时机的效果结算队列。GameLogic 先筛选时机和来源，Handler 只排序与执行。
-- 不持有全局效果索引，也不自行遍历房间、精灵或技能。

---@class EffectContext
---@field logic GameLogic
---@field room BattleRoom
---@field event TriggerEvent
---@field timing TriggerEvent @ 时机类
---@field source GameObject? @ 本次行为来源，不一定是效果拥有者
---@field target GameObject?
---@field skill Skill?
---@field data TriggerData? @ 本次时机可修改的数据；效果间共享
---@field damage integer? @ 兼容读点；修改结算数值请使用 data
---@field owner GameObject? @ 当前效果的拥有者；技能效果为使用者
---@field effect_source GameObject? @ 挂载效果的对象；技能效果为 Skill

---@class EffectHandler: Object
---@field public queue table[] @ { owner, effect_source, effect, sequence }
EffectHandler = class("EffectHandler")

function EffectHandler:initialize()
  self.queue = {}
end

--- 只接收调用方已经筛选好的效果，保持加入顺序作为同优先级的次序。
---@param owner GameObject?
---@param effect Effect?
---@param effect_source GameObject?
function EffectHandler:addEffect(owner, effect, effect_source)
  if effect == nil then return end
  table.insert(self.queue, {
    owner = owner, effect_source = effect_source or owner,
    effect = effect, sequence = #self.queue + 1,
  })
end

---@param owner GameObject?
---@param effects Effect[]?
---@param effect_source GameObject?
function EffectHandler:addEffects(owner, effects, effect_source)
  for _, effect in ipairs(effects or {}) do
    self:addEffect(owner, effect, effect_source)
  end
end

--- 结算本次队列快照。挂载变化不改写正在执行的队列，嵌套 trigger 会重新收集。
--- 每项拥有独立 ctx，data/event 仍共享，避免嵌套触发或其他效果覆盖 owner。
--- on_use 返回 true 或设置 event.broken 可打断本时机；on_cost 返回 false 放弃本效果。
---@param ctx EffectContext
---@return boolean broken
function EffectHandler:resolve(ctx)
  table.sort(self.queue, function(a, b)
    local pa, pb = a.effect:getPriority(), b.effect:getPriority()
    if pa ~= pb then return pa > pb end
    return a.sequence < b.sequence
  end)
  local event = ctx.event
  for _, entry in ipairs(self.queue) do
    if event and (event.broken or event:breakCheck()) then
      event.broken = true
      break
    end
    local effect_ctx = {}
    for key, value in pairs(ctx) do effect_ctx[key] = value end
    effect_ctx.owner = entry.owner
    effect_ctx.effect_source = entry.effect_source
    if effect_ctx.data then effect_ctx.damage = effect_ctx.data.damage end
    local effect = entry.effect
    if effect:canTrigger(effect_ctx) and effect:cost(effect_ctx) ~= false then
      local broken = effect:use(effect_ctx)
      if event and (broken == true or event.broken or event:breakCheck()) then
        event.broken = true
        event.break_reason = event.break_reason or effect:getName()
        break
      end
    end
  end
  return event ~= nil and event.broken == true
end

function EffectHandler:clear()
  self.queue = {}
end

---@return integer
function EffectHandler:count()
  return #self.queue
end

return EffectHandler
