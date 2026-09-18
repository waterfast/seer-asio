-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 精灵 ============================
--
-- 对应 freekill-core 的 `ltk/core/general.lua`（General，武将）+ `ltk/core/player.lua`
-- （Player，参战角色）。那边是两层：General 是"这个武将是谁"（静态），
-- Player 是"这一局的这个角色"（动态）。这边同样是两层：
--
--   PetSpecies  —— 精灵**种族**：只有战斗用得上的那几项——属性、种族值、特性。
--                  全服共享一份，只读，可以随 Lua 包分发。
--   Pet         —— 一只**具体的精灵**：几级、个体值多少、学习力怎么配、
--                  带哪几个技能（技能栏见 SkillSet）、现在剩多少血、身上挂着什么状态。
--
-- ---------------------------- 数值存在字段上，不是存在表里 ----------------------------
--
-- 战斗里要读"当前属性值"时，直接读字段：
--
--     pet.hp         当前体力        pet.max_hp     最大体力
--     pet.attack     攻击            pet.defense    防御
--     pet.sp_attack  特攻            pet.sp_defense 特防
--     pet.speed      速度
--
-- 这几个字段是**当前生效值**：性格修正和能力等级（±6）都已经算进去了。
-- 也就是说，伤害公式、出手顺序、UI 显示读的都是同一个数，不存在
-- "忘了乘能力等级倍率"这种 bug（那种 bug 不会报错，只会让数值悄悄不对）。
--
-- 种族值（图鉴数据）仍然在 `species.base_stats` 这张表上——那是静态数据，
-- 天生就适合用表；而"这只精灵现在的六项数值"是会变的、每只都不同的东西，
-- 做成字段更直白。想按名字遍历时用 `Pet.STAT_FIELDS`（纯粹为了遍历/协议）。
--
-- 这个区分和架构文档 §7 的数据归属表直接对应："精灵种族"是静态配置（Lua 启动时读），
-- "玩家拥有的精灵"是动态数据（C++ 存 SQLite）。C++ 那边存的是**造一只 Pet 所需要的
-- 全部输入**（种族名、等级、个体值、学习力、性格、技能名），Lua 拿到这些输入用
-- `Pet:new(spec)` 现场把 Pet 造出来。
--
-- 刻意**没有**做的东西（这里是战斗框架，不是图鉴）：
--   进化链、稀有度、捕获率、性别比例、可学技能表、经验曲线与升级、存档序列化。
-- 这些都是养成/图鉴/持久化的事，属于架构文档 §7 里"C++ 管"的那一半。
-- 战斗只需要"这只精灵现在长什么样"，不需要"它将来会变成什么样"。
--
-- ---------------------------- spec 方式 ----------------------------
--
-- 和技能/效果一样，规则作者只写表：
--
-- ```lua
-- -- 种族（图鉴数据）
-- Seer:addSpecies{
--   id = 1, name = "布布种子", elements = { "草" },
--   base_stats = { hp = 45, atk = 49, def = 65, spa = 49, spd = 65, spe = 45 },
--   ability = "茂盛",
-- }
--
-- -- 一只具体的精灵（这些字段就是 C++ 存在 SQLite 里的东西）
-- local bu = Pet:new{
--   species = "布布种子", level = 50,
--   ivs = { hp = 31, atk = 20, def = 31, spa = 31, spd = 31, spe = 28 },
--   evs = { hp = 252, def = 4, spd = 252 },
--   nature = "胆小",
--   skills = { "撞击", "藤鞭" },
-- }
-- ```

---@class PetSpeciesSpec
---@field public id integer @ 图鉴编号（全局唯一）
---@field public name string @ 名字（也是查表的键）
---@field public elements string[] @ 属性，1~2 个，如 `{ "草" }`、`{ "水", "飞行" }`
---@field public base_stats table<string, integer> @ 种族值：hp/attack/defense/sp_attack/sp_defense/speed
---@field public ability? string @ 特性名（走技能那套时机机制，见 skill.lua）

---@class PetSpecies: Object
---@field public id integer
---@field public name string
---@field public elements string[]
---@field public base_stats table<string, integer>
PetSpecies = class("PetSpecies")

---@param spec PetSpeciesSpec
function PetSpecies:initialize(spec)
  spec = spec or {}
  if type(spec.name) ~= "string" or spec.name == "" then
    error("PetSpecies 需要一个非空的 name", 2)
  end
  self.spec = spec
  self.id = spec.id
  self.name = spec.name
  self.elements = spec.elements or {}
  if #self.elements == 0 then
    Log.warning(("种族 %s 没有写属性（elements），伤害计算会退化"):format(self.name))
  end
  self.base_stats = spec.base_stats or {}
  self.ability = spec.ability
end

function PetSpecies:__tostring()
  return ("<PetSpecies %s>"):format(self.name)
end

--- 主属性（本系加成、技能默认属性都用它）
---@return string?
function PetSpecies:getPrimaryElement()
  return self.elements[1]
end

---@return boolean @ 是不是双属性
function PetSpecies:isDual()
  return #self.elements >= 2
end

--- 某一项种族值
---@param key string
---@return integer
function PetSpecies:getBaseStat(key)
  return self.base_stats[key] or 0
end

-- ============================ 一只具体的精灵 ============================

--- 造一只精灵需要哪些输入 —— 这份清单就是 C++ SQLite 该存的列。
---@class PetSpec
---@field public species string|PetSpecies @ 种族名或种族对象
---@field public level? integer @ 等级，默认 1
---@field public exp? integer @ 当前经验（C++ 存档里的数据，战斗不碰它）
---@field public ivs? table<string, integer> @ 个体值 0~31，不填默认 0（**不随机**，见下方注释）
---@field public evs? table<string, integer> @ 学习力 0~255，总和上限 510
---@field public nature? string @ 性格键，见 Pet.natures
---@field public skills? (string|Skill)[] @ 普通技能，最多 4 个
---@field public fifth? string|Skill @ 第五技能（**单独一个属性**，不占普通技能格）
---@field public nickname? string @ 昵称
---@field public hp? integer @ 当前体力，不填 = 满血
---@field public pp? table<string, integer> @ 各技能剩余 PP（不填则按技能定义的 PP）
---@field public side? integer @ 阵营（0/1），多人混战时用
---@field public seat? integer @ 出手位

Pet = class("Pet")

--- 六项数值的**字段名**，顺序固定（日志、协议、UI 都按这个顺序走）。
---
--- 注意：这张表只是"用来遍历的清单"。真正的数值在 Pet 的独立字段上
--- （`pet.attack` 等），要读某一项直接读字段就行。只有在"按顺序遍历六项"的
--- 场合（发协议、打日志、重算）才需要它。
Pet.STAT_FIELDS = { "hp", "attack", "defense", "sp_attack", "sp_defense", "speed" }
Pet.STAT_FIELDS_SET = Util.array2hash(Pet.STAT_FIELDS)

--- 可以有能力等级的那 5 项。**体力不在里面**——体力没有能力等级。
Pet.STAGE_FIELDS = { "attack", "defense", "sp_attack", "sp_defense", "speed" }
Pet.STAGE_FIELDS_SET = Util.array2hash(Pet.STAGE_FIELDS)

--- 能力等级上下限（±6 级，和主流回合制一致）
Pet.STAGE_MAX = 6

--- 学习力总和上限
Pet.EV_TOTAL_MAX = 510
Pet.EV_SINGLE_MAX = 255
Pet.IV_MAX = 31
Pet.MAX_SKILLS = 4

-- ---------------------------- 性格 ----------------------------
--
-- 性格 = "提升一项、降低另一项"，共 25 种（5 项受益 × 5 项受损）。
-- 这里只放数据：`{ name, up, down }`。`up == down` 表示无修正。
--
-- 注意：**性格名是待与图鉴核对的占位数据**。名字对不上时不用改代码，
-- 改这张表或者用 `Pet.registerNature` 覆盖即可——这正是把规则做成数据的目的。

---@class NatureDef
---@field public name string
---@field public up string?
---@field public down string?
Pet.natures = {}
Pet.nature_by_key = {}

---@param key string @ 键名（存档里存这个，比存中文名稳）
---@param def NatureDef
function Pet.registerNature(key, def)
  assert(type(key) == "string" and key ~= "", "性格的键必须是非空字符串")
  Pet.natures[key] = def
  Pet.nature_by_key[def.name] = key
end

-- 5 项非体力能力，两两组合成 25 种。键名就是 Pet 的字段名（attack/defense/...）。
local NATURE_NAMES = {
  -- 无修正的 5 种
  ["speed-speed"] = { "勤奋", nil, nil },
  ["attack-attack"] = { "坦率", nil, nil },
  ["defense-defense"] = { "认真", nil, nil },
  ["sp_attack-sp_attack"] = { "害羞", nil, nil },
  ["sp_defense-sp_defense"] = { "浮躁", nil, nil },
  -- 提升攻击
  ["attack-defense"] = { "孤僻" },
  ["attack-speed"] = { "勇敢" },
  ["attack-sp_attack"] = { "固执" },
  ["attack-sp_defense"] = { "调皮" },
  -- 提升防御
  ["defense-attack"] = { "大胆" },
  ["defense-speed"] = { "悠闲" },
  ["defense-sp_attack"] = { "淘气" },
  ["defense-sp_defense"] = { "乐天" },
  -- 提升速度
  ["speed-attack"] = { "胆小" },
  ["speed-defense"] = { "急躁" },
  ["speed-sp_attack"] = { "开朗" },
  ["speed-sp_defense"] = { "天真" },
  -- 提升特攻
  ["sp_attack-attack"] = { "内敛" },
  ["sp_attack-defense"] = { "慢吞吞" },
  ["sp_attack-speed"] = { "冷静" },
  ["sp_attack-sp_defense"] = { "马虎" },
  -- 提升特防
  ["sp_defense-attack"] = { "温和" },
  ["sp_defense-defense"] = { "温顺" },
  ["sp_defense-speed"] = { "狂妄" },
  ["sp_defense-sp_attack"] = { "慎重" },
}

for key, v in pairs(NATURE_NAMES) do
  -- 键形如 "sp_attack-defense"，用下划线分隔（因为字段名里带下划线）
  local up, down = key:match("^(%a+_?%a*)-(%a+_?%a*)$")
  if up == down then
    Pet.registerNature(key, { name = v[1], up = nil, down = nil })
  else
    Pet.registerNature(key, { name = v[1], up = up, down = down })
  end
end

--- 性格键/性格名 -> 性格键。
--- 允许作者写 `nature = "胆小"`（名字好记）或 `nature = "spe-atk"`（键名稳定）。
--- 存档里存的是**键名**：名字是给人和图鉴看的，键名才是程序的契约——
--- 哪天发现性格译名和图鉴不一致，改名字不会让老存档失效。
---@param nature string?
---@return string? key
function Pet.resolveNature(nature)
  if nature == nil then return nil end
  if Pet.natures[nature] then return nature end
  local key = Pet.nature_by_key[nature]
  if key == nil then
    Log.warning(("未知的性格 %q（既不是键名也不是已知的性格名），按无修正处理"):format(tostring(nature)))
  end
  return key
end

--- 性格对某项数值的修正倍率（入参是字段名，如 "speed"）
---@param nature_key string?
---@param field string
---@return number
function Pet.getNatureModifier(nature_key, field)
  if nature_key == nil or field == "hp" then return 1.0 end
  local nature = Pet.natures[nature_key]
  if nature == nil then return 1.0 end
  if nature.up == field then return 1.1 end
  if nature.down == field then return 0.9 end
  return 1.0
end

-- ---------------------------- 构造 ----------------------------

---@param spec PetSpec
function Pet:initialize(spec)
  spec = spec or {}

  local species = spec.species
  if type(species) == "string" then
    species = Seer.species[species]
    if species == nil then
      error(("Pet:new 找不到种族 %q，检查是否已经 Seer:addSpecies"):format(tostring(spec.species)), 2)
    end
  end
  if species == nil then
    error("Pet:new 需要 spec.species", 2)
  end

  self.species = species
  self.name = spec.nickname or species.name
  self.nickname = spec.nickname
  self.level = spec.level or 1
  self.exp = spec.exp
  self.side = spec.side
  self.seat = spec.seat

  -- 个体值默认 0 而**不是随机**：随机数必须由战斗逻辑自己管种子
  -- （架构文档 §2.3）。这里要随机的话，应该由调用方用 logic.rng 现算好再传进来。
  self.ivs = self:_fillStats(spec.ivs, 0, Pet.IV_MAX)
  self.evs = self:_fillStats(spec.evs, 0, Pet.EV_SINGLE_MAX)
  self:_clampEvTotal()

  self.nature = Pet.resolveNature(spec.nature)

  -- 战斗期状态先摆好：recalcStats 与 setStatStage 都要用到 stages
  self.stages = {}          -- 能力等级（只对 Pet.STAGE_FIELDS 那 5 项有意义）
  self.marks = {}           -- 印记（含异常状态）：key --> Mark 实例
  self.effects = {}         -- 挂在身上的**持续效果**：name --> Effect（见下面"效果"一节）
  self.sealed_skills = {}   -- 被封印/无效化的技能名（"禁止你使用某个技能"）
  self.fainted = false

  -- 技能栏：4 个普通技能槽 + **第五技能**（单独一个属性，见 SkillSet）
  self.skill_set = SkillSet:new{
    skills = spec.skills,
    fifth = spec.fifth,
    pp = spec.pp,
    max_slots = spec.max_slots or Pet.MAX_SKILLS,
  }

  -- 特性：种族自带的、永远生效的那个技能。
  -- 它和"携带技能"分开存，因为特性不占技能格、也不该被"换技能"影响。
  -- 特性走的还是同一套时机机制（见 skill.lua 里 tags 含 Skill.Ability 的写法），
  -- 所以这里只是把它找出来挂在精灵身上。
  self.ability = nil
  if species.ability then
    self.ability = Seer.skills[species.ability]
    if self.ability == nil then
      Log.warning(("种族 %s 的特性 %q 在技能表里找不到"):format(species.name, tostring(species.ability)))
    end
  end

  -- 当前数值：max_hp 和 5 项能力字段都在这里算出来（当前体力还没设，recalc 会跳过夹取）
  self:recalcStats()

  -- 当前体力：不填就是满血。最大体力是 max_hp，当前体力是 hp，两个分得清清楚楚
  self.hp = spec.hp or self.max_hp
  self.hp = math.max(0, math.min(self.hp, self.max_hp))

  self.allies = nil
  self.enemies = nil

  if self.hp <= 0 then self.fainted = true end
end

--- 把缺项补默认值，并把越界值夹回合法范围。
--- 越界不报错而是夹住：存档里出现过一次脏数据，不该让整局对战开不起来。
function Pet:_fillStats(tbl, default, max)
  local ret = {}
  for _, k in ipairs(Pet.STAT_FIELDS) do
    local v = tbl and tbl[k] or default
    if type(v) ~= "number" then v = default end
    ret[k] = math.max(0, math.min(math.floor(v), max))
  end
  return ret
end

--- 学习力总和上限 510：超了就从最后一项往前砍，保证"配点合法"
function Pet:_clampEvTotal()
  local total = 0
  for _, k in ipairs(Pet.STAT_FIELDS) do
    total = total + self.evs[k]
  end
  if total <= Pet.EV_TOTAL_MAX then return end
  for i = #Pet.STAT_FIELDS, 1, -1 do
    if total <= Pet.EV_TOTAL_MAX then break end
    local k = Pet.STAT_FIELDS[i]
    local cut = math.min(self.evs[k], total - Pet.EV_TOTAL_MAX)
    self.evs[k] = self.evs[k] - cut
    total = total - cut
  end
end

function Pet:__tostring()
  return ("<%s Lv.%d %d/%d>"):format(self.name, self.level, self.hp, self.max_hp or 0)
end

--- 由 spec 建一只精灵（语法糖）
---@param spec PetSpec
---@return Pet
function Pet.spawn(spec)
  return Pet:new(spec)
end

-- ---------------------------- 当前数值（字段，不是表）----------------------------
--
-- 公式（和主流回合制一致，赛尔号同款）：
--   体力   = ⌊(种族值×2 + 个体值 + ⌊学习力/4⌋) × 等级/100⌋ + 等级 + 10
--   其它项 = ⌊(种族值×2 + 个体值 + ⌊学习力/4⌋) × 等级/100⌋ + 5
--
-- 两步走，这一点很重要：
--   1. **面板值**：上面那个公式算出来的数，再乘性格修正（1.1 / 0.9 / 1.0）。
--      它是"这只精灵养出来是什么水平"，不含战斗中的临时变化。
--   2. **当前值**：面板值再乘能力等级倍率（±6 级）——就是 Pet 的字段上的数，
--      也就是战斗中真正参与计算的数。
-- 分成两步是为了让两边都能拿到：UI 想显示"原始 300、现在被降到 150"，
-- 就用 `getPanelStat`；伤害计算要用真正生效的数，就直接读字段。

--- 算"面板值"：种族/个体/学习力/等级/性格都算进去，**不含能力等级**。
--- 这是个纯函数——改性格、改个体值都不需要重算缓存，随时算随时对。
---@param field string @ Pet 的字段名
---@return integer
function Pet:getPanelStat(field)
  local core = math.floor((self.species:getBaseStat(field) * 2
    + self.ivs[field] + math.floor(self.evs[field] / 4)) * self.level / 100)
  if field == "hp" then
    return core + self.level + 10
  end
  return math.max(1, math.floor((core + 5) * Pet.getNatureModifier(self.nature, field)))
end

--- 重算当前数值（把 max_hp 和 5 项能力字段刷新一遍）。
--- 会在这些时候调用：造精灵、改能力等级、清空能力等级。
--- 之所以"改了等级就整体重算"而不是增量改，是因为一次算六项的开销可以忽略，
--- 而增量更新迟早会出现"某条路径忘了同步"的不一致。
function Pet:recalcStats()
  self.max_hp = self:getPanelStat("hp")

  for _, field in ipairs(Pet.STAGE_FIELDS) do
    -- 三步相乘：面板值 × 能力等级倍率 × **印记的持续倍率**。
    -- 把印记倍率也算进字段，是为了让"读 pet.speed 永远是当前真值"这条不变式成立——
    -- 麻痹降速、强化印记加攻，读出来的数字就已经是生效后的了。
    self[field] = math.max(1, math.floor(
      self:getPanelStat(field)
      * self:getStageMultiplier(field)
      * self:getMarkMultiplier(field)))
  end

  -- 算完最大体力之后，当前体力不能超上限
  if self.hp ~= nil and self.hp > self.max_hp then
    self.hp = self.max_hp
  end
  return self
end

--- 印记带来的**持续**数值倍率（速度×0.5、攻击×1.5 这类）。
--- 多个印记相乘；顺序无关（乘法可交换），所以这里用 pairs 遍历也不会破坏确定性。
---@param field string
---@return number
function Pet:getMarkMultiplier(field)
  local mult = 1
  for _, mark in pairs(self.marks or {}) do
    local m = mark.def.stat_multipliers
    if m and m[field] then
      mult = mult * m[field]
    end
  end
  return mult
end

--- 能力等级对应的倍率：+n → (2+n)/2，-n → 2/(2-n)，范围 ±6。
---@param field string
---@return number
function Pet:getStageMultiplier(field)
  local stage = self.stages[field] or 0
  if stage >= 0 then
    return (2 + stage) / 2
  end
  return 2 / (2 - stage)
end

--- 按名字取当前数值。
--- **战斗中直接读字段就行**（`pet.speed`）；这个方法只给"按名字动态取"的场合用：
--- 比如发协议给客户端要遍历六项、或者伤害公式按"物理/特殊"选攻击/防御项。
---@param field string
---@return integer
function Pet:getStat(field)
  return self[field] or 0
end

---@param field string
---@return integer
function Pet:getStatStage(field)
  return self.stages[field] or 0
end

--- 改能力等级（夹在 ±6 内），并立刻把当前数值刷新掉。
--- 真正的修改走 `BattleLogic:doStatChange`（那样才会触发时机），
--- 这个方法只是"落账 + 重算"。
---@param field string
---@param delta integer
---@return integer actual @ 实际变化量（被上下限吃掉的部分不算）
function Pet:setStatStage(field, delta)
  assert(Pet.STAGE_FIELDS_SET[field], ("未知的能力项 %q（体力没有能力等级）"):format(tostring(field)))
  local before = self.stages[field] or 0
  local after = math.max(-Pet.STAGE_MAX, math.min(Pet.STAGE_MAX, before + delta))
  self.stages[field] = after == 0 and nil or after
  if after ~= before then
    self:recalcStats()
  end
  return after - before
end

--- 清空全部能力等级（换下场、倒下时用），并重算数值
function Pet:resetStages()
  self.stages = {}
  self:recalcStats()
end

--- 当前六项数值的快照（**给协议/UI 遍历用**，战斗内部请直接读字段）。
--- 键就是 `Pet.STAT_FIELDS` 里的字段名。
---@return table<string, integer>
function Pet:getStatSnapshot()
  local ret = {}
  for _, field in ipairs(Pet.STAT_FIELDS) do
    ret[field] = self[field]
  end
  return ret
end

-- ---------------------------- 体力 ----------------------------

--- 扣血。**裸操作**：不判克制、不触发时机、不发通知。
---
--- 它是给 `BattleLogic:changeHp`（也就是 `GameEvent.ChangeHp`）用的**底座**——
--- 全项目只有那一个地方该改 hp，别的地方直接调它 = 绕过整套事件系统
--- （那样"防止体力变化"就拦不住了）。
---@param num integer
---@return integer actual @ 实际掉了多少血
function Pet:takeDamage(num)
  num = math.max(0, math.floor(num))
  local actual = math.min(self.hp, num)
  self.hp = self.hp - actual
  if self.hp <= 0 then
    self.hp = 0
    self.fainted = true
  end
  return actual
end

--- 回血。和 takeDamage 一样是裸操作，同样只该被 `BattleLogic:changeHp` 调用。
---@param num integer
---@return integer actual @ 实际回了多少血（满血时是 0）
function Pet:heal(num)
  if self.fainted then return 0 end
  num = math.max(0, math.floor(num))
  local actual = math.min(self.max_hp - self.hp, num)
  self.hp = self.hp + actual
  return actual
end

---@return integer
function Pet:getHpRatio()
  if self.max_hp <= 0 then return 0 end
  return self.hp / self.max_hp
end

---@return boolean
function Pet:isFainted()
  return self.fainted or self.hp <= 0
end

--- 满血复活（换精灵/复活类效果用）
---@param hp? integer
function Pet:revive(hp)
  self.fainted = false
  self.hp = hp and math.max(1, math.min(hp, self.max_hp)) or self.max_hp
  self.marks = {}
  self.stages = {}
  return self.hp
end

-- ---------------------------- 印记与异常状态 ----------------------------
--
-- 精灵身上挂的东西统一叫**印记**（Mark）：异常状态（弱化类/控制类）和增益印记
-- 都是它，只是 `mark_type` 不同。定义与行为在 core/mark/ 里，
-- 这里只负责"挂上去 / 摘下来 / 列表"。
--
-- 一条边界：**Pet 不解释印记的效果**（谁掉血、谁动不了），那是印记自己的触发器在管。
-- Pet 只管持有关系和数值倍率。

--- 挂一个印记。**走 BattleLogic:applyMark**（那样才有时机、有通知、有免疫判定），
--- 这个方法只是"落账"。
---@param key string
---@param mark Mark @ 已经构造好的印记实例
---@return Mark
function Pet:addMark(key, mark)
  self.marks[key] = mark
  return mark
end

---@param key string
---@return Mark?
function Pet:getMark(key)
  return self.marks[key]
end

--- 身上有没有这个印记（不管它是异常状态还是增益印记）
---@param key string
---@return boolean
function Pet:hasMark(key)
  return self.marks[key] ~= nil
end

--- 身上有没有这个**异常状态**（弱化类/控制类）
---@param key string
---@return boolean
function Pet:hasStatus(key)
  local mark = self.marks[key]
  return mark ~= nil and mark:isStatus()
end

--- 所有印记的键。**排序**过：日志/协议里的顺序必须是确定的（§2.3）。
---@return string[]
function Pet:getMarkKeys()
  local ret = {}
  for k in pairs(self.marks) do table.insert(ret, k) end
  table.sort(ret)
  return ret
end

---@return Mark[] @ 按键排序
function Pet:getMarks()
  return table.map(self:getMarkKeys(), function(k) return self.marks[k] end)
end

--- 身上的**异常状态**（弱化类 + 控制类）
---@return Mark[]
function Pet:getStatusMarks()
  return table.filter(self:getMarks(), function(m) return m:isStatus() end)
end

---@return string[]
function Pet:getStatusKeys()
  return table.map(self:getStatusMarks(), function(m) return m.key end)
end

--- 摘掉一个印记（**走 BattleLogic:removeMark** 才会触发时机与通知）
---@param key string
---@return boolean
function Pet:removeMark(key)
  if self.marks[key] == nil then return false end
  self.marks[key] = nil
  return true
end

--- 按条件清掉一批印记
---@param filter? function @ `fun(mark): boolean`；不填 = 全清
---@return integer cleared
function Pet:clearMarks(filter)
  local cleared = 0
  for _, mark in ipairs(self:getMarks()) do
    if filter == nil or filter(mark) then
      self.marks[mark.key] = nil
      cleared = cleared + 1
    end
  end
  return cleared
end

-- ---------------------------- 效果（挂在身上的回合类效果）----------------------------
--
-- **技能上写的效果和这里的"身上的效果"是同一个类**（`Effect`），区别只有寿命：
--   瞬时效果（`instant`，没有 duration）：技能结算时当场算完，不会进这张表；
--   持续效果（有 duration）：挂进 `pet.effects`，之后每个大回合自己动，
--     回合数归零或被清除时 `remove()` 把时机触发器摘干净。
--
-- 所以这张表和 `pet.marks` 的区别不是"技能效果 vs 身上效果"，而是：
--   `pet.marks`   —— 印记/异常状态：有名字、有描述、**要被玩家看见**、能被解毒
--   `pet.effects` —— 效果：纯机制（受伤减半、被打了反击、抵挡致死），不进状态栏
--
-- 遍历一律用 `getEffects()` / `getEffectsByKind()`：它们按名字排序返回数组。
-- 直接用 `pairs(pet.effects)` 会让"哪只精灵先被处理"取决于哈希顺序，
-- 同一局回放就可能出现两种结果（架构文档 §2.3）。

---@param effect Effect
function Pet:addEffect(effect)
  self.effects[effect.name] = effect
end

---@param name string
---@return Effect?
function Pet:getEffect(name)
  return self.effects[name]
end

---@param name string
---@return boolean
function Pet:hasEffect(name)
  return self.effects[name] ~= nil
end

---@return integer @ 身上挂着几个持续效果
function Pet:countEffects()
  local n = 0
  for _ in pairs(self.effects) do n = n + 1 end
  return n
end

---@return Effect[] @ 按名字排序，保证顺序确定
function Pet:getEffects()
  local names = {}
  for n in pairs(self.effects) do table.insert(names, n) end
  table.sort(names)
  return table.map(names, function(n) return self.effects[n] end)
end

--- 按效果类型筛（"我身上有哪些增伤效果"这类问题）。
---@param kind string @ Effect.kinds 里的键
---@return Effect[]
function Pet:getEffectsByKind(kind)
  return table.filter(self:getEffects(), function(e) return e.kind == kind end)
end

---@param name string
function Pet:removeEffect(name)
  self.effects[name] = nil
end

--- 按类型清理（比如"换精灵时清掉所有临时修正"）
---@param kind string
---@param reason? string
---@return integer removed
function Pet:removeEffectsByKind(kind, reason)
  local n = 0
  for _, effect in ipairs(self:getEffectsByKind(kind)) do
    effect:remove(reason or "cleared")
    n = n + 1
  end
  return n
end

--- 清除全部效果（下场/倒下时用）
---@param keep? string[] @ 这些名字的效果保留
function Pet:clearEffects(keep)
  local keep_set = keep and Util.array2hash(keep) or Util.DummyTable
  for _, effect in ipairs(self:getEffects()) do
    if not keep_set[effect.name] then
      effect:remove("cleared")
    end
  end
end

-- ---------------------------- 技能栏与 PP ----------------------------
--
-- 技能和 PP 都委托给 `self.skill_set`（SkillSet）管：4 个普通技能槽 + 第五技能。
-- Pet 上这些方法是**转发**，方便调用方写 `pet:getSkill(...)` 而不用到处
-- `pet.skill_set:getSkill(...)`；但技能栏本身是一个独立对象，
-- "哪些是普通技能、哪个是第五技能"这件事由它说了算。

--- 设置第 slot 个普通技能槽
---@param slot integer @ 1..4
---@param skill string|Skill
function Pet:setSkillSlot(slot, skill)
  return self.skill_set:setSlot(slot, skill)
end

--- 一次性换掉 4 个普通技能槽（第五技能不受影响）
---@param list (string|Skill)[]
function Pet:setSkills(list)
  return self.skill_set:setSlots(list)
end

--- 设置第五技能（单独一个属性，不占普通技能格）
---@param skill string|Skill|nil
function Pet:setFifthSkill(skill)
  return self.skill_set:setFifth(skill)
end

---@return Skill? @ 第五技能；没有就是 nil
function Pet:getFifthSkill()
  return self.skill_set:getFifth()
end

---@param name string
---@return boolean @ 这个名字是不是第五技能
function Pet:isFifthSkill(name)
  return self.skill_set:isFifth(name)
end

---@param name string
---@return boolean @ 普通技能、第五技能、或**特性**里有没有这个名字
---
--- 把特性也算进来是有原因的：触发者的归属判断（`TriggerSkill:isActorTrigger`）
--- 会问"这个触发者属不属于我"，而特性产生的触发者也必须算"属于我"。
--- 只想要"能主动用的技能"时请用 `getAllSkills()` / `skill_set:has()`。
function Pet:hasSkill(name)
  if self.skill_set:has(name) then return true end
  if self.ability and (self.ability.name == name or self.ability.trueName == name) then
    return true
  end
  return false
end

--- 这个技能是不是"特性"（特性不占技能格，也通常不能主动使用）
---@param name string
---@return boolean
function Pet:isAbility(name)
  return self.ability ~= nil and (self.ability.name == name or self.ability.trueName == name)
end

---@return Skill?
function Pet:getAbility()
  return self.ability
end

--- 这个技能是不是被封印了（"禁止你使用这个技能"）。
---@param name string
---@return boolean
function Pet:isSkillSealed(name)
  return self.sealed_skills[name] == true
end

--- 封住一个技能，让它用不出来。传表可以一次封一组。
---
--- 为什么封印记在**精灵**身上而不是改 `skill.usable`：技能对象是全局共享的
--- （图鉴里就那一份），改它等于把全场所有精灵的同一个技能一起封了。
--- 而"禁止你使用技能"是精灵身上的状态——对手封的、效果给的、回合数到了就解，
--- 所以它属于 Pet。
---@param name string|string[]
function Pet:sealSkill(name)
  if type(name) == "table" then return self:sealSkills(name) end
  assert(type(name) == "string", "sealSkill 需要技能名（或名字数组）")
  self.sealed_skills[name] = true
end

---@param names string[]
function Pet:sealSkills(names)
  for _, n in ipairs(names or {}) do
    self:sealSkill(n)
  end
end

---@param name string
function Pet:unsealSkill(name)
  self.sealed_skills[name] = nil
end

--- 解掉全部封印（比如"封印持续 2 回合"到期时）
function Pet:unsealAllSkills()
  self.sealed_skills = {}
end

---@return string[] @ 被封印的技能名（排序，便于测试与序列化）
function Pet:getSealedSkills()
  local ret = {}
  for name in pairs(self.sealed_skills) do table.insert(ret, name) end
  table.sort(ret)
  return ret
end

--- 按名字或槽位号取技能（名字会在普通技能和第五技能里一起找）
---@param key string|integer
---@return Skill?
function Pet:getSkill(key)
  if type(key) == "number" then
    return self.skill_set:getSlot(key)
  end
  return self.skill_set:find(key)
end

---@return Skill[] @ 4 个普通技能（**不含**第五技能和特性）
function Pet:getSkills()
  return self.skill_set:getSlots()
end

---@return Skill[] @ 普通技能 + 第五技能（"这只精灵拥有哪些技能"用这个）
function Pet:getAllSkills()
  return self.skill_set:getAll()
end

---@return SkillSet
function Pet:getSkillSet()
  return self.skill_set
end

--- 这个技能现在能不能用（PP 够不够、有没有被封印、技能自己的条件满足没有）
---@param skill string|Skill
---@return boolean
function Pet:canUseSkill(skill)
  local ok = self:checkSkillUsable(skill)
  return ok
end

--- 同上，但**带上原因**（客户端要把技能摆成灰的并说明为什么）。
---@param skill string|Skill
---@return boolean ok
---@return string? reason @ 见 Skill.Unusable
---@return string? text @ 给玩家看的一句话
function Pet:checkSkillUsable(skill)
  if type(skill) == "string" then skill = self:getSkill(skill) end
  if skill == nil then
    local reason = Skill.Unusable.NO_SKILL
    return false, reason, Skill.UnusableText[reason]
  end
  return skill:checkUsable(self)
end

---@param name string
---@return integer @ 剩余 PP
function Pet:getPP(name)
  return self.skill_set:getPP(name)
end

--- 消耗 PP
---@param name string
---@param n? integer
---@return boolean @ PP 够不够（不够则不减）
function Pet:usePP(name, n)
  return self.skill_set:usePP(name, n)
end

---@param name string
---@param n? integer
function Pet:restorePP(name, n)
  self.skill_set:restorePP(name, n)
end

function Pet:restoreAllPP()
  self.skill_set:restoreAllPP()
end

-- ---------------------------- 阵营 ----------------------------

--- 由战斗房间在开局时调用：把同一场战斗里的所有精灵串成敌我两方。
--- 敌我关系不能靠"谁先被创建"来判断，必须由战局显式给定。
---@param all_pets Pet[]
function Pet:linkTeams(all_pets)
  self.allies = {}
  self.enemies = {}
  for _, p in ipairs(all_pets) do
    if p == self then
      table.insert(self.allies, p)
    elseif p.side == nil or self.side == nil or p.side == self.side then
      -- 没分阵营时不判断敌我，都当自己人；需要敌我的玩法必须显式设 side
      table.insert(self.allies, p)
    else
      table.insert(self.enemies, p)
    end
  end
  return self
end

---@return Pet[]
function Pet:getAllyTeam()
  return self.allies or { self }
end

---@return Pet[]
function Pet:getEnemyTeam()
  return self.enemies or {}
end

--- 已经倒下的己方同伴里，有没有能换上来的
---@return Pet[]
function Pet:getBench()
  return table.filter(self:getAllyTeam(), function(p) return p ~= self and not p:isFainted() end)
end

-- 存档/序列化（断线重连、落盘）这里**没有**做。
-- 需要它的时候再写：要存的是"造 Pet 的输入 + 可变状态"（等级/个体值/学习力/性格/
-- 技能/当前体力/PP/能力等级/异常状态），而能力值、最大体力这些**能算出来的不要存**——
-- 存了就会出现"存档里的数字和公式算出来的不一致"这种最难查的 bug。

return {
  Pet = Pet,
  PetSpecies = PetSpecies,
}
