-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 精灵（战斗用）============================
--
-- 对应 freekill-core 的 `ltk/core/general.lua`（General，武将）。那边是两层，
-- 这边同样是两层：
--
--   PetSpecies  —— 精灵**种族**：静态图鉴数据，全服共享一份、只读。
--                  只有战斗用得上的东西：名字 / 图鉴编号 / 属性 / 种族值。
--   Pet         —— 一只**具体的战斗精灵**：几级、个体值多少、学习力怎么配、
--                  什么性格、带哪几个技能，以及由此算出来的六项属性值。
--
-- ---------------------------- 只做"初始化 + getter" ----------------------------
--
-- 本文件读取 spec、计算初始六项属性值，保存效果挂载表与独立的能力等级表。
-- 能力等级由 BattleRoom 统一修改；GameLogic 在计算攻防、速度和命中时读取。
-- 当前体力、剩余 PP、濒死、行动与敌我关系仍由战斗逻辑管理。
--
-- 于是也刻意**没有**做（它们是养成/图鉴/持久化的事）：
--   进化链、经验曲线与升级、捕获率、性别比例、稀有度、可学技能表、存档序列化。
-- 战斗只需要"这只精灵现在长什么样"，不需要"它将来会变成什么样"。
--
-- ---------------------------- 属性值算出来存字段 ----------------------------
--
-- 六项属性值在 `initialize` 里**算好存成字段**：`pet.hp` / `pet.attack` /
-- `pet.defense` / `pet.sp_attack` / `pet.sp_defense` / `pet.speed`。
-- 战斗里要读某一项直接读字段就行，不必每次重算；要按顺序遍历六项时用
-- `Pet.STAT_FIELDS`（纯粹是给日志/协议/UI 用的清单）或 `pet:getStats()`。
--
-- 注意 `pet.hp` 是**体力这一项的能力值（体力上限）**，不是"现在还剩多少血"——
-- 当前体力、扣血回血都是战斗逻辑，本模块不碰。
--
-- ---------------------------- spec 方式 ----------------------------
--
-- 和技能/效果一样，规则作者只写表：
--
-- ```lua
-- -- 种族（图鉴数据，注册进 Seer 后可以按名字查）
-- Seer:addSpecies{
--   id = 1, name = "布布种子", elements = { "草" },
--   base_stats = { hp = 45, attack = 49, defense = 65, sp_attack = 49, sp_defense = 65, speed = 45 },
-- }
--
-- -- 一只具体的精灵（这些字段就是 C++ 存在 SQLite 里的那些列）
-- local bu = Pet:new{
--   species = "布布种子", level = 50,
--   ivs = { hp = 31, speed = 28 },
--   evs = { hp = 252, sp_defense = 252 },
--   nature = "胆小",
--   skills = { "撞击", "藤鞭" },
--   fifth = "飞叶风暴",
-- }
-- ```

-- ============================ 精灵种族 ============================

--- 规则作者写的种族表。
---@class PetSpeciesSpec
---@field public name string @ 种族名，必需且非空（也是查表的键）
---@field public id? integer @ 图鉴编号（全局唯一），可空
---@field public elements? string[] @ 属性，1~2 个，如 `{ "草" }`、`{ "水", "飞行" }`；默认 `{}`
---@field public base_stats? table<string, integer> @ 种族值：hp/attack/defense/sp_attack/sp_defense/speed；默认 `{}`

--- 精灵种族：**静态图鉴数据**，只有战斗用得上的四样东西。
---
--- 它是只读的：造出来之后不该改，也没有任何 setter——要改就在造它之前改 spec。
---@class PetSpecies: Object
---@field public name string @ 种族名（也是查表的键）
---@field public id integer? @ 图鉴编号，可空
---@field public elements string[] @ 属性，1~2 个；空表表示"没写属性"
---@field public base_stats table<string, integer> @ 种族值，键同 Pet.STAT_FIELDS
PetSpecies = class("PetSpecies")

--- 读字段 + 补默认值，仅此而已。
---@param spec PetSpeciesSpec
function PetSpecies:initialize(spec)
  spec = spec or {}

  if type(spec.name) ~= "string" or spec.name == "" then
    error("PetSpecies 需要一个非空的 name", 2)
  end

  self.name = spec.name
  self.id = spec.id

  -- 属性留成空表而不是补一个默认属性：补了就是编造图鉴数据，
  -- 而伤害计算会照着这个编出来的属性去算克制——错得很安静，所以这里只告警。
  self.elements = spec.elements or {}
  if #self.elements == 0 then
    Log.warning(("种族 %s 没有写属性（elements），伤害计算会退化"):format(self.name))
  end

  self.base_stats = spec.base_stats or {}
end

function PetSpecies:__tostring()
  return ("<PetSpecies %s>"):format(self.name)
end

---@return string @ 种族名
function PetSpecies:getName()
  return self.name
end

---@return integer? @ 图鉴编号（没写就是 nil）
function PetSpecies:getId()
  return self.id
end

---@return string[] @ 属性数组（**不要就地修改**：这份表是全服共享的）
function PetSpecies:getElements()
  return self.elements
end

--- 主属性（本系加成、技能默认属性都用它）
---@return string? @ 第一个属性；没写属性就是 nil
function PetSpecies:getPrimaryElement()
  return self.elements[1]
end

---@return boolean @ 是不是双属性
function PetSpecies:isDual()
  return #self.elements >= 2
end

---@return table<string, integer> @ 六项种族值（**不要就地修改**）
function PetSpecies:getBaseStats()
  return self.base_stats
end

--- 某一项种族值。没写的项按 0 算——种族值是"缺省即 0"的数据，
--- 少写一项最多让这只精灵弱一点，不该让整局对战开不起来。
---@param field string @ 字段名，见 Pet.STAT_FIELDS
---@return integer
function PetSpecies:getBaseStat(field)
  return self.base_stats[field] or 0
end

-- ============================ 一只具体的战斗精灵 ============================

--- 造一只战斗精灵需要哪些输入 —— 这份清单就是 C++ SQLite 该存的列。
--- 除了 `species`，全部可空（不写就用默认值），所以最小写法是 `Pet:new{ species = "布布种子" }`。
---@class PetSpec: GameObjectSpec
---@field public species string|PetSpecies @ 种族名（查 `Seer.species`）或种族对象
---@field public name? string @ 昵称；不填就用种族名
---@field public nickname? string @ `name` 的旧写法，等价（两者都写时以 `name` 为准）
---@field public id? integer @ 这只精灵的实例编号，可空
---@field public level? integer @ 等级，默认 1（属性值公式要用它）
---@field public ivs? table<string, integer> @ 个体值 0~31，缺项默认 0（**不随机**，随机该由战斗逻辑的 rng 现算好再传进来）
---@field public evs? table<string, integer> @ 学习力，缺项默认 0
---@field public nature? string @ 性格：键名（"speed-attack"）或名字（"胆小"），见 Pet.natures
---@field public elements? string[] @ 属性；默认取 species.elements
---@field public skills? (string|Skill)[] @ 普通技能，最多 4 个（名字或 Skill 对象）
---@field public fifth? string|Skill @ 第五技能（**单独一个属性**，不占普通技能格），可空

local GameObject = require "core.gameobject"

---@class Pet: GameObject
---@field public stat_stages table<string, integer> @ 局内六项能力等级；初始为 0，由 BattleRoom 修改
Pet = GameObject:subclass("Pet")

--- 六项属性值的**字段名**，顺序固定（日志、协议、UI 都按这个顺序走）。
--- 真正的数值在 Pet 的独立字段上（`pet.attack` 等），这张表只是"用来遍历的清单"。
Pet.STAT_FIELDS = { "hp", "attack", "defense", "sp_attack", "sp_defense", "speed" }

--- 可强化/弱化的能力项；体力不设能力等级。每只精灵保存独立的等级表。
Pet.STAT_STAGE_FIELDS = { "attack", "defense", "sp_attack", "sp_defense", "speed", "accuracy" }
Pet.STAT_STAGE_MIN = -6
Pet.STAT_STAGE_MAX = 6

--- 个体值上限
Pet.IV_MAX = 31
--- 单项学习力上限
Pet.EV_MAX = 255
--- 技能栏位数（第五技能不占格）
Pet.MAX_SKILLS = 4

-- ---------------------------- 性格 ----------------------------
--
-- 性格 = "提升一项、降低另一项"，共 25 种（5 项受益 × 5 项受损，其中 5 种是同项=无修正）。
-- 这里只放数据：`{ name, up, down }`，`up == down`（或都是 nil）表示无修正。
--
-- 性格影响的是**属性值**，所以它必须留在这个模块里（公式的最后一步要乘它）；
-- 但"性格还能干什么别的"（比如心情、偏好食物）不属于战斗，一概没有。
--
-- 注意：**性格名是待与图鉴核对的占位数据**。名字对不上时不用改代码，
-- 改这张表或者用 `Pet.registerNature` 覆盖即可——这正是把规则做成数据的目的。

---@class NatureDef
---@field public name string @ 性格名（"固执"），给人和图鉴看
---@field public up string? @ 提升的字段名（"attack"）；nil = 不提升
---@field public down string? @ 降低的字段名（"sp_attack"）；nil = 不降低
Pet.natures = {}
Pet.nature_by_key = {}

--- 登记一种性格。放在函数里而不是写死，是为了让扩展包能覆盖/补充性格表
--- （发现译名和图鉴不一致时改数据就行，不用动代码）。
---@param key string @ 键名，形如 "attack-defense"（存档里存这个，比存中文名稳）
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
--- 允许作者写 `nature = "胆小"`（名字好记）或 `nature = "speed-attack"`（键名稳定）。
--- 存档里存的是**键名**：名字是给人和图鉴看的，键名才是程序的契约——
--- 哪天发现性格译名和图鉴不一致，改名字不会让老存档失效。
---@param nature string?
---@return string? key @ 认不出来就是 nil（= 无修正）
function Pet.resolveNature(nature)
  if nature == nil then return nil end
  if Pet.natures[nature] then return nature end
  local key = Pet.nature_by_key[nature]
  if key == nil then
    Log.warning(("未知的性格 %q（既不是键名也不是已知的性格名），按无修正处理"):format(tostring(nature)))
  end
  return key
end

--- 性格对某项数值的修正倍率（入参是字段名，如 "speed"）。
--- 体力**恒为 1.0**：体力的公式和另外五项不同，性格也不影响它。
---@param nature_key string? @ 性格键（Pet.resolveNature 的返回值）
---@param field string @ 字段名，见 Pet.STAT_FIELDS
---@return number @ 1.1（提升项）/ 0.9（降低项）/ 1.0（其余）
function Pet.getNatureModifier(nature_key, field)
  if nature_key == nil or field == "hp" then return 1.0 end
  local nature = Pet.natures[nature_key]
  if nature == nil then return 1.0 end
  if nature.up == field then return 1.1 end
  if nature.down == field then return 0.9 end
  return 1.0
end

-- ---------------------------- 内部小工具（初始化用）----------------------------

--- 按名字查种族：`Seer` 还没建起来、或者图鉴里没这个名字，都要报得清楚一点——
--- "table index is nil" 这种错会让人查半天。
---@param name string
---@return PetSpecies
local function resolveSpecies(name)
  local seer = rawget(_G, "Seer")
  if seer == nil then
    error(("Pet:new 拿到的是种族名 %q，但全局 Seer 还不存在——"
      .. "要么先加载 seer.lua，要么直接传 PetSpecies 对象"):format(name), 3)
  end
  local species = seer.species and seer.species[name]
  if species == nil then
    error(("Pet:new 找不到种族 %q，检查是否已经 Seer:addSpecies"):format(name), 3)
  end
  return species
end

--- 按名字查技能（规则作者写名字，注册表里存对象）。
---@param name string
---@return Skill
local function resolveSkill(name)
  local seer = rawget(_G, "Seer")
  if seer == nil then
    error(("Pet:new 拿到的是技能名 %q，但全局 Seer 还不存在——"
      .. "要么先加载 seer.lua，要么直接传 Skill 对象"):format(name), 3)
  end
  local skill = seer.skills and seer.skills[name]
  if skill == nil then
    error(("Pet:new 找不到技能 %q，检查是否已经 Seer:addSkill"):format(name), 3)
  end
  return skill
end

--- 名字或对象 -> 技能对象。传对象时原样返回（技能是全局共享的，不做拷贝）。
---@param v string|Skill|nil
---@return Skill?
local function coerceSkill(v)
  if v == nil then return nil end
  if type(v) == "string" then return resolveSkill(v) end
  return v
end

--- 把个体值/学习力这类"六项小表"补满六项，缺的用 default，并把越界值夹回范围。
--- 越界不报错而是夹住：存档里出现过一次脏数据，不该让整局对战开不起来。
---@param tbl table<string, integer>? @ 作者写的表，键可以只写关心的那几项
---@param default integer
---@param max integer
---@return table<string, integer>
local function fillStats(tbl, default, max)
  local ret = {}
  for _, field in ipairs(Pet.STAT_FIELDS) do
    local v = tbl and tbl[field] or default
    if type(v) ~= "number" then v = default end
    ret[field] = math.max(0, math.min(math.floor(v), max))
  end
  return ret
end

-- ---------------------------- 构造 ----------------------------

--- 造一只战斗精灵：读字段 + 补默认值 + 算一次六项属性值。
---
--- 同时初始化独立能力等级；注册进 Seer 由 `Seer:createPet` 负责。
---@param spec PetSpec
function Pet:initialize(spec)
  spec = spec or {}
  GameObject.initialize(self, spec)

  -- 种族：可以传对象（测试里就这么用），也可以传名字（走 Seer.species）
  local species = spec.species
  if type(species) == "string" then
    species = resolveSpecies(species)
  end
  if species == nil then
    error("Pet:new 需要 spec.species（种族名或 PetSpecies 对象）", 2)
  end
  self.species = species

  self.name = spec.name or spec.nickname or species.name
  self.id = spec.id
  self.level = spec.level or 1

  -- 能力等级属于本只精灵的局内状态，不写回种族或共享技能定义。
  -- 这里只初始化和提供 getter；战斗中的增减、清除统一经过 BattleRoom。
  self.stat_stages = {}
  for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do self.stat_stages[field] = 0 end

  -- 个体值默认 0 而**不是随机**：随机数必须由战斗逻辑自己管种子
  -- （架构文档 §2.3）。这里要随机的话，应该由调用方用 rng 现算好再传进来。
  self.ivs = fillStats(spec.ivs, 0, Pet.IV_MAX)
  self.evs = fillStats(spec.evs, 0, Pet.EV_MAX)

  -- 性格存**键名**（认不出来的按无修正处理，存 nil），属性值算完之后就只用来查表了
  self.nature = Pet.resolveNature(spec.nature)

  -- 属性默认跟着种族；本模块不改它，但它是"这只精灵现在是什么属性"的读点
  -- （将来若有改属性的战斗机制，那是战斗逻辑的事，写别处）
  self.elements = spec.elements or species.elements

  -- 技能：4 个普通技能槽 + 第五技能（单独一个属性，不占格）
  self.skills = self:_buildSkills(spec.skills)
  self.fifth = coerceSkill(spec.fifth)

  -- 六项属性值：算出来直接存字段（见下面"属性值"一节）
  self:_applyStats()
end

--- 把 spec.skills 变成技能对象数组，最多 `Pet.MAX_SKILLS` 个。
--- 多写的**砍掉并告警**（而不是报错）：技能栏只有 4 格是规则，不是错误。
---@param list (string|Skill)[]?
---@return Skill[]
function Pet:_buildSkills(list)
  local ret = {}
  for _, v in ipairs(list or {}) do
    if #ret >= Pet.MAX_SKILLS then
      Log.warning(("技能栏只有 %d 格，多出来的技能被忽略（%s）")
        :format(Pet.MAX_SKILLS, tostring(v)))
      break
    end
    local skill = coerceSkill(v)
    if skill == nil then
      Log.warning("技能列表里出现了 nil，已跳过")
    elseif type(skill) ~= "table" then
      error(("技能必须是技能名或 Skill 对象，收到的是 %s"):format(type(skill)), 3)
    else
      table.insert(ret, skill)
    end
  end
  return ret
end

function Pet:__tostring()
  -- 这里**没有**当前体力：Pet 只管"这只精灵是什么"，"还剩多少血"是战斗逻辑的事。
  return ("<%s Lv.%d>"):format(self.name, self.level)
end

-- ---------------------------- 属性值 ----------------------------
--
-- 公式（和主流回合制一致，赛尔号同款）：
--   核心值 = ⌊(种族值×2 + 个体值 + ⌊学习力/4⌋) × 等级/100⌋
--   体力   = 核心值 + 等级 + 10
--   其它项 = max(1, ⌊(核心值 + 5) × 性格修正⌋)
--
-- 分成两步是为了把两种"属性值"分清楚：
--   1. `getPanelStat(field)`：**不算性格修正**的值（体力的公式和另外五项不同，
--      这一点也在它里面处理）。它是"这只精灵养到什么水平"的裸数，
--      调试、UI 想显示"原始 300、性格只给了 1.1 倍"时用它。
--   2. 实例字段（`pet.attack` 等）：第 1 步再乘上性格修正（1.1 / 0.9 / 1.0）。
--      战斗中读属性值一律读这些字段——它们才是这只精灵真正生效的数。
-- 注意第 2 步里**不含任何战斗中的临时变化**（能力等级、印记倍率那些都不在这里，
-- 这个模块根本不做它们）：字段值在整个 Pet 生命周期里是恒定的。

--- 算"面板值"：种族值 / 个体值 / 学习力 / 等级都算进去，**不含性格修正**。
--- 这是个纯函数——随便调，随时算随时对（不会改任何字段）。
---@param field string @ 字段名，见 Pet.STAT_FIELDS
---@return integer
function Pet:getPanelStat(field)
  local core = math.floor((self.species:getBaseStat(field) * 2
    + (self.ivs[field] or 0) + math.floor((self.evs[field] or 0) / 4)) * self.level / 100)
  if field == "hp" then
    -- 体力：核心值 + 等级 + 10（体力没有性格修正）
    return core + self.level + 10
  end
  return core + 5
end

--- 把六项属性值算好存进字段（这才是"当前属性值"，含性格修正）。
--- 只在 `initialize` 里调用一次：本模块没有任何"重算"入口，
--- 因为能让数值变的东西（等级、个体值、性格、能力等级）都不在这里改。
---@return Pet self
function Pet:_applyStats()
  for _, field in ipairs(Pet.STAT_FIELDS) do
    -- 体力不加性格修正（getNatureModifier 对 "hp" 恒返回 1.0），
    -- 但它照样走 max(1, ...) 这一步，写法统一、也免得以后改动时漏掉。
    self[field] = math.max(1, math.floor(
      self:getPanelStat(field) * Pet.getNatureModifier(self.nature, field)))
  end
  return self
end

-- ---------------------------- getter ----------------------------
--
-- 全是**纯读字段**：没有参数校验之外的分支，不触发任何时机、不改任何东西，
-- 所以在战斗逻辑的任意时刻调用都是安全的。

---@return string @ 昵称（没写昵称就是种族名）
function Pet:getName()
  return self.name
end

---@return integer? @ 实例编号，可空
function Pet:getId()
  return self.id
end

---@return PetSpecies
function Pet:getSpecies()
  return self.species
end

---@return integer
function Pet:getLevel()
  return self.level
end

---@return table<string, integer> @ 六项个体值（**不要就地修改**）
function Pet:getIvs()
  return self.ivs
end

---@return table<string, integer> @ 六项学习力（**不要就地修改**）
function Pet:getEvs()
  return self.evs
end

---@return string? @ 性格键（"speed-attack"）；nil = 无修正
function Pet:getNature()
  return self.nature
end

---@return string[] @ 属性（默认就是种族的属性）
function Pet:getElements()
  return self.elements
end

---@return string? @ 主属性（本系加成、技能默认属性都用它）
function Pet:getPrimaryElement()
  return self.elements[1]
end

--- 按名字取**属性值**（含性格修正的那个，也就是字段上的数）。
--- 战斗中直接读字段就行（`pet.speed`）；这个方法只给"按名字动态取"的场合用：
--- 比如发协议给客户端要遍历六项、或者伤害公式按"物理/特殊"选攻击/特防项。
--- 未知的名字返回 0（读的人要能容忍"没有这一项"，而不是当场炸掉）。
---@param field string @ 字段名，见 Pet.STAT_FIELDS
---@return integer
function Pet:getStat(field)
  return self[field] or 0
end

--- 读取一个能力等级；未知能力项返回 0，与 getStat 的缺省读取约定一致。
--- 与 getStat 分离：面板不变，战斗逻辑计算有效数值时应用等级倍率。
---@param field string @ 见 Pet.STAT_STAGE_FIELDS
---@return integer
function Pet:getStatStage(field)
  return self.stat_stages[field] or 0
end

--- 返回全部能力等级的快照，修改返回值不会改动精灵本身。
---@return table<string, integer>
function Pet:getStatStages()
  local stages = {}
  for _, field in ipairs(Pet.STAT_STAGE_FIELDS) do stages[field] = self.stat_stages[field] end
  return stages
end

--- 六项属性值的 key -> value 快照（**给协议/UI 遍历用**）。
--- 每次调用都新建一张表，改它不会影响精灵本身。
---@return table<string, integer>
function Pet:getStats()
  local ret = {}
  for _, field in ipairs(Pet.STAT_FIELDS) do
    ret[field] = self[field]
  end
  return ret
end

--- 某一项**种族值**（转发到 species；种族值是静态数据，所以这也等价于读图鉴）。
---@param field string @ 字段名，见 Pet.STAT_FIELDS
---@return integer
function Pet:getBaseStat(field)
  return self.species:getBaseStat(field)
end

---@return Skill[] @ 普通技能（最多 4 个，**不含**第五技能）
function Pet:getSkills()
  return self.skills
end

--- 按名字取技能：先找普通技能，再找第五技能。
--- **只读不改**——换技能是战斗逻辑的事（而且它要发通知、走时机）。
---@param name string
---@return Skill? @ 没带这个技能就是 nil
function Pet:getSkill(name)
  for _, skill in ipairs(self.skills) do
    if skill.name == name then return skill end
  end
  if self.fifth ~= nil and self.fifth.name == name then
    return self.fifth
  end
  return nil
end

---@return Skill? @ 第五技能；没带就是 nil
function Pet:getFifthSkill()
  return self.fifth
end

return {
  Pet = Pet,
  PetSpecies = PetSpecies,
}
