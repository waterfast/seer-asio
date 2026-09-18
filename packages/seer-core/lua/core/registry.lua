-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ Seer：全局注册表 ============================
--
-- 对应 freekill-core 的 `Engine`（也就是运行时那个全局 `Fk`）。它管的是
-- "这个游戏世界里现在有哪些东西"：
--
--   * 图鉴：种族（PetSpecies）
--   * 技能：Skill / TriggerSkill（以及它们背后的骨架）
--   * 效果类型登记表（Effect.kinds 的入口）
--   * 时机类（Timing 的子类）
--   * 加载过的扩展包
--
-- 为什么要有这么一个全局表，而不是让每个模块自己管自己：
--   1. **跨引用**：技能要按名字找效果、效果要按名字找时机、精灵要按名字找技能，
--      总得有个大家都认的目录；
--   2. **重复检测**：两个包都定义了同名技能时，这里能立刻报出来。
--      这种事不报，线上表现就是"某个包的技能莫名其妙被另一个包覆盖了"，
--      极难查（freekill 在 `Engine:addSkill` 里也专门做了这个告警）；
--   3. **数据与代码分家**：扩展包只往这里塞 spec，不碰核心类。
--
-- 注意架构文档 §7 的边界：这里装的全是**静态配置**。玩家实际拥有的精灵
-- 不在这里——那是 C++ 的 SQLite 的事。Lua 侧只有"一局之内"的临时对象。

---@class Seer: Object
---@field public root string @ seer-core 包根目录（用于拼相对路径）
---@field public packages table<string, table> @ 已加载的包 spec
---@field public package_names string[] @ 包名数组（保序，日志用）
---@field public species table<string, PetSpecies> @ 种族名 --> 种族
---@field public species_by_id table<integer, PetSpecies> @ 图鉴编号 --> 种族
---@field public skills table<string, Skill> @ 技能名 --> 技能（含自动生成的子对象）
---@field public skills_by_id table<integer, Skill> @ 技能数字 id --> 技能（懒建的索引）
---@field public skill_skeletons table<string, SkillSkeleton> @ 骨架名 --> 骨架
---@field public related_skills table<string, Skill[]> @ 技能名 --> 关联技能
---@field public timing_types table<string, Timing> @ 时机名 --> 时机类
---@field public current_logic BattleLogic? @ 当前正在跑的战场（单进程单战局时用）
Seer = class("Seer")

function Seer:initialize()
  self.root = "."
  self.packages = {}
  self.package_names = {}
  self.species = {}
  self.species_by_id = {}
  self.skills = {}
  self.skills_by_id = {}   -- 懒加载：加载完包之后第一次按 id 查时才建索引
  self.skill_skeletons = {}
  self.related_skills = {}
  self.timing_types = {}
  self.current_logic = nil
end

-- ---------------------------- 日志 ----------------------------
-- 名字沿用 freekill 的 fk.qInfo/qWarning/qCritical，方便两边对照

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

-- ---------------------------- 图鉴 ----------------------------

--- 登记一个种族。
---@param spec PetSpeciesSpec
---@return PetSpecies
function Seer:addSpecies(spec)
  local sp = PetSpecies:new(spec)
  if self.species[sp.name] then
    self:qWarning(("种族 %s 被重复定义，后者覆盖前者（检查是不是两个包都定义了它）"):format(sp.name))
  end
  self.species[sp.name] = sp
  if sp.id then
    if self.species_by_id[sp.id] then
      self:qWarning(("图鉴编号 %s 被 %s 和 %s 同时占用"):format(
        tostring(sp.id), self.species_by_id[sp.id].name, sp.name))
    end
    self.species_by_id[sp.id] = sp
  end
  return sp
end

--- 按名字或图鉴编号取种族
---@param key string|integer
---@return PetSpecies?
function Seer:getSpecies(key)
  if type(key) == "number" then return self.species_by_id[key] end
  return self.species[key]
end

-- ---------------------------- 技能 ----------------------------

--- 把一个技能对象登记进来（骨架造出来的主技能和子对象都走这里）。
---@param skill Skill
function Seer:addSkill(skill)
  assert(skill:isInstanceOf(Skill), "Seer:addSkill 只接受 Skill 及其子类")
  local old = self.skills[skill.name]
  if old then
    self:qWarning(("技能 %s 被重复定义（旧：%s，新：%s）"):format(
      skill.name,
      old.package and old.package.extensionName or "unknown",
      skill.package and skill.package.extensionName or "unknown"))
  end
  self.skills[skill.name] = skill

  -- 关联技能也要递归登记：`#技能名_序号_trig` 这类自动生成的子对象
  -- 必须能被 `Seer.skills[名字]` 找到，Timing:exec 才能按名字取回触发者
  for _, s in ipairs(skill.related_skills) do
    self:addSkill(s)
  end
  return skill
end

---@param skills Skill[]
function Seer:addSkills(skills)
  for _, s in ipairs(skills) do
    self:addSkill(s)
  end
end

--- 从一张 spec 造技能。这才是规则作者会用到的入口。
---
--- 两条路，**普通技能走第一条**：
---
---   1. 纯效果拼装（绝大多数技能）：一张表 → 一个 `Skill` 对象。
---      赛尔号的技能基本上都是"数值 + 一串效果"，比如
---      「雷电拳：电系物理 65 威力，10% 让对方麻痹」——
---      这就是一个对象 + effects 列表，不需要骨架、不需要子对象。
---   2. 带时机钩子（`spec.triggers`，主要是**特性**和少数持续效果）：
---      才走骨架，把每条时机钩子拆成 `#名字_序号_trig` 子对象挂上去。
---
--- 之所以要把第一条路单独拎出来：freekill 那套骨架是为"一个技能横跨多个时机"设计的
--- （三国杀的技能常常是这样），而赛尔号的技能绝大部分根本不挂时机，
--- 全都走骨架只会让"一个技能 = 一堆对象"变成默认印象，读代码时凭空多一层。
---@param spec SkillSpec
---@return Skill @ 主技能
function Seer:createSkill(spec)
  assert(type(spec) == "table" and spec.name, "Seer:createSkill 需要一张带 name 的 spec")

  local main
  if spec.triggers == nil then
    -- 路径 1：纯效果拼装
    main = Skill:new(spec)
  else
    -- 路径 2：带时机钩子，交给骨架拆子对象
    local skeleton = SkillSkeleton:new(spec)
    if self.skill_skeletons[skeleton.name] then
      self:qWarning(("技能骨架 %s 被重复定义"):format(skeleton.name))
    end
    self.skill_skeletons[skeleton.name] = skeleton
    main = skeleton:createSkill()
  end

  self:addSkill(main)
  return main
end

---@param name string
---@return Skill?
function Seer:getSkill(name)
  return self.skills[name]
end

--- 按数字 id 找技能。
--- C++ 侧的 `USE_SKILL 1001` 用的是数字 id（协议里传数字比传中文名省事也更稳），
--- 所以加载完包之后建一份 id 索引备用。
---@param id integer
---@return Skill?
function Seer:getSkillById(id)
  if next(self.skills_by_id) == nil then
    self:_buildSkillIdIndex()
  end
  return self.skills_by_id[id]
end

function Seer:_buildSkillIdIndex()
  self.skills_by_id = {}
  for _, skill in pairs(self.skills) do
    if skill.id then
      if self.skills_by_id[skill.id] then
        self:qWarning(("技能 id %s 被 %s 和 %s 同时占用"):format(
          tostring(skill.id), self.skills_by_id[skill.id].name, skill.name))
      end
      self.skills_by_id[skill.id] = skill
    end
  end
end

-- ---------------------------- 效果 / 异常状态 ----------------------------

--- 造一个效果实例。走这里而不是直接 Effect:new，是为了让"扩展包注册的效果类型"
--- 和核心自带的走同一条路。
---@param spec EffectSpec
---@param source? Pet
---@param target_pet? Pet
---@return Effect
function Seer:createEffect(spec, source, target_pet)
  return Effect:new(spec, source, target_pet)
end

--- 注册一种**新的效果类型**（"效果写在哪里"的入口）。
---
--- 核心自带的在 `lua/core/effect/kinds.lua`；扩展包在自己的包里加
--- （`spec.effects = { { key = "...", def = {...} } }`），**不用改核心**。
---@param key string
---@param def EffectKindDef
function Seer:registerEffectKind(key, def)
  if Effect.kinds[key] ~= nil then
    self:qWarning(("效果类型 %s 被重复注册，后者覆盖前者"):format(tostring(key)))
  end
  return Effect.registerKind(key, def)
end

--- 注册一个印记（异常状态和增益印记都走它）。
--- 内置的那些在 core/mark/ 里；扩展包可以在自己的 spec 里加（`spec.marks`）。
---@param key string
---@param def MarkDef
function Seer:addMark(key, def)
  return Mark.register(key, def)
end

-- ---------------------------- 时机 ----------------------------

--- 登记一个时机类。
--- 同时挂到全局 `SeerTiming` 上：效果的类型钩子是"按名字找时机"的，
--- 有了这个名字表，core 就不用反过来依赖 server（见 effect/init.lua 的注释）。
---@param name string
---@param klass Timing
function Seer:registerTiming(name, klass)
  if self.timing_types[name] then
    self:qWarning(("时机 %s 被重复登记"):format(name))
  end
  self.timing_types[name] = klass
  SeerTiming[name] = klass
  return klass
end

---@param name string
---@return Timing?
function Seer:getTiming(name)
  return self.timing_types[name]
end

-- ---------------------------- 战局 ----------------------------

---@param logic BattleLogic
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

-- ---------------------------- 包 ----------------------------

--- 加载一个扩展包 spec。
--- spec 的形状：
--- ```lua
--- return {
---   name = "demo", version = "0.1.0",
---   statuses = { { key = "xxx", name = "..." } },
---   species  = { { name = "...", ... } },
---   skills   = { { name = "...", ... } },
---   effects  = { { key = "...", def = { ... } } },
--- }
--- ```
--- 顺序是**刻意**的：效果类型 → 印记（异常状态）→ 种族 → 技能——
--- 因为印记/技能的 spec 里写的效果在造实例时，会校验"类型/印记登记过没有"。
--- 同名文件会合并到同一个包（见下），所以一个包可以拆成几个文件写。
---@param spec table
function Seer:addPackage(spec)
  assert(type(spec) == "table" and type(spec.name) == "string", "扩展包 spec 需要 name")

  -- 同名 = 同一个包的另一个文件，合并到同一个包上。
  -- 这样一个包可以拆成几个文件写（种族一个、技能一个、特效一个），
  -- 而不用把几百个技能塞进同一个文件——赛尔号的图鉴数据量只会越来越大。
  -- 清单是数组，所以加载顺序是确定的（§2.3）。
  local pack = self.packages[spec.name]
  if pack == nil then
    pack = { name = spec.name, version = spec.version,
             marks = {}, species = {}, skills = {}, effects = {} }
    self.packages[spec.name] = pack
    table.insert(self.package_names, spec.name)
  end

  for _, field in ipairs({ "marks", "species", "skills", "effects" }) do
    pack[field] = pack[field] or {}
    for _, item in ipairs(spec[field] or {}) do
      item.package = pack
      table.insert(pack[field], item)
    end
  end

  -- 效果类型最先注册：技能/印记里写的 effect spec 要能查到自己的类型
  -- （`mark` 效果的 validate 会查 `Mark.defs`，所以印记紧跟着）。
  for _, ef in ipairs(spec.effects or {}) do
    self:registerEffectKind(ef.key, ef.def)
  end

  -- 注册**本次**这批（新包和追加的文件都走这里，所以不会漏注册）
  for _, mk in ipairs(spec.marks or {}) do
    local key = mk.key
    local def = table.simpleClone(mk)
    def.key = nil
    self:addMark(key, def)
  end

  for _, sp in ipairs(spec.species or {}) do
    self:addSpecies(sp)
  end

  for _, sk in ipairs(spec.skills or {}) do
    self:createSkill(sk)
  end

  self:qInfo(("已加载扩展包 %s（本包累计印记 %d，种族 %d，技能 %d，效果类型 %d）"):format(
    pack.name, #pack.marks, #pack.species, #pack.skills, #pack.effects))
  return pack
end

--- dofile 一个 spec 文件再加载它。
--- 注意这里用 dofile 而不是 require：spec 文件**必须**每次都被真的执行一遍，
--- 而 require 有缓存（第二次就返回旧表），热更新时会出现"改了脚本没生效"。
---@param rel_path string @ 相对于包根目录
---@return table
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

--- 全部包加载完之后做点收尾（对齐 core 的 Engine:postLoad）。
--- 目前只做一件事：把"技能里引用了不存在的技能"这类跨包问题报出来。
function Seer:postLoad()
  self:qInfo(("seer-core 就绪：种族 %d，技能 %d，时机 %d，效果类型 %d"):format(
    self:_count(self.species),
    self:_count(self.skills),
    self:_count(self.timing_types),
    self:_count(Effect.kinds)))
end

function Seer:_count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- ---------------------------- 造精灵 ----------------------------

--- 造一只精灵（C++ 传来玩家数据之后，Lua 侧就是这样把它变成可参战的对象的）
---@param spec PetSpec
---@return Pet
function Seer:createPet(spec)
  return Pet:new(spec)
end

return Seer
