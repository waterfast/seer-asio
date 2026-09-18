-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 异常状态类 ============================
--
-- 异常状态（官方叫"异常状态"，分**弱化类**和**控制类**）在机制上就是印记：
-- 有名字、有描述、有回合数、挂上去之后自己动、能被解除。所以它继承 `Mark`。
--
-- ---------------------------- 为什么要一个类，而不是一堆表 ----------------------------
--
-- 如果异常状态只是"一张表 + 一堆触发器"，那么每加一个状态都要把同样的钩子抄一遍：
--
--     麻痹 → BeforeAction 里掷骰、没过就 preventAction
--     睡眠/冰冻/害怕 → BeforeAction 里直接 preventAction
--     中毒 → RoundEnd 里按最大体力的 1/8 掉血
--     烧伤 → RoundEnd 里掉血 + 物理伤害打半折
--     冻伤 → RoundEnd 里掉血
--
-- 抄到第五个就会发现：**同一类状态的钩子代码是一模一样的，只有参数不同**
-- （掉几分之几、几成概率动不了）。所以这里把"这一类的默认行为"写进子类：
--
--   WeakenStatus（弱化类）：`turn_end_damage = {1,8}` → 回合末掉最大体力的 1/8
--                          `weaken_attack = { physical = 0.5 }` → 自己打出的物理伤害 ×0.5
--   ControlStatus（控制类）：`block_chance = 25` → 每次行动有 25% 被掐掉（不写 = 100%）
--
-- 于是"再加一个弱化类异常状态"只需要一行：
--
--     Status.register("frostbite", { name = "冻伤", class = "weaken",
--                                    turn_end_damage = {1, 16} })
--
-- ---------------------------- 这个类提供了什么 ----------------------------
--
-- 查询（可以直接单测，不用真打一局）：
--   mark:getClass()            -> "weaken" / "control"
--   mark:getClassName()        -> "弱化类" / "控制类"
--   mark:getTurnEndDamage()    -> 这回合末会掉多少血（弱化类）
--   mark:getAttackMultiplier() -> 它把某类攻击的伤害压到几成（弱化类）
--   mark:getBlockChance()      -> 行动被掐掉的概率（控制类）
--   mark:rollsActionBlock(logic) -> 这一次行动有没有被掐掉（走确定性随机数）
--
-- 批量操作：
--   Status.list()              -> 全部异常状态的键（注册顺序）
--   Status.has(pet, key)       -> 身上有没有这个异常状态
--   Status.cure(logic, pet)    -> 解除全部异常状态（只清弱化类/控制类，不动增益印记）

--- 异常状态基类。
---@class StatusMark: Mark
StatusMark = Mark:subclass("StatusMark")

-- ---------------------------- 枚举 ----------------------------

--- 异常状态的两个大类（就是 Mark.TYPE 里的那两个，这里给个更短的别名）
StatusMark.CLASS = {
  WEAKEN = Mark.TYPE.WEAKEN,
  CONTROL = Mark.TYPE.CONTROL,
}

StatusMark.CLASS_NAME = {
  [Mark.TYPE.WEAKEN] = "弱化类",
  [Mark.TYPE.CONTROL] = "控制类",
}

--- **异常状态枚举**：内置状态用这些常量，别在代码里散字符串字面量。
--- 官方 WIKI 对麻痹的定义就是「控制类异常状态，该状态下精灵无法行动」。
StatusMark.KEY = {
  -- 控制类
  PARALYSIS = "paralysis",   -- 麻痹
  SLEEP     = "sleep",       -- 睡眠
  FREEZE    = "freeze",      -- 冰冻
  FEAR      = "fear",        -- 害怕
  -- 弱化类
  POISON    = "poison",      -- 中毒
  BURN      = "burn",        -- 烧伤
  FROSTBITE = "frostbite",   -- 冻伤
}

--- 中文名（`Status.KEY` 的反查，日志/测试里好用）
StatusMark.KEY_NAME = {
  paralysis = "麻痹", sleep = "睡眠", freeze = "冰冻", fear = "害怕",
  poison = "中毒", burn = "烧伤", frostbite = "冻伤",
}

-- ---------------------------- 实例 ----------------------------

function StatusMark:initialize(key, opts)
  Mark.initialize(self, key, opts)
  if not Mark.STATUS_TYPES[self.def.mark_type] then
    error(("异常状态 %s 的类型不能是 %s"):format(key, tostring(self.def.mark_type)), 2)
  end
end

--- 异常状态**永远**算异常状态（增益印记走 BuffMark，那边返回 false）
function StatusMark:isStatus() return true end
function StatusMark:isBuff() return false end

---@return string @ "weaken" / "control"
function StatusMark:getClass() return self.def.mark_type end

---@return string @ "弱化类" / "控制类"
function StatusMark:getClassName() return StatusMark.CLASS_NAME[self.def.mark_type] or "异常状态" end

-- ============================ 弱化类 ============================

--- 往钩子表里挂一条：时机还没登记时**跳过并告警**（而不是 `triggers[nil]` 直接崩）。
--- 时机是在 `server/battle/timing.lua` 里登记的，本文件必须在那之后加载（见 seer.lua）。
---@param tbl table
---@param timing_name string
---@param spec table
local function at(tbl, timing_name, spec)
  local klass = Mark.timing(timing_name)
  if klass ~= nil then tbl[klass] = spec end
  return tbl
end

--- 弱化类异常状态：让对方慢慢变弱（掉血、打不出伤害）。
---@class WeakenStatus: StatusMark
WeakenStatus = StatusMark:subclass("WeakenStatus")

--- 这一类的默认值
---@param def MarkDef
function WeakenStatus.applyDefaults(def)
  def.mark_type = def.mark_type or Mark.TYPE.WEAKEN
  def.max_stacks = def.max_stacks or 1   -- 同一个状态默认只挂一份
  return def
end

--- 这一类的默认钩子：把 `turn_end_damage` / `weaken_attack` 两项数据翻成触发时机。
---
--- 这两个参数几乎覆盖了官方所有弱化类状态：中毒/冻伤只掉血、烧伤掉血 + 物理减半、
--- 将来"每回合掉 1/4 但加速"这类也只是加一项数据。
---@param def MarkDef
---@return table<Timing, table>
function WeakenStatus.defaultTriggers(def)
  local triggers = {}

  if def.turn_end_damage ~= nil then
    at(triggers, "RoundEnd", {
      priority = 0,   -- 必发：状态扣血不是可选项，也不该弹询问框
      on_trigger = function(trig, timing_obj, target, pet, data)
        local mark = trig.mark
        local owner = mark.pet
        if owner == nil or owner:isFainted() then return false end
        mark.logic:damage{
          target = owner,
          fixed = mark:getTurnEndDamage(),
          reason = mark.def.name,
          is_status_damage = true,   -- 不吃克制/暴击/本系
        }
        return false
      end,
    })
  end

  if def.weaken_attack ~= nil then
    -- 注意这是**攻击方**身上的状态在起作用：谁中了这个状态，谁打出去的伤害就受影响
    at(triggers, "DetermineDamage", {
      priority = 0,
      on_trigger = function(trig, timing_obj, target, pet, data)
        local mark = trig.mark
        if data.source ~= mark.pet then return false end
        if data.prevented then return false end
        local mult = mark:getAttackMultiplier(data.category)
        if mult and mult ~= 1 and data.damage > 1 then
          data.damage = math.max(1, math.floor(data.damage * mult))
        end
        return false
      end,
    })
  end

  return triggers
end

--- 回合末掉多少血。数据写的是分数（`{1, 8}` = 最大体力的 1/8），
--- 换成实际数字时**至少 1 点**——不然"最大体力很小的精灵中毒就等于没中"。
---@return integer
function WeakenStatus:getTurnEndDamage()
  local frac = self.def.turn_end_damage
  if frac == nil then return 0 end
  local num, den = frac[1] or 0, frac[2] or 1
  if num <= 0 or den <= 0 then return 0 end
  local owner = self.pet
  local max_hp = owner and owner.max_hp or 0
  return math.max(1, math.floor(max_hp * num / den))
end

--- 它把某一类攻击的伤害压到几成（没有这一项就返回 nil = 不影响）。
---@param category? SkillCategory @ Skill.Physical / Skill.Special
---@return number?
function WeakenStatus:getAttackMultiplier(category)
  local tbl = self.def.weaken_attack
  if tbl == nil or category == nil then return nil end
  return tbl[category]
end

-- ============================ 控制类 ============================

--- 控制类异常状态：让对方动不了。官方 WIKI 就是这么定义的
--- （麻痹 =「控制类异常状态，该状态下精灵无法行动」）。
---@class ControlStatus: StatusMark
ControlStatus = StatusMark:subclass("ControlStatus")

function ControlStatus.applyDefaults(def)
  def.mark_type = def.mark_type or Mark.TYPE.CONTROL
  def.max_stacks = def.max_stacks or 1
  if def.block_chance ~= nil then
    assert(type(def.block_chance) == "number" and def.block_chance >= 0 and def.block_chance <= 100,
      ("控制类异常状态 %s 的 block_chance 要在 0~100 之间"):format(def.name or "?"))
  end
  return def
end

--- 控制类的默认钩子：每次行动前问一句"这次动得了吗"。
--- `block_chance` 不写 = 100%（睡眠/冰冻/害怕就是这种"必不能动"）。
---@param def MarkDef
---@return table<Timing, table>
function ControlStatus.defaultTriggers(def)
  local triggers = {}
  -- 必发（priority 0）：控制类状态不需要问玩家"要不要生效"
  return at(triggers, "BeforeAction", {
    priority = def.trigger_priority or 0,
    on_trigger = function(trig, timing_obj, target, pet, data)
      local mark = trig.mark
      if mark:rollsActionBlock(mark.logic) then
        data:preventAction(mark.key)
      end
      return false
    end,
  })
end

--- 行动被掐掉的概率（0~100）
---@return integer
function ControlStatus:getBlockChance()
  return self.def.block_chance or 100
end

--- 这一次行动有没有被掐掉。
---
--- 掷骰走 `logic.rng`（确定性随机数），**不能**用 math.random——
--- 否则同一局回放会出现两种结果（架构文档 §2.3）。
---@param logic BattleLogic
---@return boolean blocked
function ControlStatus:rollsActionBlock(logic)
  local chance = self:getBlockChance()
  if chance >= 100 then return true end
  if chance <= 0 then return false end
  if logic and logic.rng then return logic.rng:chance(chance) end
  Log.warning(("状态 %s 判定时没有 logic.rng，无法保证确定性"):format(self.key))
  return math.random() * 100 < chance
end

-- ============================ 注册（对外入口）============================

--- 异常状态模块。`Mark.Status` 就是它。
---@class StatusModule
local Status = {
  class = StatusMark,
  WEAKEN = WeakenStatus,
  CONTROL = ControlStatus,
  KEY = StatusMark.KEY,
  KEY_NAME = StatusMark.KEY_NAME,
  CLASS = StatusMark.CLASS,
  CLASS_NAME = StatusMark.CLASS_NAME,
  CLASSES = {
    [Mark.TYPE.WEAKEN] = WeakenStatus,
    [Mark.TYPE.CONTROL] = ControlStatus,
  },
}

--- 该类定义该用哪个实例类（`Mark.classOf` 会调它）
---@param def MarkDef
---@return Object
function Status.classOf(def)
  return Status.CLASSES[def.mark_type] or StatusMark
end

--- 注册一个异常状态。
---
--- 和 `Mark.register` 的区别：这里会先按类别补齐默认行为，再登记。
--- 类别可以写 `class = "weaken"`（推荐）或直接写 `mark_type = Mark.TYPE.WEAKEN`。
---@param key string
---@param def MarkDef
---@return MarkDef
function Status.register(key, def)
  def = def or {}
  -- `class` 支持写字符串或直接写子类
  local klass = nil
  if type(def.class) == "string" then
    klass = Status.CLASSES[def.class]
    assert(klass ~= nil, ("异常状态 %s 的 class 只能是 weaken / control，收到 %q")
      :format(key, def.class))
    def.mark_type = def.mark_type or def.class
  elseif type(def.class) == "table" then
    klass = def.class
  end
  def.class = nil   -- 它只是给注册用的糖，不进定义

  def.mark_type = def.mark_type or Mark.TYPE.WEAKEN
  assert(Mark.STATUS_TYPES[def.mark_type],
    ("Status.register 只登记异常状态（弱化类/控制类），%s 收到 %q")
      :format(key, tostring(def.mark_type)))
  klass = klass or Status.classOf(def)

  klass.applyDefaults(def)

  -- 把类别默认钩子和作者自己写的钩子合起来：**作者写的优先**
  -- （比如"烧伤"想改掉默认的掉血时机，就直接自己写一条 RoundEnd）
  local merged = klass.defaultTriggers(def)
  for timing_klass, spec in pairs(def.triggers or {}) do
    merged[timing_klass] = spec
  end
  def.triggers = merged

  Mark._register(key, def)
  return def
end

---@param key string
---@return MarkDef?
function Status.get(key) return Mark.defs[key] end

---@param key string
---@return boolean
function Status.is(key) return Mark.isStatusKey(key) end

--- 全部异常状态的键（注册顺序）
---@return string[]
function Status.list() return Mark.statusKeys() end

--- 身上有没有这个异常状态
---@param pet Pet
---@param key string
---@return boolean
function Status.has(pet, key)
  if pet == nil then return false end
  return pet:hasStatus(key)
end

--- 解除异常状态：只清弱化类/控制类，**不动增益印记**。
---@param logic BattleLogic
---@param pet Pet
---@param key? string @ 只解除这一个；不填 = 全部
---@return integer cured
function Status.cure(logic, pet, key)
  if logic == nil then return 0 end
  return logic:cureStatus(pet, key)
end

-- ============================ 内置异常状态 ============================
--
-- 判断的写法：**数值做成数据**，拿不准的地方写 TODO 等图鉴核对，
-- 别硬编一个看起来很精确的假数字。

--- 内置状态的注册小包装（把枚举名当键用，免得散字符串）
local function reg(key, def) return Status.register(key, def) end

-- ---------- 控制类：动不了 ----------

reg(StatusMark.KEY.PARALYSIS, {
  name = "麻痹",
  desc = "控制类异常状态：每回合有概率无法行动，速度减半",
  class = "control",
  block_chance = 25,                 -- TODO: 与图鉴核对
  stat_multipliers = { speed = 0.5 },
})

reg(StatusMark.KEY.SLEEP, {
  name = "睡眠",
  desc = "控制类异常状态：无法行动，持续 1~3 回合",
  class = "control",
  min_turns = 1,
  max_turns = 3,
})

reg(StatusMark.KEY.FREEZE, {
  name = "冰冻",
  desc = "控制类异常状态：无法行动",
  class = "control",
})

reg(StatusMark.KEY.FEAR, {
  name = "害怕",
  desc = "控制类异常状态：无法行动，持续 1 回合",
  class = "control",
  duration = 1,
})

-- ---------- 弱化类：慢慢变弱 ----------

reg(StatusMark.KEY.POISON, {
  name = "中毒",
  desc = "弱化类异常状态：每大回合末损失最大体力的 1/8",
  class = "weaken",
  turn_end_damage = { 1, 8 },
})

reg(StatusMark.KEY.BURN, {
  name = "烧伤",
  desc = "弱化类异常状态：每大回合末损失最大体力的 1/16，物理攻击威力减半",
  class = "weaken",
  turn_end_damage = { 1, 16 },
  weaken_attack = { [Skill.Physical] = 0.5 },
})

reg(StatusMark.KEY.FROSTBITE, {
  name = "冻伤",
  desc = "弱化类异常状态：每大回合末损失最大体力的 1/16",
  class = "weaken",
  turn_end_damage = { 1, 16 },
})

return Status
