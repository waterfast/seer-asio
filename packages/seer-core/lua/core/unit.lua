-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 对战方（Unit）============================
--
-- 一局对战有**两边**，每一边就是一个 Unit（一个玩家）。这一层要解决的问题是：
-- "有些东西是挂在一整方身上的，不是挂在某一只精灵身上的"——最典型的就是
-- **玩家方全局 buff**（"本场我方所有电系伤害翻倍"、"我方全体速度 +1" 这类）。
--
-- 于是 Unit 只有五样数据：
--
--   id          玩家 id（C++ 侧的玩家标识），可空
--   name        显示名，可空（日志 / UI 用）
--   pets        这一方的**全部精灵**（Pet[]，含没出战的）
--   active_pet  **当前出战精灵**（Pet?）——场上站着的那只，没有就是 nil
--   buffs       玩家方**全局 buff**（见下文"玩家方全局 buff"一节）
--
-- ---------------------------- 只做"基本属性 + 几个读点" ----------------------------
--
-- 和 `core/pet.lua` 一样，这个文件刻意**很薄**：读字段 + 补默认值 + 一堆 getter，
-- 外加三个小写入（`setActivePet` / `addBuff` / `getBuff`）。
--
-- 刻意**没有**做（它们全是战斗逻辑 / 协议 / 持久化的事）：
--   * 换精灵的规则（出战精灵倒下了换谁上场、换精灵要走哪些时机、能不能换）；
--   * buff 的结算（什么时候触发、能不能叠加、什么时候过期、怎么注册时机）；
--   * 手牌、道具、背包、胜负判定、"这一方是敌是友"；
--   * 存档序列化（哪一方是"我方"由 BattleLogic 决定，不由 Unit 自己记）。
--
-- 换句话说：Unit 是一份**数据快照 + 几个读点**，它不回答"接下来该干什么"。

-- ---------------------------- spec ----------------------------
--
-- 和其他模块一样，调用方只写表：
--
-- ```lua
-- local unit = Unit:new{ id = 1, name = "小赛尔", pets = { lei, bu } }
-- unit:setActivePet(lei)
-- ```

--- 造一个对战方需要哪些输入；全部可空，所以最小写法是 `Unit:new{}`。
---@class UnitSpec
---@field public id? integer @ 玩家 id，可空
---@field public name? string @ 显示名，可空
---@field public pets? Pet[] @ 这一方的全部精灵（含没出战的）；默认 `{}`
---@field public active_pet? Pet @ 当前出战精灵；默认 nil（还没人上场就是 nil，之后用 setActivePet 换）

--- 对战方：一个玩家在**这一局对战里**的状态。
---
--- 注意它**不是**一局的 Battle 本身：Battle 管两边的交互（谁先手、伤害怎么算、
--- 回合怎么走），Unit 只管"这一边有什么"。所以 Unit 里没有"对手"字段——
--- 想找对手就从 Battle 里找，别在这里存第二份，否则迟早会不同步。
---@class Unit: Object
---@field public id integer? @ 玩家 id，可空
---@field public name string? @ 显示名，可空
---@field public pets Pet[] @ 这一方的全部精灵（含没出战的）
---@field public active_pet Pet? @ 当前出战精灵；nil = 场上没人
---@field public buffs table[] @ 玩家方全局 buff；结构待定，见 `addBuff`
Unit = class("Unit")

--- 读字段 + 补默认值，仅此而已。
---
--- 除了"补默认值"，这里**不做**任何校验或联动：不检查出战精灵是不是自己带的、
--- 不触发任何时机、不注册任何东西——那些都是规则，归战斗逻辑管。
---@param spec UnitSpec?
function Unit:initialize(spec)
  spec = spec or {}

  self.id = spec.id
  self.name = spec.name

  -- 精灵列表默认空表而不是 nil：这样 getPets / hasPet 每处都不用再判空
  self.pets = spec.pets or {}

  -- 出战精灵默认 nil（还没人上场）。这里不校验它在不在 self.pets 里：
  -- "只能派自己带的精灵"是规则，由战斗逻辑保证。
  self.active_pet = spec.active_pet

  -- 玩家方全局 buff：先占个空表，结构见下面"玩家方全局 buff"一节
  self.buffs = {}
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

-- ---------------------------- 玩家方全局 buff ----------------------------
--
-- 这里装的是**挂在这一整方**身上的效果：不挂在某只具体的精灵身上，我方全体都受
-- 影响（"本场我方所有电系伤害翻倍"这种）。
--
-- 注意它和 `core/mark/buff.lua` 的 `BuffMark` **不是一回事**：BuffMark 挂在
-- **一只精灵**身上，那只是那一只的状态；Unit.buffs 属于一整方，精灵换了也还在。
--
-- **结构待定**：以后这里装 `core/effect/effect.lua` 的 Effect——一个玩家方全局
-- buff 就是一个挂在某个时机上、结算时改伤害 / 改属性的 Effect。但现在 Effect
-- 还没有"属于哪一方"的概念，过期 / 叠加规则也还没定，所以这里先做到最小：
-- 存进数组、按名字能查出来。叠加、过期、时机注册等定下来再补。

--- 加一个玩家方全局 buff。
--- 简单追加：不去重、不判断能不能叠加、不注册时机、不校验类型。
---@param effect Effect|table @ 待定：以后是 Effect 对象，现在只要是个表
function Unit:addBuff(effect)
  if effect == nil then return end
  table.insert(self.buffs, effect)
end

--- 按名字取一个玩家方全局 buff：先按 `buff.name` 匹配，再按 `buff.id` 匹配。
--- 同名有多个时**返回第一个**（叠加规则还没定，所以不做合并）。
---@param name string|integer @ buff 的名字或 id
---@return Effect|table? @ 没找到就是 nil
function Unit:getBuff(name)
  if name == nil then return nil end
  for _, buff in ipairs(self.buffs) do
    if type(buff) == "table" and (buff.name == name or buff.id == name) then
      return buff
    end
  end
  return nil
end

return Unit
