-- SPDX-License-Identifier: GPL-3.0-or-later
-- Buff 生命周期管理器：添加、同 id 刷新、主动移除、分类驱散、到期与整局清理。
-- 每个 BattleRoom 独立持有一个管理器；Effect 的收集/排序/执行仍交给 trigger / Handler。
local Buff = require "core.buff.buff"

---@class BuffController: Object
---@field room BattleRoom
---@field private _owners GameObject[] @ 挂载过本局 Buff 的对象，不保存 Effect 索引
---@field private _clearing_buffs boolean
local BuffController = class("BuffController")

---@param room BattleRoom
function BuffController:initialize(room)
  self.room = room
  self._owners = {}
  self._clearing_buffs = false
end

-- ---------------------------- Buff 绑定与生命周期 ----------------------------

--- 返回本局目标挂载的实例快照，不把效果搬到 logic 的索引中。
---@param target GameObject
---@return Buff[]
function BuffController:getBuffs(target)
  local result = {}
  for _, buff in ipairs(target.buff_instances or {}) do
    if buff.room == self.room and buff.active then result[#result + 1] = buff end
  end
  return result
end

---@param target GameObject
---@param id string
---@return Buff?
function BuffController:getBuff(target, id)
  for _, buff in ipairs(self:getBuffs(target)) do if buff.id == id then return buff end end
end

--- 同 id 刷新为新实例（状态重置），不同 id 共存。层数/次数由各定义在 state 中管理。
--- BeforeBuffAdd 可取消；刷新不会触发「被消除」回调，只发 reason=refresh 的添加结果。
---@param target GameObject
---@param spec BuffSpec
---@return Buff? @ 被阻止时 nil；第二返回值为事件结果
---@return BuffChangeData
function BuffController:addBuff(target, spec)
  local logic = assert(self.room.logic, "Buff 需要已绑定的 GameLogic")
  assert(type(target.buff_instances) == "table", "Buff 目标必须是 GameObject")
  local B = require("core.events").buff
  local buff = Buff:new(self.room, target, spec)
  local data = BuffChangeData:new{ target = target, source = spec.source, buff = buff,
    previous = self:getBuff(target, spec.id), reason = "add", prevented = false, success = false }
  if data.previous then data.reason = "refresh" end
  if self._clearing_buffs or logic:trigger(B.BeforeBuffAdd, target, data) or data.prevented then
    buff.active, data.prevented = false, true
    return nil, data
  end
  -- 前置时机可以嵌套添加同 id，因此提交前重新定位，确保只保留一个实例。
  local previous = self:getBuff(target, spec.id)
  data.previous = previous
  if previous then
    data.reason = "refresh"
    previous.active = false
    for i, mounted in ipairs(target.buff_instances) do
      if mounted == previous then table.remove(target.buff_instances, i); break end
    end
  end
  table.insert(target.buff_instances, buff)
  self:_trackOwner(target)
  self.room:registerEffectSource(target)
  data.success = true
  logic:notify{ type = "BuffAdded", target = target, buff = buff.id, name = buff.name, reason = data.reason, source = data.source }
  logic:trigger(B.AfterBuffAdd, target, data)
  return buff, data
end

--- 主动消耗/驱散可以被 BeforeBuffRemove 阻止；到期/战斗清理是生命周期操作，不发前置。
--- 后置时机始终携带被移除的实例与 reason，效果可区分驱散、消耗、到期。
---@param buff Buff
---@param reason string?
---@param source GameObject?
---@return boolean removed
function BuffController:removeBuff(buff, reason, source)
  reason = reason or "removed"
  if not buff or buff.room ~= self.room or not buff.active then return false end
  local lifecycle = reason == "expired" or reason == "battle_end"
  -- 主动移除防重入；生命周期清理必须能完成尚在前置回调里的移除，避免清理后残留。
  if buff.removing and not lifecycle then return false end
  if reason == "dispel" and not buff.dispellable then return false end
  local B = require("core.events").buff
  local data = BuffChangeData:new{ target = buff.owner, source = source, buff = buff,
    reason = reason, success = false, prevented = false }
  buff.removing = true -- 防止移除前置效果递归移除同一个实例。
  if not lifecycle then
    local broken = self.room.logic:trigger(B.BeforeBuffRemove, buff.owner, data)
    if broken or data.prevented then buff.removing = false; return false end
  end
  buff.removing = false
  if not buff.active then return false end
  for i, mounted in ipairs(buff.owner.buff_instances) do
    if mounted == buff then table.remove(buff.owner.buff_instances, i); break end
  end
  buff.active, data.success = false, true
  self.room.logic:notify{ type = "BuffRemoved", target = buff.owner, source = source, buff = buff.id, name = buff.name, reason = reason }
  self.room.logic:trigger(B.AfterBuffRemove, buff.owner, data)
  return true
end

--- 消除指定类别（默认回合类），不影响能力等级、不可驱散绑定或其它类别。
---@param target GameObject
---@param category string?
---@param source GameObject?
---@return integer @ 实际移除数，可用于「消除成功则……」
function BuffController:dispelBuffs(target, category, source)
  local count = 0
  for _, buff in ipairs(self:getBuffs(target)) do
    if buff.category == (category or "turn") and self:removeBuff(buff, "dispel", source) then
      count = count + 1
    end
  end
  return count
end

--- 生命周期使用挂载过 Buff 的对象快照，不依赖效果来源是否仍参与 trigger。
--- 只保存拥有者引用，Buff 和 Effect 仍存放在各自对象上；没有全局效果索引。
---@return Buff[]
function BuffController:_snapshot()
  local buffs = {}
  for _, owner in ipairs(self._owners) do
    for _, buff in ipairs(self:getBuffs(owner)) do buffs[#buffs + 1] = buff end
  end
  return buffs
end

--- 每个拥有者按首次挂载顺序登记一次，使到期回调顺序稳定。
---@param owner GameObject
function BuffController:_trackOwner(owner)
  for _, existing in ipairs(self._owners) do if existing == owner then return end end
  self._owners[#self._owners + 1] = owner
end

--- 在回合所有结束时机结算后调用，重复调用不会重复移除。
---@param round integer
function BuffController:expireBuffs(round)
  for _, buff in ipairs(self:_snapshot()) do
    if buff.expires_after_round and round >= buff.expires_after_round then self:removeBuff(buff, "expired") end
  end
end

--- 战斗结束清理，包括已退出效果分发的对象；清理回调不能重新挂载 Buff。
function BuffController:clearBattleBuffs()
  if self._clearing_buffs then return end
  self._clearing_buffs = true
  for _, buff in ipairs(self:_snapshot()) do self:removeBuff(buff, "battle_end") end
  self._owners = {}
  self._clearing_buffs = false
end

return BuffController
