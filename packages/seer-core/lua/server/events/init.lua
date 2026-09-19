-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 流程事件（GameEvent）加载入口 ============================
--
-- 对应 freekill 的 `ltk/server/events/init.lua`：那边 require 了一大串事件文件
-- （misc / hp / death / movecard / usecard / skill / judge / gameflow / pindian），
-- 再把它们混进 Room 的包装类，让 Room 上长出一堆 `room:damage(...)` 之类的方法。
--
-- 赛尔号只要"流程事件"这一套，四个文件：
--
--   hp.lua        GameEvent.Damage / ChangeHp / Recover
--                 伤害结算链 + **唯一改血点** + 回血
--   useskill.lua  GameEvent.UseSkill
--                 一次技能使用：命中判定 → 连击 → 每击伤害 → 扣 PP → 附加效果
--   gameflow.lua  GameEvent.Battle / Round / Turn
--                 一局战斗、一个大回合、一次出手
--
-- 加载顺序：hp（最低层）→ useskill → gameflow（最高层）。互相引用都在**运行期**按
-- `GameEvent.X` 找（比如 Damage 里要跑 GameEvent.ChangeHp、Turn 里要跑 GameEvent.UseSkill），
-- 所以顺序其实不敏感；这里按层次排，是为了让"谁在上谁在下"一眼可见。
--
-- 怎么跑（事件泵还没接上时的同步跑法，见 gameflow.lua 的 runEvent）：
--
--   local logic = GameLogic:new{ pets = { ... } }
--   GameEvent.Battle:create(logic, { logic = logic }):main()   -- 有事件泵时用 :exec()
--
-- 时机的数据类（BattleStartData / TurnData / DecidePriorityData / AttackData /
-- DamageData / BattleEndData）是 core/events 里的全局，不用在这里 require。
--
-- 注意：GameEvent 基类自己（exec / prepare / main / clear、事件栈、清场事件）在
-- server/gameevent.lua 里，不在本目录——那是"事件怎么被调度"，这里是"有哪些事件"。

-- GameEvent 基类在 server/gameevent.lua 里是 local 的（模块返回值，没挂全局），
-- 这里挂成全局：流程事件之间靠全局名字互相找，规则作者写 spec 时也不用 require。
-- （单独 require gameflow/hp/useskill 时它们各自会补这一下，两边等价。）
GameEvent = rawget(_G, "GameEvent") or require "server.gameevent"

local hp = require "server.events.hp"
local useskill = require "server.events.useskill"
local gameflow = require "server.events.gameflow"

-- ---------------------------- 挂到 GameEvent 上 ----------------------------
--
-- 每个文件 require 进来时已经挂过一次（`GameEvent.X = X`），这里作为"加载入口"
-- 再显式收口一遍：只要 require "server.events"，整套流程事件就一定齐了。
-- 幂等，重复挂不会出问题。

-- 伤害 / 体力
GameEvent.Damage = hp.Damage
GameEvent.ChangeHp = hp.ChangeHp
GameEvent.Recover = hp.Recover

-- 用技能
GameEvent.UseSkill = useskill.UseSkill

-- 一局 / 一大回合 / 一次出手
GameEvent.Battle = gameflow.Battle
GameEvent.Round = gameflow.Round
GameEvent.Turn = gameflow.Turn

-- 老的 init.lua 返回的是给 Room 用的包装类（mixin：`room:damage(...)` 那一套）。
-- 赛尔号这边的流程事件都是**类**：调用方自己 `GameEvent.X:create(logic, data)`，
-- 不再往 Room 上挂方法——战局是 GameLogic，不是 Room。
return {
  Damage = hp.Damage,
  ChangeHp = hp.ChangeHp,
  Recover = hp.Recover,
  UseSkill = useskill.UseSkill,
  Battle = gameflow.Battle,
  Round = gameflow.Round,
  Turn = gameflow.Turn,
}
