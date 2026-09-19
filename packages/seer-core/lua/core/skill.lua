-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 技能 ============================
--
-- 对应 freekill-core 的 `ltk/core/skill.lua`（Skill / UsableSkill）、
-- `ltk/core/skill_skeleton.lua`（SkillSkeleton）和
-- `ltk/core/skill_type/trigger.lua`（TriggerSkill）。
--
-- ---------------------------- "spec 方式"是什么 ----------------------------
--[[
Skill 应该有几个变量
id 唯一标识
name 名称并提供翻译表？
type 特殊/物理/属性/被动
useable 是否可使用
pp 技能pp值
Combo 连击次数；也可以写
effect
element 属性
accuracy 命中率 >1000为必中技能
critical 暴击率
is_attack 是否攻击技能
--]]

--- 物理攻击 / 特殊攻击 / 属性（变化）
---@alias SkillCategory string

---@class SkillTag
--- 标签是"可以被技能/效果查询的布尔属性"。
--- 注意：赛尔号里"先制 +1"其实用 `priority` 数值表达，不必做成标签；
--- 这里只放那些**用数值表达不了**的性质。
---@field public Compulsory string @ 必发（锁定技）：不询问玩家，直接发动
---@field public name string @ 名称
---@field public NeverMiss string @ 同必中（语义上区分"自身必中"与"无视对方闪避"）
---@field public Contact string @ 接触类攻击（会触发对方的"受到接触攻击时"类特性）
---@field public Sound string @ 音波类
---@field public Punch string @ 拳击类
---@field public Bite string @ 啃咬类
---@field public Recharge string @ 蓄力技（本回合蓄力，下回合发动）
---@field public TwoTurn string @ 两回合技
---@field public Recoil string @ 有反作用力
---@field public Exclusive string @ 专属技
---@field public Ability string @ 特性（不是技能，但走同一套时机机制）
---@field public Legendary string @ 传说级技能
Skill = class("Skill")

--- ```
---@class SkillSpec
---@field public name string @ 技能名，必须全局唯一（也是查表、翻译的键）
---@field public id? integer @ 数字 id，用于和 C++ 侧 `USE_SKILL <id>` 对齐
---@field public element? string @ 技能属性；nil 表示"随精灵本属性"
---@field public category? SkillCategory @ 物理/特殊/属性，默认物理
---@field public power? integer @ 威力；属性技（状态技）不填
---@field public pp? integer @ 初始 PP，默认 20
---@field public accuracy? integer @ 命中率（0~100）；nil 或 <=0 表示必中
---@field public priority? integer @ 先制度，越大越先出手；默认 0
---@field public target? string @ 目标规则："enemy"（单体敌方）/ "self" / "ally" / "all_enemies" / "field"
---@field public crit_rate? integer @ 暴击率加成（1 表示 +1 级暴击率），默认 0
---@field public hits? integer|function @ 连击次数；也可以写 `fun(self, source, target, logic): integer`
---@field public usable? boolean|function @ 能不能用：`false` = 被禁止使用；也可以写 `fun(skill, pet, context): boolean` 按场上情况判断。不写 = 能用（但仍受 PP / 封印限制）
---@field public effects? table[] @ 效果 spec 列表，见 core/effect/init.lua
---@field public triggers? table @ 时机钩子表：`[Timing 子类] = TrigSpec`（特性/持续效果用）
---@field public tags? SkillTag[] @ 标签
---@field public desc? string @ 描述（正式描述走翻译表，这里只是给规则作者备注）
---@field public extra? table @ 塞给规则作者自用的任意数据

---@param spec SkillSpec
function Skill:initialize(spec)
  spec = spec or {}

  if type(spec.name) ~= "string" or spec.name == "" then
    error("Skill 需要一个非空的 name", 2)
  end

  self.name = spec.name
  self.id = spec.id
  -- 骨架名可能带 `#` 前缀（自动生成的子对象），`#` 开头的不显示在技能栏
  local name_splited = self.name:split("__")
  self.trueName = name_splited[#name_splited]
  self.visible = not self.name:startsWith("#")

  self.package = spec.package or { extensionName = "seer-core" }

  self.element = spec.element
  self.category = spec.category or Skill.Physical
  self.power = spec.power or 0
  self.pp = spec.pp or 20
  self.accuracy = spec.accuracy
  self.priority = spec.priority or 0
  self.target = spec.target or "enemy"
  self.crit_rate = spec.crit_rate or 0
  self.hits = spec.hits

  -- 技能的主要内容：一串效果。赛尔号的技能基本就是"数值 + 效果拼装"，
  -- 所以 effects 是主线，triggers 只是少数东西（特性）才需要。
  self.effects = spec.effects or {}
  self.tags = spec.tags or {}
  self.desc = spec.desc
  self.extra = spec.extra or {}

  -- "能不能用"是技能自己的一等属性，不是第五技能专属的东西：
  --   * `usable = false`         —— 这个技能现在被禁止使用；
  --   * `usable = function(...)` —— 要看场上情况（有相当一部分技能带前提）。
  -- 早期写法把条件塞在 `extra.usable` 里，为了不破坏已有的 spec，这里读一次收上来。
  --
  -- 注意技能对象是**全局共享**的（图鉴里就那一份，所有精灵共用），
  -- 所以"只封住某一只精灵的这个技能"不能改这里，要用 `pet:sealSkill(name)`。
  self.usable = spec.usable
  if self.usable == nil then self.usable = self.extra.usable end

  -- 一个技能可以由好几个对象拼成（主技能 + 各时机的子技能），
  -- 它们互相通过 related_skills / main_skill 找得到对方
  self.related_skills = {}
  self.main_skill = nil
  self.skeleton = nil
  self.global = false
end

function Skill:__tostring()
  return ("<Skill %s>"):format(self.name)
end

-- ============================ 基本属性 ============================

--- 这个技能是什么属性。
--- spec 里没写就取使用者的本属性（赛尔号里"普通系技能"要显式写 "普通"）
---@param pet? Pet @ 使用者
---@return string?
function Skill:getElement(pet)
  if self.element then return self.element end
  if pet and pet.species then
    return pet.species:getPrimaryElement()
  end
  return nil
end

---@return boolean
function Skill:isPhysical() return self.category == Skill.Physical end

---@return boolean
function Skill:isSpecial() return self.category == Skill.Special end

---@return boolean
function Skill:isStatus() return self.category == Skill.Status end

--- 是不是会造成伤害的技能
---@return boolean
function Skill:isDamaging()
  return self.category ~= Skill.Status and (self.power or 0) > 0
end

--- 威力。留成方法是为了给"威力随回合/连续使用递增"这类技能留口子。
---@param pet? Pet @ 使用者
---@param target? Pet @ 目标
---@return integer
function Skill:getPower(pet, target)
  local power = self.power or 0
  local override = self.extra and self.extra.power_func
  if type(override) == "function" then
    power = override(self, pet, target) or power
  end
  return power
end

--- 命中率。返回 nil 表示必中。
---@param pet? Pet
---@param target? Pet
---@return integer?
function Skill:getAccuracy(pet, target)
  if self:hasTag(Skill.SureHit) then return nil end
  local acc = self.accuracy
  if acc == nil or acc <= 0 then return nil end
  local override = self.extra and self.extra.accuracy_func
  if type(override) == "function" then
    acc = override(self, pet, target) or acc
  end
  return acc
end

---@return integer
function Skill:getPP()
  return self.pp or 0
end

---@return integer
function Skill:getPriority()
  return self.priority or 0
end


return {
  Skill = Skill,
}
