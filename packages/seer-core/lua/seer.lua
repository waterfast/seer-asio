-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ seer-core 载入入口 ============================
--
-- 对应 freekill-core 的 `lua/freekill.lua` + `lua/fk_ex.lua`。干三件事：
--
--   1. 备好 Lua 环境：把 `lua/lib`、`lua/` 加进 package.path，
--      装载类库（middleclass）和工具库（Util / Log / Rng）。
--   2. 建立全局目录：`Seer`（注册表，定义在 core/engine.lua），并把各个**基类**
--      挂成全局（`Skill` / `Pet` / `TriggerEvent` / `TriggerData` …）。
--   3. 按顺序加载：先基类，再时机类，最后扩展包 spec。
--
-- ---------------------------- 当前真实结构（重构后）--------------------------
--
--   core/engine.lua        Seer 注册表（原 core/registry.lua，已改名）
--   core/skill.lua         Skill
--   core/pet.lua           Pet / PetSpecies
--   core/trigger_event.lua TriggerEvent（时机基类）
--   core/events/           TriggerData 基类 + 18 个时机类（gameflow / attack）
--   core/elements/         属性克制表（Elements.getMultiplier）
--   core/effect/effect.lua Effect（**没有 init.lua**，见下面的 TODO）
--   core/gameobject.lua    GameObject（精灵/道具/场地的统一基类）
--   server/request/        Request + 各类 Handler（Cli / Rpc / Ai / Default）
--   server/gameevent.lua   GameEvent（freekill 移植的**协程**流程事件基类）
--   server/gamelogic.lua   GameLogic（`run()` 就是整局主循环）
--
-- **没有**的东西（旧文档里还在提，代码里已经不存在了，别照着写）：
--   core/timing.lua、core/trigger_data.lua、server/battle/*、core/effect/kinds.lua、
--   SkillSet / TriggerSkill / SkillSkeleton、core/mark/*（依赖 OwnedTrigger，见下）。
--
-- ---------------------------- 为什么基类要挂全局 ----------------------------
--
-- 因为基类之间**互相引用**：技能归 Seer 管、时机类要继承 TriggerEvent、
-- TriggerEvent 的 data 是 TriggerData 的子类、Pet 又要能按名字查技能表。
-- 如果在每个文件里互相 require，就会出现循环依赖（`a.lua` require `b.lua`，
-- `b.lua` 又 require 回去），Lua 的 require 在这种情况下会拿到半成品表。
--
-- freekill 的办法是把核心类都挂成全局（见它的 `fk_ex.lua`）：文件里
-- **加载期**需要的东西用 local require 显式拿，**运行期**才需要的东西就用全局，
-- 于是循环自然断开。本项目照抄这个做法，也顺便让扩展包作者写 spec 时
-- 能直接用 `Skill.Physical` 这些名字。
--
-- 代价是污染全局名字空间。作为补偿，本文件最后 `return` 一个表，
-- 把类都规规矩矩地列在里面——测试和嵌入方（以及将来的 C++ 侧桥接代码）
-- 可以：
--
--   local S = dofile("lua/seer.lua")
--   local pet = S.Pet:new{ species = "布布种子", level = 5 }

-- ---------------------------- 0. 一个进程只载入一次 ----------------------------
--
-- 本文件用 `dofile` 进来（而不是 require），因为它要**每次真的执行**；
-- 但"真的执行"不等于"可以执行两次"：第二次执行会把 `Seer` 这些全局表
-- 重置成新的空表，而 `require "core.skill"` 之类的模块已经被缓存、不会重新跑一遍——
-- 于是新表里什么都没有，后加载的部分就会在 `Skill:new` 这种地方拿到 nil。
--
-- 所以这里自己加一道守卫：**一个 Lua 进程里只有一份核心**。
--
-- 那热更新怎么办？答案是"换 Lua 脚本 = 换一个 Lua 子进程"，
-- 而不是在同一个进程里重载代码（反正核心进程的生命周期本来就跟着房间走）。
if rawget(_G, "SeerCore") then
  return SeerCore
end

-- ---------------------------- 1. 路径 ----------------------------

-- 用 debug.getinfo 反查本文件的位置，而不是猜 cwd。
-- C++ 拉起 Lua 子进程时的工作目录是明确的（packages/seer-core），
-- 但自测时可能从仓库根目录跑；从自身位置推 root，两种都能工作。
local _info = debug.getinfo(1, "S")
local _here = _info.source:sub(2) -- 去掉开头的 '@'
local ROOT = _here:match("^(.*)/lua/seer%.lua$") or "."

package.path = table.concat({
  ROOT .. "/lua/lib/?.lua",
  ROOT .. "/lua/?.lua",
  ROOT .. "/lua/?/init.lua",
  "./?.lua",
  "./?/init.lua",
  package.path,
}, ";")

-- ---------------------------- 2. 环境 ----------------------------

-- middleclass：轻量级面向对象库（MIT，见 lua/lib/middleclass.lua）
class = require "middleclass"

-- Util 必须在所有基类之前：基类大量用它的 table/string 扩展
Util = require "core.util"
Log = require "core.log"
Rng = require "core.rng"

-- 日志默认级别可以由外面调（C++ 侧想静音就设成 warning）
Log.min_level = "info"

-- 选项式加载：**可选**模块（server 侧那几层）载入失败时只警告、不拖垮核心。
-- 核心（engine/skill/pet/events/elements）仍然一律直接 require——
-- 那些是骨架，缺一个就说明包坏了，应该在启动时当场炸出来。
---@param name string
---@param optional boolean?
---@return any
local function load(name, optional)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  if optional then
    Log.warning(("可选模块 %s 加载失败（相关功能不可用）：%s"):format(name, tostring(mod)))
    return nil
  end
  error(("核心模块 %s 加载失败：%s"):format(name, tostring(mod)), 2)
end

-- ---------------------------- 3. 注册表 ----------------------------

-- 注册表（原 core/registry.lua，已改名 core/engine.lua）。它对应 freekill 那个全局 `Fk`。
-- 注意 engine.lua 里的 `Seer = class("Seer")` 会同时把这个类挂成全局。
Seer = load("core.engine"):new()
Seer.root = ROOT

-- ---------------------------- 4. 基类 ----------------------------
--
-- 下面这些 require **会顺带把类挂成全局**——这是刻意的，也是抄 freekill 的做法：
-- 每个核心模块在文件里就把自己的类挂到全局（`Skill = class("Skill")`），
-- 于是"运行期互相引用"不需要 require，循环依赖自然断开。
-- 这里用 local 接一下返回值，一是能立刻拿到引用，二是让加载顺序在代码里看得见。
--
-- 加载顺序是有讲究的，不是随便排的：
--   trigger_event -> events : 时机类（events/*.lua）要 TriggerEvent:subclass，
--                             TriggerData 也要在 events/init.lua 里先有
--   events        -> gamelogic : gamelogic 直接用全局的数据类（TurnData / DamageData …）

local TriggerEventModule = load("core.trigger_event")
TriggerEvent = TriggerEventModule

-- core/events 返回 { TriggerData, timings, gameflow, attack }：
--   TriggerData 是时机数据的基类；timings 是 18 个时机类**按战斗流程顺序**的数组。
-- 加载它就会把数据类挂成全局（BattleStartData / TurnData / DamageData / AttackData …），
-- server/gamelogic.lua 正是靠这些全局名字造数据的。
local Events = load("core.events")
TriggerData = Events.TriggerData
Timings = Events.timings

-- 时机名字表：时机名（"BattleStart"）--> 时机类。
-- 旧结构里这件事由 `server/battle/timing.lua` 干（那个文件已随重构删除），
-- 但"按名字找时机"的需求还在（效果 / 印记 / 未来的 spec 里写 `[时机] = ...`，
-- 而且 core 不该反过来依赖 server）。所以这里照着 core.events 的清单建一份。
-- `Seer.timing_types` 是注册表里声明过的字段（`postLoad` 会数它），重构后一直没人填，
-- 顺带补上——不然那行就绪日志永远显示"时机 0"。
SeerTiming = {}
for _, klass in ipairs(Timings) do
  SeerTiming[klass.name] = klass
  Seer.timing_types[klass.name] = klass
end

GameObject = load("core.gameobject")

local SkillModule = load("core.skill")
Skill = SkillModule.Skill

local PetModule = load("core.pet")
Pet = PetModule.Pet
PetSpecies = PetModule.PetSpecies

-- 属性克制表：由 Seer:initialize 里的 loadElements() 装好（加载失败会退化成中性并告警）
Elements = Seer:getElements()

-- ---------------------------- 5. 效果与对战方 ----------------------------
-- trigger 的必需依赖：加载失败直接报错，避免战斗静默丢失效果。
local BuffModule = load("core.buff")
Buff = BuffModule.Buff
BuffController = BuffModule.BuffController
Effect = load("core.effect.effect")
EffectHandler = load("core.effect.effect_handler")
Unit = load("core.unit")
BattleRoom = load("server.battleroom")

-- ---------------------------- 6. 印记（暂不加载）---------------------------
--
-- TODO(重构未完成)：`core/mark/` 整体依赖一套**还没重建**的效果 / 触发器体系：
--   * `OwnedTrigger`（mark/init.lua 用它 subclass 出 MarkTrigger、用它装技能钩子）
--     —— 类本身不存在，所以 mark/init.lua **一加载就炸**；
--   * `pet:recalcStats()` / `pet.marks` / `pet.seat`（Pet 上已被删掉）；
--   * `logic:applyEffect` / `logic:removeTrigger`（GameLogic 上没有）。
--   所以这里**先不加载** core.mark。等 OwnedTrigger + 效果系统重建之后，
--   把下面这行恢复，并注意它必须排在时机类之后（印记要按名字挂时机）。
--
-- Mark = load("core.mark")

-- ---------------------------- 7. 战斗侧 ----------------------------

-- 询问机制（freekill `lua/server/request.lua` 的移植）：`Request` 描述"问什么"，
-- 各个 Handler 决定"谁去答"（命令行 / AI / 真人客户端 / 无头默认）。
-- ⚠ 还没接进 GameLogic（见 server/gamelogic.lua 里 pickAction 的 TODO），
--   现在加载只是为了类可用、包可用。
Request = load("server.request", true)

-- 流程事件（GameEvent）：freekill 那边是**协程**式的流程框架。
-- 当前的 GameLogic:run() 是直接循环、没走它；这里只保证基类可 require。
GameEvent = load("server.gameevent", true)

-- 战局：GameLogic:new{ pets = ..., rng_seed = ... } → logic:run() 跑完整局。
-- 必须最后加载：它 require core.events，并在运行时用全局数据类。
GameLogic = load("server.gamelogic")

-- ---------------------------- 8. 扩展包 ----------------------------

--- 启动：加载所有扩展包并收尾。
--- `list` 省略时读 `lua/specs/init.lua` 里的清单（那个文件目前不存在，
--- 于是跳过包加载——核心类照样可用，只是图鉴/技能表是空的）。
---@param list? string[]
---@return Seer
function Seer:start(list)
  local count = self:loadPackages(list)
  if count == 0 then
    self:qInfo("没有加载任何扩展包：核心类可用，但图鉴/技能表是空的")
  end
  self:postLoad()
  return self
end

Seer:start()

-- ---------------------------- 9. 返回值 ----------------------------

--- 挂到全局 `SeerCore`，本文件开头的守卫靠它判断"这个进程已经载入过了"
SeerCore = {
  -- 注册表
  Seer = Seer,

  -- 基类
  GameObject = GameObject,
  TriggerEvent = TriggerEvent,
  TriggerData = TriggerData,
  Skill = Skill,
  Pet = Pet,
  PetSpecies = PetSpecies,
  Effect = Effect,
  Buff = Buff,
  BuffController = BuffController,
  EffectHandler = EffectHandler,   -- 效果的调度器（收集 → 排序 → 筛选 → 执行）
  Unit = Unit,                     -- 挂载玩家方效果
  BattleRoom = BattleRoom,         -- 局内状态与效果来源容器

  -- 时机：18 个类（按战斗流程顺序）+ 两组分类
  Timings = Timings,
  SeerTiming = SeerTiming,         -- 时机名 --> 时机类（按名字查时机用这个）
  Timing = Events.gameflow,        -- 流程类时机（BattleStart / TurnStart / … / BattleEnd）
  AttackTimings = Events.attack,   -- 出手与伤害链（BeforeAttack / … / AttackEnd）

  -- 战斗侧
  Elements = Elements,
  Request = Request,
  GameEvent = GameEvent,
  GameLogic = GameLogic,

  -- 工具
  Util = Util,
  Log = Log,
  Rng = Rng,
  root = ROOT,
}

-- 守卫命中时直接返回同一份表；正常路径也返回它，于是"被 dofile 几次"都是同一份
return SeerCore
