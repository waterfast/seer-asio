#!/usr/bin/env lua5.4
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 战斗示例：雷伊 vs 盖亚 ============================
--
-- ```bash
-- cd packages/seer-core && lua5.4 examples/battle_demo.lua
-- ```
--
-- 这是**最小可跑的战斗示例**：不起服务端、不起客户端、不碰 C++，
-- 用 standard 包里的雷伊（电系）和盖亚（战斗系）打一整局，并把战报打出来。
--
-- 它同时也是这套核心的用法说明书：看这一个文件就知道
--   精灵怎么造 → 技能怎么配（含第五技能）→ 怎么让 AI 决定出招 → 怎么读事件流。
--
-- 想换成"两个进程 + RPC"的方式跑同一局，看 `examples/rpc_demo.lua`。

local HERE = debug.getinfo(1, "S").source:sub(2)
local ROOT = HERE:match("^(.*)/examples/[^/]+$") or "."
local S = dofile(ROOT .. "/lua/seer.lua")

-- 核心日志走 stderr；战报我们自己打，所以这里把核心日志调安静点
S.Log.min_level = "warning"

-- ============================ 一、造两只精灵 ============================

--- 用哪个技能槽 + 第五技能，都是"玩家配招"的结果（C++ 侧从 SQLite 里读出来传进来）。
---
--- 等级用 **100**：赛尔号实战就是练到 100 级打的。50 级时 HP 太小、而伤害公式里的
--- 等级项又降得没那么快，会出现"140 威力一招秒人"的假象（那不是公式错，是等级不对）。
local function make_lei()
  return S.Pet:new{
    species = "雷伊", level = 100, side = 0, seat = 1,
    -- 个体值/学习力/性格就是存档里的那几列
    ivs = { hp = 31, sp_attack = 31, speed = 31, sp_defense = 20 },
    evs = { hp = 60, sp_attack = 252, speed = 198 },
    nature = "胆小",              -- +速度 -攻击
    -- 真实技能表（见 lua/specs/standard/skills.lua）：
    --   电击光束（特殊 60，5% 麻痹）/ 惊雷切（物理 55，血少于一半时威力×2）
    --   万丈光芒（特殊 75，解弱）/ 雷祭（属性，100% 麻痹但命中只有 50%）
    skills = { "电击光束", "惊雷切", "万丈光芒", "雷祭" },
    fifth = "元气电光球",
  }
end

local function make_gaiya()
  return S.Pet:new{
    species = "盖亚", level = 100, side = 1, seat = 2,
    ivs = { hp = 31, attack = 31, speed = 31, defense = 25 },
    evs = { hp = 252, attack = 252, speed = 6 },
    nature = "固执",              -- +攻击 -特攻
    -- 真实技能表：
    --   气力（攻击+1）/ 渗透劲（特殊 20 + 附加 50 固定伤害）
    --   日月皆伤（物理 140，消强）/ 神经修复（回复最大体力的 1/3）
    skills = { "气力", "渗透劲", "日月皆伤", "神经修复" },
    fifth = "联盟的审判",
  }
end

local lei, gaiya = make_lei(), make_gaiya()

-- ============================ 二、一个很笨的 AI ============================
--
-- 它扮演"玩家"：每次战斗问"这回合用什么技能"时，由它作答。
-- 接客户端的时候，这个位置就是 C++（它去问真人玩家）。
--
-- 怎么被问到的：`logic:askForAction` 在没有 interactive 时会调 `request_hook`，
-- 把 `{ kind = "AskForAction", pet = 座位, skills = { 可用的技能名 },
--        unusable = { {name, reason, text} }, fifth = 第五技能名 }`
-- 交出来，然后拿它的返回值当答复。（`unusable` 是给客户端把技能摆成灰的用的；
-- `fifth` 只是"第五技能摆在哪个位置"的提示，不是可用性规则。）

--- 给技能打个分，分高的优先用。
--- 分数刻意排成"先把强化/回复用掉，再考虑输出"，这样一局里能跑出更多机制
--- （强化、第五技能、异常状态、连击……），而不是一上来就拼命打。
local function score_skill(skill, pet, foe)
  local hp_ratio = pet:getHpRatio()

  -- 第五技能：这是"收人头"用的（盖亚的联盟的审判 PP 只有 1），
  -- 所以压到对方血少时才拿出来——不然一局就两回合结束了，看不出别的机制。
  if pet:isFifthSkill(skill.name) then
    return (foe ~= nil and foe:getHpRatio() < 0.4) and 200 or 90
  end

  -- 看技能里带了什么效果，决定"现在该不该用它"
  for _, spec in ipairs(skill.effects or {}) do
    -- 回复 / 解除异常：血少了才值
    if spec.kind == "heal" or spec.kind == "cure" then
      if hp_ratio < 0.6 then return 150 end
    end

    -- 自我强化：还没强化过就用
    if spec.kind == "stat" and (spec.target == "self" or spec.target == nil) then
      for field, delta in pairs(spec.stages or {}) do
        if delta > 0 and pet:getStatStage(field) <= 0 then return 140 end
      end
    end

    -- 弱化对方
    if spec.kind == "stat" and spec.target ~= "self" then return 120 end

    -- 吸取：血少时更值
    if spec.kind == "drain" and hp_ratio < 0.7 then return 130 end

    -- 消强：对方身上有提升时最值得用（"消除对手能力提升状态"）
    if spec.kind == "clear_stages" and (spec.side or "up") == "up" and foe ~= nil then
      for _, field in ipairs(S.Pet.STAGE_FIELDS) do
        if foe:getStatStage(field) > 0 then return 130 end
      end
    end

    -- 施加异常状态：控制类/弱化类都值得试（概率太低就算了）
    if spec.kind == "mark" or spec.kind == "status" then
      local def = S.Mark.defs[spec.mark or spec.status]
      if def ~= nil and def.mark_type ~= S.Mark.TYPE.BUFF and (spec.probability or 100) >= 50 then
        return 125
      end
    end
  end

  -- 攻击技：威力越大越优先（所以这里分数上限大约 130，压不过上面那些）
  if skill:isDamaging() then return skill:getPower(pet, foe) end
  return 10
end

---@param room table
---@param request table
local function ai(room, request)
  local pets_by_seat = {}
  for _, p in ipairs(room.pets) do pets_by_seat[p.seat] = p end

  local pet = pets_by_seat[request.pet]
  local foe = nil
  for _, p in ipairs(room.pets) do
    if p.side ~= pet.side then foe = p end
  end

  local best, best_score = nil, -1
  for _, name in ipairs(request.skills) do
    local skill = S.Seer:getSkill(name)
    if skill then
      local sc = score_skill(skill, pet, foe)
      if sc > best_score then best, best_score = skill, sc end
    end
  end

  if best == nil then return {} end   -- 没得选 = 这回合不出手
  return { skill = best.name, target = foe and foe.seat or nil }
end

-- ============================ 三、跑一局 ============================

local room = {
  pets = { lei, gaiya },
  log = {},
}

function room:getAlivePets()
  local ret = {}
  for _, p in ipairs(self.pets) do
    if not p:isFainted() then table.insert(ret, p) end
  end
  return ret
end

--- 战斗核每做一件事都会推一条事件过来。这里把它打印成战报。
--- （接客户端时，这个函数就是"把事件转给 C++ 推给玩家"那一步。）
function room:notifyPlayers(evt)
  table.insert(self.log, evt)

  local function who(seat)
    for _, p in ipairs(self.pets) do
      if p.seat == seat then return p.name end
    end
    return "?"
  end

  if evt.type == "RoundStart" then
    print(("\n===== 第 %d 回合 ====="):format(evt.round))

  elseif evt.type == "UseSkill" then
    local tag = evt.fifth and "【第五技能】" or ""
    local hits = (evt.hits or 1) > 1 and (" × %d 连击"):format(evt.hits) or ""
    print(("  %s 使用了 %s%s%s"):format(who(evt.source), tag, evt.skill, hits))

  elseif evt.type == "SkillMissed" then
    print(("    → 打空了！"))

  elseif evt.type == "SkillUnusable" then
    -- 原因由核心给（no_pp / sealed / forbidden / condition），客户端照着显示就行
    print(("    → %s 用不出来（%s）"):format(evt.skill, evt.text or evt.reason or "不可用"))

  elseif evt.type == "Damage" and (evt.damage or 0) > 0 then
    local extra = {}
    if evt.crit then table.insert(extra, "暴击") end
    if (evt.effectiveness or 1) > 1 then table.insert(extra, "效果拔群") end
    if (evt.effectiveness or 1) < 1 then table.insert(extra, "效果不佳") end
    local suffix = #extra > 0 and ("（" .. table.concat(extra, "/") .. "）") or ""
    print(("    → %s 受到 %d 点伤害%s"):format(who(evt.target), evt.damage, suffix))

  elseif evt.type == "DamagePrevented" then
    print(("    → %s 的伤害被挡下了"):format(who(evt.target)))

  elseif evt.type == "Recover" and (evt.num or 0) > 0 then
    print(("    → %s 回复了 %d 点体力"):format(who(evt.target), evt.num))

  elseif evt.type == "StatChanged" then
    local parts = {}
    for field, delta in pairs(evt.stages or {}) do
      table.insert(parts, ("%s%+d"):format(field, delta))
    end
    table.sort(parts)
    print(("    → %s 的能力变化：%s"):format(who(evt.target), table.concat(parts, " ")))

  elseif evt.type == "StatusApplied" then
    local def = S.Mark.defs[evt.status]
    print(("    → %s 陷入%s"):format(who(evt.target), def and def.name or evt.status))

  elseif evt.type == "StatusRemoved" then
    local def = S.Mark.defs[evt.status]
    print(("    → %s 的%s解除了"):format(who(evt.target), def and def.name or evt.status))

  elseif evt.type == "ActionPrevented" then
    local def = S.Mark.defs[evt.reason]
    print(("    → %s 因为%s没能行动"):format(who(evt.pet), def and def.name or tostring(evt.reason)))

  elseif evt.type == "NotAction" or evt.type == "NoAction" then
    print(("    → %s 这回合没有出手"):format(who(evt.pet)))

  elseif evt.type == "PetFainted" then
    print(("  *** %s 倒下了 ***"):format(who(evt.pet or evt.seat)))

  elseif evt.type == "GameOver" then
    if evt.winner ~= nil then
      print(("  *** 对局结束：%s 获胜（%s）***"):format(who(evt.winner == 0 and 1 or 2), tostring(evt.reason)))
    else
      print(("  *** 对局结束：平局（%s）***"):format(tostring(evt.reason)))
    end
  end
end

-- 战斗逻辑本体
local logic = S.BattleLogic:new(room, {
  seed = "lei-vs-gaiya",       -- 种子定了，这一局就能重放（§2.3）
  actors = room.pets,
  request_hook = ai,           -- 无头模式：AI 就地作答，一步都不挂起
})
logic:registerAllPets()

print("雷伊 Lv.100  vs  盖亚 Lv.100")
print("（种族值/技能表都照图鉴抄了，但**伤害公式的系数还没和实机核对**，")
print("  所以这一局不能拿来判断强弱平衡——它的意义是验证机制能跑通。）")
print(("  雷伊  体力 %d  攻击 %d  特攻 %d  特防 %d  速度 %d")
  :format(lei.max_hp, lei.attack, lei.sp_attack, lei.sp_defense, lei.speed))
print(("  盖亚  体力 %d  攻击 %d  防御 %d  速度 %d")
  :format(gaiya.max_hp, gaiya.attack, gaiya.defense, gaiya.speed))

local kind = logic:start()

print()
print(("打完了：%s，共 %d 回合"):format(kind, logic.round))
print(("  雷伊  剩余体力 %d/%d"):format(lei.hp, lei.max_hp))
print(("  盖亚  剩余体力 %d/%d"):format(gaiya.hp, gaiya.max_hp))
print(("  事件流 %d 条（其中流程事件 %d 条，时机 %d 条）"):format(
  #logic.event_log,
  (function() local n = 0 for _, e in ipairs(logic.event_log) do if e.kind == "game_event" then n = n + 1 end end return n end)(),
  (function() local n = 0 for _, e in ipairs(logic.event_log) do if e.kind == "timing" then n = n + 1 end end return n end)()))

-- ============================ 四、复盘一点细节 ============================

print()
print("=== 查几个「当时发生了什么」 ===")

local damage_events = logic.event_recorder[S.GameEvent.Damage] or {}
print(("  整局一共 %d 次伤害结算"):format(#damage_events))
if damage_events[1] then
  local d = damage_events[1]
  local use = d:findParent(S.GameEvent.UseSkill)
  print(("  第一次伤害：%s 打 %s，%d 点，用的是 %s"):format(
    d.data.source and d.data.source.name or "?",
    d.data.target.name, d.data.damage,
    use and use.data.skill.name or "?"))
end

local round1 = logic.event_recorder[S.GameEvent.Round][1]
if round1 then
  local in_round1 = round1:searchEvents(S.GameEvent.UseSkill, 10)
  print(("  第一回合里发生了 %d 次技能使用"):format(#in_round1))
end

-- ============================ 五、机制巡演 ============================
--
-- 上面那一局是"自由对战"，两三回合就打完了（雷伊体力种族只有 71，本来就脆）。
-- 光看那个看不出每种机制长什么样，所以这里再按剧本把关键机制各演一遍。
-- 每一段都是"造两只精灵 → 干一件事 → 看结果"，可以直接改参数做实验。

print()
print("=== 机制巡演：每种机制各演一遍 ===")

--- 造一对只用来做实验的精灵
local function lab_pair(tag, a_skills, b_skills, a_opts, b_opts)
  local a = S.Pet:new{
    species = "雷伊", level = 100, side = 0, seat = 1,
    skills = a_skills, evs = (a_opts or {}).evs,
    nature = (a_opts or {}).nature,
  }
  local b = S.Pet:new{
    species = "盖亚", level = 100, side = 1, seat = 2,
    skills = b_skills, evs = (b_opts or {}).evs,
    nature = (b_opts or {}).nature,
  }
  local logic = S.BattleLogic:new(
    { pets = { a, b }, notifyPlayers = function() end },
    { seed = tag, actors = { a, b } })
  logic:registerAllPets()
  return a, b, logic
end

-- ---------- 1. 控制类异常状态：麻痹 ----------
do
  local a, b, logic = lab_pair("tour-control", { "抓" }, { "叩击" })
  local mark = logic:applyMark{ target = b, mark = "paralysis", source = a }
  print(("1) 控制类印记：给盖亚挂「%s」（%s，%s）")
    :format(mark:getName(), mark:getTypeName(), mark:getDesc()))
  print(("   盖亚速度从 %d 掉到 %d（印记的持续倍率算进了字段）")
    :format(b.speed / 0.5, b.speed))
  local prevented = 0
  for _ = 1, 20 do
    if logic:beginAction(b, nil) then prevented = prevented + 1 end
  end
  print(("   20 次行动里有 %d 次被麻痹掐掉（def.block_chance = %d%%）")
    :format(prevented, S.Mark.defs.paralysis.block_chance))
end

-- ---------- 2. 弱化类异常状态：中毒 ----------
do
  local a, b, logic = lab_pair("tour-weaken", { "抓" }, { "叩击" })
  logic:applyMark{ target = b, mark = "poison", source = a }
  local hp = b.hp
  logic:endRound()
  print(("2) 弱化类印记：中毒让盖亚回合末掉了 %d 点（最大体力的 1/8 = %d）")
    :format(hp - b.hp, math.floor(b.max_hp / 8)))
end

-- ---------- 3. 增益印记：护盾 ----------
do
  local a, b, logic = lab_pair("tour-buff", { "抓" }, { "叩击" })
  logic:applyMark{ target = b, mark = "shield", source = b }
  local r1 = logic:damage{ source = a, target = b, fixed = 100 }
  local r2 = logic:damage{ source = a, target = b, fixed = 100 }
  print(("3) 增益印记：护盾挡掉了第一下（%d 点），第二下挡不住（%d 点）")
    :format(r1.damage, r2.damage))
  print(("   护盾挡完就消失了，盖亚身上还剩 %d 个印记"):format(#b:getMarks()))
end

-- ---------- 4. 消强 + 附加异常（"复用"的典型） ----------
do
  local a, b, logic = lab_pair("tour-clear", { "抓" }, { "日月皆伤" })
  a:setStatStage("attack", 2)
  a:setStatStage("speed", 1)
  print(("4) 消强：雷伊先给自己 +2 攻击 +1 速度（攻击 %d，速度等级 %d）")
    :format(a.attack, a:getStatStage("speed")))

  -- 「日月皆伤」官方效果就是"消除对手能力提升状态"，这里再把"消除成功则烧伤"串上
  local clear = S.Effect:create({
    kind = "clear_stages", side = "up",
    then_effects = { { kind = "mark", mark = "burn", probability = 100 } },
    condition = function(effect, ctx)
      for _, field in ipairs(S.Pet.STAT_FIELDS) do
        if (ctx.target:getStatStage(field) or 0) > 0 then return true end
      end
      return false
    end,
  }, b, a)
  clear:apply(logic, { source = b, target = a })
  print(("   消强之后：攻击等级 %d，速度等级 %d，并且%s")
    :format(a:getStatStage("attack"), a:getStatStage("speed"),
      a:hasStatus("burn") and "被附加了烧伤" or "没被附加异常"))
  print("   （同一段代码把 then_effects 换成 frostbite 就是另一个技能——这就叫复用）")
end

-- ---------- 5. 连击 ----------
do
  local a, b, logic = lab_pair("tour-combo", { "抓" }, { "连环摔投" }, nil, { evs = { attack = 252 } })
  local before = #(logic.event_recorder[S.GameEvent.Damage] or {})
  local r = logic:useSkill{ source = b, target = a, skill = S.Seer:getSkill("连环摔投") }
  local after = #(logic.event_recorder[S.GameEvent.Damage] or {})
  print(("5) 连击：连环摔投打了 %d 下（每下独立结算，所以减伤是逐下生效的）")
    :format(after - before))
  print(("   累计伤害 %d，a 剩 %d/%d"):format(r.damage, a.hp, a.max_hp))
end

-- ---------- 6. 增伤（前置效果） ----------
do
  local a, b, logic = lab_pair("tour-power", { "惊雷切" }, { "叩击" }, { evs = { attack = 252 } })
  local full = logic:useSkill{ source = a, target = b, skill = S.Seer:getSkill("惊雷切") }.damage
  a.hp = math.floor(a.max_hp * 0.4)
  local low = logic:useSkill{ source = a, target = b, skill = S.Seer:getSkill("惊雷切") }.damage
  print(("6) 增伤：惊雷切「自身 HP 小于 1/2 时威力 ×2」（满血 %d → 残血 %d）")
    :format(full, low))
  print("   （它是 phase = \"before\" 的效果：伤害算出来**之前**就把威力改掉了）")
end

-- ---------- 7. 附加固定伤害 ----------
do
  local a, b, logic = lab_pair("tour-adddmg", { "抓" }, { "渗透劲" })
  local hp0 = a.hp
  logic:useSkill{ source = b, target = a, skill = S.Seer:getSkill("渗透劲") }
  print(("7) 附加伤害：渗透劲威力只有 20，但额外附加 50 点固定伤害（总共打掉 %d 点）")
    :format(hp0 - a.hp))
end

-- ---------- 8. 吸取（按结果算的效果） ----------
do
  local drain_skill = S.Seer:createSkill{
    name = "巡演_吸取", element = "电", category = S.Skill.Special,
    power = 80, pp = 10, accuracy = 100,
    effects = { { kind = "drain", ratio = 0.5 } },
  }
  local a, b, logic = lab_pair("tour-drain", { drain_skill }, { "叩击" }, { evs = { sp_attack = 252 } })
  a.hp = math.floor(a.max_hp * 0.5)
  local hp0 = a.hp
  local dealt = logic:useSkill{ source = a, target = b, skill = drain_skill }.damage
  print(("8) 吸取：打出 %d 伤害，自己回了 %d 点（ratio = 0.5，读的是 ctx.damage）")
    :format(dealt, a.hp - hp0))
end

-- ---------- 9. 技能可用性：usable / PP / 封印 ----------
--
-- 需求上明确过的一点：技能要有"能不能用"这个属性——有时候是规则禁止你使用某个技能，
-- 有时候就是 PP 用光了。这两个来源（加上"被封印"）**共用同一个判断**，
-- 所以"列候选"和"真使用"永远一致，不会出现"界面上能点、点了说用不出来"。
do
  local cond = S.Seer:createSkill{
    name = "巡演_背水一击", element = "普通", category = S.Skill.Physical,
    power = 120, pp = 3, accuracy = 100,
    usable = function(skill, pet) return pet:getHpRatio() < 0.5 end,
  }
  local banned = S.Seer:createSkill{
    name = "巡演_被禁止使用的技能", element = "普通", category = S.Skill.Physical,
    power = 999, pp = 5, accuracy = 100,
    usable = false,
  }
  local a, b, logic = lab_pair("tour-usable", { cond, banned }, { "叩击" })

  local function show(sk)
    local ok, reason, text = a:checkSkillUsable(sk)
    print(("   %s：%s → %s"):format(sk.name, ok and "可用" or "不可用", text or "-"))
  end

  print("9) 技能可用性：usable / PP / 封印 三个来源，同一个 Skill:checkUsable")
  show(cond)                                   -- 满血：技能自己的条件不满足
  a.hp = math.floor(a.max_hp * 0.3)
  show(cond)                                   -- 残血：条件满足
  show(banned)                                 -- spec 里写死 usable = false
  a:usePP(cond.name, 3)
  show(cond)                                   -- PP 用光
  a:restoreAllPP()
  a:sealSkill(cond.name)
  show(cond)                                   -- 被封印

  local r = logic:useSkill{ source = a, target = b, skill = cond }
  print(("   真去用它：prevented = %s，原因 %s，提示语「%s」（客户端照着显示就行）")
    :format(tostring(r.prevented), tostring(r.prevent_reason), tostring(r.prevent_text)))
  print("   （第五技能走的是同一套判断：一样有 PP、一样会被封印——它没有专属规则，")
  print("     它和普通技能的区别只是摆在单独一个技能位上）")
end

-- ---------- 10. 印记类 / 异常状态类 / 新注册的效果 ----------
--
-- 这一段是给"我加的东西写在哪里"做示范的：
--   * 异常状态的类别行为在 mark/status.lua（弱化类掉血、控制类掐行动），
--     具体状态只写数据 → `mark:getTurnEndDamage()` 这类方法可以直接问数值；
--   * 新效果类型注册在 **包里**（lua/specs/standard/effects.lua），核心一行没改；
--   * 持续型效果挂在**精灵身上**（pet.effects 表），回合数到点自己收尾。
do
  local a, b, logic = lab_pair("tour-mark-class",
    { "试作·封印之雷" }, { "气力", "渗透劲", "叩击" })

  print("10) 印记类与注册点")
  print(("   异常状态枚举：%s"):format(table.concat(
    { S.Status.KEY.PARALYSIS, S.Status.KEY.POISON, S.Status.KEY.BURN }, "/")))

  local poison = logic:applyMark{ target = a, mark = "poison", source = b }
  print(("   给雷伊挂「%s」：%s，%s")
    :format(poison:getName(), poison:getClassName(),
      poison.turns and ("还剩 %d 回合"):format(poison.turns) or "一直挂着直到被解除"))
  print(("   它每回合末会掉 %d 点（最大体力 %d 的 1/8）——直接问类，不用跑一回合")
    :format(poison:getTurnEndDamage(), a.max_hp))

  local burn = logic:applyMark{ target = a, mark = "burn", source = b }
  print(("   烧伤把物理伤害压到 %s 倍，特殊伤害不受影响（getAttackMultiplier 给 nil）")
    :format(tostring(burn:getAttackMultiplier(S.Skill.Physical))))

  local para = logic:applyMark{ target = a, mark = "paralysis", source = b }
  print(("   麻痹是控制类：每回合 %d%% 动不了（mark:getBlockChance）")
    :format(para:getBlockChance()))

  -- 解除异常状态只清弱化类/控制类，不会顺手把增益印记拆了
  local shield = logic:applyMark{ target = a, mark = "shield", source = a }
  print(("   雷伊身上：%d 个异常状态 + 1 个增益印记（%s）")
    :format(#a:getStatusKeys(), shield:getName()))
  print(("   解除全部异常状态 → 清掉 %d 个；增益印记还在：%s")
    :format(logic:cureStatus(a), tostring(a:hasMark("shield"))))

  -- 包内注册的效果：封招（持续型），挂到对手身上
  logic:useSkill{ source = a, target = b, skill = S.Seer:getSkill("试作·封印之雷") }
  local sealed = b:getSealedSkills()
  print(("   用「试作·封印之雷」（包内注册的效果 seal_skill）→ 盖亚被封：%s")
    :format(#sealed > 0 and sealed[1] or "无"))
  print(("   于是它的可用性判断直接给出原因：%s")
    :format(select(3, b:checkSkillUsable(sealed[1] or "叩击")) or "-"))
  print(("   这个效果就挂在盖亚身上的 pet.effects 表里（现在有 %d 个持续效果）")
    :format(b:countEffects()))

  -- 抵挡致死伤害：又一个持续型效果，挂在**自己**身上
  -- （先把护盾摘掉，不然这一下会被护盾吃掉，看不到抵挡在起作用）
  logic:removeMark(a, "shield", "cleared")
  local endure = S.Effect:create({ kind = "endure", duration = 2, target = "self" }, a, a)
  logic:applyEffect(endure)
  local hp_before = a.hp
  logic:damage{ source = b, target = a, fixed = a.hp + 999 }
  print(("   挂上「试作·不屈意志」后再挨必死一击：体力 %d → %d，效果自己收掉了（%s）")
    :format(hp_before, a.hp, tostring(not a:hasEffect(endure.name))))

  print("   （这四种效果都在 lua/specs/standard/effects.lua 里注册——核心没动过一行）")
end

print()
print("以上每一段都可以改参数重跑：改 spec 里的数字就行，不用碰核心代码。")
