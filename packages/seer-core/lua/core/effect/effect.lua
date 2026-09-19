-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 效果（Effect）============================
--
-- 一个效果由八样东西构成：
--
--   id           唯一标识
--   name         名字（日志 / UI 用）
--   reason       触发原因：为什么触发的
--   timing       触发时机：挂在哪个时机上
--   priority     优先级：越大越先触发，默认 0
--   can_trigger  触发条件：fun(effect, ctx): boolean
--   on_cost      代价：fun(effect, ctx)
--   on_use       执行效果：fun(effect, ctx)
--
-- 结算顺序：先 `can_trigger` 问够不够格，再 `on_cost` 付代价，最后 `on_use` 真结算。

---@class Effect: Object
---@field public id string|integer @ 唯一标识
---@field public name string @ 名字（没写就是 id 的字符串形式）
---@field public reason string? @ 触发原因
---@field public timing TriggerEvent? @ 触发时机
---@field public priority integer @ 优先级，越大越先触发，默认 0
Effect = class("Effect")

---@class EffectSpec
---@field public id string|integer @ 唯一标识
---@field public name? string @ 名字
---@field public reason? string @ 触发原因
---@field public timing? TriggerEvent @ 触发时机
---@field public priority? integer @ 优先级，越大越先触发，默认 0
---@field public can_trigger? function @ 触发条件 fun(effect, ctx): boolean
---@field public on_cost? function @ 代价 fun(effect, ctx)
---@field public on_use? function @ 执行效果 fun(effect, ctx)

---@param spec EffectSpec
function Effect:initialize(spec)
  spec = spec or {}
  assert(spec.id ~= nil, "Effect 需要 id")

  self.id = spec.id
  self.name = spec.name or tostring(spec.id)
  self.reason = spec.reason
  self.timing = spec.timing
  self.priority = spec.priority or 0
  self.can_trigger = spec.can_trigger
  self.on_cost = spec.on_cost
  self.on_use = spec.on_use
end

-- ---------------------------- 基本读取 ----------------------------

---@return string|integer
function Effect:getId() return self.id end

---@return string
function Effect:getName() return self.name end

---@return string? @ 触发原因
function Effect:getReason() return self.reason end

---@return string? @ 触发时机
function Effect:getTiming() return self.timing end

---@return integer @ 优先级，越大越先触发（没写就是 0）
function Effect:getPriority() return self.priority end

-- ---------------------------- 基本写入 ----------------------------

---@param name string
function Effect:setName(name) self.name = name end

---@param reason? string
function Effect:setReason(reason) self.reason = reason end

---@param timing? string
function Effect:setTiming(timing) self.timing = timing end

-- ---------------------------- 三个动作 ----------------------------
--
-- 把 `can_trigger` / `on_cost` / `on_use` 包一层：没写就是"不拦、不付、不做事"。

--- 触发条件：没写 can_trigger 就默认放行。
---@param ctx table
---@return boolean
function Effect:canTrigger(ctx)
  if not self.can_trigger then return true end
  return self.can_trigger(self, ctx) and true or false
end

--- 代价：没写 on_cost 就表示这个效果不用付代价。
---@param ctx table
function Effect:cost(ctx)
  if not self.on_cost then return end
  return self.on_cost(self, ctx)
end

--- 执行效果：没写 on_use 就什么都不做。
---@param ctx table
function Effect:use(ctx)
  if not self.on_use then return end
  return self.on_use(self, ctx)
end

function Effect:__tostring()
  return ("<Effect %s %s>"):format(tostring(self.id), tostring(self.name))
end

return Effect