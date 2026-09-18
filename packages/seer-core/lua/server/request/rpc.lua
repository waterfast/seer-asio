-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ RPC 处理器：挂起等客户端 ============================
--
-- 接真人客户端（C++/Unity）时用的处理器。它干的事就一件：
-- **把请求挂起，把包发出去，等外面把答复 resume 回来**。
--
-- 这是架构文档 §5.3 那个来回的落点：
--
--   Lua（规则）  ──yield──▶  事件管理器  ──yield──▶  logic:start() 返回 "request"
--        ▲                                                     │
--        │                                              RPC 层把 {ask=...} 发给 C++
--        │                                                     │
--        └────── logic:resume(答复) ◀── handlePlayerAction ◀── 玩家点了技能
--
-- 它同时也是"换成 Unity 也能正常跑"的关键：**它和单机的 CliHandler 是同一套接口**
-- （`send` / `takeReply` / `waitReply`），区别只是"答案从哪里来"。

---@class RpcHandler: RequestHandler
RpcHandler = RequestHandler:subclass("RpcHandler")

--- 挂起等答复。
--- 会把"当前在等谁、等的是什么"写进 `logic.pending_request`，
--- RPC 层（session.lua）就是读它来给客户端组包的。
---@param request Request
---@return any @ 答复（由 logic:resume 送进来）
function RpcHandler:waitReply(request)
  local pet = request:pendingPet()
  if pet == nil then return nil end

  self.logic:requireYieldable()
  self.pending_pet = pet

  local payload = request:toJson(pet)
  self.logic.pending_request = payload

  -- 真正的挂起。`logic:resume(reply)` 的 reply 就是这里的返回值。
  local reply = coroutine.yield("__handleRequest", payload)

  self.logic.pending_request = nil

  -- 答复**记在这个处理器上**，等 `Request:ask` 的等待循环下一轮轮询取走。
  -- 超时/投降这类"唤醒理由"也照记：Request:checkReply 认得 TIMER_REASON。
  if reply ~= nil then self.replies[pet] = reply end
  return reply
end

return RpcHandler
