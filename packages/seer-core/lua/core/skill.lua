-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 技能 ============================
--
-- 对应 freekill-core 的 `ltk/core/skill.lua`。一个技能 = 基础数值（威力 / PP / 命中 /
-- 先制 / 暴击率 / 连击数）+ 一串效果（effects）+ 少量时机钩子（triggers）。
--
-- 这个类只有两件事：**初始化**（把 spec 的字段读进实例字段）和**读字段的 getter**。
-- 别的一概不做——技能对象是图鉴里**全局共享**的那一份，任何"随场上情况变化"的判断
-- （伤害、命中、能不能用、标签查询、技能栏、时机触发）都属于战斗逻辑，写在 core/ 下
-- 的其他文件里。所以这里没有分支、没有查询、不碰精灵。
--
-- 字段一览（spec 里叫什么，实例上就叫什么，一一对应；准确类型见下面的 `---@class Skill`）：
--
--   name      技能名。必需、非空，也是查表 / 翻译的键
--   id        数字 id，和 C++ 的 `USE_SKILL <id>` 对齐，可空
--   element   技能属性（"电" / "战斗" …）；nil = 随使用者本属性
--   category  物理 / 特殊 / 属性，见下面 Skill.Physical / Skill.Special / Skill.Status
--   power     威力，默认 0（属性技不写）
--   pp        初始 PP，默认 20
--   accuracy  命中率 0~100；nil 或 <=0 = 必中
--   priority  先制度，越大越先出手，默认 0
--   target    目标规则，默认 "enemy"
--   crit_rate 暴击率加成（1 = +1 级暴击率），默认 0
--   hits      连击次数：整数，或按场上情况算的函数，可空
--   usable    能不能用：false = 禁用；函数 = 按场上情况判断，可空。不写 = 能用
--             （仍受 PP / 封印限制；真正的判定由战斗逻辑负责，不在这里）
--   effects   效果列表，默认 {}，每项是一张效果 spec（`{ kind = "...", ... }`）
--   triggers  时机钩子表，可空（特性这类常驻的东西才用）
--   tags      标签数组，默认 {}
--   desc      描述，可空（正式描述走翻译表，这里只是给规则作者备注）
--   extra     给规则作者自用的任意数据，默认 {}

--- 技能类别：Skill.Physical / Skill.Special / Skill.Status
---@alias SkillCategory string

--- 一个技能。**只有数据，没有行为**：读它的字段用下面的 getter；要改它得在造它之前改 spec。
---@class Skill: Object
---@field public name string @ 技能名（全局唯一，也是查表 / 翻译的键）
---@field public id integer? @ 数字 id，和 C++ 的 `USE_SKILL <id>` 对齐
---@field public element string? @ 技能属性；nil 表示"随使用者本属性"
---@field public category SkillCategory @ Skill.Physical / Skill.Special / Skill.Status
---@field public power integer @ 威力（属性技是 0）
---@field public pp integer @ 初始 PP
---@field public accuracy integer? @ 命中率 0~100；nil 表示必中
---@field public priority integer @ 先制度，越大越先出手
---@field public target string @ "enemy" / "self" / "ally" / "all_enemies" / "field"
---@field public crit_rate integer @ 暴击率加成（1 表示 +1 级暴击率）
---@field public hits integer|fun(self: Skill, source: Pet, target: Pet, logic: BattleLogic): integer @ 连击次数；整数或函数，可空
---@field public usable boolean|fun(skill: Skill, pet: Pet, context: table): boolean @ 能不能用；可空（nil = 能用，仍受 PP / 封印限制）
---@field public effects Effect[] @ 效果列表，每项是一张效果
---@field public tags string[] @ 标签
---@field public desc string? @ 描述（给规则作者备注用）
---@field public extra table<string, any> @ 规则作者自用的任意数据
Skill = class("Skill")

-- ---------------------------- 类别常量 ----------------------------
--
-- 值是**字符串**不是枚举数字：它们会直接出现在 spec 里（`category = "special"`）、
-- 出现在日志和协议里，字符串能让排查问题的人一眼看懂。代价是拼错了不报错、
-- 只会悄悄退化成默认值——所以规则作者请一律写 `Skill.Special`，别手打字符串。

--- 物理攻击：用攻击 / 防御算伤害
Skill.Physical = "physical"
--- 特殊攻击：用特攻 / 特防算伤害
Skill.Special = "special"
--- 属性（变化）技：不造成伤害，靠 effects 生效
Skill.Status = "status"

-- ---------------------------- spec ----------------------------

--- 规则作者写的就是这张表（"spec 方式"）。只有 `name` 是必需的，其余不写就用默认值。
---@class SkillSpec
---@field public name string @ 技能名，必须全局唯一（也是查表、翻译的键）
---@field public id? integer @ 数字 id，用于和 C++ 侧 `USE_SKILL <id>` 对齐
---@field public element? string @ 技能属性（如 "电"）；nil 表示"随使用者本属性"
---@field public category? SkillCategory @ 物理 / 特殊 / 属性，默认 Skill.Physical
---@field public power? integer @ 威力，默认 0；属性技（状态技）不填
---@field public pp? integer @ 初始 PP，默认 20
---@field public accuracy? integer @ 命中率 0~100，默认 0（必中）；写 >=1000 也算必中
---@field public priority? integer @ 先制度，越大越先出手，默认 0，先制>1000为必中
---@field public target? string @ "enemy"（单体敌方）/ "self" / "ally" / "all_enemies" / "field"，默认 "enemy"
---@field public crit_rate? integer @ 暴击率加成（1 表示 +1 级暴击率），默认 0
---@field public hits? integer|fun(self: Skill, source: Pet, target: Pet, logic: BattleLogic): integer @ 连击次数；整数，或写成函数按场上情况算
---@field public usable? boolean|fun(skill: Skill, pet: Pet, context: table): boolean @ 能不能用：`false` = 被禁止使用；函数 = 按场上情况判断；不写 = 能用（仍受 PP / 封印限制）
---@field public effects? EffectSpec[] @ 效果列表
---@field public tags? string[] @ 标签：用数值表达不了的性质才做成标签（"先制 +1" 用 priority，不做标签）
---@field public desc? string @ 描述（正式描述走翻译表，这里只是给规则作者备注）
---@field public extra? table<string, any> @ 塞给规则作者自用的任意数据

--- 造一个技能：读字段 + 补默认值，仅此而已。
---@param spec SkillSpec
function Skill:initialize(spec)
  spec = spec or {}

  if type(spec.name) ~= "string" or spec.name == "" then
    error("Skill 需要一个非空的 name", 2)
  end

  self.name = spec.name
  self.id = spec.id

  -- element 的 nil 是**有含义**的："这个技能的属性随使用者本属性"，
  -- 所以这里不能补默认值——读的人要能区分"没写"和"写了"。
  self.element = spec.element

  self.category = spec.category or Skill.Physical
  self.power = spec.power or 0
  self.pp = spec.pp or 20
  self.accuracy = spec.accuracy or 0
  self.priority = spec.priority or 0
  self.target = spec.target or "enemy"
  self.crit_rate = spec.crit_rate or 0 --暴击率

  -- 这两个"可以是函数"的字段原样留着，由用它的地方判断类型
  self.hits = spec.hits
  self.usable = spec.usable

  self.effects = spec.effects or {}
  self.triggers = spec.triggers
  self.tags = spec.tags or {}
  self.desc = spec.desc
  self.extra = spec.extra or {}
end

---@return string @ 形如 `<Skill 撞击>`
function Skill:__tostring()
  return ("<Skill %s>"):format(self.name)
end

-- ============================ 读字段 ============================
--
-- 全是**只读转发**：没有分支、没有查询、不碰精灵。
-- "随场上情况算出来"的版本（威力浮动、命中判定、能不能用……）属于战斗逻辑，不在这里。

---@return string
function Skill:getName()
  return self.name
end

---@return integer?
function Skill:getId()
  return self.id
end

--- 技能属性。返回 nil 表示"随使用者本属性"——由调用方去问使用者的种族。
---@return string?
function Skill:getElement()
  return self.element
end

---@return SkillCategory
function Skill:getCategory()
  return self.category
end

---@return integer
function Skill:getPower()
  return self.power
end

---@return integer
function Skill:getPP()
  return self.pp
end

--- 先制度，越大越先出手。
---@return integer
function Skill:getPriority()
  return self.priority
end

--- 命中率。返回 nil（或 <=0）表示必中。
---@return integer?
function Skill:getAccuracy()
  return self.accuracy
end

---@return integer
function Skill:getCritRate()
  return self.crit_rate
end

--- 连击次数：可能是整数，也可能是 `fun(self, source, target, logic)`，没写就是 nil。
---@return integer|fun(self: Skill, source: Pet, target: Pet, logic: BattleLogic): integer
function Skill:getHits()
  return self.hits
end

---@return string
function Skill:getTarget()
  return self.target
end

---@return EffectSpec[]
function Skill:getEffects()
  return self.effects
end

---@return string[]
function Skill:getTags()
  return self.tags
end

---@return string?
function Skill:getDesc()
  return self.desc
end

---@return boolean
function Skill:isPhysical()
  return self.category == Skill.Physical
end

---@return boolean
function Skill:isSpecial()
  return self.category == Skill.Special
end

---@return boolean
function Skill:isStatus()
  return self.category == Skill.Status
end

--- 会不会造成伤害：类别不是属性技，且威力大于 0。
--- 属性技即使写了 power 也不算伤害技——看类别，不看威力。
---@return boolean
function Skill:isDamaging()
  return self.category ~= Skill.Status and (self.power or 0) > 0
end

return {
  Skill = Skill,
}
