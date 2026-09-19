-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ Seer：全局注册表 ============================
--
-- 对应 freekill-core 的 `Engine`（也就是运行时那个全局 `Fk`）。它只回答一个问题：
-- **"这个游戏世界里现在有哪些东西"**。四本册子：
--
--   species  —— 精灵**种族**（PetSpecies）：静态图鉴，属性 / 种族值 / 特性。
--   pets     —— 运行时精灵**实例**（Pet）：一场战斗里真正参战的那些。
--   skills   —— 技能（Skill）：图鉴里就那一份，全场共享。
--   effects  —— 效果（Effect）：由 `createEffect` 造好并导进引擎。
--   elements —— 属性克制表（`core.elements` 模块，按需加载）。
--
-- 再加几样基础设施：时机类表（Timing 的子类）、扩展包加载、当前战局、随机数。
--
-- ---------------------------- 为什么要有这么个全局表 ----------------------------
--
--   1. **跨引用**：技能要按 id 查效果、精灵要按 id 查技能和种族。C++ 侧传来的就是
--      数字 id（`USE_SKILL 1001` 比传中文名省事也更稳），图鉴编号也是 id；
--      所以这里按 id 存，别人问什么都答得上；
--   2. **重复检测**：两个包占了同一个 id（或同一个名字）时立刻告警。不报的话，
--      线上表现是"某个包的技能莫名其妙被另一个包顶掉了"，极难查
--      （freekill 在 `Engine:addSkill` 里也专门做了这个告警）；
--   3. **数据与代码分家**：扩展包只往这里塞 spec，不碰核心类。
--
-- ---------------------------- id 是唯一键，名字只是索引 ----------------------------
--
-- 官方赛尔号用的就是编号：精灵有图鉴编号、技能有技能编号。**同名是合法的**
-- （不同精灵可以有同名技能、同一只精灵的多个形态也是不同条目），所以：
--
--   * **主表按 id 存**：`species_by_id` / `skills_by_id` / `effects_by_id` / `pets_by_id`。
--     要精确拿到某一个对象，**一律用 id**：`getSkillById(1001)`；
--   * **名字索引只是便利**：`species["布布种子"]`、`skills["撞击"]` 这种写法好写、
--     日志好看，而且 `pet.lua` 就是按名字解析种族和技能的，所以留着。
--     但名字不唯一时它只能装一个（**最后注册的那个**，并且告警）——
--     也就是说"名字索引里是谁"取决于加载顺序，**不能拿它当唯一标识**。
--
-- 一句话：**id 决定"是谁"，名字只决定"写起来顺不顺"**。想按名字显示中文，
-- 用下面的 `getSkillName(id)` / `getSkillDesc(id)` 一类方法，别把名字当键。
--
-- 边界（架构文档 §7）：这里装的是**本进程内**的目录。玩家**拥有**的精灵存在
-- C++ 的 SQLite 里，Lua 侧只有"一局之内"的对象——所以 `species` 是全服共享的
-- 静态配置，`pets` 是一次战斗运行期的东西，两者刻意分开。
--
-- ---------------------------- 种族 vs 实例 ----------------------------
--
-- 这是最容易搞混的地方，所以表和工厂方法都分开：
--
--   Seer:addSpecies{ id = 1, name = "布布种子", ... }  -- 图鉴：这是个什么样的精灵（静态、只读）
--   Seer:createPet{ id = 7, species = "布布种子" }     -- 这一局里的那一只（动态、会掉血）
--
-- `skills` 一层就够：技能对象本身只有数据、没有随场上变化的字段（见 skill.lua），
-- 图鉴里那一份就是全场共享的那一份，不需要再分"类型"和"实例"。
--
-- `effects` 也是**一层**：一张 spec 造一个 Effect，由 `createEffect` 造好后顺手
-- 导进引擎（`self.effects` / `self.effects_by_id`），没有"效果类型（kind）"那层间接
-- ——见下面"效果"一节。
--
-- ---------------------------- spec 方式 ----------------------------
--
-- 规则作者只写表，注册一律走这里（id 尽量都写：它是唯一标识，也是协议里传的那个数）：
--
-- ```lua
-- Seer:addSpecies{ id = 1, name = "布布种子", elements = { "草" } }
-- Seer:createSkill{ id = 1001, name = "撞击", category = Skill.Physical, power = 35 }
-- Seer:createEffect{ id = "burn_dot", name = "灼烧掉血", timing = ..., on_use = ... }
-- Seer:createPet{ id = 7, species = "布布种子", level = 50, skills = { "撞击" } }
--
-- Seer:getSkillById(1001)   --> Skill 对象
-- Seer:getSkillName(1001)   --> "撞击"（客户端手里只有 id，显示用的名字问这里要）
-- ```
--
-- 注意：`PetSpec.species` / `PetSpec.skills` 目前由 pet.lua 按**名字**解析
-- （`seer.species[name]` / `seer.skills[name]`），所以那里写名字或直接传对象。
-- 想在 spec 里写编号，得同时改 pet.lua 那两处解析。

---@class Seer: Object
---@field public root string @ seer-core 包根目录（用来拼包内相对路径）
---@field public species table<string, PetSpecies> @ 种族**名字索引**（重名留最后一个并告警；唯一键是 id）
---@field public species_by_id table<integer, PetSpecies> @ 种族**主表**：图鉴编号 --> 种族
---@field public pets table<string, Pet> @ 精灵**名字索引**：pet.name --> Pet（重名留最后一个并告警）
---@field public pets_by_id table<string|integer, Pet> @ 精灵**主表**：PetSpec.id --> Pet
---@field public skills table<string, Skill> @ 技能**名字索引**（重名留最后一个并告警；唯一键是 id）
---@field public skills_by_id table<integer, Skill> @ 技能**主表**：技能编号 --> 技能（和 C++ 的 USE_SKILL 对齐）
---@field public effects table<string, Effect> @ 效果**名字索引**：效果名 --> Effect
---@field public effects_by_id table<string|integer, Effect> @ 效果**主表**：Effect.id --> Effect（唯一键）
---@field public elements table? @ `core.elements` 模块（属性克制表）；加载失败时为 nil
---@field public packages table<string, table> @ 已加载的扩展包 spec：包名 --> 包
---@field public package_names string[] @ 包名数组（保序，日志与加载顺序用）
---@field public timing_types table<string, Timing> @ 时机名 --> 时机类
---@field public current_logic BattleLogic? @ 当前正在跑的战场（单进程单战局时用）
Seer = class("Seer")

function Seer:initialize()
  -- 包根目录。真正的值由 seer.lua 用 `Seer.root = ROOT` 填进来（注释见 resolvePath）
  self.root = "."

  -- 精灵：种族（静态）+ 实例（运行时）。id 是主表，名字是索引（见文件头）
  self.species = {}
  self.species_by_id = {}
  self.pets = {}
  self.pets_by_id = {}

  -- 技能
  self.skills = {}
  self.skills_by_id = {}

  -- 效果：createEffect 造出来的都导进这两张表
  self.effects = {}
  self.effects_by_id = {}

  -- 扩展包
  self.packages = {}
  self.package_names = {}

  -- 战斗基础设施
  self.timing_types = {}
  self.current_logic = nil

  -- 属性克制表：独立模块，加载失败也不该挡住核心启动
  self.elements = nil
  self:loadElements()
end

-- ---------------------------- 日志 ----------------------------
-- 名字沿用 freekill 的 qInfo/qWarning/qCritical，方便两边对照着读

function Seer:qInfo(...) Log.info(...) end
function Seer:qWarning(...) Log.warning(...) end
function Seer:qCritical(...) Log.critical(...) end

-- ---------------------------- 路径 ----------------------------

--- 把包内相对路径拼成真实路径。
--- 这里刻意不读环境变量、不猜 cwd：C++ 拉起 Lua 子进程时的工作目录是明确的，
--- 猜出来的路径只会让"本地能跑、线上找不到文件"这种事反复发生。
---@param rel string
---@return string
function Seer:resolvePath(rel)
  if rel:sub(1, 1) == "/" then return rel end
  return self.root .. "/" .. rel
end

-- ============================ 1. 精灵：种族 ============================
--
-- 种族是**静态图鉴数据**：全服共享一份、只读、可以随 Lua 包分发。
-- 两张表同时维护，但地位不同：
--   * `self.species_by_id` —— **主表**，键是图鉴编号，一个编号就是一隻精灵；
--   * `self.species`      —— **名字索引**，方便规则作者写 `species = "布布种子"`
--     （pet.lua 也是按名字解析的）。重名时留最后注册的那个并告警：
--     名字不是唯一标识，要精确取请用编号。

--- 登记一个种族。
---@param spec PetSpeciesSpec
---@return PetSpecies
function Seer:addSpecies(spec)
  local sp = PetSpecies:new(spec)

  -- id 是唯一键，必须尽量写：没有它就只能靠名字找，而名字可能重复
  if sp.id == nil then
    self:qWarning(("种族 %s 没有写图鉴编号（id），只能按名字查——建议补上 id"):format(sp.name))
  else
    local old = self.species_by_id[sp.id]
    if old ~= nil and old ~= sp then
      self:qWarning(("图鉴编号 %s 被 %s 和 %s 同时占用（id 必须唯一，后者覆盖前者）"):format(
        tostring(sp.id), old.name, sp.name))
    end
    self.species_by_id[sp.id] = sp
  end

  -- 名字索引：重名是**合法**的（不同编号的同名精灵），所以这里只留最后一个并告警，
  -- 两个种族本身都好好地在主表里，谁也顶不掉谁
  if self.species[sp.name] ~= nil then
    self:qWarning(("种族名 %s 重复（编号 %s 与 %s），按名字查只能拿到最后一个，请用 id 取"):format(
      sp.name, tostring(self.species[sp.name].id), tostring(sp.id)))
  end
  self.species[sp.name] = sp

  return sp
end

--- 按**图鉴编号**取种族（唯一键，最准的查法）。
---@param id integer
---@return PetSpecies?
function Seer:getSpeciesById(id)
  return self.species_by_id[id]
end

--- 按名字或图鉴编号取种族（图省事的写法；数字按 id 查，字符串按名字查）。
--- 名字重名时拿到的是最后注册的那个——要确定是哪一个请用 `getSpeciesById`。
---@param key string|integer
---@return PetSpecies?
function Seer:getSpecies(key)
  if type(key) == "number" then return self.species_by_id[key] end
  return self.species[key]
end

-- ============================ 2. 精灵：实例 ============================
--
-- 和种族相反：Pet 是**运行时**对象（这只精灵几级、属性值多少、带着哪几个技能），
-- 寿命跟着一局战斗走。C++ 把存档里的输入（种族 / 等级 / 个体值 / 学习力 /
-- 性格 / 技能）传给 Lua，这里用 `createPet` 现场把它变成能参战的对象。
--
-- 唯一键同样是 **id**（`PetSpec.id`，C++ 那边给的实例编号）：一局里两只
-- "布布种子"完全正常（双方的镜像队），靠名字根本分不开。

--- 造一只精灵，并登记进引擎。
---
--- 登记两张表：
---   * `self.pets_by_id[pet.id]` —— 主表（有 id 才登记），战斗里认精灵靠它；
---   * `self.pets[pet.name]`    —— 名字索引，图省事的写法与日志用。
---
--- **注意**：名字索引同名会互相覆盖（镜像对战两边都带"布布种子"很常见），
--- 所以重名要告警、且它留的是最后创建的那只。要精确找某一只请用 `getPetById`。
---@param spec PetSpec
---@return Pet
function Seer:createPet(spec)
  local pet = Pet:new(spec)

  if pet.id ~= nil then
    local old = self.pets_by_id[pet.id]
    if old ~= nil and old ~= pet then
      self:qWarning(("精灵 id %s 被 %s 和 %s 同时占用（同 id 重造会覆盖）"):format(
        tostring(pet.id), old.name, pet.name))
    end
    self.pets_by_id[pet.id] = pet
  end

  if self.pets[pet.name] ~= nil then
    self:qWarning(("精灵名 %s 已有实例，名字索引被新实例覆盖（要分清同名的两只请用 id）"):format(
      pet.name))
  end
  self.pets[pet.name] = pet

  return pet
end

--- 按 **id** 取运行时精灵实例（最准的查法；没创建过或没写 id 就是 nil）。
---@param id string|integer
---@return Pet?
function Seer:getPetById(id)
  return self.pets_by_id[id]
end

--- 按名字取运行时精灵实例（图省事；同名时拿到最后创建的那只）。
---@param name string
---@return Pet?
function Seer:getPet(name)
  return self.pets[name]
end

-- ============================ 3. 技能 ============================
--
-- 技能对象只有数据（威力 / PP / 类别 / 效果列表），图鉴里那一份就是全场共享的
-- 那一份，所以不需要"类型 / 实例"两层。同样两张表、一种地位：
--   * `self.skills_by_id` —— **主表**，键是技能编号（C++ 的 `USE_SKILL 1001` 就是它）；
--   * `self.skills`       —— **名字索引**，方便按名字取（pet.lua 按名字解析技能）。
-- **同名技能是合法的**（不同精灵可以有同名技能），所以唯一标识只能是 id。

--- 把一个技能对象登记进来。
---@param skill Skill
---@return Skill
function Seer:addSkill(skill)
  assert(skill ~= nil and skill:isInstanceOf(Skill), "Seer:addSkill 只接受 Skill 及其子类")

  -- id 是唯一键。没有 id 的技能只能按名字查，而同名是允许的 → 一定要提醒
  if skill.id == nil then
    self:qWarning(("技能 %s 没有写 id，只能按名字查——建议补上（协议里也用它）"):format(skill.name))
  else
    local old_id = self.skills_by_id[skill.id]
    if old_id ~= nil and old_id ~= skill then
      self:qWarning(("技能 id %s 被 %s 和 %s 同时占用（id 必须唯一，后者覆盖前者）"):format(
        tostring(skill.id), old_id.name, skill.name))
    end
    self.skills_by_id[skill.id] = skill
  end

  -- 名字索引：重名合法，留最后一个并告警（两个技能都在主表里，按 id 都取得到）
  local old = self.skills[skill.name]
  if old ~= nil and old ~= skill then
    self:qWarning(("技能名 %s 重复（id %s 与 %s），按名字查只能拿到最后一个，请用 id 取"):format(
      skill.name, tostring(old.id), tostring(skill.id)))
  end
  self.skills[skill.name] = skill

  return skill
end

--- 批量登记（包加载完一批技能时偶尔用得上）
---@param skills Skill[]
function Seer:addSkills(skills)
  for _, s in ipairs(skills) do
    self:addSkill(s)
  end
end

--- 从一张 spec 造技能并登记。**规则作者会用到的入口就是它。**
---
--- 赛尔号的技能基本就是"数值 + 一串效果"（「雷电拳：电系物理 65 威力，
--- 10% 让对方麻痹」就是一个 Skill 对象加一张 effects 列表），
--- 所以这里没有别的路径：一个 spec 就是一个对象。
---@param spec SkillSpec
---@return Skill
function Seer:createSkill(spec)
  assert(type(spec) == "table" and type(spec.name) == "string" and spec.name ~= "",
    "Seer:createSkill 需要一张带 name 的 spec")

  local skill = Skill:new(spec)
  self:addSkill(skill)
  return skill
end

---@param name string
---@return Skill?
function Seer:getSkill(name)
  return self.skills[name]
end

--- 按数字 id 找技能。
--- C++ 侧的 `USE_SKILL 1001` 用的是数字 id（协议里传数字比传中文名省事也更稳）。
---@param id integer
---@return Skill?
function Seer:getSkillById(id)
  return self.skills_by_id[id]
end

-- ============================ 4. 效果 ============================
--
-- 效果只有**一层**：`Effect` 实例本身。spec 是数据（id / name / 触发时机 /
-- 触发条件 / 代价 / 执行体），`createEffect` 把它造成能挂到精灵或技能上的对象，
-- **顺手导进 `self.effects`**——和 pets / skills 一个待遇：
-- "这个引擎造过哪些效果"在一张表里看得见。
--
-- 这里**没有** freekill 那套"效果类型（kind）登记表"：`Effect` 类里根本没有
-- `kinds` / `registerKind`。那套东西是"一种效果一套实现、注册一次全局复用"的写法，
-- 而赛尔号的效果是**一张 spec 造一个实例**，再套一层类型注册只会让
-- "这个效果写在哪"变成两个地方，还多一步查表。

--- 造一个效果，并导入引擎。
---
--- 走这里而不是到处 `Effect:new`：所有效果都从同一个门进来，引擎才知道自己有哪些效果
--- （统一日志、校验、计数将来都只改这一个地方）。包 spec 里的 `effects` 也走这条路
--- （见 addPackage），**没有第二条注册路径**。
---
--- 导入两张表：
---   * `self.effects_by_id[effect.id]` —— 主表。`Effect` 本来就要求 id（唯一标识），
---     所以效果**一定**能按 id 取到；
---   * `self.effects[effect.name]`    —— 名字索引，图省事用（`Effect` 没写 name 时用 id 兜底）。
---
--- 两张表都是**留最新**的、不告警：效果是运行时对象，同一个效果每回合、每只精灵身上
--- 重造是**正常**的（不像种族/技能那样是定义冲突，那种才要报）。
--- 所以要把某个实例发给谁，请用**返回值**；这两张表只是"引擎造过什么"的目录，
--- 谁身上挂着什么看 `pet.effects`。
---@param spec EffectSpec
---@param source? Pet @ 效果来源（谁给的）
---@param target_pet? Pet @ 效果挂在哪只精灵身上
---@return Effect
function Seer:createEffect(spec, source, target_pet)
  assert(type(spec) == "table", "Seer:createEffect 需要一张 effect spec")

  local effect = Effect:new(spec, source, target_pet)

  self.effects_by_id[effect.id] = effect
  self.effects[effect.name] = effect
  return effect
end

--- 按 **id** 取效果（唯一键；没造过就是 nil）。
---@param id string|integer
---@return Effect?
function Seer:getEffectById(id)
  return self.effects_by_id[id]
end

--- 按名字取效果（图省事；同名时拿到最后造的那个）。
---@param name string
---@return Effect?
function Seer:getEffect(name)
  return self.effects[name]
end

-- ============================ 5. 图鉴文本（按 id 取名字和描述） ============================
--
-- C++ / 客户端手里通常只有 id（协议里传的就是编号，图鉴里查的也是编号），
-- 要显示中文名和技能描述时问这里。名字是**显示数据**，id 才是标识：哪天要统一换成
-- 翻译表、或者把名字改成英文键，改动都只在这几个方法里，调用方不用动。
--
-- 这 6 个方法都**nil 安全**：id 不认识、或者那一项自己没写描述，就返回 nil
-- （不报错、也不编一个名字出来）——显示层拿到 nil 可以自己退化成"未知技能 1001"。
--
-- 注：`desc` 目前只有技能有（skill.lua 的 `SkillSpec.desc`）；种族和效果的类还没有
-- 这个字段，所以那两个 `getXxxDesc` 现在固定返回 nil，等类上加了就自动生效。

--- 技能编号 --> 技能名
---@param id integer
---@return string? name
function Seer:getSkillName(id)
  local skill = self.skills_by_id[id]
  return skill ~= nil and skill.name or nil
end

--- 技能编号 --> 技能描述（规则作者的备注；正式文案将来走翻译表）
---@param id integer
---@return string? desc
function Seer:getSkillDesc(id)
  local skill = self.skills_by_id[id]
  return skill ~= nil and skill.desc or nil
end

--- 图鉴编号 --> 种族名
---@param id integer
---@return string? name
function Seer:getSpeciesName(id)
  local sp = self.species_by_id[id]
  return sp ~= nil and sp.name or nil
end

--- 图鉴编号 --> 种族描述（`PetSpecies` 现在还没有 desc 字段，暂时恒为 nil）
---@param id integer
---@return string? desc
function Seer:getSpeciesDesc(id)
  local sp = self.species_by_id[id]
  return sp ~= nil and sp.desc or nil
end

--- 效果 id --> 效果名
---@param id string|integer
---@return string? name
function Seer:getEffectName(id)
  local effect = self.effects_by_id[id]
  return effect ~= nil and effect.name or nil
end

--- 效果 id --> 效果描述（`Effect` 现在还没有 desc 字段，暂时恒为 nil）
---@param id string|integer
---@return string? desc
function Seer:getEffectDesc(id)
  local effect = self.effects_by_id[id]
  return effect ~= nil and effect.desc or nil
end

-- ============================ 6. 属性 ============================
--
-- 属性克制表是一张**纯数据表**（谁打谁是 2 倍 / 0.5 倍 / 免疫），
-- 放在独立模块 `core.elements` 里，和核心代码解耦：
-- 图鉴核对出哪条关系写错了，改那个模块就行，不用碰引擎。

--- 加载属性克制表模块。
---
--- 用 `pcall(require, ...)` 而不是直接 require：这张表是**可选**的，
--- 模块还没写好（正在并行开发）或者出错了，核心也要能起来——
--- 只是属性克制会退化成中性，这时必须留下一条 warning，别让它悄悄变中性。
---@return table? elements
function Seer:loadElements()
  local ok, mod = pcall(require, "core.elements")
  if ok and type(mod) == "table" then
    self.elements = mod
    return mod
  end

  self.elements = nil
  self:qWarning(("属性克制表 core.elements 加载失败，属性克制退化为中性：%s"):format(
    tostring(mod)))
  return nil
end

---@return table? @ `core.elements` 模块；没加载成功就是 nil
function Seer:getElements()
  return self.elements
end

--- 查"攻击属性打防御属性"的倍率：2 克制 / 0.5 被抵抗 / 0 免疫 / 1 中性，
--- 双属性会合并成 4 / 1.5 / 0.25 这类值（合并规则见 core/elements/init.lua）。
---
--- 委托而已——算法只有一份，在 `core.elements` 里，这里**不复制**它。
---
--- 这里只做一层 **nil 安全**：克制表没加载成功时返回 1（中性）。
--- "倍率 1"正好是"什么都没发生"的语义，比让整局伤害计算崩掉合适，
--- 而且加载失败时 `loadElements` 已经报过一次 warning 了，不会悄无声息。
--- 属性名写错（比如"雷"）**不**在这里兜：那是数据错误，
--- 应该按 core/elements 的约定当场 error，别被静默吃成中性。
---@param attack string @ 攻击方（技能）的属性，单个
---@param defend string|string[] @ 防御方属性：字符串 = 单属性；数组 = 1~2 个属性
---@return number
function Seer:getElementMultiplier(attack, defend)
  local elements = self.elements
  if elements == nil or type(elements.getMultiplier) ~= "function" then
    return 1
  end
  return elements.getMultiplier(attack, defend)
end

-- ============================ 7. 时机 ============================
--
-- 时机等待重构

-- ============================ 8. 印记 ============================
--扽得改重构


-- ============================ 9. 战局与随机数 ============================

---@param logic BattleLogic
---@return BattleLogic
function Seer:setLogic(logic)
  self.current_logic = logic
  return logic
end

---@return BattleLogic?
function Seer:getLogic()
  return self.current_logic
end

--- 造一个确定性的随机数发生器。战斗里所有随机都必须从这里拿。
---@param seed integer|string
---@return Rng
function Seer:newRng(seed)
  return Rng:new(seed)
end

-- ============================ 10. 扩展包 ============================

--- 加载一个扩展包 spec。
--- spec 的形状：
--- ```lua
--- return {
---   name = "demo", version = "0.1.0",
---   effects  = { { id = "...", name = "...", timing = ..., on_use = ... } },
---   marks    = { { key = "xxx", name = "..." } },
---   species  = { { name = "...", ... } },
---   skills   = { { name = "...", ... } },
--- }
--- ```
---
--- 登记顺序是**刻意**的：效果 → 印记 → 种族 → 技能——
--- 因为后面的 spec 里写的是前面的名字（技能/印记里会按名字引用效果），
--- 反过来就会出现"明明写了却找不到"。
---@param spec table
---@return table pack @ 合并后的包（同名文件会并到同一个包上）
function Seer:addPackage(spec)
  assert(type(spec) == "table" and type(spec.name) == "string", "扩展包 spec 需要 name")

  -- 同名 = 同一个包的另一个文件，合并到同一个包上。
  -- 这样一个包可以拆成几个文件写（种族一个、技能一个、特效一个），
  -- 而不用把几百个技能塞进同一个文件——赛尔号的图鉴数据量只会越来越大。
  -- 清单是数组，所以加载顺序是确定的（§2.3）。
  local pack = self.packages[spec.name]
  if pack == nil then
    pack = {
      name = spec.name,
      version = spec.version,
      effects = {}, marks = {}, species = {}, skills = {},
    }
    self.packages[spec.name] = pack
    table.insert(self.package_names, spec.name)
  end

  -- 原样记进包里（spec 是数据，注册表只负责"登记"和"按顺序注册"）
  for _, field in ipairs({ "effects", "marks", "species", "skills" }) do
    pack[field] = pack[field] or {}
    for _, item in ipairs(spec[field] or {}) do
      item.package = pack
      table.insert(pack[field], item)
    end
  end

  -- 按依赖顺序注册**本次**这批（新包和追加的文件都走这里，所以不会漏注册）
  -- 效果先来：技能和印记的 spec 里会按名字引用它们
  for _, ef in ipairs(spec.effects or {}) do
    self:createEffect(ef)
  end

  for _, mk in ipairs(spec.marks or {}) do
    local def = table.simpleClone(mk)
    def.key = nil
    self:addMark(mk.key, def)
  end

  for _, sp in ipairs(spec.species or {}) do
    self:addSpecies(sp)
  end

  for _, sk in ipairs(spec.skills or {}) do
    self:createSkill(sk)
  end

  self:qInfo(("已加载扩展包 %s（本包累计效果 %d，印记 %d，种族 %d，技能 %d）"):format(
    pack.name, #pack.effects, #pack.marks, #pack.species, #pack.skills))
  return pack
end

--- dofile 一个 spec 文件再加载它。
--- 注意这里用 loadfile 而不是 require：spec 文件**必须**每次都被真的执行一遍，
--- 而 require 有缓存（第二次就返回旧表），热更新时会出现"改了脚本没生效"。
---@param rel_path string @ 相对于包根目录
---@return table pack
function Seer:loadPackageFile(rel_path)
  local path = self:resolvePath(rel_path)
  local chunk, err = loadfile(path)
  if chunk == nil then
    error(("加载包文件 %s 失败：%s"):format(path, tostring(err)), 2)
  end

  local spec = chunk()
  assert(type(spec) == "table", ("包文件 %s 必须 return 一张表"):format(path))
  return self:addPackage(spec)
end

--- 加载所有扩展包。
--- 由 `lua/specs/init.lua` 返回一份文件清单（而不是去列目录）：
---   * 不依赖 lfs / io.popen，跨环境一致；
---   * 清单是**数组**，加载顺序是确定的——顺序确定，注册顺序才确定，
---     出问题时才能复现（架构文档 §2.3）。
---@param list? string[] @ 省略则读 `lua/specs/init.lua`
---@return integer count
function Seer:loadPackages(list)
  if list == nil then
    local path = self:resolvePath("lua/specs/init.lua")
    local chunk, err = loadfile(path)
    if chunk == nil then
      self:qInfo("没有 lua/specs/init.lua，跳过扩展包加载（只跑核心也能工作）")
      return 0
    end
    list = chunk()
    assert(type(list) == "table", "lua/specs/init.lua 必须 return 一个文件清单数组")
  end

  local count = 0
  for _, rel in ipairs(list) do
    self:loadPackageFile(rel)
    count = count + 1
  end
  return count
end

--- 数一张表里有几项（只给下面那行日志用）
---@param t table?
---@return integer
local function count_keys(t)
  if t == nil then return 0 end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

--- 全部包加载完之后收尾（对齐 core 的 `Engine:postLoad`）。
--- 就一件事：打一行"我这边有什么"的就绪日志——启动完扫一眼就知道图鉴有没有加载上。
function Seer:postLoad()
  self:qInfo(("seer-core 就绪：种族 %d，技能 %d，时机 %d，效果 %d"):format(
    count_keys(self.species), count_keys(self.skills),
    count_keys(self.timing_types), count_keys(self.effects)))
end

return Seer
