-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 技能 ============================
--
-- 对应 freekill-core 的 `ltk/core/skill.lua`（Skill / UsableSkill）、
-- `ltk/core/skill_skeleton.lua`（SkillSkeleton）和
-- `ltk/core/skill_type/trigger.lua`（TriggerSkill）。
--
-- ---------------------------- "spec 方式"是什么 ----------------------------
--
-- 一套技能要回答两个问题：
--   1. 一个技能长什么样（数值、属性、效果）—— 这是**数据**；
--   2. 一个技能怎么发动、什么时候发动、效果怎么结算 —— 这是**代码**。
--
-- freekill 的做法是：**规则作者只写一张声明式的表（spec），由核心去把它"造"成对象**。
-- 表里每个键就是一个"效果类型"，核心逐键调用对应的 createXXXSkill 工厂，
-- 产出一个（可能不止一个）技能对象。这套做法的好处：
--
--   * 规则作者不碰面向对象：写 `power = 40` 就行，不用 `:new()`、不用管继承；
--   * 引擎能**统一**处理横切逻辑：次数限制、优先级、可见性、翻译表、
--     重复注册告警……都在工厂里做一次，所有技能都受益；
--   * 一个技能可以**横跨多个时机**：主效果 + 若干时机钩子，被自动拆成
--     `#名字_序号_类型` 的子对象并挂到 `related_skills` 上。
--
-- 本项目照搬这套。本文件里的三层是：
--
--   SkillSkeleton  —— spec 的持有者 + 工厂。作者写一张表，交给它 `createSkill()`。
--   Skill          —— 运行时对象，管"数值"（威力/命中/PP/属性/效果列表）。
--   TriggerSkill   —— 运行时对象，管"时机"（某个 Timing 类上的一次钩子）。
--
-- 为什么"效果列表"不在这里造对象？因为赛尔号的"效果"是独立的一等公民
-- （会挂在精灵身上、有回合数、能被清除），所以它有自己的类：core/effect/init.lua。
-- Skill 只负责**描述**效果（存 spec），真正造出 Effect 实例是 Effect 自己的事。

--- 物理攻击 / 特殊攻击 / 属性（变化）
---@alias SkillCategory string

---@class SkillTag
--- 标签是"可以被技能/效果查询的布尔属性"。
--- 注意：赛尔号里"先制 +1"其实用 `priority` 数值表达，不必做成标签；
--- 这里只放那些**用数值表达不了**的性质。
---@field public Compulsory string @ 必发（锁定技）：不询问玩家，直接发动
---@field public SureHit string @ 必中（无视命中判定）
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

-- 分类常量（写成字符串而不是数字：存进 SQLite / JSON 时人可读）
Skill.Physical = "physical"
Skill.Special = "special"
Skill.Status = "status"

-- 标签常量
Skill.Compulsory = "Compulsory"
Skill.SureHit = "SureHit"
Skill.NeverMiss = "NeverMiss"
Skill.Contact = "Contact"
Skill.Sound = "Sound"
Skill.Punch = "Punch"
Skill.Bite = "Bite"
Skill.Recharge = "Recharge"
Skill.TwoTurn = "TwoTurn"
Skill.Recoil = "Recoil"
Skill.Exclusive = "Exclusive"
Skill.Ability = "Ability"
Skill.Legendary = "Legendary"

--- "这个技能为什么用不出来"。集中成一份常量，是因为有三个地方要用同一套词：
--- 流程里拦住技能时的播报、给客户端的"这个技能为什么是灰的"、以及测试。
--- 判断一律返回**原因字符串**而不是光一个 false——UI 得能显示"PP 不足"还是"被封印"。
Skill.Unusable = {
  NO_PET    = "no_pet",    -- 没有使用者（一般说明流程代码传错了）
  NO_SKILL  = "no_skill",  -- 这只精灵身上没有这个技能（名字写错/被换掉了）
  SEALED    = "sealed",    -- 被封印 / 被无效化（pet:sealSkill）
  NO_PP     = "no_pp",     -- PP 用完了
  FORBIDDEN = "forbidden", -- 技能自己写着不能用（usable = false）
  CONDITION = "condition", -- 技能写了条件，这次不满足
  -- 下面两个不是"某个技能不可用"，而是"这回合索性没有技能可用"：
  NO_SKILL_CHOSEN = "no_skill_chosen", -- 玩家/客户端这回合没给出技能
  NO_USABLE_SKILL = "no_usable_skill", -- 手上一个能用的技能都没有
}
Skill.UnusableText = {
  no_pet          = "没有使用者",
  no_skill        = "没有这个技能",
  sealed          = "技能被封印",
  no_pp           = "PP 已用完",
  forbidden       = "该技能现在无法使用",
  condition       = "使用条件不满足",
  no_skill_chosen = "这回合没有选择技能",
  no_usable_skill = "没有可以使用的技能",
}

--- 技能 spec —— 规则作者实际写的那张表。
--- 例：
--- ```lua
--- return {
---   name = "火花", id = 1002, element = "火", category = Skill.Special,
---   power = 40, pp = 25, accuracy = 100, priority = 0, target = "enemy",
---   effects = { { kind = "status", status = "burn", probability = 10 } },
--- }
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

--- 这一击打几下（连击）。
--- 每次连击都是一次**独立的伤害结算**（各自过一遍伤害链），
--- 而不是"把伤害乘个倍数"——因为减伤、护盾、免疫这类效果是逐次生效的。
---@param source? Pet
---@param target? Pet
---@param logic? BattleLogic @ 想掷骰就用它的 rng（战斗内的随机必须走它）
---@return integer
function Skill:getHits(source, target, logic)
  local h = self.hits
  if type(h) == "function" then h = h(self, source, target, logic) end
  if type(h) ~= "number" then return 1 end
  return math.max(1, math.floor(h))
end

---@return string
function Skill:getTarget()
  return self.target or "enemy"
end

---@param tag SkillTag
---@return boolean
function Skill:hasTag(tag)
  return table.contains(self.tags, tag)
end

--- 拿到本技能所属的骨架（规则作者写的那张 spec 的主人）。
--- 直接手写的 Skill（没走骨架）返回 nil。
---@return SkillSkeleton?
function Skill:getSkeleton()
  return self.skeleton
end

--- 这个技能"现在能不能用"，不能用的话**为什么**。
---
--- 集中在一处判断，是因为"能不能用"有三个来源，而它们必须**只有一个答案**：
---   1. PP —— 用完就没了（最常见的那一个）；
---   2. 封印 —— `pet:sealSkill(name)`，被对手封掉/无效化；
---   3. 技能自己的条件 —— spec 里的 `usable`，`false` 或者一个判断函数。
--- "选择技能"（`AskForAction` 列候选）和"执行技能"（`GameEvent.UseSkill` 拦住）
--- 用的是这同一个判断，所以不会出现"界面上能选、真用的时候被拒"这种前后不一致。
---
--- 返回原因字符串而不是只返回 false：客户端要把技能摆成灰的并说明为什么，
--- 规则代码也常常想知道"是没 PP 了还是被封印了"。
---@param pet Pet
---@param context? table @ 额外上下文（留给将来：比如"这一击是不是追加的"）
---@return boolean ok
---@return string? reason @ 见 Skill.Unusable
---@return string? text @ 给玩家看的一句话
function Skill:checkUsable(pet, context)
  local reason = nil

  if pet == nil then
    reason = Skill.Unusable.NO_PET
  elseif pet:isSkillSealed(self.name) then
    reason = Skill.Unusable.SEALED
  elseif pet:getPP(self.name) <= 0 then
    reason = Skill.Unusable.NO_PP
  elseif self.usable == false then
    reason = Skill.Unusable.FORBIDDEN
  elseif type(self.usable) == "function" then
    -- 条件函数抛错就让它抛出去：规则写错了该立刻暴露，而不是被静默当成"不能用"
    -- （和效果/时机里的处理一致——被吞掉的 bug 最难查）。
    if not self.usable(self, pet, context) then
      reason = Skill.Unusable.CONDITION
    end
  end

  if reason == nil then return true end
  return false, reason, Skill.UnusableText[reason]
end

--- 这个技能现在能不能用（只看布尔值，不要原因时用这个）。
---@param pet Pet
---@param context? table
---@return boolean
function Skill:isUsable(pet, context)
  local ok = self:checkUsable(pet, context)
  return ok
end

--- 直接改"能不能用"。
--- 用于**整局范围**的开关（比如某个规则一开，全场禁用某类技能）。
--- 只想封住某一只精灵，请用 `pet:sealSkill`——技能对象是全局共享的。
---@param value boolean|function|nil
function Skill:setUsable(value)
  self.usable = value
end

--- 把"效果 spec"实例化成 Effect（在 effect.lua 里实现，这里只转发）。
--- 用 __index 之外的方式转发是为了避免 Skill 依赖 Effect 的加载顺序。
---@param source Pet @ 效果来源
---@param target Pet @ 效果目标
---@return Effect[]
function Skill:createEffects(source, target)
  -- 效果没写 `target` 时，默认**跟随技能自己的目标规则**。
  --
  -- 不这么做的话，"属性技 + 效果没写目标"就会解析到"技能的目标"上，
  -- 而属性技的目标是自己——于是"回复自身、解除自身异常"这类效果会打到对面去
  -- （不报错，就是治错人）。技能级的目标和效果级的目标用词不同
  -- （技能写 "enemy"/"self"，效果写 "target"/"self"），所以这里做一次映射。
  local by_skill_target = {
    self = "self",
    enemy = "target",
    ally = "target",
    all_enemies = "all_enemies",
    all_allies = "all_allies",
    field = "all_enemies",
  }
  local default_target = by_skill_target[self:getTarget()] or "target"

  local ret = {}
  for _, spec in ipairs(self.effects or {}) do
    if spec.target == nil then
      spec = table.simpleClone(spec)
      spec.target = default_target
    end
    table.insert(ret, Effect:create(spec, source, target))
  end
  return ret
end
--- 加一个关联对象（主技能 <-> 子技能互相找）
---@param skill Skill
function Skill:addRelatedSkill(skill)
  table.insert(self.related_skills, skill)
  Seer.related_skills[self.name] = Seer.related_skills[self.name] or {}
  table.insert(Seer.related_skills[self.name], skill)
end

--- 这个对象是不是"属于某只精灵的技能"，而不是全局技能/模式技。
--- 对应 core 的 `Skill:isPlayerSkill(player, includeModeSkill)`。
---@param pet? Pet
---@param include_mode? boolean @ 是否把模式技也算进来
---@return boolean
function Skill:isActorSkill(pet, include_mode)
  local skel = self:getSkeleton()
  if skel == nil then return true end
  return not (self.name:endsWith("&") or (not include_mode and skel.mode_skill))
end

-- core 里的名字叫 isPlayerSkill，保留一个别名，方便两边对着读
Skill.isPlayerSkill = Skill.isActorSkill

-- ============================ TriggerSkill ============================

--- 某个时机的触发 spec。规则作者在 `triggers` 表里写的就是这个。
---@class TrigSpec
---@field public priority? number @ 优先级，越大越优先（默认 1）
---@field public can_trigger? function @ 能不能发动：fun(self, event, target, pet, data): boolean
---@field public on_trigger? function @ 发动：fun(self, event, target, pet, data): boolean? @ 返回 true 表示打断本时机
---@field public trigger_times? function @ 单精灵单时机内的发动次数上限：fun(...): integer
---@field public can_refresh? function
---@field public on_refresh? function
---@field public late_refresh? boolean @ refresh 放到触发之后再做
---@field public global? boolean @ 全局触发者（不属于任何精灵，任何精灵行动时都会被问到）
---@field public name? string @ 覆盖自动生成的子对象名

--- 触发技：一个"在某个时机上挂一个钩子"的运行时对象。
--- 对应 freekill 的 TriggerSkill。
---@class TriggerSkill: Skill
---@field public event Timing @ 挂在哪个时机类上
---@field public priority number @ 越大越优先
---@field public global boolean @ 是否全局触发者
---@field public late_refresh boolean? @ refresh 是否放到触发之后
---@field public owner Pet? @ 归属的精灵（动态挂载时用）
TriggerSkill = Skill:subclass("TriggerSkill")

---@param name string
---@param spec? TrigSpec
function TriggerSkill:initialize(name, spec)
  spec = spec or {}
  Skill.initialize(self, {
    name = name,
    tags = spec.tags or {},
    target = "self",
    category = Skill.Status,
  })
  self.timing = spec.timing
  self.priority = spec.priority or 1
  self.global = spec.global or false
  self.late_refresh = spec.late_refresh or false

  -- 钩子：spec 里给了就用 spec 的，没给就落到下面这些默认实现上
  if spec.can_trigger then
    -- **包一层**：先判"这个触发者属不属于当前这只精灵"，再跑作者写的条件。
    --
    -- 为什么必须包：默认的 triggerable 里带着归属判断（`pet:hasSkill(自己)`），
    -- 一旦被 spec 的 can_trigger 整个替换掉，归属判断就没了——于是
    -- "盖亚的特性给雷伊加攻击"这种事会**静默**发生（不报错、数值就是不对）。
    -- freekill 就是这么被替换掉的（它的 can_trigger 作者得自己记得判归属）。
    -- 全局触发者（global = true）不受影响：它们本来就不属于任何精灵。
    local user_can_trigger = spec.can_trigger
    self.triggerable = function(sk, timing, target, pet, data)
      if not sk.global then
        if pet == nil or not pet:hasSkill(sk:getOwnerName()) then
          return false
        end
      end
      return user_can_trigger(sk, timing, target, pet, data)
    end
  end
  if spec.on_trigger then self.trigger = spec.on_trigger end
  if spec.on_refresh then self.refresh = spec.on_refresh end
  if spec.can_refresh then self.canRefresh = spec.can_refresh end
  if spec.trigger_times then self.triggerableTimes = spec.trigger_times end
end

--- 默认的"能不能发动"：只有当受动者就是自己、且自己没有失效时才发动。
--- 对应 core 的 TriggerSkill:triggerable。
---@param event Timing
---@param target Pet? @ 受动者
---@param pet Pet @ 当前行动/被询问的精灵
---@param data TriggerData
---@return boolean
function TriggerSkill:triggerable(event, target, pet, data)
  return target ~= nil and target == pet and (self.global or self:isEffectable(pet))
end

--- 默认的"发动"：什么都不做。子类/spec 应该覆盖它。
---@return boolean? @ 返回 true 表示打断本时机
function TriggerSkill:trigger(event, target, pet, data)
  return false
end

---@return number @ 单精灵单时机内的发动次数上限
function TriggerSkill:triggerableTimes(event, target, pet, data)
  return 1
end

---@return boolean
function TriggerSkill:canRefresh(event, target, pet, data)
  return false
end

function TriggerSkill:refresh(event, target, pet, data) end

--- 这个触发者是不是"属于当前这只精灵"的。
--- freekill 用它决定"先问本人、再问全局"，实现见 Timing:exec。
---
--- 注意这里比对的是**骨架名**（比如 "茂盛"），不是触发者自己的名字
--- （自动生成的是 "#茂盛_1_trig"）。因为精灵身上挂的是主技能，
--- 子对象只是主技能的一部分——这一点和 core 的
--- `target:hasSkill(self:getSkeleton().name)` 完全一致。
---@param pet? Pet
---@param include_mode? boolean
---@return boolean
function TriggerSkill:isActorTrigger(pet, include_mode)
  if self.global then return true end
  if pet == nil then return false end
  -- owner 是动态挂上去的（比如效果产生的临时触发器）
  if self.owner then return self.owner == pet end
  return pet:hasSkill(self:getOwnerName())
end

--- 这只精灵身上"代表我这个触发者"的技能名。
--- 走骨架名 / 主技能名 / trueName 三级回退，保证三种来源的触发者都能对上：
---   * 骨架造出来的子对象：用骨架名
---   * 手写的技能对象：用自己名字
---   * 效果产生的触发器：有 owner 字段，上面直接比 owner，不走这里
---@return string
function TriggerSkill:getOwnerName()
  local skel = self:getSkeleton()
  if skel then return skel.name end
  if self.main_skill then return self.main_skill.name end
  return self.trueName or self.name
end

--- 技能对某只精灵是否"生效"（没被无效化/封印）。
--- 这里先做成简单的可重写点；"无效化"类效果的接入留给战斗状态机阶段。
---@param pet Pet
---@return boolean
function TriggerSkill:isEffectable(pet)
  if pet == nil then return false end
  return pet:hasSkill(self:getOwnerName()) and not pet:isSkillSealed(self:getOwnerName())
end

-- ============================ 挂在精灵身上的触发器 ============================
--
-- **效果**（Effect）和**印记**（Mark）都需要"挂到某只精灵身上、在某个时机插一脚"。
-- 这件事的机制完全一样：一张 `{ [时机] = 规格 }` 表 → 若干触发器 → 注册进战局。
-- 所以抽一个基类出来，两边都不用重复写钩子转发、次数限制、refresh 这些。
--
-- 名字里的 "Owned" = 有归属：它属于某一只精灵（`owner`），
-- 而 `Timing:exec` 就是靠这一点决定"这一刻该问谁"。

---@class OwnedTrigger: TriggerSkill
---@field public owner Pet @ 挂在哪只精灵身上
---@field public trig_spec table @ 规格（同名钩子写法与技能那边完全一致）
OwnedTrigger = TriggerSkill:subclass("OwnedTrigger")

--- 规格统一在这里存：子类（EffectTrigger / MarkTrigger）就不用各写一遍 initialize，
--- 也不会出现"某个子类忘了存 trig_spec、然后在 canRefresh 里炸掉"这种漏。
function OwnedTrigger:initialize(name, spec)
  TriggerSkill.initialize(self, name, spec or {})
  self.trig_spec = spec or {}
end

--- 默认：只有挂在自己身上时才被问到。
--- 不能走 TriggerSkill 的默认实现（那个会去查精灵有没有同名技能）。
function OwnedTrigger:triggerable(timing, target, pet, data)
  return self.owner ~= nil and self.owner == pet
end

function OwnedTrigger:isActorTrigger(pet, include_mode)
  return self.owner ~= nil and self.owner == pet
end

--- 钩子签名和技能那边**完全一致**：`fun(self, timing, target, pet, data)`。
--- 想拿"我是谁产生的"用 `self.effect` / `self.mark`。
function OwnedTrigger:trigger(timing, target, pet, data)
  local fn = self.trig_spec.on_trigger
  if fn then return fn(self, timing, target, pet, data) end
  return false
end

function OwnedTrigger:triggerableTimes(timing, target, pet, data)
  local fn = self.trig_spec.trigger_times
  if fn then return fn(self, timing, target, pet, data) end
  return self.trig_spec.times or 1
end

function OwnedTrigger:canRefresh(timing, target, pet, data)
  if self.trig_spec.late_refresh ~= nil then
    self.late_refresh = self.trig_spec.late_refresh
  end
  local fn = self.trig_spec.can_refresh
  if fn then return fn(self, timing, target, pet, data) end
  return false
end

function OwnedTrigger:refresh(timing, target, pet, data)
  local fn = self.trig_spec.on_refresh
  if fn then return fn(self, timing, target, pet, data) end
end

--- 把一张 `{ [时机] = 规格 }` 表装成触发器并注册进战局。
---
--- 顺序必须确定（排序后再装），否则"同一优先级谁先被问到"会随 `pairs` 的遍历顺序变，
--- 而 §2.3 要求同一局可复现。
---@param logic BattleLogic
---@param klass table @ 用哪个子类（EffectTrigger / MarkTrigger）
---@param owner Pet
---@param prefix string @ 名字前缀（保证唯一）
---@param triggers_def table
---@param default_priority number
---@param extras table @ 额外塞进触发器的字段（`effect = ...` / `mark = ...`）
---@return table[] installed
function OwnedTrigger.installTable(logic, klass, owner, prefix, triggers_def, default_priority, extras)
  local pending = {}
  for timing_klass, spec in pairs(triggers_def or {}) do
    if type(spec) == "table" and type(spec[1]) == "table" then
      -- 写成数组就是"同一个时机挂多个钩子"
      for _, one in ipairs(spec) do
        table.insert(pending, { timing_klass, one })
      end
    else
      table.insert(pending, { timing_klass, spec })
    end
  end

  table.sort(pending, function(a, b)
    if a[1].name ~= b[1].name then return a[1].name < b[1].name end
    return (a[2].name or "") < (b[2].name or "")
  end)

  local installed = {}
  for i, item in ipairs(pending) do
    local timing_klass, trig_spec = item[1], item[2]
    local trig = klass:new(("%s_%d"):format(prefix, i), trig_spec)
    trig.timing = timing_klass
    trig.owner = owner
    trig.priority = trig_spec.priority or default_priority or 1
    trig.global = false
    for k, v in pairs(extras or {}) do trig[k] = v end
    table.insert(installed, trig)
    logic:addTrigger(trig)
  end
  return installed
end

-- ============================ SkillSkeleton ============================

--- 一个"效果类型"的工厂登记项，对应 freekill 的 `Fk.skill_keys`。
---@class SkillKeyDef
---@field public create function @ fun(skeleton, idx, key, data): Skill|nil
---@field public priority integer @ 排序权重：大的排在 effect_spec_list 前面

--- 技能骨架：spec 的持有者与工厂。
--- 规则作者写的那张表交给它，`createSkill()` 返回主技能（子对象挂在 related_skills 上）。
---@class SkillSkeleton
---@field public name string
---@field public spec SkillSpec @ 原始 spec（改数值只要改它再重建）
---@field public tags SkillTag[]
---@field public mode_skill boolean? @ 模式技（不属于任何精灵，比如场地规则）
---@field public effects Skill[] @ 本骨架造出来的所有对象（主技能 + 各时机子技能）
---@field public effect_names string[] @ 各对象的注册名
---@field public effect_spec_list table[] @ {key, attribute, data} 三元组列表，按优先级排序
---@field public extra table
---@field public on_acquire? function @ 精灵获得技能时
---@field public on_lose? function @ 精灵失去技能时
SkillSkeleton = class("SkillSkeleton")

-- 效果类型工厂表：key --> SkillKeyDef。startup 时注册，见文件末尾。
SkillSkeleton.skill_keys = {}

--- 注册一个"效果类型"，让 spec 里可以用这个键。
---@param key string
---@param def SkillKeyDef
function SkillSkeleton.registerKey(key, def)
  assert(type(key) == "string" and key ~= "", "效果类型的键必须是非空字符串")
  assert(type(def.create) == "function", "效果类型 " .. key .. " 需要一个 create 工厂函数")
  SkillSkeleton.skill_keys[key] = { def.create, def.priority or 1 }
end

---@param spec SkillSpec
function SkillSkeleton:initialize(spec)
  spec = spec or {}
  if type(spec.name) ~= "string" or spec.name == "" then
    error("SkillSkeleton 需要一个非空的 name", 2)
  end
  self.spec = spec
  self.name = spec.name
  self.trueName = self.name:split("__")[2] or self.name
  self.tags = spec.tags or {}
  self.effects = {}
  self.effect_names = {}
  self.effect_spec_list = {}
  self.mode_skill = spec.mode_skill
  self.extra = spec.extra or {}
  self.on_acquire = spec.on_acquire
  self.on_lose = spec.on_lose
  self.visible = not self.name:startsWith("#")

  -- 1) 从 spec 的数值部分建主技能（`power`/`pp`/`effects` 这些都归它）
  local main_spec = {}
  for k, v in pairs(spec) do
    main_spec[k] = v
  end
  main_spec.name = self.name
  main_spec.package = spec.package or { extensionName = "seer-core" }
  self.main_spec = main_spec

  -- 2) 把 `triggers` 表展开成 effect_spec_list 的条目。
  --
  -- 注意这里**必须排序**：`pairs` 的遍历顺序在 Lua 里是不保证的（同一份数据
  -- 换个进程/换个 Lua 版本就可能不同）。而下面 createSkill 会用序号给子对象
  -- 命名（`#名字_序号_trig`），序号一变，子对象名就变——名字进了存档和日志之后
  -- 就再也对不上了。架构文档 §2.3 要求"同一局同一串事件序列 → 同一结果"，
  -- 所以凡是要"遍历一张表然后产生顺序"的地方，都得有确定的排序。
  if spec.triggers then
    local events = {}
    for event_klass in pairs(spec.triggers) do
      assert(type(event_klass) == "table" and event_klass.isSubclassOf
        and event_klass:isSubclassOf(Timing),
        ("技能 %s 的 triggers 键必须是 Timing 的子类，收到 %s"):format(self.name, tostring(event_klass)))
      table.insert(events, event_klass)
    end
    table.sort(events, function(a, b) return a.name < b.name end)

    for _, event_klass in ipairs(events) do
      self:addEffect(event_klass, spec.triggers[event_klass])
    end
  end
end

--- 给骨架加一个效果（一个时机钩子，或将来别的东西）。
--- 对应 core 的 `SkillSkeleton:addEffect`：它要保证"主效果"排在最前面，
--- 于是按类型优先级决定插到头还是插到尾。
---@param key any @ 目前是 Timing 子类（时机）
---@param data table @ TrigSpec
---@return SkillSkeleton self
function SkillSkeleton:addEffect(key, data)
  local prio
  if type(key) == "table" and key.isSubclassOf and key:isSubclassOf(Timing) then
    prio = 3 -- 时机类钩子：排在数值型主效果后面
  else
    local def = SkillSkeleton.skill_keys[key]
    prio = def and def[2] or 1
  end

  local main_effect = self.effect_spec_list[1]
  local insert_first
  if not main_effect then
    insert_first = true
  else
    insert_first = prio > (main_effect[4] or 0)
  end

  -- entry 沿用 core 的位置式三元组 {key, attribute, data}，第 4 位是本项目加的排序权重
  local entry = { key, nil, data, prio }
  if insert_first then
    table.insert(self.effect_spec_list, 1, entry)
  else
    table.insert(self.effect_spec_list, entry)
  end
  return self
end

--- 把 spec 造成运行时对象。
--- 返回主技能；各时机子技能挂在主技能的 related_skills 上，并已注册进 Seer.skills。
---@return Skill
function SkillSkeleton:createSkill()
  -- 主技能：数值 + 效果描述
  local main_skill = Skill:new(self.main_spec)
  main_skill.skeleton = self
  table.insert(self.effects, main_skill)
  table.insert(self.effect_names, self.name)

  for i, entry in ipairs(self.effect_spec_list) do
    local key, _attr, data = entry[1], entry[2], entry[3]
    local sub

    if type(key) == "table" and key.isSubclassOf and key:isSubclassOf(Timing) then
      sub = self:createTriggerSkill(i, key, data)
    else
      local def = SkillSkeleton.skill_keys[key]
      if def == nil then
        Log.warning(("技能 %s 使用了未注册的效果类型 %q，已跳过"):format(self.name, tostring(key)))
      else
        sub = def[1](self, i, key, data)
      end
    end

    if sub then
      -- 自动命名：`#技能名_序号_类型`。`#` 开头 = 不显示在技能栏（对齐 core）
      sub.name = data.name or ("#%s_%d_trig"):format(self.name, i)
      sub.trueName = self.name
      sub.visible = false
      sub.skeleton = self
      sub.main_skill = main_skill
      main_skill:addRelatedSkill(sub)
      table.insert(self.effects, sub)
      table.insert(self.effect_names, sub.name)
    end
  end

  return main_skill
end

--- 从一条 `triggers` 项造一个 TriggerSkill。
--- 对应 core 的 `SkillSkeleton:createTriggerSkill`。
---@param idx integer @ 在 effect_spec_list 里的序号
---@param event_klass Timing @ 时机类
---@param spec TrigSpec
---@return TriggerSkill
function SkillSkeleton:createTriggerSkill(idx, event_klass, spec)
  spec = spec or {}
  local sk = TriggerSkill:new(("#%s_%d_trig"):format(self.name, idx), spec)
  sk.timing = event_klass
  sk.priority = spec.priority or 1
  sk.global = spec.global or false
  sk.tags = self.tags
  return sk
end

-- ============================ 技能栏 ============================

--- 技能栏：**4 个普通技能槽 + 1 个第五技能**。
---
--- 第五技能**在机制上就是一个普通技能**：同一个 Skill 类、一样有 PP、一样走
--- `Skill:checkUsable`（PP 空了 / 被封印 / 技能自己的条件不满足，就一样用不出来）。
--- 它唯一的特殊之处是**摆在哪一格**——图鉴里写的就是"4 个技能 + 1 个第五技"，
--- 配招时也是分开配的。所以这里给它一个单独属性，而不是塞进 `slots[5]`：
---
---   * "哪几个是配的普通技能"在类型层面就是确定的。若塞成 5 元素数组，
---     每一处用到技能的地方都得判断"这是不是第 5 个"，只要有一处忘了判断
---     （"随机挑一个技能""把第 2 个技能换掉"），第五技能就会被当成普通技能用出去；
---   * 整组换普通技能（`setSlots`）时不会顺手把它清掉；
---   * 客户端要把它单独摆一个位置，不必自己数下标。
---
--- 反过来：**不要**因为"它是第五技能"就给它加规则。要禁止一个技能使用，
--- 用 `Skill:checkUsable` 的那三个来源（PP / `pet:sealSkill` / spec 的 `usable`），
--- 跟它是不是第五技能没有关系。
---
--- PP 也放在这里：PP 是**每个技能槽上的状态**，跟着技能走，不该散在 Pet 上。
---@class SkillSet
---@field public slots Skill[] @ 普通技能（最多 max_slots 个）
---@field public fifth Skill? @ 第五技能（单独一个属性，没有就是 nil）
---@field public pp table<string, integer> @ 技能名 --> 剩余 PP
SkillSet = class("SkillSet")

--- 把 spec 里写的技能（名字或对象）解析成 Skill 对象
---@param skill string|Skill
---@return Skill
function SkillSet.resolveSkill(skill)
  if type(skill) == "table" then return skill end
  local def = Seer.skills[skill] or Seer.skill_skeletons[skill]
  if def == nil then
    error(("技能表里没有 %q（检查是不是包没加载）"):format(tostring(skill)), 3)
  end
  return def
end

---@param spec? table @ `{ skills = {...}, fifth = ..., pp = {...}, max_slots = 4 }`
function SkillSet:initialize(spec)
  spec = spec or {}
  self.slots = {}
  self.fifth = nil
  self.max_slots = spec.max_slots or 4
  self.pp = {}

  for i, sk in ipairs(spec.skills or {}) do
    self:setSlot(i, sk)
  end
  if spec.fifth ~= nil then
    self:setFifth(spec.fifth)
  end

  -- 初始 PP：默认取技能定义里的 PP，spec 里给了就按 spec 覆盖
  for _, sk in ipairs(self:getAll()) do
    self.pp[sk.name] = (spec.pp and spec.pp[sk.name]) or sk:getPP()
  end
end

function SkillSet:__tostring()
  local names = table.map(self.slots, function(s) return s.name end)
  return ("<SkillSet %s%s>"):format(table.concat(names, "/"),
    self.fifth and (" + 第五:" .. self.fifth.name) or "")
end

--- 往第 slot 个普通技能槽放技能
---@param slot integer @ 1..max_slots
---@param skill string|Skill
---@return Skill
function SkillSet:setSlot(slot, skill)
  assert(type(slot) == "number" and slot >= 1 and slot <= self.max_slots,
    ("技能槽只能填 1~%d，收到 %s"):format(self.max_slots, tostring(slot)))
  local sk = SkillSet.resolveSkill(skill)
  self.slots[slot] = sk
  self.pp[sk.name] = self.pp[sk.name] or sk:getPP()
  return sk
end

--- 一次性把普通技能槽整组换掉（换技能、开局给它配招时用）。
--- 只动普通技能槽，**不动第五技能**——第五技能是单独的属性，
--- 换普通技能不该顺手把它清掉。
---@param list (string|Skill)[]
---@return SkillSet self
function SkillSet:setSlots(list)
  self.slots = {}
  for i, sk in ipairs(list or {}) do
    self:setSlot(i, sk)
  end
  return self
end

---@param slot integer
---@return Skill?
function SkillSet:getSlot(slot)
  return self.slots[slot]
end

--- 设置第五技能（单独一个属性，不占普通技能格）
---@param skill string|Skill|nil @ 传 nil 表示没有第五技能
---@return Skill?
function SkillSet:setFifth(skill)
  if skill == nil then
    self.fifth = nil
    return nil
  end
  local sk = SkillSet.resolveSkill(skill)
  self.fifth = sk
  self.pp[sk.name] = self.pp[sk.name] or sk:getPP()
  return sk
end

---@return Skill?
function SkillSet:getFifth()
  return self.fifth
end

---@return Skill[] @ 普通技能（4 个槽里的，可能不满）
function SkillSet:getSlots()
  return self.slots
end

---@return integer @ 带了几个普通技能
function SkillSet:count()
  return #self.slots
end

--- 这只精灵**拥有**的全部技能：4 个普通技能 + 第五技能。
--- 用在"找触发者""问玩家要指令"这类地方。
---@return Skill[]
function SkillSet:getAll()
  local ret = {}
  for _, sk in ipairs(self.slots) do table.insert(ret, sk) end
  if self.fifth then table.insert(ret, self.fifth) end
  return ret
end

---@param name string
---@return boolean
function SkillSet:has(name)
  return self:find(name) ~= nil
end

---@param name string
---@return Skill?
function SkillSet:find(name)
  if name == nil then return nil end
  return table.find(self:getAll(), function(s)
    return s.name == name or s.trueName == name
  end)
end

--- 这个名字是不是第五技能
---@param name string
---@return boolean
function SkillSet:isFifth(name)
  if self.fifth == nil or name == nil then return false end
  return self.fifth.name == name or self.fifth.trueName == name
end

---@param name string
---@return integer @ 剩余 PP
function SkillSet:getPP(name)
  return self.pp[name] or 0
end

---@param name string
---@param n? integer
---@return boolean @ PP 够不够（不够则不减）
function SkillSet:usePP(name, n)
  n = n or 1
  local cur = self:getPP(name)
  if cur < n then return false end
  self.pp[name] = cur - n
  return true
end

---@param name string
---@param n? integer
function SkillSet:restorePP(name, n)
  local sk = self:find(name)
  local max = sk and sk:getPP() or 0
  self.pp[name] = math.min(max, self:getPP(name) + (n or max))
end

function SkillSet:restoreAllPP()
  for _, sk in ipairs(self:getAll()) do
    self.pp[sk.name] = sk:getPP()
  end
end

return {
  Skill = Skill,
  TriggerSkill = TriggerSkill,
  OwnedTrigger = OwnedTrigger,
  SkillSkeleton = SkillSkeleton,
  SkillSet = SkillSet,
}
