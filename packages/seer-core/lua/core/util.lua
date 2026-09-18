-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- seer-core 的工具函数集。
--
-- 这里只保留战斗核真正用得到的那部分，函数名和行为刻意与 freekill-core 的
-- `lua/core/util.lua` 对齐（同名同语义），这样两边源码可以对着读。
-- 上游那个文件有 800 多行，绝大部分是卡牌/装备/阶段相关的，我们不需要。

-- 本文件要求全局 `class` 已经就位（seer.lua 里 `class = require "middleclass"`）。
-- 单独 require 本文件时顺手补一下，免得报 "attempt to call a nil value"。
if not rawget(_G, "class") then
  class = require "middleclass"
end

Util = {}

Util.DummyFunc = function() end
Util.TrueFunc = function() return true end
Util.FalseFunc = function() return false end

--- 一个"读啥都没有、写啥都报错"的空表。
--- 用来把 `t or {}` 换掉，省掉一堆 nil 判断：`(tbl or Util.DummyTable).foo` 恒为 nil。
Util.DummyTable = setmetatable({}, {
  __newindex = function() error("Cannot assign to dummy table") end,
})

--- 数组转哈希集：{"a","b"} --> {a=true, b=true}
Util.array2hash = function(t)
  local ret = {}
  for _, e in ipairs(t) do
    ret[e] = true
  end
  return ret
end

--- 给一组常量生成"名字 --> 值"和"值 --> 名字"的双向表。
--- 用法：`local Color, ColorStr = Util.CreateEnum { Red = 1, Green = 2 }`
Util.CreateEnum = function(t, enum)
  local reverse = {}
  local enums = enum or {}
  for k, v in pairs(t) do
    enums[k] = v
    reverse[v] = k
  end
  return enums, reverse
end

Util.IdMapper = function(e) return e.id end

--- "安全调用"：出错不往外抛，只记一条 critical 日志并返回 nil。
--- 对应 freekill 的全局 `Pcall`（在它的 core/debug.lua 里）。
---
--- 为什么流程事件里到处用它：一个流程事件是**协程**，异常会直接掀掉整条协程栈
--- （结算做到一半、栈上的事件全悬空）。规则代码出错应该只让"这一步没做成"，
--- 而不是把整局打死——所以清场、退出这类"必须发生"的钩子都包一层。
---@param f? function
---@return ... @ 正常时是 f 的返回值；出错时是 nil
function Util.Pcall(f, ...)
  if type(f) ~= "function" then return nil end
  local function msgh(err)
    Log.critical(tostring(err) .. "\n" .. debug.traceback(nil, 2))
    return err
  end
  local ret = table.pack(xpcall(f, msgh, ...))
  if ret[1] then
    return table.unpack(ret, 2, ret.n)
  end
  return nil
end

--- 判断一个值是不是"可以被当成数据编解码"的对象（有 __tocbor 之类）。
Util.isCborObject = function(v)
  if type(v) ~= "table" then return false end
  local mt = getmetatable(v)
  return mt ~= nil and mt.__tocbor ~= nil
end

-- ============================ table 扩展 ============================

--- 正序遍历数组部分（ipairs 的语义），func(value, index)
function table.forEach(self, func)
  for i, v in ipairs(self) do
    func(v, i)
  end
end

--- 数组里是否全部满足 func（空数组返回 true）
function table.every(self, func)
  for _, v in ipairs(self) do
    if not func(v) then return false end
  end
  return true
end

--- 数组里是否至少有一个满足 func
function table.any(self, func)
  for _, v in ipairs(self) do
    if func(v) then return true end
  end
  return false
end

--- 返回第一个满足 func 的元素（找不到返回 nil）
function table.find(self, func)
  for _, v in ipairs(self) do
    if func(v) then return v end
  end
  return nil
end

--- 过滤出满足 func 的元素，返回新数组
function table.filter(self, func)
  local ret = {}
  for _, v in ipairs(self) do
    if func(v) then table.insert(ret, v) end
  end
  return ret
end

--- 把每个元素映射成 func(v) 后的新数组
function table.map(self, func)
  local ret = {}
  for i, v in ipairs(self) do
    ret[i] = func(v)
  end
  return ret
end

function table.reduce(self, init, func)
  local ret = init
  for _, v in ipairs(self) do
    ret = func(ret, v)
  end
  return ret
end

--- 线性查找元素本身（不是下标）
function table.contains(self, element)
  for _, v in ipairs(self) do
    if v == element then return true end
  end
  return false
end

--- 返回元素下标，找不到返回 nil
function table.indexOf(self, value, from)
  for i = from or 1, #self do
    if self[i] == value then return i end
  end
  return nil
end

--- 删掉数组里第一个等于 element 的元素
function table.removeOne(self, element)
  local idx = table.indexOf(self, element)
  if idx then
    table.remove(self, idx)
    return true
  end
  return false
end

--- 深拷贝一层（元素本身如果是表，仍然是同一个引用）
function table.simpleClone(self)
  local ret = {}
  for k, v in pairs(self) do
    ret[k] = v
  end
  return ret
end

--- 只要是表就深拷贝（会处理环引用）
function table.clone(self)
  local seen = {}
  local function clone(t)
    if type(t) ~= "table" then return t end
    if seen[t] then return seen[t] end
    local ret = {}
    seen[t] = ret
    for k, v in pairs(t) do
      ret[clone(k)] = clone(v)
    end
    return setmetatable(ret, getmetatable(t))
  end
  return clone(self)
end

--- 把数组里的元素逐个插入到目标数组（追加）
function table.insertTable(self, list)
  for _, v in ipairs(list) do
    table.insert(self, v)
  end
end

--- 不存在才插入（按元素值判重）
function table.insertIfNeed(self, element)
  if not table.contains(self, element) then
    table.insert(self, element)
    return true
  end
  return false
end

function table.insertTableIfNeed(self, list)
  for _, v in ipairs(list) do
    table.insertIfNeed(self, v)
  end
end

--- 把 source 里的键值覆盖进 self（浅层），返回 self
function table.assign(self, source)
  for k, v in pairs(source or {}) do
    self[k] = v
  end
  return self
end

--- 数组切片，下标从 1 开始，_end 含端点
function table.slice(self, begin, _end)
  local ret = {}
  for i = begin, _end do
    table.insert(ret, self[i])
  end
  return ret
end

--- 两个数组是否有交集
function table.hasIntersection(self, tbl)
  for _, v in ipairs(self) do
    if table.contains(tbl, v) then return true end
  end
  return false
end

--- 浅比较：键值集合相同即相等（不递归）
function table.isEqual(self, other)
  if type(other) ~= "table" then return false end
  for k, v in pairs(self) do
    if other[k] ~= v then return false end
  end
  for k in pairs(other) do
    if self[k] == nil then return false end
  end
  return true
end

--- 用给定的随机数发生器洗牌（原地）。传 rng 是为了确定性：洗牌也必须可复现。
---@param rng? Rng @ 省略则用 math.random（不推荐，会破坏确定性）
function table.shuffle(self, rng)
  local n = #self
  for i = n, 2, -1 do
    local j
    if rng then
      j = rng:random(i)
    else
      j = math.random(i)
    end
    self[i], self[j] = self[j], self[i]
  end
  return self
end

--- 随机取一个元素
function table.random(self, rng)
  if #self == 0 then return nil end
  local i = rng and rng:random(#self) or math.random(#self)
  return self[i]
end

-- ============================ string 扩展 ============================

--- 按分隔符切分，返回数组。分隔符按纯文本匹配（不是 Lua 模式串），
--- 所以 `"a.b".split(".")` 得到 {"a","b"} 而不是被 `.` 当成通配符。
--- 空串的切分结果为空表——这点和 freekill 一致。
function string:split(delimiter)
  if self == "" then return {} end
  local ret = {}
  local from = 1
  while true do
    local s, e = self:find(delimiter, from, true)
    if not s then
      table.insert(ret, self:sub(from))
      return ret
    end
    table.insert(ret, self:sub(from, s - 1))
    from = e + 1
  end
end

function string:startsWith(start)
  return self:sub(1, #start) == start
end

function string:endsWith(ending)
  return ending == "" or self:sub(-#ending) == ending
end

-- ============================ Stack ============================

--- 一个极简的栈。freekill 用它做"事件栈"（game_event_stack / cleaner_stack）。
--- p 是栈顶下标，t 是底层数组——core 的代码直接读这两个字段，所以保持一致。
---@class Stack
Util.Stack = class("Stack")

function Util.Stack:initialize()
  self.t = {}
  self.p = 0
end

function Util.Stack:push(e)
  self.p = self.p + 1
  self.t[self.p] = e
  return e
end

function Util.Stack:pop()
  if self.p == 0 then return nil end
  local ret = self.t[self.p]
  self.t[self.p] = nil
  self.p = self.p - 1
  return ret
end

--- 栈顶元素
function Util.Stack:top()
  return self.t[self.p]
end

function Util.Stack:isEmpty()
  return self.p == 0
end

--- 按**身份**把自己从栈里摘掉（不是"弹栈顶"）。
---
--- 为什么需要这个：流程事件的栈纪律比想象中松——清场事件（ClearEvent）在跑自己的
--- `clear()` 时可能又插进来一串新事件，那些事件结束时会往同一个栈上压新的清场事件。
--- 这时候如果还写 `stack:pop()`，弹掉的就是**别人**，而自己会永远留在栈上
--- （表现是"每轮都在 resume 一个已经死掉的协程"，原地打转）。
--- freekill 用的是位置式 pop（`game_event_stack:pop()`），它依赖严格的 LIFO；
--- 这里改成按身份摘，顺序怎么变都不会出错。
---@param item any
---@return boolean removed
function Util.Stack:remove(item)
  for i = self.p, 1, -1 do
    if self.t[i] == item then
      table.remove(self.t, i)
      self.p = self.p - 1
      return true
    end
  end
  return false
end

--- 从栈顶往下找第一个满足 func 的元素
function Util.Stack:find(func)
  for i = self.p, 1, -1 do
    if func(self.t[i]) then return self.t[i] end
  end
  return nil
end

--- 取一份从栈底到栈顶的快照
function Util.Stack:snapshot()
  return table.slice(self.t, 1, self.p)
end

return Util
