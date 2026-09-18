-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 效果（Effect）============================
--
-- 这个**文件夹**装的是"效果"这套制度：
--
--   effect/init.lua   —— Effect 类：注册表、目标解析、结算、生命周期（本文件）
--   effect/kinds.lua  —— **内置效果类型 = 注册点**：伤害/回复/能力等级/印记/…
--
-- "效果"是赛尔号里的一等公民：一个技能除了那一下伤害，还会附带别的后果——
-- 让对手中毒、让自己特攻 +2、接下来三回合受到的伤害减半……
--
-- 关键设计：**技能上的效果和挂在精灵身上的回合类效果是同一个类**。
-- 区别只有"寿命"：
--
--   瞬时效果（instant）：技能结算时当场算完就结束（伤害、回复、能力等级变化）
--   持续效果：`duration` 不为 nil → 注册成时机触发器 + 写进 `pet.effects` 那张表，
--             之后每回合自己动（每回合掉血、受伤减半、被打了反击……），
--             回合数归零或被清除时 `remove()` 把触发器摘干净。
--
-- 所以精灵身上有两张表，各管各的：
--   `pet.marks`   —— 印记（有名字、有描述、能被解毒、UI 要显示）：Mark 类
--   `pet.effects` —— 效果（纯机制，不进状态栏）：Effect 类
-- 为什么不合成一个：印记是**状态**（"你现在中毒了"），效果是**机制**
-- （"这 3 回合你受到的伤害减半"）。前者的名字要被玩家看见、要被
-- "解除异常状态"精确地挑出来，后者不该出现在状态栏里。
-- 完整分析见 `docs/effects-marks-status.md`。
--
-- ---------------------------- 效果类型 = 插件 ----------------------------
--
-- 延续技能的"spec 方式"：效果的类型不是靠继承，而是靠**注册表**。
-- 每种效果类型在 `Effect.kinds` 里登记一份"说明书"（内置的写在 kinds.lua，
-- 扩展包在自己包里再追加一份，写法完全一样）：
--
--   * `instant`     ：true = 当场结算，不挂时机（伤害、回复、能力等级变化）
--   * `on_apply`    ：instant 效果的结算体
--   * `triggers`    ：非 instant 效果挂到哪些时机上、钩子怎么写
--   * `on_expire`   ：到回合数归零被清除时做什么
--   * `validate`    ：spec 字段的合法性检查（把"写错数据"挡在加载期，
--                     而不是等战斗打到一半才崩）
--
-- 好处和技能那边一样：加一种新效果不用改核心，只要 `Effect.registerKind`。
-- 副作用是**开局加载时会做校验**，规则作者的数据笔误能立刻看到。

--- 技能结算上下文：一次技能从头到尾共享的那份数据。
---
--- 为什么需要它：很多效果**没法只看 spec 就知道该干什么**，得看"刚刚打出了什么"：
---   * 吸取：「回复造成伤害的 50%」——不知道伤害就无从算起
---   * 反作用力：「自己受到造成伤害的 1/3」
---   * 附加效果的条件：「只在造成伤害时才附加异常状态」
--- 所以 ExecuteSkill 流程会把这份上下文一路传给每个效果。
---
---@class EffectCtx
---@field public source Pet @ 使用者
---@field public target? Pet @ 目标
---@field public skill Skill @ 正在结算的技能
---@field public damage integer @ 这次技能**累计造成**的伤害（连击是各段之和）
---@field public hits integer @ 打了几下
---@field public crit boolean @ 有没有打出暴击
---@field public missed boolean @ 是不是打空了（打空时附加效果一律不结算）
---@field public extra table @ 效果之间互相传数据的小口袋
---@field public power_multiplier number @ "增伤"用的威力倍率（前置效果往里乘，伤害结算时用它）

---@class EffectSpec
---@field public kind string @ 效果类型，必须是 Effect.kinds 里注册过的键
---@field public name? string @ 覆盖自动生成的名字（用于日志/回放定位）
---@field public probability? number @ 触发概率 0~100，默认 100
---@field public condition? function @ 附加条件：`fun(effect, ctx): boolean`，不满足就跳过
---@field public phase? string @ "after"（默认，伤害之后）/ "before"（伤害**之前**，用来改威力）
---@field public then_effects? table[] @ 本体生效之后再接着结算的效果（"消除成功，令对方烧伤"就是这么写的）
---@field public ratio? number @ 比例型效果的系数（吸取/反作用力这类按"造成伤害的几成"算）
---@field public target? string @ 作用目标："target"（技能目标）/ "self"（使用者）/ "all_allies" / "all_enemies"
---@field public duration? integer @ 持续回合数；不填 = 立即结算（不挂时机）
---@field public value? integer @ 通用数值（伤害量、回复量、固定值……由 kind 解释）
---@field public stages? table<string, integer> @ 能力等级变化，如 `{ spa = 2, spe = 1 }`
---@field public status? string @ 异常状态键（= mark 的别名，见 core/mark/status.lua）
---@field public element? string @ 属性（固定伤害的属性等）
---@field public priority? number @ 挂在时机上时的优先级，默认 1
---@field public times? integer @ 单精灵单时机内的最多触发次数，默认 1
---@field public stages_max? integer @ 叠加层数上限（kind 为 mark 时用）
---@field public triggers? table @ 额外的时机钩子（在 kind 自带的之外追加）
---@field public tags? string[]
---@field public extra? table @ 规则作者自用

Effect = class("Effect")

--- 效果类型注册表：key --> EffectKindDef
---@class EffectKindDef
---@field public name string @ 人可读的类型名（日志用）
---@field public instant boolean @ 是否立即结算
---@field public validate? function @ fun(spec): boolean, string? —— 返回 false + 原因
---@field public on_apply? function @ fun(effect) —— 立即结算
---@field public on_expire? function @ fun(effect)
---@field public on_stack? function @ fun(effect, old_stacks)
---@field public triggers? table<Timing, table|table[]> @ 时机钩子
Effect.kinds = {}

---@param spec EffectSpec
---@param source? Pet @ 效果来源（用技能的那只精灵）
---@param target_pet? Pet @ 效果目标
function Effect:initialize(spec, source, target_pet)
  spec = spec or {}
  if type(spec.kind) ~= "string" then
    error("Effect 需要 spec.kind（效果类型）", 2)
  end
  local def = Effect.kinds[spec.kind]
  if def == nil then
    error(("Effect 的类型 %q 没有注册，请先用 Effect.registerKind 注册"):format(spec.kind), 2)
  end

  self.spec = spec
  self.kind = spec.kind
  self.kind_def = def
  self.name = spec.name or ("#%s_%d"):format(spec.kind, Effect._next_seq())

  self.probability = spec.probability
  self.target_rule = spec.target or "target"
  self.duration = spec.duration
  self.value = spec.value
  self.stages = spec.stages
  self.status = spec.status
  self.mark = spec.mark
  self.side = spec.side
  self.multiplier = spec.multiplier
  self.element = spec.element
  self.priority = spec.priority or 1
  self.times = spec.times or 1
  self.stages_max = spec.stages_max
  self.ratio = spec.ratio
  self.condition = spec.condition
  self.phase = spec.phase or "after"
  self.then_effects = spec.then_effects
  self.tags = spec.tags or {}
  self.extra = spec.extra or {}

  self.source = source
  self.target_pet = target_pet

  -- 运行时状态
  self.applied = false
  self.remaining = spec.duration
  self.stacks = 1
  self.triggers = {}
  self.logic = nil

  -- 加载期校验：数据笔误在开局就报出来
  if def.validate then
    local ok, reason = def.validate(spec)
    if not ok then
      Log.warning(("效果 %s（类型 %s）的 spec 有问题：%s"):format(self.name, spec.kind, tostring(reason)))
    end
  end
end

-- 自动编号只用来让日志/回放能区分同名效果；它不影响判定
Effect._seq = 0
function Effect._next_seq()
  Effect._seq = Effect._seq + 1
  return Effect._seq
end

function Effect:__tostring()
  return ("<Effect %s %s on %s>"):format(
    self.name, self.kind, self.target_pet and self.target_pet.name or "?")
end

--- 从 spec 造一个效果实例。
--- 写成"类方法"（要拿 klass 参数），这样既能 `Effect:create(spec, src, tgt)`，
--- 也能在将来有 Effect 子类时 `MyEffect:create(...)`——契约和 TriggerData.create 一致。
---@param klass Effect @ 实际类型（冒号调用时自动传入）
---@param spec EffectSpec
---@param source? Pet
---@param target_pet? Pet
---@return Effect
function Effect.create(klass, spec, source, target_pet)
  return klass:new(spec, source, target_pet)
end

--- 注册一种效果类型。规则作者/扩展包可以用它加新效果，不用改本文件。
---@param key string
---@param def EffectKindDef
function Effect.registerKind(key, def)
  assert(type(key) == "string" and key ~= "", "效果类型的键必须是非空字符串")
  assert(type(def) == "table", "效果类型 " .. key .. " 的说明书必须是一张表")
  if def.instant and type(def.on_apply) ~= "function" then
    assert(false, "立即结算的效果类型 " .. key .. " 必须提供 on_apply")
  end
  Effect.kinds[key] = def
end

-- ============================ 作用目标 ============================

--- 解析"这个效果该作用在谁身上"。
---@param ctx table @ `{ source = Pet, target = Pet }`
---@return Pet[] @ 目标列表
function Effect:resolveTargets(ctx)
  ctx = ctx or {}
  local source = ctx.source or self.source
  local target = ctx.target or self.target_pet

  local rule = self.target_rule
  -- "target" 和 "enemy" 是一回事：技能已经把目标算好了，效果直接用。
  -- 让规则作者能照技能里的写法（target = "enemy"）照抄，少一个要记的差异。
  if rule == "self" then
    return source and { source } or {}
  elseif rule == "target" or rule == "enemy" then
    return target and { target } or {}
  elseif rule == "all_enemies" then
    local base = target or source
    return base and base:getEnemyTeam() or {}
  elseif rule == "all_allies" then
    local base = source or target
    return base and base:getAllyTeam() or {}
  end

  Log.warning(("效果 %s 的目标规则 %q 无法识别"):format(self.name, tostring(rule)))
  return {}
end

-- ============================ 结算 ============================

--- 概率判定。用 logic 的确定性随机数发生器——**不要**用 math.random，
--- 否则回放会对不上（架构文档 §2.3）。
---@param logic BattleLogic
---@return boolean
function Effect:rollProbability(logic)
  local percent = self.probability
  if percent == nil or percent >= 100 then return true end
  if percent <= 0 then return false end
  if logic and logic.rng then
    return logic.rng:chance(percent)
  end
  Log.warning("Effect:rollProbability 没有 logic.rng，概率判定降级为 math.random（会破坏确定性）")
  return math.random() * 100 < percent
end

--- 把一个效果真正拍到目标身上。
---@param logic BattleLogic
---@param ctx? table @ `{ source = Pet, target = Pet }`
---@return boolean applied @ 是否真的生效（概率没过 / 目标已被免疫 都返回 false）
function Effect:apply(logic, ctx)
  self.logic = logic or self.logic
  ctx = ctx or {}

  -- 附加条件（"只在造成伤害时""只在对方没倒下时"……）
  if type(self.condition) == "function" and not self.condition(self, ctx) then
    return false
  end

  if not self:rollProbability(self.logic) then
    return false
  end

  local targets = self:resolveTargets(ctx)
  if #targets == 0 then return false end

  local def = self.kind_def
  local any = false

  for _, pet in ipairs(targets) do
    -- 同一个效果重复拍上去 = 叠层，而不是各挂一份。
    -- 判重靠**名字**：自动编号的效果每次都是新名字（各自独立），
    -- 想叠层就得在 spec 里显式写 `name = "..."`（比如"每层 +1"的标记类效果）。
    -- 这个设计是刻意的：默认"不叠"，需要叠的才写名字，免得随手写个效果就莫名其妙叠起来。
    local exist = pet:getEffect(self.name)
    if exist then
      exist:addStack()
      any = true
    else
      self.target_pet = pet
      -- `on_apply` 对**两类**效果都会跑：
      --   * 立即型（伤害/回复/能力变化）：它就是全部内容；
      --   * 持续型（异常状态/标记/数值修正）：它是"拍上去那一刻要做的事"
      --     （比如挂状态），之后才靠 install 注册的时机钩子持续起作用。
      if def.on_apply then def.on_apply(self, pet, ctx) end
      if not def.instant then
        self:install()
        pet:addEffect(self)
      end
      any = true
    end
  end

  self.applied = any

  -- "消除成功则令对方烧伤"这类：本体生效之后，接着结算串在后面的效果。
  -- 这正是"可复用 + 只差一两个参数"的落点——模板相同，参数不同。
  if any and self.then_effects then
    for _, spec in ipairs(self.then_effects) do
      local follow = Effect:create(spec, self.source, self.target_pet)
      follow:apply(self.logic, ctx)
    end
  end

  return any
end

--- 叠一层
function Effect:addStack()
  local old = self.stacks
  self.stacks = self.stacks + 1
  if self.stages_max and self.stacks > self.stages_max then
    self.stacks = self.stages_max
  end
  if self.kind_def.on_stack then
    self.kind_def.on_stack(self, old)
  end
  -- 叠加时刷新持续回合（"再中一次毒，回合数重新算"）
  if self.duration then
    self.remaining = self.duration
  end
  return self.stacks
end

--- 它是"瞬时效果"还是"持续效果"。
--- 瞬时效果当场算完就结束；持续效果会挂进 `pet.effects` 并注册时机钩子。
---@return boolean
function Effect:isPersistent()
  return not self.kind_def.instant
end

--- 把 kind 自带的时机钩子 + spec 里额外写的钩子装成触发器。
--- 装表、排序、注册这些细节在 `OwnedTrigger.installTable`（效果和印记共用一份）。
function Effect:install()
  if not self.logic then return end

  -- status / modifier 的钩子是"按数据现搭"的，先解析出来
  if type(self.kind_def.triggers) == "string" then
    self.kind_def = table.simpleClone(self.kind_def)
    self.kind_def.triggers = self:resolveKindTriggers()
  end

  local merged = {}
  for timing_klass, spec in pairs(self.kind_def.triggers or {}) do
    merged[timing_klass] = spec
  end
  for timing_klass, spec in pairs(self.spec.triggers or {}) do
    merged[timing_klass] = spec
  end

  self.triggers = OwnedTrigger.installTable(
    self.logic, EffectTrigger, self.target_pet,
    ("#effect_%s"):format(self.name), merged, self.priority,
    { effect = self })
end

--- 摘掉所有触发器
function Effect:uninstall()
  for _, trig in ipairs(self.triggers) do
    if self.logic then self.logic:removeTrigger(trig) end
  end
  self.triggers = {}
end

--- 回合末递减；归零就清除。
---@param logic BattleLogic
---@return boolean expired
function Effect:tick(logic)
  self.logic = logic or self.logic
  if self.remaining == nil then return false end
  self.remaining = self.remaining - 1
  if self.remaining <= 0 then
    self:remove("duration")
    return true
  end
  return false
end

--- 清除效果。
---@param reason? string
function Effect:remove(reason)
  if self.kind_def.on_expire then
    self.kind_def.on_expire(self)
  end
  self:uninstall()
  if self.target_pet then
    self.target_pet:removeEffect(self.name)
  end
  self.applied = false
  self.remove_reason = reason
end

--- 序列化（回放/重连要做状态快照时用）
function Effect:serialize()
  return {
    name = self.name,
    kind = self.kind,
    spec = self.spec,
    remaining = self.remaining,
    stacks = self.stacks,
  }
end

-- ============================ 效果触发器 ============================

--- 一个效果挂到时机上用的适配器。
--- 触发器本身的所有机制（归属判断、次数限制、refresh、装表）都在
--- `OwnedTrigger` 里（core/skill.lua），这里只是把"我代表哪个效果"放在 `.effect` 上。
---@class EffectTrigger: OwnedTrigger
---@field public effect Effect
EffectTrigger = OwnedTrigger:subclass("EffectTrigger")

function EffectTrigger:__tostring()
  return ("<EffectTrigger %s of %s>"):format(self.name, tostring(self.effect))
end

--- modifier 这类效果的钩子是"按数据现搭"的（规则作者在 extra.timing 里写时机名），
--- 所以在 install 之前把它从占位字符串解析成真正的钩子表。
--- 这一步要等 events.lua 加载完（时机类登记进 SeerTiming）之后才能做。
---@return table<Timing, table>
function Effect:resolveKindTriggers()
  local raw = self.kind_def.triggers
  if type(raw) == "table" then return raw end
  if raw ~= "MODIFIER" then return {} end

  -- events.lua 会把时机类挂到 SeerTiming 上，这里按名字取，避免 core -> server 的依赖
  local function ev(name)
    local klass = SeerTiming and SeerTiming[name]
    if klass == nil then
      Log.warning(("效果 %s 需要时机 %s，但它还没注册"):format(self.name, name))
    end
    return klass
  end

  -- MODIFIER：spec.extra.timing 里写的是时机名
  local name = self.spec.extra.timing
  local klass = ev(name)
  if klass == nil then return {} end
  return {
    [klass] = {
      priority = self.spec.extra.priority or self.priority,
      on_trigger = function(trig, event, target, pet, data)
        return self.spec.extra.apply(trig.effect, data)
      end,
    },
  }
end

-- ============================ 内置效果类型 ============================
--
-- 上面是"制度"，这里是"内容"：所有内置效果类型的说明书都在 kinds.lua 里，
-- 靠 `Effect.registerKind` 登记进 `Effect.kinds`。**要加效果就改那个文件**
-- （扩展包则在 `lua/specs/<包名>/effects.lua` 里加，方式一模一样）。
--
-- 放在最后 require 是因为 kinds.lua 要用全局 `Effect` 调的 `registerKind`。
Effect.kinds_builtin = require "core.effect.kinds"

return Effect
