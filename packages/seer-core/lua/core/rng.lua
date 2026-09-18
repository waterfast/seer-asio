-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- 确定性随机数发生器（xoshiro256**）。
--
-- 为什么不用 `math.random`：架构文档 §2 的第 3 条"确定性"要求
-- "同一局、同一串事件序列 → 同一结果"，这是回放、断线重连、争议裁决的基础。
-- `math.random` 用的是全局状态，一局里只要有别人（比如另一个房间、甚至调试代码）
-- 调过一次，序列就变了，复盘必然对不上。
--
-- xoshiro256** 正是 Lua 5.4 的 `math.random` 内部用的算法。这里自己实现一份，
-- 好处是每个 BattleLogic 可以持有**自己独立的随机状态**（Rng:new(seed)），
-- 互不干扰，并且状态可以被记录进存档/回放。
--
-- 接口刻意与 math.random 一致：random() / random(m) / random(m, n)。

-- 单独 require 本文件时补一下全局 class（正常都是从 seer.lua 进来的）
if not rawget(_G, "class") then
  class = require "middleclass"
end

---@class Rng
---@field public s integer[] 4 个 64 位状态字
Rng = class("Rng")

-- 掩码。注意 Lua 5.4 的整数是 64 位有符号，0xFFFFFFFFFFFFFFFF 就是 -1，
-- 所以 `x & MASK` 其实是恒等操作；留着它只是为了让"只取 64 位"这个意图显式，
-- 真正的回绕靠的是 Lua 整数运算本身的模 2^64 语义。
local MASK = 0xFFFFFFFFFFFFFFFF

--- 64 位循环左移
local function rotl(x, k)
  return ((x << k) | (x >> (64 - k))) & MASK
end

--- 状态推进，返回下一个 64 位无符号整数
local function nextState(s)
  local result = rotl((s[2] * 5) & MASK, 7) * 9 & MASK
  local t = (s[2] << 17) & MASK

  s[3] = s[3] ~ s[1]
  s[4] = s[4] ~ s[2]
  s[2] = s[2] ~ s[3]
  s[1] = s[1] ~ s[4]
  s[3] = s[3] ~ t
  s[4] = rotl(s[4], 45)

  return result
end

--- 把任意整数（可以是负数、也可以是字符串哈希出来的数）打散成 4 个状态字。
--- 用的是 splitmix64，这是 xoshiro 作者推荐的种子初始化方式：
--- 直接拿种子当状态会出现"相邻种子序列高度相关"的问题。
local function seedFromNumber(seed)
  seed = seed & MASK
  local s = {}
  for i = 1, 4 do
    seed = (seed + 0x9E3779B97F4A7C15) & MASK
    local z = seed
    z = ((z ~ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
    z = ((z ~ (z >> 27)) * 0x94D049BB133111EB) & MASK
    s[i] = z ~ (z >> 31)
  end
  return s
end

--- 把字符串种子折成一个整数（FNV-1a 64 位），方便用 "room-3-game-1" 这种种子
local function hashString(str)
  local h = 0xCBF29CE484222325
  for i = 1, #str do
    h = h ~ str:byte(i)
    h = (h * 0x100000001B3) & MASK
  end
  return h
end

---@param seed? integer|string @ 省略则用 os.time()，但**战斗内必须显式给种子**
function Rng:initialize(seed)
  if seed == nil then
    seed = os.time()
  end
  if type(seed) == "string" then
    seed = hashString(seed)
  end
  self.s = seedFromNumber(seed)
end

--- 返回 [0, 1) 的浮点数
function Rng:randomFloat()
  -- 取高 53 位映射到 [0,1)，和标准库的精度一致
  return (nextState(self.s) >> 11) * (1.0 / 9007199254740992.0)
end

--- 三种调用形式，和 math.random 对齐：
---   rng:random()      --> [0, 1) 浮点
---   rng:random(m)     --> [1, m] 整数
---   rng:random(m, n)  --> [m, n] 整数
function Rng:random(m, n)
  if m == nil then
    return self:randomFloat()
  end
  if n == nil then
    m, n = 1, m
  end
  if m > n then
    error(("interval is empty (m=%d, n=%d)"):format(m, n), 2)
  end
  return m + math.floor(self:randomFloat() * (n - m + 1))
end

--- 概率判定：percent 是 0~100 的百分数。
--- 返回 true 表示"命中"。概率 <= 0 恒假、>= 100 恒真，且**不消耗随机数**——
--- 这点很重要：不然改一个概率值就会让整局后续的随机序列全部错位。
---@param percent number|nil
function Rng:chance(percent)
  if percent == nil then return true end
  if percent <= 0 then return false end
  if percent >= 100 then return true end
  return self:randomFloat() * 100 < percent
end

--- 随机取数组里的一个元素
function Rng:choice(t)
  if #t == 0 then return nil end
  return t[self:random(#t)]
end

--- 原地洗牌
function Rng:shuffle(t)
  return table.shuffle(t, self)
end

--- 导出状态：写进存档/回放，之后 setState 就能接着同一条序列往下走
function Rng:getState()
  return { self.s[1], self.s[2], self.s[3], self.s[4] }
end

function Rng:setState(state)
  assert(type(state) == "table" and #state == 4, "Rng:setState 需要 4 个状态字")
  self.s = { state[1], state[2], state[3], state[4] }
end

function Rng:__tostring()
  return ("<Rng %s>"):format(table.concat(table.map(self.s, function(v)
    return ("%016x"):format(v)
  end), " "))
end

return Rng
