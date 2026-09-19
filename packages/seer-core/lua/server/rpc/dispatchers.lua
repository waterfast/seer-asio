-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 对面能调我们的方法 ============================
--
-- 这张表就是架构文档 §5.5 的落地：C++（测试时是另一个 Lua）通过 RPC 调这些方法，
-- 每个方法把战斗往前推一步。
--
-- 返回值约定**照抄 freekill 的 dispatchers.lua**：
--   第一个返回值是"成功了吗"，后面才是真正的结果。
--     成功：return true, result
--     失败：return false, "错误名"（可选）, "详细说明"
--   jsonrpc.lua 会把 `false` 翻成标准的 error 包回给对面。
-- 这条约定值得照抄——它把"业务失败"和"代码崩了"分得清清楚楚：
-- 前者是协议里的一条 error（对面能优雅处理），后者是 internal_error（对面该报警）。
--
-- 另外：这里的方法都是**同步**的（阻塞式 RPC，freekill 的 README 论证过够用）。
-- ⚠ 重构后 `GameLogic:run()` 是**一跑到底**的（直接循环，内部 `pickAction` 自动选招，
--   见 server/gamelogic.lua 的 TODO），原来那套"跑到要问人就停下"的
--   `logic:start()` / `logic:resume(reply)` 已随 `BattleLogic` 一起删除。所以现在：
--     * `runGame`            —— 一次把整局跑完，返回 finished 结果；
--     * `handlePlayerAction` —— 没有挂起点可以恢复，明确返回 not_implemented。
--   等 Request 层接进 GameLogic 之后，这两个方法再按原来的形状补回来。

local Dispatchers = {}

-- 本模块要用到的全局（由 entry.lua 载入 seer.lua 时创建）
local function seer() return Seer end

-- ============================ 基础 ============================

--- 不得不品的 ping：验证"进程起来了、来回通得了"
function Dispatchers.ping()
  return true, "PONG"
end

--- 收摊：告诉主循环可以退出了
function Dispatchers.bye()
  require("server.rpc.stdio").finished = true
  return true, "Goodbye"
end

--- 脚本版本（架构文档 §2.5 热更新用：版本旧了就让旧房间自然淘汰）
function Dispatchers.loadScript(params)
  return true, { version = Dispatchers.version }
end

Dispatchers.version = "0.1.0"

-- ============================ 对局 ============================

--- 开局：把对面传来的玩家数据造成精灵、接进战局。**不推进对局**。
---@param params table @ `{ roomId, seed, players = { { playerId, pets = { PetSpec... } } } }`
function Dispatchers.startGame(params)
  if type(params) ~= "table" then return false, "invalid_params", "startGame 需要参数" end

  local room_id = params.roomId
  if type(room_id) ~= "number" then return false, "invalid_params", "缺 roomId" end

  local ok, session_or_err = pcall(Session.create, room_id, params)
  if not ok then
    return false, "internal_error", tostring(session_or_err)
  end
  return true, Session.describe(session_or_err)
end

--- 开跑：把这一局跑到结束，把结果返回给对面。
---
-- 这就是"Lua 是大脑"的入口。**当前实现一跑到底**：`GameLogic:run()` 会一直循环到
-- 分出胜负才返回，不像原来那样在"需要玩家决定"的地方停下——因为 GameLogic
-- 还没接 Request 层（见文件头说明与 server/gamelogic.lua 的 TODO）。
function Dispatchers.runGame(params)
  local session, err = Session.get(params and params.roomId)
  if session == nil then return false, "invalid_params", err end

  session.logic:run()
  return true, Session.next_task(session, "finished")
end

--- 玩家操作。
--- 把玩家的选择翻译成挂起点期待的那个答复，让 Lua 继续跑，返回下一件要问的事。
---
--- TODO(交互式询问未接)：原来的实现是
---     local request = logic.pending_request   -- 现在挂着等谁答
---     ... 把 action 翻成 reply ...
---     local kind = logic:resume(reply)
--- 但 `pending_request` / `resume` 都是原 `BattleLogic` 的入口，重构后已经没有了
--- （新的 GameLogic 一跑到底，不会停在"等玩家操作"的地方）。所以这里明确报
--- not_implemented，而不是去调一堆不存在的函数。
---@param params table @ `{ roomId, playerId, action = { type = "UseSkill", skillName|skillId, targetId } }`
function Dispatchers.handlePlayerAction(params)
  local session, err = Session.get(params and params.roomId)
  if session == nil then return false, "invalid_params", err end

  return false, "not_implemented",
    "GameLogic 还没接 Request 层：没有挂起点可以恢复玩家操作（见 server/gamelogic.lua 的 TODO）"
end

--- 玩家进出房（架构文档 §5.5）。目前只是占位：真正的进房/掉线在房间层。
function Dispatchers.onPlayerJoin(params)
  return true, { ok = true }
end

function Dispatchers.onPlayerLeave(params)
  return true, { ok = true }
end

--- 投降：直接结算（不走"问人"那条路，因为投降本身就是一个决定）
function Dispatchers.surrender(params)
  local session, err = Session.get(params and params.roomId)
  if session == nil then return false, "invalid_params", err end

  local logic = session.logic
  -- playerId -> 阵营：会话里存的是 **0 基**阵营（`side - 1`，见 Session.create），
  -- 而 GameLogic 的 sides 是 **1 基**（sides[1] / sides[2]），所以 +1。
  local p = session.players[params.playerId]
  if p == nil then
    return false, "invalid_params", ("不认识的 playerId %s"):format(tostring(params.playerId))
  end
  local loser_side = p.side + 1
  local winner = (loser_side == 1) and 2 or 1
  -- 原来是 `logic:gameOver(...)`（BattleLogic 的入口）；新的 GameLogic 叫 finishGame
  logic:finishGame(winner, "surrender")
  return true, Session.next_task(session, "finished")
end

return Dispatchers
