-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ RPC 进程入口 ============================
--
-- 对应 freekill-core 的 `lua/server/rpc/entry.lua`：父进程（将来是 C++ 的 RoomThread）
-- 用 `lua5.4 lua/server/rpc/entry.lua` 把战斗核拉起来，然后通过 stdin/stdout 上的
-- JSON-RPC 说话。
--
-- ```bash
-- # 手动起来看看（它会先打一条 hello，然后等消息）
-- cd packages/seer-core && lua5.4 lua/server/rpc/entry.lua
--
-- # 或者让 examples/rpc_demo.lua 拉起它、驱动一整局：
-- lua5.4 examples/rpc_demo.lua
-- ```
--
-- ---------------------------- 这一层现在到哪一步了 ----------------------------
--
-- ✅ 能跑的：JSON-RPC 2.0（也支持 `SEER_RPC_MODE=cbor` 切 CBOR）、stdio 分帧、
--    请求/响应/通知、阻塞式调用（等答复期间照常服务对面的请求，不会互相堵死）、
--    方法表（dispatchers）、信号出口（peer）、会话管理（session）。
-- ⬜ 没做的：**真正的 C++ 那一端**。我们现在用另一个 Lua 进程当"对面"
--    （见 examples/rpc_demo.lua），所以整条链路是真的，只是对面还不是 C++。
--
-- ---------------------------- 为什么日志走 stderr ----------------------------
--
-- stdout 是协议通道。往里写一行日志，对面就会解析出一个天书包。
-- 所以 `Log.sink` 被换成了"走 stderr + （连着对面时）发一条 log 通知"。

-- ---------------------------- 定位包根目录 ----------------------------
-- 用 debug.getinfo 反查本文件位置，这样从任何 cwd 启动都能找到 seer.lua
local HERE = debug.getinfo(1, "S").source:sub(2)
local ROOT = HERE:match("^(.*)/lua/server/rpc/[^/]+$") or "."

package.path = table.concat({
  ROOT .. "/lua/lib/?.lua",
  ROOT .. "/lua/?.lua",
  ROOT .. "/lua/?/init.lua",
  "./?.lua",
  "./?/init.lua",
  package.path,
}, ";")

-- ---------------------------- 载入核心 ----------------------------
-- 注意顺序：seer.lua 会把核心类挂成全局（Skill / Pet / BattleLogic / GameEvent…），
-- 之后 dispatchers.lua / session.lua 才能直接用它们。
local SeerCore = dofile(ROOT .. "/lua/seer.lua")

local jsonrpc = require "server.rpc.jsonrpc"
local stdio = require "server.rpc.stdio"
local peer = require "server.rpc.peer"
local Session = require "server.session"
local dispatchers = require "server.rpc.dispatchers"

-- 我们要服务的方法表（对面调我们时用这张）
peer.methods = dispatchers
peer.request_handler = dispatchers

--- 主循环：读一条、处理一条。
--- 对应 freekill 的 `mainLoop`（它也是"一直 io.read()，有消息就 server_response"）。
local function mainLoop()
  peer.connected = true
  peer.installLogSink()

  -- 握手：告诉对面"我起来了、我是什么版本、协议用的什么编码"。
  -- 对面在正式开始前就能确认子进程活着（架构文档 §5.5 的 loadScript/ping 同理）。
  peer.notify("hello", {
    core = "seer-core",
    version = dispatchers.version,
    mode = peer.mode,
    statFields = Pet.STAT_FIELDS,
  })

  while not stdio.finished do
    local packet = peer.read()
    if packet == nil then
      -- 管道断了：父进程没了，收摊
      io.stderr:write("[seer-core] 父进程关掉了管道，RPC 进程退出\n")
      break
    end

    local res = jsonrpc.server_response(dispatchers, packet)
    if res ~= nil then
      if not peer.write(res) then
        -- 回包序列化不了：至少把"我出错了"告诉对面，别让它一直等
        local id = packet and packet[jsonrpc.key_id]
        if id ~= nil then
          peer.write(jsonrpc.response_error(packet, "internal_error", "response not serializable"))
        end
      end
    end
  end

  return 0
end

--- 被 require/dofile 时拿到的东西：可以不起进程、直接在本进程里调方法（方便自测）
---@return table
local function module_api()
  return {
    SeerCore = SeerCore,
    peer = peer,
    dispatchers = dispatchers,
    Session = Session,
    mainLoop = mainLoop,
  }
end

-- 只有"被当成脚本执行"时才跑主循环（被 require/dofile 时只返回接口）
if arg and arg[0] and arg[0]:find("entry%.lua$") then
  os.exit(mainLoop())
end

return module_api()
