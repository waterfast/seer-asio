-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 战斗 / 回合流程时机 ============================
--
-- 一局战斗的外层时间轴：
--
--   BattleStart ── TurnStart ── TurnReady ── DecidePriority
--        ──>（攻击流程，见 attack.lua）── TurnEnd ── AfterTurnEnd
--        ──>（下一回合，直到分出胜负）── BattleEnd
--
-- 和 freekill 的"轮 / 回合 / 阶段"不同：赛尔号没有判定/摸牌/出牌/弃牌那一套，
-- 一个大回合 = 双方各行动一次（先手那方的攻击结算夹在中间）。
-- 所以这里只有"战斗 / 回合"两层；攻击与伤害那 11 个时机单独放 attack.lua。
--
-- 本文件只写**定义**（数据类 + 时机类）。真正的调度（先制度排序、回合循环、
-- 胜负判定）属于流程事件（GameEvent）与 BattleLogic，后面再实现。

-- ---------------------------- 数据类 ----------------------------

--- 战斗开始的数据。暂无可携带的字段，先占一个类型位（类型标注与协议会用到）。
---@class BattleStartData: TriggerData
BattleStartData = TriggerData:subclass("BattleStartData")

--- 战斗结束的数据。
---@class BattleEndData: TriggerData
---@field public winner any @ 获胜方（Unit 或具体精灵，类型待对战局结构敲定后收紧）
---@field public reason string? @ 结束原因（一方全灭 / 投降 / 超时……）
BattleEndData = TriggerData:subclass("BattleEndData")

--- 回合数据（TurnStart / TurnReady / TurnEnd / AfterTurnEnd 共用）。
---@class TurnData: TriggerData
---@field public turn_number integer @ 第几个大回合，从 1 起
TurnData = TriggerData:subclass("TurnData")

--- 决定出手顺序的数据。赛尔号按"先制度 → 速度 → 座位"排，这里只装数据。
---@class DecidePriorityData: TriggerData
---@field public actions table[] @ 本回合双方各自选定的行动：`{ source, skill, target }`
---@field public order GameObject[] @ 排好的出手顺序（元素是行动者，可与 actions 一一对应）
DecidePriorityData = TriggerData:subclass("DecidePriorityData")

-- ---------------------------- 时机类 ----------------------------

--- 战斗开始。
---@class BattleStart: TriggerEvent
---@field data BattleStartData
local BattleStart = TriggerEvent:subclass("BattleStart")

--- 回合开始（双方选技能之前）。
---@class TurnStart: TriggerEvent
---@field data TurnData
local TurnStart = TriggerEvent:subclass("TurnStart")

--- 回合就绪（双方都选完了，即将进入出手阶段）。
---@class TurnReady: TriggerEvent
---@field data TurnData
local TurnReady = TriggerEvent:subclass("TurnReady")

--- 决定出手顺序。
---@class DecidePriority: TriggerEvent
---@field data DecidePriorityData
local DecidePriority = TriggerEvent:subclass("DecidePriority")

--- 回合结束（进入收尾前）。
---@class TurnEnd: TriggerEvent
---@field data TurnData
local TurnEnd = TriggerEvent:subclass("TurnEnd")

--- 回合结束后（持续效果/异常状态回合递减等收尾都在这里）。
---@class AfterTurnEnd: TriggerEvent
---@field data TurnData
local AfterTurnEnd = TriggerEvent:subclass("AfterTurnEnd")

--- 战斗结束。
---@class BattleEnd: TriggerEvent
---@field data BattleEndData
local BattleEnd = TriggerEvent:subclass("BattleEnd")

return {
  BattleStart = BattleStart,
  TurnStart = TurnStart,
  TurnReady = TurnReady,
  DecidePriority = DecidePriority,
  TurnEnd = TurnEnd,
  AfterTurnEnd = AfterTurnEnd,
  BattleEnd = BattleEnd,
}
