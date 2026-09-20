-- SPDX-License-Identifier: GPL-3.0-or-later
-- BattleRoom 保存一局共享的数据，GameLogic 负责规则和时机调度。
-- 参考新月杀 ServerRoomBase 的局内 tag、logic 引用与通知入口：
-- https://github.com/Qsgs-Fans/freekill-core/blob/master/lua/server/roombase.lua
-- 本类不维护全局效果索引，只保留可挂载效果的对象引用。

local GameObject = require "core.gameobject"
local BuffController = require "core.buff.controller"

--- 一局战斗的共享上下文；每局新建，结束后随 Session 一起释放。
--- 效果保存在所属对象上，tags、通知队列和额外效果来源只属于当前房间。
--- 房间本身也是效果载体，可直接调用继承的 addEffect/removeEffect。
---@class BattleRoom: GameObject
---@field public units Unit[] @ 对战方列表，与逻辑层共享对象
---@field public pets Pet[] @ 全部参战精灵，顺序用于分配协议座位
---@field public buff_controller BuffController @ 本局独立的 Buff 生命周期管理器
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
  self.buff_controller = BuffController:new(self)
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

-- ---------------------------- 能力等级写入入口 ----------------------------

--- 检查请求，避免拼错字段或非整数等级产生无声的状态污染。
---@param target Pet
---@param changes table<string, integer>
local function validateStageChanges(target, changes)
  local allowed = {}
  for _, field in ipairs(target.class.STAT_STAGE_FIELDS) do allowed[field] = true end
  for field, delta in pairs(changes) do
    assert(allowed[field], "未知能力等级: " .. tostring(field))
    assert(math.type(delta) == "integer", "能力等级变化必须是整数")
  end
end

--- 执行一次等级操作。先发通用/专用前置时机，再一次写入全部能力，最后发后置时机。
--- 清除只将指定符号的等级推向 0，不会把消强算作普通弱化、把解弱算作强化。
--- 前置效果可修改 changes、删除单项或设置 prevented；所有实际写入统一限于 [-6,6]。
--- 前置时机允许嵌套操作，所以提交时重新读当前等级，避免覆盖嵌套操作的结果。
---@param data StatStageChangeData
---@return StatStageChangeData @ success/actual 表示实际结果；被取消和无变化均不发后置时机
function BattleRoom:_applyStatStageChange(data)
  local logic = assert(self.logic, "能力等级变化需要已绑定 GameLogic 的 BattleRoom")
  local timing = require("core.events").stat_stage
  local target, operation = data.target, data.operation
  assert(target and type(target.getStatStages) == "function", "能力等级目标必须是 Pet")
  validateStageChanges(target, data.changes)
  local beforeTiming, afterTiming
  if operation == "clear_positive" then
    beforeTiming, afterTiming = timing.BeforePositiveStatStagesClear, timing.AfterPositiveStatStagesClear
  elseif operation == "clear_negative" then
    beforeTiming, afterTiming = timing.BeforeNegativeStatStagesClear, timing.AfterNegativeStatStagesClear
  else
    assert(operation == "change", "当前只实现等级增减、消强、解弱")
  end
  data.before = target:getStatStages()
  data.after = target:getStatStages()
  if logic:trigger(timing.BeforeStatStageChange, target, data) or data.prevented then
    data.prevented = true
    return data
  end
  if beforeTiming and (logic:trigger(beforeTiming, target, data) or data.prevented) then
    data.prevented = true
    return data
  end
  validateStageChanges(target, data.changes)
  data.before = target:getStatStages()
  data.after = target:getStatStages()
  for _, field in ipairs(target.class.STAT_STAGE_FIELDS) do
    local before = data.before[field]
    local delta = data.changes[field] or 0
    if operation == "clear_positive" then
      delta = before > 0 and math.max(-before, math.min(0, delta)) or 0
    elseif operation == "clear_negative" then
      delta = before < 0 and math.min(-before, math.max(0, delta)) or 0
    end
    local after = math.max(target.class.STAT_STAGE_MIN, math.min(target.class.STAT_STAGE_MAX, before + delta))
    data.after[field] = after
    if after ~= before then
      data.actual[field] = after - before
      data.success = true
    end
  end
  -- 全部字段准备完毕才提交，后置效果看到的是完整的本次结果。
  for field, delta in pairs(data.actual) do target.stat_stages[field] = data.before[field] + delta end
  if data.success then
    logic:notify{ type = "StatStagesChanged", target = target, source = data.source,
      operation = operation, changes = data.actual, reason = data.reason }
    logic:trigger(timing.AfterStatStageChange, target, data)
    if afterTiming then logic:trigger(afterTiming, target, data) end
  end
  return data
end

--- 按增量改变多项等级，如 { attack = 2, speed = 2 }；消强/解弱不要通过负/正增量模拟。
---@param target Pet
---@param changes table<string, integer>
---@param source GameObject?
---@param reason string?
---@return StatStageChangeData
function BattleRoom:changeStatStages(target, changes, source, reason)
  return self:_applyStatStageChange(StatStageChangeData:new{
    target = target, source = source, changes = changes, reason = reason,
  })
end

--- 构建清除请求。fields 省略表示全部六项，传数组可以只消除本次暴击对应的防御强化。
local function clearStages(room, target, source, reason, fields, positive)
  local changes = {}
  for _, field in ipairs(fields or target.class.STAT_STAGE_FIELDS) do
    local stage = target:getStatStage(field)
    changes[field] = ((positive and stage > 0) or (not positive and stage < 0)) and -stage or 0
  end
  return room:_applyStatStageChange(StatStageChangeData:new{
    target = target, source = source, reason = reason, changes = changes,
    operation = positive and "clear_positive" or "clear_negative",
  })
end

--- 消除能力提升：只处理正等级，保留所有负等级；不走普通弱化语义。
---@param target Pet
---@param source GameObject?
---@param reason string?
---@param fields string[]? @ 默认全部，可指定防御或特防等子集
---@return StatStageChangeData
function BattleRoom:clearPositiveStatStages(target, source, reason, fields)
  return clearStages(self, target, source, reason, fields, true)
end

--- 解除能力下降：只处理负等级，保留所有正等级；不走普通强化语义。
---@param target Pet
---@param source GameObject?
---@param reason string?
---@param fields string[]?
---@return StatStageChangeData
function BattleRoom:clearNegativeStatStages(target, source, reason, fields)
  return clearStages(self, target, source, reason, fields, false)
end

-- ---------------------------- HP / 伤害入口 ----------------------------

--- 固定/百分比伤害必须显式给 kind 与 damage；攻击伤害给 kind="attack"、source、skill。
--- 固定/百分比只区分规则类别，百分比取哪个上限、克制或吸取数额由具体效果确定。
---@param spec DamageData|table
---@param action table? @ 显式注入当前技能效果；一般嵌套伤害不传，避免递归套用
---@return DamageData
function BattleRoom:damage(spec, action)
  return assert(self.logic, "伤害需要 GameLogic"):damage(DamageData:new(spec._data or spec), action)
end

---@param spec RecoverData|table @ {target, num, source?, skill?, reason?, parent?}
---@param action table?
---@return RecoverData
function BattleRoom:recover(spec, action)
  return require("server.events.hp").recover(assert(self.logic), RecoverData:new(spec._data or spec), action)
end

--- 直接流失/增加体力。只发 HP 时机，不伪造伤害或回复；通常回血应使用 recover。
---@param spec HpChangeData|table @ {target, num, source?, reason?}
---@return HpChangeData
function BattleRoom:changeHp(spec)
  return require("server.events.hp").changeHp(assert(self.logic), HpChangeData:new(spec._data or spec))
end

-- ---------------------------- Buff 对外接口 ----------------------------
-- Room 是规则作者的统一入口；实例挂载、生命周期和控制标记均由本房间的管理器负责。

---@param target GameObject
---@return Buff[] @ 本局目标的活跃绑定快照
function BattleRoom:getBuffs(target)
  return self.buff_controller:getBuffs(target)
end

---@param target GameObject
---@param id string
---@return Buff?
function BattleRoom:getBuff(target, id)
  return self.buff_controller:getBuff(target, id)
end

--- 添加或刷新同 id 的绑定，事件与实例状态由 BuffController 统一管理。
---@param target GameObject
---@param spec BuffSpec
---@return Buff?
---@return BuffChangeData
function BattleRoom:addBuff(target, spec)
  return self.buff_controller:addBuff(target, spec)
end

---@param buff Buff
---@param reason string?
---@param source GameObject?
---@return boolean removed
function BattleRoom:removeBuff(buff, reason, source)
  return self.buff_controller:removeBuff(buff, reason, source)
end

---@param target GameObject
---@param category string? @ 默认 turn
---@param source GameObject?
---@return integer @ 实际驱散数
function BattleRoom:dispelBuffs(target, category, source)
  return self.buff_controller:dispelBuffs(target, category, source)
end

---@param round integer @ 当前回合结束后清理
function BattleRoom:expireBuffs(round)
  self.buff_controller:expireBuffs(round)
end

--- 清理本局所有绑定，包括已注销效果来源的拥有者。
function BattleRoom:clearBattleBuffs()
  self.buff_controller:clearBattleBuffs()
end

return BattleRoom
