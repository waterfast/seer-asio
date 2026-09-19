-- SPDX-License-Identifier: GPL-3.0-or-later
-- 游戏对象统一保存身份和挂载效果。Unit、Pet、Skill、房间以及天气均可继承。
-- 每个对象有独立的效果数组；Effect 定义可共享，局内状态应放在挂载对象上。

---@class GameObject: Object
---@field public id integer|string? @ 对象标识；唯一性由所属容器保证
---@field public name string? @ 显示名
---@field public effects Effect[] @ 本对象挂载的效果，按挂载顺序保存
GameObject = class("GameObject")

---@class GameObjectSpec
---@field public id integer|string?
---@field public name string?
---@field public effects Effect[]?

---@param spec GameObjectSpec?
function GameObject:initialize(spec)
  spec = spec or {}
  self.id = spec.id
  self.name = spec.name
  self.effects = {}
  for _, effect in ipairs(spec.effects or {}) do
    self:addEffect(effect)
  end
end

---@return integer|string?
function GameObject:getId()
  return self.id
end

---@return string?
function GameObject:getName()
  return self.name
end

--- 返回挂载表。战斗每次触发重新读取，增删从下次触发开始生效。
---@return Effect[]
function GameObject:getEffects()
  return self.effects
end

--- 按引用挂载；重复挂载同一个定义不叠加，叠加规则由具体效果实现。
---@param effect Effect
---@return boolean added
function GameObject:addEffect(effect)
  assert(type(effect) == "table" and type(effect.getTiming) == "function",
    "GameObject:addEffect 需要 Effect 对象")
  for _, mounted in ipairs(self.effects) do
    if mounted == effect then return false end
  end
  table.insert(self.effects, effect)
  return true
end

--- 按引用卸载，避免相同 id 的不同实例互相影响。
---@param effect Effect
---@return boolean removed
function GameObject:removeEffect(effect)
  for i, mounted in ipairs(self.effects) do
    if mounted == effect then
      table.remove(self.effects, i)
      return true
    end
  end
  return false
end

function GameObject:__tostring()
  return ("<GameObject #%s %s>"):format(tostring(self.id), tostring(self.name))
end

return GameObject
