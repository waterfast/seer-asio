-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 时机基类（Timing）============================
--
-- 名字说明：freekill 里这个类叫 `TriggerEvent`（触发事件）。本项目一开始也叫 `Timing`，
-- 但那会跟**流程事件** `GameEvent`（server/battle/game_event.lua）撞车：
-- 一个是"这一刻谁想插一脚"（同步、一次问完就走），
-- 一个是"这件事怎么一步步走完"（协程、能等客户端、能插子事件、能被打断）。
-- 两者是**上下层关系**而不是继承关系：流程事件执行到某一步时去触发时机。
-- 所以这里改名叫 `Timing`（时机），把"事件"这个词留给 GameEvent。
--
-- 本文件是 freekill-core `lua/core/trigger_event.lua`（TriggerEvent）的移植版：
-- 字段、方法语义、`exec()` 的调度算法都是照着它写的，只在命名上把
-- "player（角色）"换成了本项目的"pet（精灵）"，另外把几处依赖 freekill 全局
-- 的东西（Fk、room:askToChoice）换成了本项目对应的 Seer / logic。
-- 对照阅读时按这张表映射：
--
--   freekill TriggerEvent      -> seer Timing
--   freekill Player            -> seer Pet                 （参战单位）
--   freekill Fk.skills[name]   -> seer Seer.skills[name]
--   freekill room.askToChoice  -> seer logic:askToChoice   （问客户端，可无头降级）
--   logic.current_trigger_event_id -> logic.current_timing_id
--
-- ---------------------------- 这个类是干什么的 ----------------------------
--
-- 它是**一个"时机"**。战斗里的一切都是时机：回合开始、行动前、命中判定、
-- 伤害结算、伤害结算后、回合结束、精灵倒下……每个时机都对应 Timing 的一个子类
-- （见 server/battle/timing.lua），而每次"这个时机真的发生了"就 new 一个
-- Timing 实例，把它交给 `exec()`，由它去问：**谁想在这个时机做事？**
--
-- 谁会想做事的，就是**触发者**：TriggerSkill（技能/特性的时机钩子）和
-- Effect 挂上去的效果触发器。它们由 `BattleLogic:addTrigger()` 按时机类注册进
-- `logic.trigger_table[时机类]`，`exec()` 再从里面挑。
--
-- exec() 的调度规则（照抄 core，顺序本身就是规则的一部分）：
--
--   1) refresh 阶段（early）：轮询所有触发者的 `canRefresh/refresh`，
--      让它们清掉自己的临时状态（标记、计数器）。放在最前面是因为
--      "本时机开始"就该把上一时机的残留清掉。
--      标了 `late_refresh` 的留到第 4 步再 refresh。
--   2) 如果当前事件已经"被杀"（`cur_event.killed`），本次只做 refresh 不触发——
--      被杀的事件再正常触发只可能出现在清理阶段，会出乱子。
--   3) 触发阶段：按**优先级从高到低**逐个优先级处理；同一优先级内，
--      让每个精灵轮流挑一个要发动的触发者，直到这轮没人能发动为止。
--      * 优先级 <= 0 视为"锁定技/必发效果"，不询问玩家，直接取第一个能用的；
--        正优先级要问玩家（`askToChoice`）。
--      * 同一个触发者在"单个精灵 + 单个时机"内有发动次数上限
--        （`triggerableTimes`），超了就不再进候选。
--      * 玩家取消消耗（`cancel_cost`）时把该技能的已发动次数记成 -1，
--        表示"这个时机别再问它了"。
--   4) refresh 阶段（late）：补跑 late_refresh 的 refresh。
--
-- 返回 `broken`：true 表示"这个时机被打断了"，调用方（比如伤害结算）应当停止
-- 后续流程。这就是 `breakCheck` 的意义——伤害被防止了，就不该再走"受到伤害后"
-- 那一串时机。
--
-- ---------------------------- 和游戏事件的区别 ----------------------------
--
-- freekill 有**两层**事件：
--   * GameEvent（lua/server/gameevent.lua）：协程栈，是"流程"单位（放动画、
--     等客户端、能插入子事件、能被 kill）。它管的是"活的怎么往下走"。
--   * TriggerEvent（本文件）：时机，是"查询"单位。它管的是"这一刻谁想插一脚"。
-- 本项目当前只实现后者——回合状态机（第 7 阶段）做起来之后，如果发现需要
-- "结算到一半等客户端播完动画再继续"，再补 GameEvent 那一层。

---@class Timing: Object
---@field public id integer @ 本事件的编号（全局递增，回放/日志靠它对齐）
---@field public room any @ 战斗房间（要提供 .logic）
---@field public target any? @ 触发这个时机的"受动者"（被打的那只精灵等）
---@field public data TriggerData @ 时机数据，子类会把类型写具体
---@field public skill_data table<string, table<string, any>> @ 各触发者在本事件内的私有数据
---@field public finished_skills string[] @ 已发动完的触发者名（core 的保留字段，exec 当前不消费）
---@field public refresh_only boolean? @ 本次是否只跑 refresh
---@field public invoked_times table<string, number> @ 触发者在"单精灵单时机"内的已发动次数
---@field public broken boolean? @ 本时机是否被打断
---@field public break_reason string? @ 被谁打断的
Timing = class("Timing")

---@param room any @ 战斗房间
---@param target any? @ 受动者
---@param data TriggerData @ 时机数据
function Timing:initialize(room, target, data)
  self.room = room
  self.target = target
  self.data = data

  local logic = room.logic
  -- 顺手把 logic 也挂上：触发者几乎总要拿它（掷骰、结算伤害、发通知），
  -- 而 core 里得写 `room.logic` 绕一趟。这里是本项目加的一点便利。
  self.logic = logic
  logic.current_timing_id = (logic.current_timing_id or 0) + 1
  self.id = logic.current_timing_id

  self.skill_data = {}
  self.finished_skills = {}
  self.invoked_times = {}

  -- 数据对象自己会检查必填字段（TriggerData.checkSpec），这里只是容忍漏传：
  -- 少一个 data 应该让"这个时机少做点事"，而不是把整局打死
  if data ~= nil and data.checkSpec then
    data:checkSpec()
  end
end

function Timing:__tostring()
  return ("<Timing #%d %s>"):format(self.id, self.class.name)
end

-- ============================ 触发者私有数据 ============================

--- 往"某个触发者在本时机内的私有数据"里记一个键值。
--- 典型用途：技能先算好消耗（目标、代价）存这里，执行效果时再取出来。
---@param trig any @ 触发者（TriggerSkill / EffectTrigger）
---@param k string
---@param v any
function Timing:setSkillData(trig, k, v)
  local name = trig.name
  self.skill_data[name] = self.skill_data[name] or {}
  self.skill_data[name][k] = v
end

---@param trig any
---@param k string
---@return any
function Timing:getSkillData(trig, k)
  local name = trig.name
  return self.skill_data[name] and self.skill_data[name][k]
end

--- 记录消耗数据（选中的目标、付出的代价等）。
---@param trig any
---@param v table @ 建议是键值表：`tos`（精灵目标）、`value`（代价数值）
function Timing:setCostData(trig, v)
  self:setSkillData(trig, "cost_data", v)
end

---@param trig any
---@return table?
function Timing:getCostData(trig)
  return self:getSkillData(trig, "cost_data")
end

--- 该触发者是否在本时机取消了消耗（取消过就不要再问它了）
---@param trig any
---@return boolean
function Timing:isCancelCost(trig)
  return not not self:getSkillData(trig, "cancel_cost")
end

-- ============================ 打断判定 ============================

--- 本时机是否该停止询问后续触发者。
--- 基类恒为 false；子类按"这件事还有没有必要继续"重写，
--- 比如伤害事件在 `data.prevented` 或伤害 <= 0 时就该 break。
---@return boolean
function Timing:breakCheck()
  return false
end

--- 供触发者主动打断本时机（比如"我防止了这次伤害"）
---@param reason string? @ 谁打断的
function Timing:breakEvent(reason)
  self.broken = true
  self.break_reason = reason or self.break_reason
  return true
end

-- ============================ 调度核心 ============================

--- 单个优先级、单个精灵内最多发动多少次。
--- core 没有这个上限：只要 `triggerableTimes` 返回 math.huge，而触发者又永远
--- 满足 `triggerable`，那里就会死循环。对卡牌游戏可能无所谓（次数总有来源），
--- 但战斗核一旦死循环，整个房间的 Lua 进程就卡住了（架构文档 §2.4）。
--- 所以这里加一道闸，超了就记警告并放弃本精灵本优先级剩下的触发。
Timing.MAX_TRIGGERS_PER_PRIORITY = 100

--- 执行本时机：把所有注册在这个时机上的触发者按优先级跑一遍。
---@return boolean broken @ true = 时机被打断，调用方应停止后续流程
function Timing:exec()
  local room, logic = self.room, self.room.logic
  local triggers = logic.trigger_table[self.class] or Util.DummyTable
  if #triggers == 0 then return false end

  local event_klass = self.class
  local target = self.target
  local data = self.data

  -- 要问哪些精灵：logic 给的**数组快照**（core 用的是环形链，见 logic:getActors 的注释）。
  -- 快照是只读的，所以本时机里嵌套触发的其他时机各拿各的一份，互不干扰。
  local actors = logic:getActors()
  if #actors == 0 then
    -- 没有能响应的精灵：退化成"只问受动者一次"
    if self.target == nil then return false end
    actors = { self.target }
  end
  local actor = actors[1]   -- 触发阶段会逐只改它，refresh 阶段各自用 a

  -- ---------- 1) refresh 阶段（early）----------
  for _, a in ipairs(actors) do
    for _, trig in ipairs(triggers) do
      if trig:canRefresh(self, target, a, data) and not trig.late_refresh then
        trig:refresh(self, target, a, data)
      end
    end
  end

  -- ---------- 2) 被杀的事件只 refresh ----------
  local cur_event = logic:getCurrentEvent() or Util.DummyTable
  self.refresh_only = self.refresh_only or cur_event.killed

  local broken = false

  -- ---------- 3) 触发阶段 ----------
  if not self.refresh_only then
    local prio_tab = logic.trigger_priority_table[event_klass] or Util.DummyTable
    local prev_prio = math.huge

    for _, prio in ipairs(prio_tab) do
      if broken then break end
      -- 优先级表是降序的，遇到重复项跳过（core 原样保留的这个防御）
      if prio >= prev_prio then
        goto continue
      end

      for _, a in ipairs(actors) do
        actor = a
        -- 每个精灵重新计数：同一触发者可以先在这只精灵身上发一次、
        -- 再到另一只身上发一次（"单精灵单时机内的次数上限"就是这个意思）
        self.invoked_times = {}
        local triggerable_limit = {}

        local filter_func = function(trig)
          local invoked_times = self.invoked_times[trig.name] or 0
          if trig.priority ~= prio or invoked_times == -1 then
            -- 优先级对不上，或者已经被"取消消耗"标记成别再问了
            return false
          end

          local times = trig:triggerableTimes(self, target, actor, data)
          if invoked_times < times and trig:triggerable(self, target, actor, data) then
            if times > 1 then
              triggerable_limit[trig.name] = times
            end
            return true
          end
          return false
        end

        local trig_available = table.filter(triggers, filter_func)

        -- 先问"属于本精灵自己的"触发者，再问全局的（core 的 isPlayerSkill 语义）
        local actor_trig_finished = false
        local invocations = 0
        while #trig_available > 0 do
          invocations = invocations + 1
          if invocations > Timing.MAX_TRIGGERS_PER_PRIORITY then
            Log.warning(("时机 %s 在优先级 %s 上发动次数超过 %d，强制停止（检查触发者的次数限制）")
              :format(event_klass.name, tostring(prio), Timing.MAX_TRIGGERS_PER_PRIORITY))
            break
          end
          local actor_trigs = {}
          if not actor_trig_finished then
            actor_trigs = table.filter(trig_available, function(t) return t:isActorTrigger(actor, true) end)
            actor_trig_finished = #actor_trigs == 0
          else
            trig_available = table.filter(trig_available, function(t) return not t:isActorTrigger(actor, true) end)
            if #trig_available == 0 then break end
          end

          -- 同一个触发者可能还能发动多次，选项里带上剩余次数。
          -- 拼出来的形如 `#trigger_muti:::名字:剩余次数`，下面再拆回来。
          -- 注意格式必须**严格**和拆分逻辑对齐：多一个空格，拆出来的名字就会
          -- 带个前导空格，于是 `Seer.skills[名字]` 查不到、触发者静默消失。
          -- （core 的格式是 "#skill_muti_trigger:::" .. name .. ":" .. left）
          local formatChoiceName = function(t)
            local left = (triggerable_limit[t.name] or 1) - (self.invoked_times[t.name] or 0)
            if left > 1 then
              return "#trigger_muti:::" .. t.name .. ":" .. left
            end
            return t.name
          end

          local trig_name
          if prio <= 0 then
            -- 优先级 <= 0 = 锁定技/必发效果，不问玩家
            trig_name = trig_available[1].name
          else
            trig_name = logic:askToChoice(actor, {
              trigger_name = "trigger",
              prompt = "#choose-trigger",
              choices = table.map(#actor_trigs > 0 and actor_trigs or trig_available, formatChoiceName),
            })
          end

          -- 把 "#trigger_muti::: name:left" 拆回真正的名字
          if trig_name and trig_name:startsWith("#trigger_muti") then
            local splitted = trig_name:split(":")
            trig_name = splitted[#splitted - 1]
          elseif trig_name == nil then
            -- 问不出来（玩家超时/断线）：本优先级剩下的触发者都放弃，
            -- 但不能死循环，所以直接跳出这个 while
            break
          end

          local trig = logic:getTrigger(trig_name)
          if trig == nil then
            Log.warning(("时机 %s 中找不到触发者 %q，跳过"):format(event_klass.name, tostring(trig_name)))
            break
          end

          self.invoked_times[trig.name] = (self.invoked_times[trig.name] or 0) + 1
          broken = trig:trigger(self, target, actor, data) or self:breakCheck() or cur_event.killed
          if self:isCancelCost(trig) then
            self.invoked_times[trig.name] = -1
          end

          if broken then
            self.broken = true
            self.break_reason = trig.name
            break
          end

          trig_available = table.filter(triggers, filter_func)
        end

        if broken then break end
      end

      prev_prio = prio
      ::continue::
    end
  end

  -- ---------- 4) refresh 阶段（late）----------
  for _, a in ipairs(actors) do
    for _, trig in ipairs(triggers) do
      if trig:canRefresh(self, target, a, data) and trig.late_refresh then
        trig:refresh(self, target, a, data)
      end
    end
  end

  return broken
end

return Timing
