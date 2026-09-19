-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 印记（Mark）============================
--
-- ⛔ 当前状态：**不要 require 这个文件，它会加载失败**。
--
-- `seer.lua` 里已经刻意**没有**加载 `core.mark`（那里留了 TODO）。原因是这个目录
-- 整体依赖一套**还没重建**的效果 / 触发器体系，具体缺什么：
--
--   1. `OwnedTrigger` —— **类不存在**。本文件末尾 `MarkTrigger = OwnedTrigger:subclass(...)`
--      会在**加载期**直接报 "attempt to index a nil value (global 'OwnedTrigger')"，
--      整个模块进不来。原来它是"谁拥有这个触发器"的基类（效果/技能/印记共用），
--      和 TriggerEvent / TriggerData 一样属于需要重建的触发体系。
--   2. `pet.marks` / `pet.effects` —— 挂在精灵身上的印记表与效果表。重构后的
--      `Pet` 只剩"初始化 + getter"（见 core/pet.lua），这些战斗状态字段全部删掉了；
--      将来的归宿应该是战斗逻辑（`GameLogic`）或一层独立的战斗状态对象。
--   3. `pet:recalcStats()` —— 能力等级 / 印记倍率的重算入口，Pet 上已删除
--      （Pet 现在只在 initialize 里算一次六项属性值）。
--   4. `pet.seat` —— Pet 上已没有 seat（现在只有 `GameLogic:_defaultSides` 临时挂的
--      "阵营内序号"），所以 `("#mark_%s_%s"):format(pet.seat or 0, ...)` 这类命名要重想。
--   5. `logic:applyEffect(...)` / `logic:removeTrigger(...)` —— `GameLogic`
--      （server/gamelogic.lua）上没有这两个入口。
--   6. `Effect:create(spec, source, pet)` —— 效果现在只有 `core/effect/effect.lua`
--      这一个文件（**没有 init.lua**），而且 `Seer:createEffect(spec, source, target)`
--      才是唯一的创建入口；`Effect.create` 这个写法不存在。
--   7. `SeerTiming[name]` 里的**旧时机名**：`Mark.timing("RoundEnd")` /
--      `"DetermineDamage"` / `"BeforeAction"` 这些名字现在都不存在了——
--      当前只有 core/events 里的 18 个时机（TurnEnd / AfterTurnEnd /
--      DamageCalculate / BeforeAttack …）。`SeerTiming` 由 seer.lua 按那 18 个类重建。
--
-- 结论：**印记体系（含异常状态）与效果/触发器体系一起待重建**。重建时需要的
-- 零件清单就在上面这 7 条。在那之前，本目录的文件保持原样、只作参考，
-- `specs/` 里的包也不要再写 `marks = {...}`（`Seer:addMark` 也不存在，
-- 见 core/engine.lua 的 addPackage）。
--
-- ============================ 原始说明 ============================
--
-- 这个**文件夹**装的是"挂在精灵身上、有回合数、会自己动"的东西：
--
--   mark/init.lua    —— Mark 基类：注册表、生命周期、被动触发器（本文件）
--   mark/status.lua  —— **异常状态类**（弱化类 / 控制类）+ 内置的异常状态
--   mark/buff.lua    —— **增益印记类** + 两个通用例子（护盾 / 强化）
--
-- 为什么异常状态和增益印记是**同一个基类**：官方分法本来就是"弱化类异常状态 /
-- 控制类异常状态"，而护盾、加速这类增益印记除了"对谁好"之外机制一模一样——
-- 有名字、有描述、有回合数、挂上去之后在特定时机自己生效、能被解除、能被 UI 展示。
-- 分成两套写的话，这些共同部分要写两遍，然后改一处漏一处。
--
-- 三层的分工（详见 docs/effects-marks-status.md）：
--
--   Mark        基类。管"挂在谁身上、还剩几回合、有哪些被动钩子"。
--   StatusMark  异常状态类。管"弱化类/控制类**默认怎么动**"，让具体状态只写数据。
--   BuffMark    增益印记类。同上，只是"对自己好"。
--
-- ---------------------------- 印记 vs 效果 ----------------------------
--
-- 印记是**状态**（要显示、要被解毒、有名字），效果是**机制**（改数值、反击、抵挡）。
-- 两者都是"挂在精灵身上的持续东西"，但是两个表、两个类：
--   精灵身上的印记：`pet.marks`（key → Mark），有名字有描述，能被 cureStatus 清掉
--   精灵身上的效果：`pet.effects`（name → Effect），只是机制，不进状态栏
-- 所以"技能上的 effect"和"挂在精灵身上的回合类 effect"**是同一个类**（Effect），
-- 区别只是寿命：瞬时结算 vs 挂上去留着。这一点文档里专门分析过。
--
-- ---------------------------- 用枚举写类 ----------------------------
--
-- 印记是**数据**，不是继承体系。新增一个印记 = 一张表：
--
--     Mark.Status.register("burn", { name = "烧伤", class = "weaken",
--                                    turn_end_damage = {1, 16} })
--
-- 这一点和官方数据对得上：官方技能表里每个技能挂的是**效果ID 枚举**
-- （33=消强、3=解弱、10=施加异常、29/38/60=附加伤害、31=连击、37/42/88=增伤、
-- 43=恢复、46=抵挡），参数另写——"可复用的模板 + 参数"本来就是官方的做法。

---@class Mark: Object
---@field public key string @ 印记的键（枚举值，如 "burn"）
---@field public def MarkDef @ 它的定义（注册表里的那一份）
---@field public pet Pet? @ 挂在谁身上
---@field public source Pet? @ 谁挂上去的
---@field public turns integer? @ 还剩几个大回合；nil = 一直挂着直到被解除
---@field public stacks integer @ 层数
---@field public extra table @ 这个**实例**的私有数据（同一种印记挂在不同精灵身上可以带不同参数）
---@field public triggers OwnedTrigger[] @ 装上去的被动触发器
Mark = class("Mark")

-- ============================ 枚举 ============================

--- 印记类型。目前按官方分法区分这三类：
---   * 弱化类（WEAKEN）：中毒、烧伤、冻伤…… 让对方慢慢变弱
---   * 控制类（CONTROL）：麻痹、睡眠、冰冻、害怕…… 让对方动不了
---   * 增益类（BUFF）：护盾、加速…… 对自己好的
--- 前两类合起来就是**异常状态**（见 Mark.STATUS_TYPES）。
Mark.TYPE = {
  WEAKEN = "weaken",
  CONTROL = "control",
  BUFF = "buff",
}

Mark.TYPE_NAME = {
  [Mark.TYPE.WEAKEN] = "弱化类",
  [Mark.TYPE.CONTROL] = "控制类",
  [Mark.TYPE.BUFF] = "增益类",
}

--- 哪些类型算"异常状态"（会被解毒/解除异常的效果处理掉）。
--- 增益印记不在里面——"解毒"不该顺手把护盾也拆了。
Mark.STATUS_TYPES = {
  [Mark.TYPE.WEAKEN] = true,
  [Mark.TYPE.CONTROL] = true,
}

-- ============================ 定义（数据）============================

--- 一个印记的定义。规则作者写的就是这张表。
---@class MarkDef
---@field public name string @ 显示名（如 "烧伤"）
---@field public desc? string @ 一句话描述（给日志/客户端用）
---@field public mark_type string @ Mark.TYPE.*（写 class 时会自动填上）
---@field public duration? integer @ 持续几个大回合；nil = 直到被解除
---@field public min_turns? integer @ 挂上时随机回合数的下限（和 max_turns 一起用时掷骰）
---@field public max_turns? integer
---@field public stat_multipliers? table<string, integer> @ 对当前数值的持续倍率（如 speed = 0.5、attack = 1.5）
---@field public effects? table[] @ 挂上那一刻立刻结算的效果
---@field public on_attach? fun(mark: Mark, logic: BattleLogic, pet: Pet) @ 挂上去时做的事（触发器之外的自定义动作）
---@field public on_detach? fun(mark: Mark, logic: BattleLogic, pet: Pet, reason: string?) @ 摘掉时做的事（用来撤销 on_attach 的副作用）
---@field public triggers? table @ 被动时机钩子：`{ [时机] = 规格 }`
---@field public max_stacks? integer @ 最多叠几层，默认 1（不叠）
---@field public trigger_priority? number @ 这些钩子的默认优先级，默认 0
---@field public tags? string[]
Mark.defs = {}

--- 注册顺序。`pairs` 的顺序在 Lua 里是不保证的，而"哪只精灵先被处理"这种事
--- 必须每次一样（架构文档 §2.3），所以另外记一份有序清单。
Mark.registered = {}

--- 把定义塞进注册表（**不做任何加工**）。
--- 一般不用直接调它：`Mark.register` 会按类型分派给 `Status` / `Buff` 的注册函数，
--- 那两个会先把"这一类印记的默认行为"补进定义里。
---@param key string
---@param def MarkDef
---@return MarkDef
function Mark._register(key, def)
  assert(type(key) == "string" and key ~= "", "印记的键必须是非空字符串")
  assert(type(def) == "table" and type(def.name) == "string", ("印记 %s 需要一个 name"):format(key))
  assert(Mark.TYPE_NAME[def.mark_type] ~= nil,
    ("印记 %s 的 mark_type 必须是 Mark.TYPE 里的值，收到 %q"):format(key, tostring(def.mark_type)))
  if Mark.defs[key] == nil then
    table.insert(Mark.registered, key)
  else
    Log.warning(("印记 %s 被重复注册（后注册的覆盖前面的）"):format(key))
  end
  Mark.defs[key] = def
  return def
end

--- 注册一个印记（扩展包和核心都用这一个入口）。
---
--- 它是个**分派器**：异常状态交给 `Mark.Status.register`、增益印记交给
--- `Mark.Buff.register`，于是"弱化类默认每回合掉血""控制类默认掐掉行动"这类
--- 类别行为会自动补上，规则作者只写数据。
---@param key string
---@param def MarkDef
---@return MarkDef
function Mark.register(key, def)
  def = def or {}
  if Mark.STATUS_TYPES[def.mark_type] and Mark.Status ~= nil then
    return Mark.Status.register(key, def)
  elseif def.mark_type == Mark.TYPE.BUFF and Mark.Buff ~= nil then
    return Mark.Buff.register(key, def)
  end
  -- 还没加载子模块（或者 mark_type 缺失）：按原样登记，报错交给 _register
  return Mark._register(key, def)
end

---@param key string
---@return MarkDef?
function Mark.get(key)
  return Mark.defs[key]
end

---@param key string
---@return boolean @ 这个键是不是"异常状态"（弱化类或控制类）
function Mark.isStatusKey(key)
  local def = Mark.defs[key]
  return def ~= nil and Mark.STATUS_TYPES[def.mark_type] == true
end

---@param key string
---@return boolean
function Mark.isBuffKey(key)
  local def = Mark.defs[key]
  return def ~= nil and def.mark_type == Mark.TYPE.BUFF
end

--- 按注册顺序遍历（要产生顺序的地方一律用它，别用 pairs）
---@param fn fun(key: string, def: MarkDef)
function Mark.forEach(fn)
  for _, key in ipairs(Mark.registered) do
    local def = Mark.defs[key]
    if def ~= nil then fn(key, def) end
  end
end

--- 所有异常状态的键（按注册顺序）。
--- "随机解除一个异常状态""面板上列出所有状态"这类地方要用它。
---@return string[]
function Mark.statusKeys()
  local ret = {}
  Mark.forEach(function(key, def)
    if Mark.STATUS_TYPES[def.mark_type] then table.insert(ret, key) end
  end)
  return ret
end

--- 某个印记该用哪个实例类。给 `Mark:new` 用，也让外部能问"这是哪一类"。
---@param key string
---@return Object @ Mark 的子类
function Mark.classOf(key)
  local def = Mark.defs[key]
  if def == nil then return Mark end
  if Mark.STATUS_TYPES[def.mark_type] and Mark.Status ~= nil then
    return Mark.Status.classOf(def)
  elseif def.mark_type == Mark.TYPE.BUFF and Mark.Buff ~= nil then
    return Mark.Buff.class
  end
  return Mark
end

--- 按名字取时机类。
---
--- ⚠ 调用方（本目录的 status.lua / buff.lua）现在传的还是**旧时机名**
--- （"BeforeAction" / "RoundEnd" / "DetermineDamage"）——那些名字已经随重构消失，
--- 当前只有 core/events 里的 18 个时机（TurnEnd / AfterTurnEnd / DamageCalculate /
--- BeforeAttack …），`SeerTiming` 由 seer.lua 按那张清单重建。
--- 所以现在这个查询一律查不到、只留一条 warning；重建印记体系时要把调用方
--- 的时机名一起换掉（见本文件头的第 7 条）。
---@param name string
---@return TriggerEvent?
function Mark.timing(name)
  local klass = SeerTiming and SeerTiming[name]
  if klass == nil then
    Log.warning(("印记要用时机 %s，但它还没登记（旧时机名，见 core/mark/init.lua 文件头）")
      :format(name))
  end
  return klass
end

-- ============================ 实例 ============================

---@param key string
---@param opts? table @ `{ source = Pet, turns = integer, stacks = integer, extra = table, logic = BattleLogic }`
function Mark:initialize(key, opts)
  local def = Mark.defs[key]
  if def == nil then
    error(("印记 %q 没有注册过（先用 Mark.register 定义它）"):format(tostring(key)), 2)
  end
  opts = opts or {}

  self.key = key
  self.def = def
  self.pet = nil
  self.source = opts.source
  self.stacks = opts.stacks or 1
  -- 实例私有数据：同一种印记挂在不同精灵身上可以带不同参数
  -- （比如"封住的技能是哪一个"——技能名不可能写死在定义里）
  self.extra = opts.extra or {}

  -- 持续回合：显式给了就用给的；否则看定义（min/max 要掷骰，掷骰得走 logic.rng）
  if opts.turns ~= nil then
    self.turns = opts.turns
  elseif def.duration ~= nil then
    self.turns = def.duration
  elseif def.min_turns or def.max_turns then
    local lo = def.min_turns or def.max_turns
    local hi = def.max_turns or def.min_turns
    if opts.logic and opts.logic.rng and hi > lo then
      self.turns = opts.logic.rng:random(lo, hi)
    else
      self.turns = lo
    end
  else
    self.turns = nil
  end

  self.triggers = {}
end

function Mark:__tostring()
  local t = self.turns and ("剩 %d 回合"):format(self.turns) or "永久"
  return ("<%s(%s) %s x%d>"):format(self.def.name, self.key, t, self.stacks)
end

-- ---------------------------- 查询 ----------------------------

---@return string
function Mark:getType() return self.def.mark_type end

---@return string @ "弱化类" / "控制类" / "增益类"
function Mark:getTypeName() return Mark.TYPE_NAME[self.def.mark_type] or "未知" end

---@return string
function Mark:getName() return self.def.name end

---@return string
function Mark:getDesc() return self.def.desc or "" end

--- 是不是异常状态（弱化类/控制类）。解除异常的效果只认这些。
---@return boolean
function Mark:isStatus() return Mark.STATUS_TYPES[self.def.mark_type] == true end

function Mark:isWeaken() return self.def.mark_type == Mark.TYPE.WEAKEN end
function Mark:isControl() return self.def.mark_type == Mark.TYPE.CONTROL end
function Mark:isBuff() return self.def.mark_type == Mark.TYPE.BUFF end

---@return boolean
function Mark:isExpired()
  return self.turns ~= nil and self.turns <= 0
end

-- ---------------------------- 生命周期 ----------------------------

--- 挂到精灵身上：注册被动触发器 + 结算"挂上那一刻"的效果 + 刷新数值。
--- 顺序有讲究：先登记进 `pet.marks`、再装触发器、最后才跑 `on_attach` 和 effects，
--- 这样钩子/效果里查"我身上有没有这个印记"能看到它。
---@param logic BattleLogic
---@param pet Pet
function Mark:attach(logic, pet)
  self.logic = logic
  self.pet = pet
  pet.marks[self.key] = self

  -- 数值倍率（速度×0.5、攻击×1.5 这类）靠重算生效，所以挂上/摘掉都要重算
  pet:recalcStats()

  self.def.triggers = self.def.triggers or {}
  self.triggers = OwnedTrigger.installTable(
    logic, MarkTrigger, pet, ("#mark_%s_%s"):format(pet.seat or 0, self.key),
    self.def.triggers, self.def.trigger_priority or 0,
    { mark = self })

  -- 定义自己的挂载动作（比如"封招"印记在这里把技能封掉）
  if type(self.def.on_attach) == "function" then
    self.def.on_attach(self, logic, pet)
  end

  for _, spec in ipairs(self.def.effects or {}) do
    logic:applyEffect(Effect:create(spec, self.source, pet), {
      source = self.source,
      target = pet,
      reason = self.key,
    })
  end

  logic:notify{
    type = "MarkApplied",
    target = pet.seat,
    key = self.key,
    name = self.def.name,
    mark_type = self.def.mark_type,
    turns = self.turns,
  }
end

--- 从精灵身上摘掉。
---@param logic BattleLogic
---@param reason? string @ "expired" / "cured" / "consumed" / "cleared"
function Mark:detach(logic, reason)
  logic = logic or self.logic
  local pet = self.pet

  -- 先撤销挂载动作（比如解封），再摘触发器：撤销时可能还要用到触发器
  if type(self.def.on_detach) == "function" and pet ~= nil then
    self.def.on_detach(self, logic, pet, reason)
  end

  if logic ~= nil then
    for _, trig in ipairs(self.triggers) do
      logic:removeTrigger(trig)
    end
  end
  self.triggers = {}

  if pet ~= nil then
    pet.marks[self.key] = nil
    pet:recalcStats()
    if logic ~= nil then
      logic:notify{
        type = "MarkRemoved",
        target = pet.seat,
        key = self.key,
        name = self.def.name,
        mark_type = self.def.mark_type,
        reason = reason,
      }
    end
  end
  self.pet = nil
end

--- 叠一层（默认不叠：max_stacks 不填就是 1）。
---@return integer stacks
function Mark:addStack()
  local max = self.def.max_stacks or 1
  self.stacks = math.min(max, self.stacks + 1)
  -- 再中一次通常刷新回合数
  if self.turns ~= nil and self.def.duration then
    self.turns = self.def.duration
  end
  return self.stacks
end

--- 走一个大回合。返回 true 表示这次该消失了。
---@param logic BattleLogic
---@return boolean expired
function Mark:tick(logic)
  if self.turns == nil then return false end   -- 永久印记不递减
  self.turns = self.turns - 1
  return self.turns <= 0
end

--- 序列化（状态快照/回放用）
function Mark:serialize()
  return {
    key = self.key,
    name = self.def.name,
    mark_type = self.def.mark_type,
    turns = self.turns,
    stacks = self.stacks,
    extra = self.extra,
  }
end

-- ============================ 印记产生的触发器 ============================

--- 印记的被动钩子用的触发器。
--- 它和效果的 EffectTrigger 是同一个基类，只是把"我代表谁"放在 `.mark` 上。
---@class MarkTrigger: OwnedTrigger
---@field public mark Mark
MarkTrigger = OwnedTrigger:subclass("MarkTrigger")

function MarkTrigger:__tostring()
  return ("<MarkTrigger %s of %s>"):format(self.name, tostring(self.mark))
end

-- ============================ 子模块 ============================
--
-- 放在最后 require：两个子模块要用上面的基类（全局 `Mark`），
-- 而且它们注册的印记要能走 `Mark._register`。

Mark.Status = require "core.mark.status"
Mark.Buff = require "core.mark.buff"

return Mark
