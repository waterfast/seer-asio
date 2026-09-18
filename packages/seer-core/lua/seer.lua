-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ seer-core 载入入口 ============================
--
-- 对应 freekill-core 的 `lua/freekill.lua` + `lua/fk_ex.lua`。干三件事：
--
--   1. 备好 Lua 环境：把 `lua/lib`、`lua/` 加进 package.path，
--      装载类库（middleclass）和工具库（Util / Log / Rng）。
--   2. 建立全局目录：`Seer`（注册表），并把各个**基类**挂成全局
--      （`Skill` / `Timing` / `Effect` / `Pet` …）。
--   3. 按顺序加载：先基类，再具体时机（要继承 Timing），最后扩展包 spec。
--
-- ---------------------------- 为什么基类要挂全局 ----------------------------
--
-- 因为基类之间**互相引用**：Skill 归 Seer 管、Effect 会造出 TriggerSkill 的子类、
-- Timing 要按时机找触发者、Pet 又要能查技能表。如果在每个文件里互相 require，
-- 就会出现循环依赖（`skill.lua` require `effect.lua`，`effect.lua` 又 require
-- 回去），Lua 的 require 在这种情况下会拿到半成品表。
--
-- freekill 的办法是把核心类都挂成全局（见它的 `fk_ex.lua`）：文件里
-- **加载期**需要的东西用 local require 显式拿，**运行期**才需要的东西就用全局，
-- 于是循环自然断开。本项目照抄这个做法，也顺便让扩展包作者写 spec 时
-- 能直接用 `Skill.Physical`、`SeerTiming.Damage` 这些名字。
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
-- 但"真的执行"不等于"可以执行两次"：第二次执行会把 `Seer` / `SeerTiming` 这些
-- 全局表重置成新的空表，而 `require "server.battle.timing"` 之类的模块
-- 已经被缓存、不会重新跑一遍——于是新表里什么都没有，后加载的包就会在
-- `[SeerTiming.HpChanged] = ...` 这种地方拿到 nil 而报 "table index is nil"。
--
-- 所以这里自己加一道守卫：**一个 Lua 进程里只有一份核心**。
--
-- 那热更新怎么办（架构文档 §2.5）？答案是"换 Lua 脚本 = 换一个 Lua 子进程"，
-- 而不是在同一个进程里重载代码。反正核心进程的生命周期本来就跟着房间走。
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

-- 注册表。它对应 freekill 运行时那个全局 `Fk`。
Seer = require("core.registry"):new()
Seer.root = ROOT

-- 时机名字表。effect.lua 是"按名字找时机"的（core 不该反过来依赖 server），
-- 所以时机类登记时会同时挂到这个全局表上，见 Seer:registerTiming。
SeerTiming = {}

-- ---------------------------- 3. 基类 ----------------------------
--
-- 下面这些 require **会顺带把类挂成全局**——这是刻意的，也是抄 freekill 的做法：
-- 每个核心模块在文件里就把自己的类挂到全局（`Skill = class("Skill")`），
-- 于是"运行期互相引用"不需要 require，循环依赖自然断开。
-- 这里用 local 接一下返回值，一是能立刻拿到引用，二是让加载顺序在代码里看得见。

-- 加载顺序是有讲究的，不是随便排的：
--   trigger_data -> event      : Timing 的 data 必须是 TriggerData 的子类
--   skill        -> effect     : effect/init.lua 加载时要 TriggerSkill:subclass 造 EffectTrigger
--   effect       -> pet        : pet 挂印记时要查 Mark.defs
--   event/skill  -> server.battle.events : 具体时机要 Timing:subclass
local TriggerDataModule = require "core.trigger_data"
TriggerData = TriggerDataModule

local TimingModule = require "core.timing"
Timing = TimingModule

local SkillModule = require "core.skill"
Skill = SkillModule.Skill
TriggerSkill = SkillModule.TriggerSkill
SkillSkeleton = SkillModule.SkillSkeleton
SkillSet = SkillModule.SkillSet

-- effect/init.lua 内部会把 EffectTrigger 挂成全局（它是 TriggerSkill 的子类），
-- 并在文件末尾 require effect/kinds.lua —— 那里才是"内置效果类型"的注册点
local EffectModule = require "core.effect"
Effect = EffectModule

local PetModule = require "core.pet"
Pet = PetModule.Pet
PetSpecies = PetModule.PetSpecies

-- ---------------------------- 4. 战斗侧 ----------------------------

-- 时机表要先把事件类登记进 Seer，后面的包才能在 spec 里写 `triggers = { [SeerTiming.Damage] = ... }`
require "server.battle.timing"

-- 印记（含异常状态）：必须在时机表之后——内置的异常状态要挂
-- BeforeAction / RoundEnd / DetermineDamage 这些具体时机，是按名字查的。
-- mark/init.lua 会接着 require mark/status.lua（异常状态类）+ mark/buff.lua（增益印记类）。
Mark = require "core.mark"

Element = require "server.battle.element"
Damage = require "server.battle.damage"

-- 询问机制（freekill `lua/server/request.lua` 的移植）：`Request` 描述"问什么"，
-- 各个 Handler 决定"谁去答"（命令行 / AI / 真人客户端）。必须在 logic 之前加载：
-- logic 的 askToChoice / askForAction 就是靠它们实现的。
-- require 之后这几个类会挂成全局，这里接一下只是为了把加载顺序写在代码里。
Request = require "server.request"

BattleLogic = require "server.battle.logic"

-- 流程事件（GameEvent）：先基类+管理器，再具体事件——因为
--   * hp.lua / gameflow.lua 加载时就要 `GameEvent:subclass`；
--   * gameflow.lua 会给 BattleLogic 挂上 `run()`（一局的主循环），
--     所以必须在 BattleLogic 之后加载。
GameEvent = require "server.battle.game_event"
require "server.battle.hp"
require "server.battle.gameflow"

-- ---------------------------- 5. 扩展包 ----------------------------

--- 启动：加载所有扩展包并收尾。
--- `list` 省略时读 `lua/specs/init.lua` 里的清单。
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

-- ---------------------------- 6. 返回值 ----------------------------

--- 挂到全局 `SeerCore`，本文件开头的守卫靠它判断"这个进程已经载入过了"
SeerCore = {
  -- 注册表
  Seer = Seer,

  -- 基类
  TriggerData = TriggerData,
  Timing = Timing,
  Skill = Skill,
  TriggerSkill = TriggerSkill,
  SkillSkeleton = SkillSkeleton,
  SkillSet = SkillSet,
  Mark = Mark,
  MarkTrigger = MarkTrigger,
  -- 印记的两个类别子类与模块（`Mark.Status` / `Mark.Buff` 是同一份东西）
  StatusMark = StatusMark,
  WeakenStatus = WeakenStatus,
  ControlStatus = ControlStatus,
  BuffMark = BuffMark,
  Status = Mark.Status,
  Buff = Mark.Buff,
  Effect = Effect,
  EffectTrigger = EffectTrigger,
  Pet = Pet,
  PetSpecies = PetSpecies,

  -- 询问机制（对应 freekill 的 Request / RequestHandler）
  Request = Request,
  RequestHandler = RequestHandler,
  AiHandler = AiHandler,
  DefaultHandler = DefaultHandler,
  CliHandler = CliHandler,
  RpcHandler = RpcHandler,

  -- 战斗侧：两层事件
  SeerTiming = SeerTiming,
  GameEvent = GameEvent,
  -- 时机数据类（timing.lua 里定义的；规则作者也常直接写 `SeerTiming` 的全局）
  Data = {
    TurnData = TurnData, ActionData = ActionData, SkillUseData = SkillUseData,
    HitCheckData = HitCheckData, DamageData = DamageData,
    HpChangedData = HpChangedData, RecoverData = RecoverData,
    StatChangeData = StatChangeData, MarkData = MarkData,
    SwitchData = SwitchData, FaintData = FaintData,
    GameStartData = GameStartData, GameOverData = GameOverData,
  },
  Element = Element,
  Damage = Damage,
  BattleLogic = BattleLogic,

  -- 工具
  Util = Util,
  Log = Log,
  Rng = Rng,
  root = ROOT,
}

-- 守卫命中时直接返回同一份表；正常路径也返回它，于是"被 dofile 几次"都是同一份
return SeerCore
