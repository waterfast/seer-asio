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
-- 唯一"会停下来等"的是玩家操作——但它不是在这里等，而是 Lua 内部挂起
-- （见 logic:start()/resume 与 peer.call），所以这个方法本身也是立刻返回的。

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

--- 开跑：一直跑到"需要玩家决定"或者"打完"，把下一件事返回给对面。
---
--- 这就是"Lua 是大脑"的入口：对面调一次，Lua 会一直算到**非问人不可**才回来。
function Dispatchers.runGame(params)
  local session, err = Session.get(params and params.roomId)
  if session == nil then return false, "invalid_params", err end

  session.logic.interactive = true
  local kind = session.logic:start()
  return true, Session.next_task(session, kind)
end

--- 玩家操作（架构文档 §5.5）。
--- 把玩家的选择翻译成挂起点期待的那个答复，让 Lua 继续跑，返回下一件要问的事。
---@param params table @ `{ roomId, playerId, action = { type = "UseSkill", skillName|skillId, targetId } }`
function Dispatchers.handlePlayerAction(params)
  local session, err = Session.get(params and params.roomId)
  if session == nil then return false, "invalid_params", err end

  local logic = session.logic
  local request = logic.pending_request
  if request == nil then
    return false, "server_error", "当前没有在等玩家操作（先调 runGame）"
  end

  local action = params.action or {}
  local reply

  if request.kind == "AskForAction" then
    if action.type == "UseSkill" then
      local skill = (action.skillName and seer():getSkill(action.skillName))
        or (action.skillId and seer():getSkillById(action.skillId))
      if skill == nil then
        return false, "invalid_params", ("技能 %s 不存在"):format(
          tostring(action.skillName or action.skillId))
      end
      reply = { skill = skill.name, target = action.targetId }

    elseif action.type == "Pass" then
      reply = {}

    else
      -- TODO(项目 7)：换精灵、道具、逃跑。要现在 gameflow.lua 的
      -- Round:buildTurnOrder / Turn 里留出位置，才能在这里翻译成答复。
      return false, "invalid_params", ("还不支持的操作类型 %q"):format(tostring(action.type))
    end

  elseif request.kind == "AskForChoice" then
    reply = action.choice

  else
    return false, "server_error", ("还不认识这种询问 %q"):format(tostring(request.kind))
  end

  local kind = logic:resume(reply)
  return true, Session.next_task(session, kind)
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
  local loser = params.playerId
  local winner
  for _, pet in ipairs(session.pets) do
    if pet.side ~= nil and pet.side ~= loser then winner = pet.side end
  end
  logic:gameOver(winner, "surrender")
  return true, Session.next_task(session, "finished")
end

return Dispatchers
