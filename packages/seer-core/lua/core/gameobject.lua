--战斗力最基础的类，精灵，道具...都采用obj类

---@class GameObject: Object
---@field public id integer
---@field public name string 对象名称，精灵类
local GameObject = class("GameObject")


function GameObject:initialize(room, target, data)
  self.room = room
  self.target = target
  self.data = data
  local logic = room.logic
  logic.current_trigger_event_id = logic.current_trigger_event_id + 1
  self.id = logic.current_trigger_event_id

  self.skill_data = {}
  self.finished_skills = {}
  self.invoked_times = {}
end






return