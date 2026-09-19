-- SPDX-License-Identifier: GPL-3.0-or-later
local GameObject = require "core.gameobject"
-- 对战方保存一个玩家的局内数据：精灵、出战精灵和继承自 GameObject 的 effects。
-- 规则层负责切换精灵和结算；Unit 只保存状态与提供挂载 API。
-- 旧 buffs/addBuff/getBuff 是同一张效果表的兼容读写口，不另建效果池。

--- 造一个对战方需要哪些输入；全部可空，所以最小写法是 `Unit:new{}`。
---@class UnitSpec: GameObjectSpec
---@field public id? integer @ 玩家 id，可空
---@field public name? string @ 显示名，可空
---@field public pets? Pet[] @ 这一方的全部精灵（含没出战的）；默认 `{}`
---@field public active_pet? Pet @ 当前出战精灵；默认 nil（还没人上场就是 nil，之后用 setActivePet 换）

--- 对战方：一个玩家在**这一局对战里**的状态。
---
--- 注意它**不是**一局的 Battle 本身：Battle 管两边的交互（谁先手、伤害怎么算、
--- 回合怎么走），Unit 只管"这一边有什么"。所以 Unit 里没有"对手"字段——
--- 想找对手就从 Battle 里找，别在这里存第二份，否则迟早会不同步。
---@class Unit: GameObject
---@field public id integer? @ 玩家 id，可空
---@field public name string? @ 显示名，可空
---@field public pets Pet[] @ 这一方的全部精灵（含没出战的）
---@field public active_pet Pet? @ 当前出战精灵；nil = 场上没人
---@field public buffs Effect[] @ effects 的兼容别名
Unit = GameObject:subclass("Unit")

--- 读字段 + 补默认值，仅此而已。
---
--- 挂载效果沿用 GameObject 的基本检查；这里不检查出战精灵是不是自己带的、
--- 不触发任何时机、不注册任何东西——那些都是规则，归战斗逻辑管。
---@param spec UnitSpec?
function Unit:initialize(spec)
  spec = spec or {}
  GameObject.initialize(self, spec)

  -- 精灵列表默认空表而不是 nil：这样 getPets / hasPet 每处都不用再判空
  self.pets = spec.pets or {}

  -- 出战精灵默认 nil（还没人上场）。这里不校验它在不在 self.pets 里：
  -- "只能派自己带的精灵"是规则，由战斗逻辑保证。
  self.active_pet = spec.active_pet

  -- 与 effects 共用同一张挂载表，不产生第二份效果来源。
  self.buffs = self.effects
end

function Unit:__tostring()
  local id = self.id ~= nil and tostring(self.id) or "?"
  local name = self.name ~= nil and ("(" .. self.name .. ")") or ""
  local active = "无出战"
  if self.active_pet ~= nil then
    active = ("%s(出战)"):format(self.active_pet.name or "?")
  end
  return ("<Unit %s%s: %s x%d>"):format(id, name, active, #self.pets)
end

-- ---------------------------- getter ----------------------------
--
-- 和 Pet 一样，全是**纯读字段**：不触发任何时机、不改任何东西，
-- 所以在战斗逻辑的任意时刻调用都是安全的。

---@return integer? @ 玩家 id（没写就是 nil）
function Unit:getId()
  return self.id
end

---@return string? @ 显示名（没写就是 nil，可空是允许的：日志里叫 id 也行）
function Unit:getName()
  return self.name
end

--- 这一方的**全部**精灵（不是只剩"还能出战的"——那要按当前体力筛，是战斗逻辑的事）。
---@return Pet[] @ 内部表本身（**要增删精灵就在这里改**，本模块不提供增删接口）
function Unit:getPets()
  return self.pets
end

---@return Pet? @ 当前出战精灵；nil = 场上没人（比如正在换精灵）
function Unit:getActivePet()
  return self.active_pet
end

---@return table[] @ 玩家方全局 buff（内部表本身；要加请用 `addBuff`）
function Unit:getBuffs()
  return self.buffs
end

--- 这一方有没有这只精灵。
--- 按**引用**比较（同一只精灵对象），不按名字——名字可以重复，对象不会。
---@param pet Pet? @ 传 nil 安全，返回 false
---@return boolean
function Unit:hasPet(pet)
  if pet == nil then return false end
  for _, p in ipairs(self.pets) do
    if p == pet then return true end
  end
  return false
end

--- 这只精灵是不是**当前出战**的那只。同样按引用比较。
---@param pet Pet? @ 传 nil 安全，返回 false
---@return boolean
function Unit:isActive(pet)
  return pet ~= nil and self.active_pet == pet
end

-- ---------------------------- 小写入 ----------------------------

--- 设置当前出战精灵。传 nil 表示场上没人（比如换精灵的空档）。
---
--- 本模块**只改字段**：不校验这只精灵属不属于这一方、不检查它是不是濒死、
--- 也不触发"上场/下场"的时机——那些都是战斗逻辑的事（要发通知、要走时机）。
---@param pet Pet? @ 新的出战精灵；nil = 清空
function Unit:setActivePet(pet)
  self.active_pet = pet
end

-- ---------------------------- 旧 buff API 兼容 ----------------------------
-- 玩家方效果统一挂在 effects；旧 API 转发到同一张表，不再维护第二份效果来源。

---@param effect Effect
---@return boolean added
function Unit:addBuff(effect)
  if effect == nil then return false end
  return self:addEffect(effect)
end

--- 按名字或 id 返回第一个效果；新代码优先用 GameObject 的挂载 API。
---@param name string|integer
---@return Effect?
function Unit:getBuff(name)
  if name == nil then return nil end
  for _, effect in ipairs(self.effects) do
    if effect.name == name or effect.id == name then return effect end
  end
  return nil
end

return Unit
