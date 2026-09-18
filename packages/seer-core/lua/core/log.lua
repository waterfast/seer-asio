-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- 极简日志。
--
-- 关键约定：**日志一律走 stderr，绝不碰 stdout。**
-- 因为按架构文档 §5.1，Lua 子进程的 stdin/stdout 是给 C++ 的 RPC 通道，
-- 往里写一行"日志"就会污染协议流，让 C++ 侧解析出一个天书包。freekill 的
-- `fk.qInfo` 最终也是交给底层去分流，我们这里直接用 stderr 更省事。
--
-- 日志最后应该由 C++ 统一记录（架构文档 §5.4 的 `log(level, msg)` 信号），
-- 所以 `Log.sink` 是可替换的：以后接上 RPC 就把它换成"发给 C++"。

Log = {}

Log.levels = {
  debug = 10,
  info = 20,
  warning = 30,
  critical = 40,
}

-- 低于这个级别的日志直接丢掉
Log.min_level = "info"

--- 日志出口。签名是 fun(level: string, msg: string)。
--- 以后接 RPC 时替换成把消息丢给 C++ 的函数即可，调用方一行都不用改。
Log.sink = function(level, msg)
  io.stderr:write(string.format("[seer-core][%s] %s\n", level, msg))
end

--- 由日志内容拼出最终字符串（对象会走 __tostring）
function Log.format(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do
    local v = select(i, ...)
    if type(v) == "table" then
      parts[i] = tostring(v)
    else
      parts[i] = tostring(v)
    end
  end
  return table.concat(parts, "")
end

function Log.emit(level, ...)
  if (Log.levels[level] or 0) < (Log.levels[Log.min_level] or 0) then return end
  Log.sink(level, Log.format(...))
end

function Log.debug(...) Log.emit("debug", ...) end
function Log.info(...) Log.emit("info", ...) end
function Log.warning(...) Log.emit("warning", ...) end
function Log.critical(...) Log.emit("critical", ...) end

--- 断言失败：战斗核遇到不可能发生的事（比如技能表里出现未注册的效果类型）
--- 时用这个，而不是直接 error，好让 C++ 侧能收到可读的错误再决定怎么处理。
function Log.assert(cond, msg)
  if not cond then
    Log.critical("ASSERT FAILED: ", msg or "(no message)")
    return false
  end
  return true
end

return Log
