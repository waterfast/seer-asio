-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ stdio 传输 ============================
--
-- 抄自 freekill-core 的 `lua/server/rpc/stdio.lua`，改动：
--   1. 不再依赖全局 `fk._rpc_finished`，用一个模块内的开关 `stdio.finished`；
--   2. `send` 直接写 stdout 并 flush（freekill 用的是 print，缓冲行为在管道下不保险）；
--   3. 补了这份说明。
--
-- 为什么用 stdin/stdout：父进程（将来是 C++ 的 RoomThread）拉起这个 Lua 进程之后，
-- 两者之间只有管道可用。**关键约束：stdout 只能拿来传协议消息**，
-- 所以本项目的日志一律走 stderr（见 core/log.lua），
-- 否则一行日志就会让对面解析出一个天书包。
--
-- 分帧方式：JSON 模式是"一行一条消息"（NDJSON，`io.read()` 读一行）；
-- CBOR 模式由 `cbor.decode_file` 自己从流里读够一个完整对象。

-- 在用上socket之前，我们先用stdio来实现消息收发
-- 实现类似socket的receive和send两个方法即可

local io = io

local M = {}
M.finished = false

---@return string? @ 一行消息；nil = 对面关掉了管道（该收摊了）
local function receive()
  if M.finished then return nil end
  return io.read("l")
end

---@param data string
local function send(data)
  io.stdout:write(data, "\n")
  io.stdout:flush()
end


M.receive = receive
M.send = send
-- 提供给cbor的接口，它需要xxx:read()
M.stdin = {
  read = function(_, n)
    if M.finished then return "" end
    -- 没想到io.input():read(0)的情况下依然会等stdin有数据可读才返回
    -- 我们用的cbor并不希望这种情况发生
    if n == 0 then return "" end
    return io.read(n)
  end,
}
M.stdout = io.output()

return M
