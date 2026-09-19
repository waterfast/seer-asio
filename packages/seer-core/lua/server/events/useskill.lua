-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 流程事件：用一次技能 ============================
--
-- 赛尔号里"用技能"这一步就等于**整次攻击结算**（没有三国杀那种"出牌 → 响应 → 生效"
-- 的多段结构），顺序是：
--
--   GameEvent.UseSkill
--     1. 命中判定：`skill:getAccuracy()`，nil / <= 0 = 必中；打空 → SkillMissed 通知并整个跳过
--     2. 连击次数：`skill:getHits()`，整数或 `fun(skill, source, target, logic)`，上限 20
--     3. 每一击单独跑一次 GameEvent.Damage（伤害参数 → 伤害时机 → 扣血都在 hp.lua 那边）
--     4. 扣 PP（一次技能使用扣 1 点）
--     5. 附加效果（效果系统还没接，见下面的 TODO）
--
-- 每一步之间都不夹"时机"：时机的粒度在攻击流程那 11 个（BeforeAttack … AttackEnd），
-- 由 GameEvent.Turn 在调用本事件前后触发（见 gameflow.lua 的 Turn:main）。
--
-- 攻击数据（AttackData）是 Turn 和 UseSkill **共用同一份**：命中 / 连击数 / 总伤害都记
-- 在它上面，返回去之后 AttackReady / Attack / AfterAttack / AttackEnd 那几个时机读的
-- 就是这一份。
--
-- TODO（都标在调用点上）：打空要不要照样扣 PP、连击要不要按击扣 PP、附加效果系统。

-- GameEvent 基类（流程事件）。正常由 server/events/init.lua 先挂成全局；
-- 单独 require 本文件（测试脚本）时补一次，和 core/rng.lua 补 `class` 是一个意思。
GameEvent = rawget(_G, "GameEvent") or require "server.gameevent"

-- ---------------------------- 小工具 ----------------------------
--
-- 和 gameflow.lua / hp.lua 里那几份**逐字一样**（三个文件要各自独立、可单独 require，
-- 所以有意重复；为什么不开公共模块见 gameflow.lua 的"小工具"一节）。

--- 这个值像不像"战局"（GameLogic / BattleLogic）：能 `trigger(时机, ...)` 就算。
--- 给下面"从几种 create 形状里认出哪个参数是战局"用。
---@param v any
---@return boolean
local function isLogic(v)
  return type(v) == "table" and type(v.trigger) == "function"
end

--- 取流程事件的数据表（顺便认出战局）。
--
-- 基类（server/gameevent.lua）的参数顺序正在来回改，所以这里对**四种形状**都兼容：
--   * `create(logic, data)` —— 当前基类 `initialize(event, room, ...)` 的写法：
--     `ev.room = logic`、`ev.logic = logic`、`ev.data = data`
--   * `create(data, logic)` —— README §5.7 写的写法（data 在前）：当前基类下
--     `ev.data` 会变成那个 logic（这里靠 isLogic 认出来丢掉），数据落在 `ev.room` 上
--   * 上面两种在**老 freekill 基类**（`initialize(event, ...)`）下都会变成
--     `ev.data = { a, b }`：这里拆开，并认出哪个是战局
--   * `create(data)` —— 数据被当成"战局容器"，落在 `ev.room` 上
-- 关键在：本目录的流程数据**都自带 `logic` 字段**，所以怎么传都能把战局找回来。
---@param ev GameEvent
---@return table? data @ 流程事件的数据
---@return GameLogic? logic_arg @ 顺带认出来的战局（没有就是 nil）
local function eventData(ev)
  local data = ev.data

  -- 成对形状 `{ a, b }`：谁是战局看谁像战局，另一个就是数据
  if type(data) == "table" and not isLogic(data) and getmetatable(data) == nil
    and rawget(data, "logic") == nil and rawget(data, 1) ~= nil then
    local a, b = data[1], data[2]
    if isLogic(a) then return b, a end
    return a, b
  end

  -- 正常形状：ev.data 就是数据（"空表"和"是战局"的都不算，见下面两条兜底）
  if type(data) == "table" and not isLogic(data) and next(data) ~= nil then
    return data, nil
  end

  -- 数据被当成"战局容器"塞进 ev.room 了（create 只传一个参数的那种写法）
  if type(ev.room) == "table" and not isLogic(ev.room) then return ev.room, nil end
  return data, nil
end

--- 从流程事件上取战局（GameLogic / BattleLogic），找不到就明确报错。
--
-- 依次找：成对表里那个像战局的 → ev.logic（基类会填）→ data.logic → ev.room 本身
-- → ev.room.logic → 全局 RoomInstance.logic（freekill 时代的老兜底）。
---@param ev GameEvent
---@return GameLogic logic @ 战局
---@return table? data @ 顺便把数据取出来（省一次 eventData）
local function eventLogic(ev)
  local data, logic_arg = eventData(ev)
  local logic
  if isLogic(logic_arg) then
    logic = logic_arg
  elseif isLogic(ev.logic) then
    logic = ev.logic
  elseif type(data) == "table" and isLogic(data.logic) then
    logic = data.logic
  elseif isLogic(ev.room) then
    logic = ev.room
  elseif type(ev.room) == "table" and isLogic(ev.room.logic) then
    logic = ev.room.logic
  else
    local room = rawget(_G, "RoomInstance")
    if room ~= nil and isLogic(room.logic) then logic = room.logic end
  end

  if logic == nil then
    error("流程事件找不到战局：create 的参数 / ev.logic / data.logic / ev.room 里都没有能 trigger 的对象", 3)
  end
  return logic, data
end

--- 打一条事件通知（有 logic:notify 就走协议出口，没有就退到日志）。
---@param logic GameLogic
---@param evt table
local function notify(logic, evt)
  if type(logic.notify) == "function" then
    return logic:notify(evt)
  end
  Log.info(("🎮 %s"):format(tostring(evt.type)))
end

--- 这只精灵倒下了没（战局自己的实现优先）。
---@param logic GameLogic
---@param pet Pet
---@return boolean
local function isFainted(logic, pet)
  if type(logic.isFainted) == "function" then return logic:isFainted(pet) end
  return pet.fainted == true or (pet.hp or 0) <= 0
end

--- 跑一个子流程事件。有事件泵（logic:pushEvent / resumeEvent）时走 exec()，
--- 没有泵时同步跑 prepare() / main()（详见 gameflow.lua 的 runEvent 注释）。
---@param tp GameEvent @ 事件类
---@param data table @ 事件数据
---@param logic GameLogic? @ 战局
---@return GameEvent ev
local function runEvent(tp, data, logic)
  -- 参数顺序按当前基类（initialize(event, room, ...)）：战局在前、数据在后。
  -- 反过来写（README §5.7 的 data 在前）也认，见上面的 eventData。
  local ev = tp:create(logic, data)
  if ev.exec ~= nil and logic ~= nil and type(logic.getCurrentEvent) == "function"
    and type(logic.pushEvent) == "function" and type(logic.resumeEvent) == "function" then
    ev:exec()
    return ev
  end
  if type(ev.prepare) == "function" and ev:prepare() then return ev end
  ev:main()
  return ev
end

--- 扣 PP。战局有 usePP 就用它的（PP 这本账只该有一个地方记），
--- 没有就直接改 `logic.pp[pet][技能名]`。
---@param logic GameLogic
---@param pet Pet
---@param skill Skill|string
---@param n integer @ 扣几点
local function consumePP(logic, pet, skill, n)
  n = n or 1
  if type(logic.usePP) == "function" then return logic:usePP(pet, skill, n) end
  local name = type(skill) == "string" and skill or skill.name
  if logic.pp and logic.pp[pet] then
    logic.pp[pet][name] = math.max(0, (logic.pp[pet][name] or 0) - n)
  end
end

-- ============================ 用一次技能 ============================

--- 用一次技能（一次技能使用的完整结算）。
---
--- 数据就是那一份 AttackData（不是另开一张表）：`GameEvent.UseSkill:create(logic, attack)`。
---@class GameEvent.UseSkill : GameEvent
---@field public data AttackData
local UseSkill = GameEvent:subclass("GameEvent.UseSkill")

function UseSkill:__tostring()
  local atk = eventData(self) or {}
  return ("<UseSkill %s by %s #%d>"):format(
    tostring(atk.skill and atk.skill.name),
    tostring(atk.source and atk.source.name),
    self.id or -1)
end

function UseSkill:main()
  local logic, atk = eventLogic(self)
  if type(atk) ~= "table" then
    error("GameEvent.UseSkill 需要一份 AttackData 当数据", 2)
  end

  local source, target, skill = atk.source, atk.target, atk.skill
  if source == nil or target == nil or skill == nil then
    error("GameEvent.UseSkill 的 AttackData 必须带 source / target / skill", 2)
  end
  atk.logic = atk.logic or logic

  -- 目标在出手前就已经倒下（Turn 里会改选目标，这里是兜底）：这一手连 PP 都不扣
  if isFainted(logic, target) then
    notify(logic, { type = "ActionSkipped", source = source, target = target, reason = "fainted_target" })
    return false
  end

  -- 1. 命中判定：nil / <= 0 = 必中（见 core/skill.lua 的 accuracy 字段）
  local accuracy = skill:getAccuracy()
  if accuracy ~= nil and accuracy > 0 and not logic.rng:chance(accuracy) then
    atk.missed = true
    notify(logic, { type = "SkillMissed", source = source, target = target, skill = skill })
    -- 打空：连击、伤害、附加效果一条都不走。
    -- TODO: 打空要不要照样扣 PP（实机行为待核对）。现在按"整个跳过"处理，
    --       和 GameLogic:doAttack 的旧实现一致。
    return false
  end

  -- 2. 连击次数：整数，或 `fun(skill, source, target, logic)`；上限 20 防死循环
  local hits = skill:getHits()
  local n = 1
  if type(hits) == "number" then
    n = hits
  elseif type(hits) == "function" then
    n = hits(skill, source, target, logic)
  end
  n = math.max(1, math.min(math.floor(tonumber(n) or 1), 20))
  atk.hits = n

  -- 3. 每一击单独结算一次伤害：减伤 / 护盾 / 免疫都是逐击生效的；
  --    中间把目标打倒了就不再补刀（剩下的击数作废）。
  for i = 1, n do
    if isFainted(logic, target) then break end

    local dmg = DamageData:new{
      source = source, target = target, skill = skill,
      index = i,                -- 第几击（日志 / 协议用；参数由 Damage 那边凑）
      logic = logic,
    }
    runEvent(GameEvent.Damage, dmg, logic)

    -- 把这一击的结果累加回整次技能的数据上（打了几点、有没有暴击）
    atk.damage_data = dmg
    atk.damage = (atk.damage or 0) + (dmg.damage or 0)
    if dmg.crit then atk.crit = true end
    -- 被防止 / 伤害不足 1 点时 Damage 自己会打 DamagePrevented，这里不重复报
  end

  -- 4. 扣 PP：一次技能使用扣 1 点。
  -- TODO: 连击是不是按击扣 PP（实机行为待核对）；PP 归零的技能由决策那步挑不出来。
  consumePP(logic, source, skill, 1)

  -- 5. 附加效果
  --
  -- 效果系统（core/effect + 效果时机）还没接上，这一步现在只做两件事：
  --   * 把"这个技能带了哪些效果"记进攻击数据（协议 / 复盘要看）；
  --   * 打一条 SkillEffect 通知占位。
  -- 附加效果要用的时机就是 AttackReady / Attack / AfterAttack：它们由 Turn 在
  -- UseSkill 返回之后统一触发（见 gameflow.lua 的 GameEvent.Turn:main），
  -- 效果挂上去就能生效——所以这里不需要自己再触发一遍。
  -- TODO: 效果系统接上后，在这里逐条结算 skill:getEffects()；
  --       打空 / 被免疫的那几击该怎么处理（现在是"打空直接跳过、被免疫照旧走"）也要一起定。
  atk.effects = skill:getEffects()
  notify(logic, {
    type = "SkillEffect", source = source, target = target, skill = skill, effects = atk.effects,
  })
  return true
end

-- ---------------------------- 挂到 GameEvent 上 ----------------------------

GameEvent.UseSkill = UseSkill

return {
  UseSkill = UseSkill,
}
