-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 对面的"手脚" ============================
--
-- `peer` 是 Lua 侧通往父进程（将来是 C++ 的 RoomThread，测试时是另一个 Lua）的**唯一出口**。
--
-- ---------------------------- 为什么方向是双向的 ----------------------------
--
-- 架构文档 §5.3 那句话在这里落地："Lua 是大脑，C++ 是身体"。
-- 所以 RPC 不是"C++ 单向调用 Lua"，而是两边都能发起：
--
--   C++ → Lua（Request）：startGame / runGame / handlePlayerAction …
--        —— 收到就执行，执行完回一条 Response（见 dispatchers.lua）
--   Lua → C++（Request）：delay / notifyPlayers / gameOver …
--        —— Lua 自己发出去，**阻塞等答复**（因为 Lua 没有定时器、没有 socket）
--   Lua → C++（Notification）：log —— 单向，不等回复
--
-- `peer.call` 就是"发出去、等答复"那一半。它在等答复的过程中**照样会服务对面发来的请求**
-- （这正是 freekill README 里那段 callRpc 伪代码的做法）：否则一旦两边同时想说话，
-- 就会各自堵在 read 上，变成死锁。
--
-- ---------------------------- 传输无关 ----------------------------
--
-- 编解码（JSON / CBOR）由 jsonrpc.lua 决定，读写由 stdio.lua 决定。
-- 想把管道换成 socket、把 JSON 换成 CBOR，都只改那两个文件——本文件一个字都不用动。

Peer = {}

local json = require "json"
local cbor = require "cbor"
local jsonrpc = require "server.rpc.jsonrpc"
local stdio = require "server.rpc.stdio"

--- 编解码模式：环境变量 SEER_RPC_MODE=cbor 时走 CBOR（默认 JSON，人可读、好调试）
Peer.mode = os.getenv("SEER_RPC_MODE") == "cbor" and "cbor" or "json"

--- 我们要服务的**方法表**（对面调我们时查它）。运行时由 dispatchers.lua 填。
---@type table<string, function>
Peer.methods = {}

--- 对面发来的请求，在处理时用的兜底方法表（`call` 等待期间会用到）
Peer.request_handler = nil

-- ============================ 编解码 ============================

local function encode(packet)
  if Peer.mode == "cbor" then return cbor.encode(packet) end
  return json.encode(packet)
end

local function send_packet(packet)
  if Peer.mode == "cbor" then
    stdio.stdout:write(encode(packet))
    stdio.stdout:flush()
  else
    stdio.send(encode(packet))
  end
end

---@return table? packet
local function receive_packet()
  if Peer.mode == "cbor" then
    return cbor.decode_file(stdio.stdin)
  end
  local msg = stdio.receive()
  if msg == nil then return nil end
  local ok, packet = pcall(json.decode, msg)
  if not ok then
    -- 对面发的不是合法 JSON：按协议回一条 parse_error（但这说明对面有问题）
    send_packet(jsonrpc.response_error({}, "parse_error", msg))
    return {}
  end
  return packet
end

--- 读一条消息（主循环用；`call` 等待期间也用它）
---@return table? packet @ nil = 管道断了
function Peer.read()
  return receive_packet()
end

--- 写一条消息。
---
--- 序列化失败**不能把进程带走**：一次"返回值里塞了活对象"的疏忽不该让整局消失，
--- 所以这里包一层，失败就记一条 critical 并返回 false，调用方可以回一条 error。
---@param packet table
---@return boolean ok
function Peer.write(packet)
  local ok, err = pcall(send_packet, packet)
  if not ok then
    Log.critical(("RPC 消息序列化失败（返回值里是不是带了活对象/循环引用？）：%s")
      :format(tostring(err)))
    return false
  end
  return true
end

-- ============================ 工具 ============================

local function is_response_for(packet, id)
  return packet[jsonrpc.key_jsonrpc] == "2.0"
    and packet[jsonrpc.key_id] == id
    and type(packet[jsonrpc.key_method]) ~= "string"
    and not packet[jsonrpc.key_error]
end

--- 服务一条对面发来的请求（把结果回过去）。
--- 返回 true 表示"这条消息被当作请求处理了"。
local function serve_request(packet)
  local methods = Peer.request_handler or Peer.methods
  local res = jsonrpc.server_response(methods, packet)
  if res ~= nil then
    send_packet(res)
    return true
  end
  -- 对面发来的是**通知**（有 method、没 id）：按协议不需要回复，
  -- 所以这也算"处理过了"——不然会被当成"不认识的消息"报假警告。
  if type(packet[jsonrpc.key_method]) == "string" and packet[jsonrpc.key_id] == nil then
    return true
  end
  return false
end

-- ============================ 出口 ============================

--- 发一条 Request 并**等答复**（等待期间照常服务对面的请求）。
---@param method string
---@param params? table|any[]
---@return any result @ 对面的 result（出错时是 nil）
function Peer.call(method, params)
  local req = jsonrpc.request(method, params)
  local id = req[jsonrpc.key_id]
  send_packet(req)

  while true do
    local packet = receive_packet()
    if packet == nil then
      -- 管道断了：说明父进程没了，没必要继续等
      Log.warning(("等在 %s 的答复时管道断了"):format(method))
      return nil
    end

    if is_response_for(packet, id) then
      return packet[jsonrpc.key_result]
    end

    if packet[jsonrpc.key_error] and packet[jsonrpc.key_id] == id then
      Log.warning(("RPC %s 出错：%s"):format(method,
        tostring(packet[jsonrpc.key_error][jsonrpc.key_error_message])))
      return nil
    end

    -- 不是给我的答复 → 那就是对面发来的请求，先把它办了（不然会互相堵死）
    if not serve_request(packet) then
      Log.warning("收到一条既不认识也不是答复的消息，已丢弃")
    end
  end
end

--- 发一条 Notification：单向，不等回复。
---@param method string
---@param params? table|any[]
function Peer.notify(method, params)
  send_packet(jsonrpc.notification(method, params))
end

-- ============================ 信号出口（架构文档 §5.4） ============================
--
-- 这几条就是"Lua 让 C++ 替它干的活"。定义在一处，规则代码只调这些函数，
-- 不用关心底下是管道还是 socket。

--- 把一批事件推给房间里的客户端（公开信息）
---@param room_id integer
---@param events table[]
function Peer.notifyPlayers(room_id, events)
  return Peer.call("notifyPlayers", { roomId = room_id, events = events })
end

--- 只推给某个玩家（私密信息：手牌、自己精灵的详细状态）
---@param room_id integer
---@param player_id integer
---@param event table
function Peer.notifyPlayer(room_id, player_id, event)
  return Peer.call("notifyPlayer", { roomId = room_id, playerId = player_id, event = event })
end

--- 请求一个定时器：C++ 等够 ms 之后再回来（架构文档 §5.3 第 4~5 步）。
--- **这是阻塞的**：Lua 自己不会"等"，所以只能让 C++ 等完再叫醒它。
---@param room_id integer
---@param ms integer
---@param reason? string
function Peer.delay(room_id, ms, reason)
  return Peer.call("delay", { roomId = room_id, ms = ms, reason = reason })
end

--- 一局结束：交给 C++ 去结算战绩、落盘（Lua 不碰数据库，架构文档 §7）
---@param room_id integer
---@param result table
function Peer.gameOver(room_id, result)
  return Peer.call("gameOver", { roomId = room_id, result = result })
end

--- Lua 的日志交给 C++ 统一记录（单向，不等回复，免得日志把战斗卡住）
---@param level string
---@param msg string
function Peer.log(level, msg)
  Peer.notify("log", { level = level, msg = msg })
end

--- 打印到 stderr 的兜底日志出口：接上 RPC 之后日志交给 C++
function Peer.installLogSink()
  Log.sink = function(level, msg)
    -- 同时走 stderr：RPC 还没跑起来、或者对面不处理日志时，至少本地看得到
    io.stderr:write(("[seer-core][%s] %s\n"):format(level, msg))
    if Peer.connected then
      Peer.log(level, msg)
    end
  end
end

return Peer
