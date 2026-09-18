-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 请求处理器（答复者一侧）============================
--
-- 对应 freekill-core 的 `lua/core/request_handler.lua`。
--
-- 它回答的问题是：**"有人被问了，谁去答？"**
--
-- 服务端只知道"我要问这么一件事"（`Request`，见 init.lua），
-- 至于这件事最后是被人用命令行点、被真人客户端点、被 AI 算出来的，
-- 服务端一概不管——它只跟一个 `RequestHandler` 说话。这样换界面不用改规则：
--
--   CliHandler      单机版：把选项打到终端，读一行输入（本文件的 cli.lua）
--   RpcHandler      接客户端：挂起，把请求包发给 C++/Unity，等它回话（rpc.lua）
--   AiHandler       跑 AI/自测：就地调一个函数拿答复，一步都不挂起
--   DefaultHandler  无头降级：没人的时候用"默认答复"（比如挑一个能打的技能）
--
-- 前两个是"要真的等人"，后两个是"当场就有答案"。所以接口分成两半：
--
--   send(request, pet)      把请求**发出去**（CLI 在这里就把问题打到终端上）
--   takeReply(request, pet) 非阻塞地问一句"答复到了吗"（nil = 还没有）
--   waitReply(request)      **挂起**等答复（只有 RpcHandler 会真的挂）
--
-- `Request:ask()` 的等待循环就是"发送 → 轮询 takeReply → 没有变化就 waitReply"。
-- 于是同一份游戏流程，换一个 handler 就从单机变联机，规则代码一行不改。

---@class RequestHandler: Object
---@field public logic BattleLogic @ 它服务的战局
---@field public replies table<Pet, any> @ 精灵 → 还没被取走的答复
---@field public pending_pet Pet? @ 当前挂起时问的是谁
RequestHandler = class("RequestHandler")

---@param opts? table @ `{ logic = BattleLogic }`
function RequestHandler:initialize(opts)
  opts = opts or {}
  self.logic = opts.logic
  self.replies = {}
  self.pending_pet = nil
  self.finished = false
end

function RequestHandler:__tostring()
  return ("<%s>"):format(self.class.name or "RequestHandler")
end

--- 把请求发出去（准备界面 / 发网络包 / 直接算答案）。
--- 就地作答的处理器（AI、CLI 的脚本输入）在这里就把答复放进 `self.replies`。
---@param request Request
---@param pet Pet
function RequestHandler:send(request, pet) end

--- 非阻塞地取这只精灵的答复。
---@return any @ nil = 还没答复（不是"取消"！取消是空串，见 Request.CANCEL）
function RequestHandler:takeReply(request, pet)
  return self.replies[pet]
end

--- 取走答复（取走之后不会重复处理）
---@return any
function RequestHandler:consumeReply(request, pet)
  local reply = self.replies[pet]
  self.replies[pet] = nil
  return reply
end

--- 挂起等外部回话。默认**不挂起**（立刻返回 nil = 还没答复）。
--- 只有 RpcHandler 会覆盖它，去 `coroutine.yield`。
---@return any @ 答复；nil = 这次唤醒没带答复
function RequestHandler:waitReply(request)
  return nil
end

--- 一次询问结束时的收尾（关掉界面/清标志）。
---@param request Request
function RequestHandler:finish(request)
  self.pending_pet = nil
end

--- 请求被取消了（有人投降/超时/流程中断时的通知）。
---@param request Request
function RequestHandler:cancel(request)
  for pet in pairs(self.replies) do self.replies[pet] = nil end
end

-- ============================ AI：就地作答 ============================

--- 用一段函数回答所有问题。
--- 这就是原来的 `logic.request_hook`：跑 AI、跑示例、跑自测都用它，一步都不挂起。
--- 函数签名保持和以前一样：`fun(room, request_json) -> reply`，
--- 所以已有的示例/AI 代码不用改。
---@class AiHandler: RequestHandler
---@field public fn fun(room: any, request: table): any
AiHandler = RequestHandler:subclass("AiHandler")

function AiHandler:initialize(opts)
  RequestHandler.initialize(self, opts)
  assert(type(opts.fn) == "function", "AiHandler 需要一个函数 fn(room, request)")
  self.fn = opts.fn
end

function AiHandler:send(request, pet)
  local payload = request:toJson(pet)
  Log.debug(("AI 作答：%s 的 %s"):format(pet.name, tostring(payload.kind)))
  self.replies[pet] = self.fn(self.logic and self.logic.room, payload)
end

-- ============================ 无头降级：默认答复 ============================

--- 没人可问时的处理器：
---   * `AskForAction` 之类：返回 nil，让 `Request:_finish` 用**默认答复**
---     （问的人会算好"一个能打的技能"，见 logic:askForAction）；
---   * `AskForChoice`：优先问房间适配器（`room:askToChoice`，测试里的假房间就在这），
---     没有就选第一个选项——决策固定，所以整局可复现（架构文档 §2.3）。
---@class DefaultHandler: RequestHandler
DefaultHandler = RequestHandler:subclass("DefaultHandler")

function DefaultHandler:send(request, pet)
  if request.command == "AskForChoice" and self.logic ~= nil
    and type(self.logic.room.askToChoice) == "function" then
    self.replies[pet] = self.logic.room:askToChoice(pet, request.data[pet])
    return
  end
  -- 其余情况交给默认答复：这里什么都不放，`Request:_finish` 会填
end

return {
  RequestHandler = RequestHandler,
  AiHandler = AiHandler,
  DefaultHandler = DefaultHandler,
}
