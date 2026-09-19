-- SPDX-License-Identifier: GPL-3.0-or-later
-- BattleRoom 保存一局共享的数据，GameLogic 负责规则和时机调度。
-- 参考新月杀 ServerRoomBase 的局内 tag、logic 引用与通知入口：
-- https://github.com/Qsgs-Fans/freekill-core/blob/master/lua/server/roombase.lua
-- 本类不维护全局效果索引，只保留可挂载效果的对象引用。

local GameObject = require "core.gameobject"

--- 一局战斗的共享上下文；每局新建，结束后随 Session 一起释放。
--- 效果保存在所属对象上，tags、通知队列和额外效果来源只属于当前房间。
--- 房间本身也是效果载体，可直接调用继承的 addEffect/removeEffect。
---@class BattleRoom: GameObject
---@field public units Unit[] @ 对战方列表，与逻辑层共享对象
---@field public pets Pet[] @ 全部参战精灵，顺序用于分配协议座位
---@field public logic GameLogic? @ 当前局的规则执行器
---@field public tags table<string, any> @ 服务端局内临时信息，不自动同步客户端
---@field public events table[] @ 待 Session 发送的通知
---@field public seat_of table<Pet, integer> @ 全局唯一协议座位，与阵营内座位分离
---@field private _effect_sources GameObject[] @ 按注册顺序保存的效果载体
BattleRoom = GameObject:subclass("BattleRoom")

---@class BattleRoomSpec: GameObjectSpec
---@field public units Unit[]?
---@field public pets Pet[]?

--- 建立局内容器；参战对象的效果来源由 GameLogic 开局注册。
---@param spec BattleRoomSpec?
function BattleRoom:initialize(spec)
  spec = spec or {}
  GameObject.initialize(self, spec)
  self.units = spec.units or {}
  self.pets = spec.pets or {}
  self.logic = nil
  self.tags = {}
  self.events = {}
  self.seat_of = {}
  self._effect_sources = {}
  for seat, pet in ipairs(self.pets) do
    self.seat_of[pet] = seat
  end
end

--- 注册效果载体；按对象引用去重，不复制效果，也不按效果 id 建索引。
--- 即便当前没有效果，也保留对象：它之后挂载的效果在下次 trigger 可被收集。
--- 房间自身由 GameLogic 单独收集，不再加入此列表。
---@param object GameObject
---@return boolean added @ 已注册或 object 就是本房间时返回 false
function BattleRoom:registerEffectSource(object)
  assert(type(object) == "table" and type(object.getEffects) == "function",
    "BattleRoom:registerEffectSource 需要提供 getEffects 的游戏对象")
  if object == self then return false end
  for _, source in ipairs(self._effect_sources) do
    if source == object then return false end
  end
  table.insert(self._effect_sources, object)
  return true
end

--- 移除载体登记，保留对象自己的效果；已经构造的时机效果集不受影响。
--- 移除后若还要参与后续时机，需再次注册。
---@param object GameObject
---@return boolean removed
function BattleRoom:unregisterEffectSource(object)
  for i, source in ipairs(self._effect_sources) do
    if source == object then
      table.remove(self._effect_sources, i)
      return true
    end
  end
  return false
end

--- 返回有序载体快照；改返回数组不会破坏登记，但对象仍是原对象。
--- 调度器应在每次 trigger 读取各对象的 getEffects()，不要长期缓存效果。
---@return GameObject[]
function BattleRoom:getEffectSources()
  local sources = {}
  for i, source in ipairs(self._effect_sources) do sources[i] = source end
  return sources
end

--- 向指定对象挂载效果并确保载体已注册，可用于局内临时天气等对象。
--- 效果内容仍由对象保存；重复挂载不叠加，返回值沿用对象的 addEffect。
---@param object GameObject
---@param effect Effect
---@return boolean added
function BattleRoom:addObjectEffect(object, effect)
  assert(type(object) == "table" and type(object.getEffects) == "function"
    and type(object.addEffect) == "function",
    "BattleRoom:addObjectEffect 需要可挂载效果的游戏对象")
  local added = object:addEffect(effect)
  self:registerEffectSource(object)
  return added
end

--- 从对象卸载效果；不自动注销空载体，便于之后重新挂载。
---@param object GameObject
---@param effect Effect
---@return boolean removed
function BattleRoom:removeObjectEffect(object, effect)
  return object:removeEffect(effect)
end

--- 取得服务端局内信息；缺失返回 nil，false 会原样保留。
---@param name string
---@return any
function BattleRoom:getTag(name)
  return self.tags[name]
end

--- 保存当前局共享信息，表值按引用保存；传 nil 等同于删除。
--- 调用方负责命名和清理规则范围内的临时值，不依赖进程级全局变量。
---@param name string
---@param value any
function BattleRoom:setTag(name, value)
  self.tags[name] = value
end

--- 删除局内信息，不发送客户端通知。
---@param name string
function BattleRoom:removeTag(name)
  self.tags[name] = nil
end

--- 返回对战方原数组，阵营与行动规则由 GameLogic 管理。
---@return Unit[]
function BattleRoom:getUnits()
  return self.units
end

--- 返回全部精灵原数组；不等同于当前出战精灵。
---@return Pet[]
function BattleRoom:getPets()
  return self.pets
end

---@return GameLogic?
function BattleRoom:getLogic()
  return self.logic
end

--- 绑定或释放执行器引用；不启动游戏，也不重置局内状态。
---@param logic GameLogic?
function BattleRoom:setLogic(logic)
  self.logic = logic
end

--- 读取全局协议座位；空房间后续由 GameLogic 填入 pets 时按数组顺序补登记。
--- 对不属于本房间的对象，兼容其已有 seat 字段。
--- 不修改 pet.seat，避免覆盖 GameLogic 的阵营内座位。
---@param pet Pet?
---@return integer?
function BattleRoom:seatOf(pet)
  if pet == nil then return nil end
  if self.seat_of[pet] ~= nil then return self.seat_of[pet] end
  for seat, candidate in ipairs(self.pets) do
    if candidate == pet then
      self.seat_of[pet] = seat
      return seat
    end
  end
  return pet.seat
end

--- 查询当前仍可行动的出战精灵，由 GameLogic 判定存活与出战状态。
--- 尚未绑定执行器时沿用 Session 约定，返回全部精灵作为初始化信息。
---@return Pet[]
function BattleRoom:getAlivePets()
  if self.logic == nil then return self.pets end
  return self.logic:getActors()
end

--- 缓存一条通知；Session 负责序列化和实际发送，本方法不执行网络操作。
--- 事件按引用保存，入队后调用方不应再修改该表。
---@param event table
function BattleRoom:notifyPlayers(event)
  table.insert(self.events, event)
end

--- 取走当前通知队列并换成新队列，保持入队顺序且不会重复出队。
---@return table[]
function BattleRoom:drainEvents()
  local events = self.events
  self.events = {}
  return events
end

return BattleRoom
