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
--   1. **跨引用**：技能要按名字查效果、精灵要按名字查技能和特性。
--      pet.lua 里直接写的就是 `Seer.species[name]` / `Seer.skills[species.ability]`，
--      所以这几张表的名字和形状是**契约**，不能随手改；
--   2. **重复检测**：两个包定义了同名技能/种族时，这里立刻告警。不报的话，
--      线上表现是"某个包的技能莫名其妙被另一个包覆盖了"，极难查
--      （freekill 在 `Engine:addSkill` 里也专门做了这个告警）；
--   3. **数据与代码分家**：扩展包只往这里塞 spec，不碰核心类。
--
-- 边界（架构文档 §7）：这里装的是**本进程内**的目录。玩家**拥有**的精灵存在
-- C++ 的 SQLite 里，Lua 侧只有"一局之内"的对象——所以 `species` 是全服共享的
-- 静态配置，`pets` 是一次战斗运行期的东西，两者刻意分开。
--
-- ---------------------------- 种族 vs 实例 ----------------------------
--
-- 这是最容易搞混的地方，所以表和工厂方法都分开：
--
--   Seer:addSpecies{ name = "布布种子", ... }  -- 图鉴：这是个什么样的精灵（静态、只读）
--   Seer:createPet{ species = "布布种子" }     -- 这一局里的那一只（动态、会掉血）
--
-- `skills` 一层就够：技能对象本身只有数据、没有随场上变化的字段（见 skill.lua），
-- 图鉴里那一份就是全场共享的那一份，不需要再分"类型"和"实例"。
--
-- `effects` 也是**一层**：一张 spec 造一个 Effect，由 `createEffect` 造好后顺手
-- 导进引擎（`self.effects`），没有"效果类型（kind）"那层间接——见下面"效果"一节。
--
-- ---------------------------- spec 方式 ----------------------------
--
-- 规则作者只写表，注册一律走这里：
--
-- ```lua
-- Seer:addSpecies{ id = 1, name = "布布种子", elements = { "草" } }
-- Seer:createSkill{ name = "撞击", category = Skill.Physical, power = 35 }
-- Seer:createEffect{ id = "burn_dot", name = "灼烧掉血", timing = ..., on_use = ... }
-- Seer:createPet{ species = "布布种子", level = 50, skills = { "撞击" } }
-- ```

---@class Seer: Object
---@field public root string @ seer-core 包根目录（用来拼包内相对路径）
---@field public species table<string, PetSpecies> @ 种族：种族名 --> 种族（静态图鉴）
---@field public species_by_id table<integer, PetSpecies> @ 种族：图鉴编号 --> 种族
---@field public pets table<string, Pet> @ 运行时精灵实例：pet.name --> Pet
---@field public skills table<string, Skill> @ 技能：技能名 --> 技能
---@field public skills_by_id table<integer, Skill> @ 技能：数字 id --> 技能（和 C++ 的 USE_SKILL 对齐）
---@field public effects table<string, Effect> @ 效果：效果名 --> Effect（由 createEffect 导入）
---@field public elements table? @ `core.elements` 模块（属性克制表）；加载失败时为 nil
---@field public packages table<string, table> @ 已加载的扩展包 spec：包名 --> 包
---@field public package_names string[] @ 包名数组（保序，日志与加载顺序用）
---@field public timing_types table<string, Timing> @ 时机名 --> 时机类
---@field public current_logic BattleLogic? @ 当前正在跑的战场（单进程单战局时用）
Seer = class("Seer")

function Seer:initialize()
  -- 包根目录。真正的值由 seer.lua 用 `Seer.root = ROOT` 填进来（注释见 resolvePath）
  self.root = "."

  -- 精灵：种族（静态）+ 实例（运行时）
  self.species = {}
  self.species_by_id = {}
  self.pets = {}

  -- 技能
  self.skills = {}
  self.skills_by_id = {}

  -- 效果：createEffect 造出来的都导进这张表（和 pets / skills 一样留一份目录）
  self.effects = {}

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
-- 两张索引同时维护，因为两种查法都常用：
--   * 按名字查（技能、特性、存档里写的都是名字）—— `self.species`
--   * 按图鉴编号查（协议里传数字更稳）—— `self.species_by_id`

--- 登记一个种族。
---@param spec PetSpeciesSpec
---@return PetSpecies
function Seer:addSpecies(spec)
  local sp = PetSpecies:new(spec)

  if self.species[sp.name] ~= nil then
    self:qWarning(("种族 %s 被重复定义，后者覆盖前者（检查是不是两个包都定义了它）"):format(sp.name))
  end
  self.species[sp.name] = sp

  if sp.id ~= nil then
    local old = self.species_by_id[sp.id]
    if old ~= nil and old ~= sp then
      self:qWarning(("图鉴编号 %s 被 %s 和 %s 同时占用"):format(
        tostring(sp.id), old.name, sp.name))
    end
    self.species_by_id[sp.id] = sp
  end

  return sp
end

--- 按名字或图鉴编号取种族。
---@param key string|integer
---@return PetSpecies?
function Seer:getSpecies(key)
  if type(key) == "number" then return self.species_by_id[key] end
  return self.species[key]
end

-- ============================ 2. 精灵：实例 ============================
--
-- 和种族相反：Pet 是**运行时**对象（这只精灵几级、多少血、挂着什么状态），
-- 寿命跟着一局战斗走。C++ 把存档里的输入（种族名 / 等级 / 个体值 / 学习力 /
-- 性格 / 技能名）传给 Lua，这里用 `createPet` 现场把它变成能参战的对象。

--- 造一只精灵，并登记进 `self.pets`。
---
--- 键用 `pet.name`（昵称优先，没昵称就是种族名）——"按名字找精灵"是战斗里
--- 最常见的查法（触发者、被攻击者、协议里都传名字）。
---
--- **注意**：同名会互相覆盖（镜像对战里两边可能都带"布布种子"），所以这里
--- 重名要告警。要严格区分同名的两只，得靠 `pet.side` / `pet.seat`，
--- 或者调用方自己另外记一份按座位的表——注册表这一层的键就是名字。
---@param spec PetSpec
---@return Pet
function Seer:createPet(spec)
  local pet = Pet:new(spec)

  if self.pets[pet.name] ~= nil then
    self:qWarning(("精灵 %s 已被创建过，注册表里的旧实例被新实例覆盖"):format(pet.name))
  end
  self.pets[pet.name] = pet

  return pet
end

--- 按名字取运行时精灵实例（没创建过就是 nil）。
---@param name string
---@return Pet?
function Seer:getPet(name)
  return self.pets[name]
end

-- ============================ 3. 技能 ============================
--
-- 技能对象只有数据（威力 / PP / 类别 / 效果列表），图鉴里那一份就是全场共享的
-- 那一份，所以不需要"类型 / 实例"两层，一张 `self.skills` 就够。
--
-- 数字 id 索引**随手维护**：`addSkill` 遇到 `skill.id` 就填进 `skills_by_id`，
-- 不搞"加载完再懒建一次"那套（懒建会让"什么时候索引才有效"变成隐形约定）。

--- 把一个技能对象登记进来。
---@param skill Skill
---@return Skill
function Seer:addSkill(skill)
  assert(skill ~= nil and skill:isInstanceOf(Skill), "Seer:addSkill 只接受 Skill 及其子类")

  local old = self.skills[skill.name]
  if old ~= nil and old ~= skill then
    self:qWarning(("技能 %s 被重复定义，后者覆盖前者"):format(skill.name))
  end
  self.skills[skill.name] = skill

  -- 有数字 id 就顺手建 id 索引（同一只 id 被两个技能占用要报出来）
  if skill.id ~= nil then
    local old_id = self.skills_by_id[skill.id]
    if old_id ~= nil and old_id ~= skill then
      self:qWarning(("技能 id %s 被 %s 和 %s 同时占用"):format(
        tostring(skill.id), old_id.name, skill.name))
    end
    self.skills_by_id[skill.id] = skill
  end

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

--- 造一个效果，并导入引擎的 `self.effects`。
---
--- 走这里而不是到处 `Effect:new`：所有效果都从同一个门进来，引擎才知道自己有哪些效果
--- （统一日志、校验、计数将来都只改这一个地方）。包 spec 里的 `effects` 也走这条路
--- （见 addPackage），**没有第二条注册路径**。
---
--- 键用 `effect.name`（spec 没写 name 时 `Effect` 用 id 兜底），和 pets / skills 一致。
--- 同名会覆盖（引擎里留的是最新那个）：效果同名很正常——同一个效果可以同时挂在
--- 好几只精灵身上、也会每个回合重造。所以要把这个对象发给谁，请用**返回值**，
--- `self.effects` 只是"引擎造过什么"的目录，不是谁身上的背包
--- （身上挂着什么看 `pet.effects`）。
---@param spec EffectSpec
---@param source? Pet @ 效果来源（谁给的）
---@param target_pet? Pet @ 效果挂在哪只精灵身上
---@return Effect
function Seer:createEffect(spec, source, target_pet)
  assert(type(spec) == "table", "Seer:createEffect 需要一张 effect spec")

  local effect = Effect:new(spec, source, target_pet)
  self.effects[effect.name] = effect
  return effect
end

--- 按名字取引擎里创建过的效果（没创建过就是 nil）
---@param name string
---@return Effect?
function Seer:getEffect(name)
  return self.effects[name]
end

-- ============================ 5. 属性 ============================
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

-- ============================ 6. 时机 ============================
--
-- 时机等待重构

-- ============================ 7. 印记 ============================
--扽得改重构


-- ============================ 8. 战局与随机数 ============================

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

-- ============================ 9. 扩展包 ============================

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
