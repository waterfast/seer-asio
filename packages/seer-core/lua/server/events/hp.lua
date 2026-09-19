-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 流程事件：伤害 / 体力 ============================
--
-- 一次伤害（= 一次技能使用里的一击）的完整结算链：
--
--   GameEvent.Damage
--     1. 凑参数：威力 / 物攻物防或特攻特防 / 本系加成 / 属性克制 / 暴击 / 随机浮动
--     2. DamageParamCalculate → BeforeDamageCalculate 时机（参数还能改：改威力、改攻防、免疫）
--     3. 套伤害公式（base = floor((2*lv/5+2) * 威力 * 攻击 / 防御 / 50 + 2)，再乘那几个系数）
--     4. DamageCalculate → AfterDamageCalculate → FinalDamageCalculate 时机（减伤 / 加伤 / 定死伤害）
--     5. 被打断 / 被防止 / 伤害不足 1 点 → 到此为止（DamagePrevented 通知，不扣血）
--     6. GameEvent.ChangeHp —— **整个引擎唯一改血的地方**
--
--   GameEvent.ChangeHp   把体力夹进 [0, max_hp]；扣到 0 就标记 fainted 并通知 PetFainted
--   GameEvent.Recover    回血（拒绝已倒下的目标）；夹上限交给 ChangeHp
--
-- 事件树的形状（父事件是"谁引起的"）：
--
--   Turn ─ UseSkill ─ Damage ─ ChangeHp
--
-- 去掉的三国杀东西：铁索连环（属性伤害传导到其他"横置"角色）、护甲 / 护盾（shield）、
-- 体力流失（loseHp —— 赛尔号没有"失去体力"这种区别于伤害的扣血）、体力上限变化
-- （ChangeMaxHp：赛尔号的体力上限就是能力值里的 hp，战斗里不变）、濒死求桃 / 复活。
-- 精灵扣到 0 就是倒下了。
--
-- **系数全是占位**（待与实机核对）：本系 1.5、暴击 1.5、随机 0.85~1.0、
-- 暴击率每级 6.25%。这几条抄的是 GameLogic:calcParams / damageFormula（"直接循环"
-- 时代的参考实现）。真正的系数表属于规则数据，将来应该收进 core/ 或 spec，
-- 这里只是让流程先能跑通。

local EV = require "core.events"
-- 属性克制（纯函数模块，不是类，没挂全局，所以这里显式 require）
local Elements = require "core.elements"

-- GameEvent 基类（流程事件）。正常由 server/events/init.lua 先挂成全局；
-- 单独 require 本文件（测试脚本）时补一次，和 core/rng.lua 补 `class` 是一个意思。
GameEvent = rawget(_G, "GameEvent") or require "server.gameevent"

--- 攻击 / 伤害流程的时机：DamageParamCalculate / BeforeDamageCalculate / DamageCalculate /
--- AfterDamageCalculate / FinalDamageCalculate（其它几个在 gameflow.lua 的 Turn 里触发）
local A = EV.attack

-- ---------------------------- 小工具 ----------------------------
--
-- 和 gameflow.lua / useskill.lua 里那几份**逐字一样**（三个文件要各自独立、可单独
-- require，所以有意重复；为什么不开公共模块见 gameflow.lua 的"小工具"一节）。

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

-- ---------------------------- 伤害公式 ----------------------------

--- 凑伤害参数：威力 / 攻防 / 本系 / 克制 / 暴击 / 随机浮动。
--
-- 系数全是占位（见文件头）。技能属性为 nil 表示"随使用者本属性"（core/skill.lua 的约定），
-- 所以这里用 `skill:getElement() or source:getPrimaryElement()`。
---
-- 改参数的效果要挂在 DamageParamCalculate / BeforeDamageCalculate 时机上，
-- 别改这个函数（公式见 damageFormula）。
---@param logic GameLogic
---@param dmg DamageData
---@return DamageData dmg
local function calcParams(logic, dmg)
  local source, target, skill = dmg.source, dmg.target, dmg.skill

  local element = skill:getElement() or source:getPrimaryElement()
  dmg.element = element
  dmg.power = skill:getPower() or 0
  dmg.category = skill:getCategory()

  -- 物理用攻击 / 防御，特殊用特攻 / 特防
  local physical = skill:isPhysical()
  dmg.attack = source:getStat(physical and "attack" or "sp_attack")
  dmg.defense = target:getStat(physical and "defense" or "sp_defense")

  -- 本系加成（STAB）：技能属性 == 使用者的属性之一。1.5 是占位，待核对
  local stab = 1
  if element ~= nil then
    for _, pet_element in ipairs(source:getElements()) do
      if pet_element == element then
        stab = 1.5
        break
      end
    end
  end
  dmg.stab = stab

  -- 属性克制：技能那一个属性打受击方的（1~2 个）属性，
  -- 双属性合并规则（含 0 = 免疫、4 = 双倍克制）在 core/elements 里算好了
  dmg.multiplier = (element ~= nil) and Elements.getMultiplier(element, target:getElements()) or 1

  -- 暴击：crit_rate 每级 +6.25%（占位，待与实机核对）
  local crit_rate = skill:getCritRate() or 0
  dmg.crit = crit_rate > 0 and logic.rng:chance(6.25 * crit_rate) or false

  -- 随机浮动：0.85 ~ 1.0（占位，待与实机核对）。
  -- 注意走 logic.rng，不要碰 math.random（确定性要求，见 core/rng.lua）
  dmg.random = logic.rng:random(85, 100) / 100

  dmg.damage = 0
  dmg.prevented = false
  return dmg
end

--- 套伤害公式。
--
--   base   = floor((2 * 等级 / 5 + 2) * 威力 * 攻击 / 防御 / 50 + 2)
--   伤害   = base * 本系 * 克制 * 暴击(1.5) * 随机(0.85~1.0)
--
-- **系数待核对**（见文件头）；公式里的 50 和第二项 +2 也是照搬参考实现的占位。
---@param dmg DamageData @ 参数已经由 calcParams 凑好
---@return integer damage @ 取整后的伤害（0 表示打不动）
local function damageFormula(dmg)
  local level = dmg.source:getLevel() or 50
  local power = dmg.power or 0
  local attack = dmg.attack or 0
  local defense = dmg.defense or 0
  if defense <= 0 then defense = 1 end -- 数据脏的时候别除爆

  local base = math.floor((2 * level / 5 + 2) * power * attack / defense / 50 + 2)
  local damage = base
  damage = damage * (dmg.stab or 1)
  damage = damage * (dmg.multiplier or 1)
  if dmg.crit then damage = damage * 1.5 end
  damage = damage * (dmg.random or 1)

  -- 克制倍率为 0（免疫）时**不能**靠 max(1, ...) 硬打 1 点：那是"打不动"，
  -- 该由上面的 Damage 流程判成"伤害不足 1 点"而不扣血。
  if damage <= 0 then return 0 end
  return math.max(1, math.floor(damage))
end

-- ============================ 一次伤害 ============================

--- 一次伤害的流程事件。数据就是那一份 DamageData：
--- `GameEvent.Damage:create(logic, DamageData:new{ source=…, target=…, skill=… })`。
---@class GameEvent.Damage : GameEvent
---@field public data DamageData
local Damage = GameEvent:subclass("GameEvent.Damage")

function Damage:__tostring()
  local dmg = eventData(self) or {}
  return ("<Damage %d : %s <= %s #%d>"):format(
    dmg.damage or 0,
    tostring(dmg.target and dmg.target.name),
    tostring(dmg.source and dmg.source.name),
    self.id or -1)
end

function Damage:main()
  local logic, dmg = eventLogic(self)
  if type(dmg) ~= "table" then
    error("GameEvent.Damage 需要一份 DamageData 当数据", 2)
  end

  local source, target, skill = dmg.source, dmg.target, dmg.skill
  if source == nil or target == nil or skill == nil then
    error("GameEvent.Damage 的 DamageData 必须带 source / target / skill", 2)
  end

  -- 目标已经倒了：没有可打的血（UseSkill 会挑活着的目标，这里是兜底）
  if isFainted(logic, target) then return false end

  -- 1. 凑参数
  calcParams(logic, dmg)

  -- 2. 参数环节的时机（改威力 / 改攻防 / 免疫都在这里动手）
  logic:trigger(A.DamageParamCalculate, target, dmg)
  logic:trigger(A.BeforeDamageCalculate, target, dmg)

  -- 3. 套公式
  dmg.damage = damageFormula(dmg)

  -- 4. 结算链上剩下的时机（减伤 / 加伤 / 把伤害定死都在这里改 dmg.damage）
  local broken = logic:trigger(A.DamageCalculate, target, dmg)
  broken = logic:trigger(A.AfterDamageCalculate, target, dmg) or broken
  broken = logic:trigger(A.FinalDamageCalculate, target, dmg) or broken

  -- 5. 被打断、被防止、或者伤害不足 1 点：不扣血，到此为止
  if broken or dmg.prevented or (dmg.damage or 0) < 1 then
    local reason = "zero"
    if broken then
      reason = "broken"
    elseif dmg.prevented then
      reason = "prevented"
    end
    dmg.damage = math.max(0, dmg.damage or 0)
    notify(logic, {
      type = "DamagePrevented", source = source, target = target, skill = skill,
      damage = dmg.damage, reason = reason,
    })
    return false
  end

  -- 6. 唯一改血点：伤害就是"扣 dmg.damage 点血"（负数 = 扣）
  runEvent(GameEvent.ChangeHp, {
    logic = logic, target = target, num = -dmg.damage, reason = "damage",
    source = source, skill = skill, damage_data = dmg,
  }, logic)
  return true
end

-- ============================ 改血 ============================

--- 改血事件的数据。
---@class ChangeHpFlowData
---@field public logic GameLogic @ 战局
---@field public target Pet @ 改谁的体力
---@field public num integer @ 变化量：负数是扣血，正数是回血
---@field public reason string? @ damage / recover ……（只是给日志和时机的标签）
---@field public source GameObject? @ 变化的来源（谁打的 / 谁治的）
---@field public skill Skill? @ 引起变化的技能
---@field public damage_data DamageData? @ 引起变化的伤害数据（回血时没有）
---@field public before integer? @ 变化前的体力（main 里填）
---@field public after integer? @ 变化后的体力（main 里填）
---@field public actual integer? @ 实际变化量（被上限 / 0 夹过之后的值，main 里填）

--- 改变体力 —— **整个引擎唯一改血的地方**。
--
-- 别的任何地方都不许直接写 `pet.hp`（不然"谁扣的血"永远对不上账）：
-- 扣血、回血、以后可能有的固定伤害 / 吸血 …… 全部走这个事件。
---@class GameEvent.ChangeHp : GameEvent
---@field public data ChangeHpFlowData
local ChangeHp = GameEvent:subclass("GameEvent.ChangeHp")

function ChangeHp:__tostring()
  local data = eventData(self) or {}
  return ("<ChangeHp %d : %s <= %s #%d>"):format(
    data.num or 0, tostring(data.reason),
    tostring(data.target and data.target.name), self.id or -1)
end

function ChangeHp:main()
  local logic, data = eventLogic(self)
  data = data or {}

  local target = data.target
  local num = math.floor(tonumber(data.num) or 0)
  if target == nil then
    error("GameEvent.ChangeHp 需要 data.target（改谁的体力）", 2)
  end
  if num == 0 then return false end

  -- 夹进 [0, max_hp]。上限没备好的（max_hp 是 nil）就按当前体力当上限：
  -- 宁可这一局不动血，也别凭空造一个上限出来。
  local max_hp = target.max_hp or target.hp or 0
  local before = target.hp or 0
  local after = math.max(0, math.min(max_hp, before + num))
  target.hp = after
  local actual = after - before

  -- 扣到 0 就是倒下了（赛尔号没有濒死求桃那一套）
  local fainted_now = false
  if after <= 0 and before > 0 then
    target.fainted = true
    fainted_now = true
  end

  data.before, data.after, data.actual = before, after, actual

  notify(logic, {
    type = "HpChanged", target = target, before = before, after = after, num = actual,
    reason = data.reason, source = data.source, skill = data.skill,
  })
  if fainted_now then
    notify(logic, {
      type = "PetFainted", target = target, source = data.source, skill = data.skill,
      reason = data.reason,
    })
  end

  return actual ~= 0
end

-- ============================ 回血 ============================

--- 回血事件的数据。
---@class RecoverFlowData
---@field public logic GameLogic @ 战局
---@field public target Pet @ 给谁回血
---@field public num integer @ 回多少（> 0）
---@field public reason string? @ 默认 "recover"
---@field public source GameObject? @ 谁治的
---@field public skill Skill? @ 用哪个技能治的

--- 回复体力。拒绝给已倒下的精灵回血（免得变成"无限复活"——
--- 要让倒下的站起来得走复活流程，那个还没有），夹上限交给 ChangeHp。
---@class GameEvent.Recover : GameEvent
---@field public data RecoverFlowData
local Recover = GameEvent:subclass("GameEvent.Recover")

function Recover:__tostring()
  local data = eventData(self) or {}
  return ("<Recover %d : %s <= %s #%d>"):format(
    data.num or 0, tostring(data.reason),
    tostring(data.target and data.target.name), self.id or -1)
end

function Recover:main()
  local logic, data = eventLogic(self)
  data = data or {}

  local target = data.target
  local num = math.floor(tonumber(data.num) or 0)
  if target == nil then
    error("GameEvent.Recover 需要 data.target（给谁回血）", 2)
  end
  if num <= 0 then return false end

  if isFainted(logic, target) then
    notify(logic, { type = "RecoverRefused", target = target, num = num, reason = "fainted" })
    return false
  end

  local before = target.hp or 0
  runEvent(GameEvent.ChangeHp, {
    logic = logic, target = target, num = num,
    reason = data.reason or "recover", source = data.source, skill = data.skill,
  }, logic)

  -- 满血时回血是"处理了但没变化"，返回值按实际有没有涨血来给
  return (target.hp or 0) > before
end

-- ---------------------------- 挂到 GameEvent 上 ----------------------------

GameEvent.Damage = Damage
GameEvent.ChangeHp = ChangeHp
GameEvent.Recover = Recover

return {
  Damage = Damage,
  ChangeHp = ChangeHp,
  Recover = Recover,
}
