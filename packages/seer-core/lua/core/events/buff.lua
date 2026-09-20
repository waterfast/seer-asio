-- SPDX-License-Identifier: GPL-3.0-or-later
---@class BuffChangeData: TriggerData
---@field target GameObject @ buff 的拥有者
---@field source GameObject? @ 本次添加/移除的发起者
---@field buff Buff @ 被添加/移除的实例
---@field previous Buff? @ 同 id 被刷新前的实例
---@field reason string @ add / refresh / dispel / expired / consumed / battle_end 等
---@field prevented boolean @ 仅 BeforeBuffAdd 和主动移除前可防止
---@field success boolean
BuffChangeData = TriggerData:subclass("BuffChangeData")
local timings = {}
for _, name in ipairs{ "BeforeBuffAdd", "AfterBuffAdd", "BeforeBuffRemove", "AfterBuffRemove" } do
  timings[name] = TriggerEvent:subclass(name)
end
return timings
