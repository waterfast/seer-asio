-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- TriggerData：事件/时机的"数据对象"基类。
--
-- 这是从 freekill-core 的 `ltk/core/events/init.lua` 抄来的实现（逐行等价，只补了注释）。
-- 它的手法很值得学：**继承 + 代理**。
--
--   * 继承：`DamageData = TriggerData:subclass("DamageData")` 拿到 `class` 语义，
--     于是 `logic.trigger_table[self.class]` 能按"最具体的时机类"分表。
--   * 代理：实例不把 spec 的字段复制到自己身上，而是存进 `self._data`，
--     用 `__index` / `__newindex` 把读写转发过去。这样：
--       1. 规则作者写 `{ damage = 30 }` 这种字面量表就行，不用先建类；
--       2. 数据类型又带着类信息，能 `isInstanceOf(DamageData)` 判断；
--       3. 事件流转和回放时可以整体取出 `_data` 序列化（`toTable`）。
--
-- 为什么需要"数据对象"而不是裸 table：伤害结算是一串时机
-- （PreDamage → DetermineDamage → Damage → Damaged → DamageFinished），
-- 每个时机都可能被技能改数值（`data:changeDamage(-5)`、`data:preventDamage()`）。
-- 大家操作的是**同一个** data 对象，改动才能沿着结算链传下去。

---@class TriggerData: Object
---@field private _data table @ 真正存数据的表（规则作者写的 spec）
---@field public extra_data any @ 挂带数据（core 保留字段）
---@field public class TriggerData @ middleclass 给的类引用，trigger_table 用它分表
TriggerData = class("TriggerData")

--- 子类可以声明必填字段，`TriggerData:checkSpec()` 会据此报错。
--- 例：`DamageData.spec_required = { "from", "to", "damage" }`
TriggerData.spec_required = nil

---@param spec? table @ 规则作者写的字面量表
function TriggerData:initialize(spec)
  self._data = spec or {}
end

--- 读：类里没有的字段就去 _data 里找
function TriggerData:__index(k)
  if k == "_data" then return rawget(self, k) end
  local d = rawget(self, "_data")
  if d == nil then return nil end
  return d[k]
end

--- 写：类里没有的字段就写进 _data（所以 `data.damage = 0` 改的是数据本身）
function TriggerData:__newindex(k, v)
  if k == "_data" then return rawset(self, k, v) end
  local d = rawget(self, "_data")
  if d == nil then return rawset(self, k, v) end
  d[k] = v
end

function TriggerData:__tostring()
  return ("<%s>"):format(self.class.name)
end

--- 取出底层数据表（回放/存档/传给 C++ 时用）
---@return table
function TriggerData:toTable()
  return rawget(self, "_data") or {}
end

--- 检查 spec_required 里声明的字段是否都在。
--- 返回 false 时只报警告不抛错：战斗核在线上宁可"带着缺字段继续跑"，
--- 也不要因为一个数据笔误把整个房间的 Lua 进程打死（架构文档 §2.4 进程隔离）。
---@return boolean
function TriggerData:checkSpec()
  local required = self.class.spec_required
  if not required then return true end
  local d = self:toTable()
  local missing = {}
  for _, k in ipairs(required) do
    if d[k] == nil then table.insert(missing, k) end
  end
  if #missing == 0 then return true end
  Log.warning(("%s 缺少必填字段: %s（data=%s）"):format(
    self.class.name, table.concat(missing, ", "), tostring(self)))
  return false
end

--- 从 spec 建实例的语法糖，对齐 `GameEvent:create` 的写法。
--- 用法：`DamageData:create{ from = sha, to = bu, damage = 30 }`
---@param klass TriggerData @ 子类（实际类型）
---@param spec table
---@return TriggerData
function TriggerData.create(klass, spec)
  local obj = klass:new(spec)
  obj:checkSpec()
  return obj
end

return TriggerData
