#!/usr/bin/env lua5.4
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ seer-core 单跑测试 ============================
--
--   cd packages/seer-core && lua5.4 tests/test_core.lua
--   或者从仓库根目录： make test-lua
--
-- 这个文件本身就是架构文档 §4 里说的"能单跑 Lua 脚本的测试入口"：
-- **不起服务端、不起客户端、不需要 C++**，整份战斗核在纯 Lua 里验证。
-- 这也是把规则放进 Lua 的最大好处之一——结算逻辑能脱离网络单独测。
--
-- 它同时也是一份"怎么用这套核心"的说明书：看下面每一段就知道
-- 精灵怎么造、技能怎么声明、效果怎么生效、时机怎么挂。

-- 从自身位置推包根目录：这样从任何 cwd 跑都能找到 seer.lua
local HERE = debug.getinfo(1, "S").source:sub(2)
local PKG_ROOT = HERE:match("^(.*)/tests/[^/]+$") or "."

local S = dofile(PKG_ROOT .. "/lua/seer.lua")

-- 载入本身会打两条 info，测试期间先静音，让输出只剩 PASS/FAIL。
-- 专门验证日志的用例会自己把级别调回来并挂一个收集用的 sink（见"日志"一节）。
S.Log.min_level = "critical"

local GREEN, RED, DIM, RESET = "\27[32m", "\27[31m", "\27[2m", "\27[0m"

local checks, failures = 0, 0

local function check(cond, desc, actual)
  checks = checks + 1
  if cond then
    print(("  %sPASS%s %s"):format(GREEN, RESET, desc))
    return true
  end
  failures = failures + 1
  print(("  %sFAIL%s %s"):format(RED, RESET, desc))
  if actual ~= nil then
    print(("       %s实际: %s%s"):format(DIM, tostring(actual), RESET))
  end
  return false
end

local function eq(actual, expected, desc)
  return check(actual == expected, desc,
    ("期望 %s，实际 %s"):format(tostring(expected), tostring(actual)))
end

local function section(name)
  print(("\n%s== %s ==%s"):format(DIM, name, RESET))
end

-- ---------------------------- 测试脚手架 ----------------------------

--- 一个"假房间"：只提供战斗核真正会用到的那几个接口。
--- 它存在本身就说明了一件事：**战斗核没有硬依赖 C++ 或 socket**，
--- 想单测只要凑出这几个方法（对应架构文档 §5.4 的 askToChoice/notifyPlayers）。
local function makeRoom()
  local room = {
    pets = {},
    notified = {},   -- notifyPlayers 收到的消息（用来断言"有没有通知 C++"）
    asked = {},      -- askToChoice 被问过什么
    answer = nil,    -- 强制答复（nil = 就选第一个）
  }
  function room:getAlivePets()
    return table.filter(self.pets, function(p) return not p:isFainted() end)
  end
  function room:askToChoice(pet, params)
    table.insert(self.asked, { pet = pet, params = params })
    if self.answer ~= nil then return self.answer end
    return params.choices and params.choices[1]
  end
  function room:notifyPlayers(evt)
    table.insert(self.notified, evt)
  end
  return room
end

local function makeBattle(pets, seed)
  local room = makeRoom()
  room.pets = pets
  local logic = S.BattleLogic:new(room, { seed = seed or "seer-test-seed", actors = pets })
  logic:registerAllPets()
  return logic, room
end

--- 造一只精灵，side 默认 0
local function makePet(species_name, opts)
  opts = opts or {}
  opts.species = species_name
  if opts.side == nil then opts.side = 0 end
  return S.Pet:new(opts)
end

-- 计数/取名字的小工具：事件流里两层都记着，用 kind 区分
local function countLog(logic, kind, name)
  local n = 0
  for _, e in ipairs(logic.event_log) do
    if e.kind == kind and (name == nil or e.name == name) then n = n + 1 end
  end
  return n
end

--- 一份标准的测试阵容：草系(0) vs 火系(1)
local function makeStandardPets()
  local bu = makePet("布布种子", {
    level = 50, side = 0, seat = 1,
    ivs = { hp = 31, attack = 20, defense = 31, sp_attack = 31, sp_defense = 31, speed = 28 },
    evs = { hp = 252, defense = 4, sp_defense = 252 },
    nature = "胆小",
    skills = { "撞击", "藤鞭", "蓄能", "麻痹粉" },
  })
  local huo = makePet("小火猴", {
    level = 50, side = 1, seat = 2,
    ivs = { hp = 31, attack = 31, defense = 31, sp_attack = 31, sp_defense = 31, speed = 31 },
    nature = "坦率",
    skills = { "撞击", "火花" },
  })
  return bu, huo
end

--- 造一个只用来做单点验证的技能 + 触发器。
--- 每个测试用独立的技能名，避免互相污染全局技能表。
local function makeTriggerSkill(name, event_klass, trig_spec)
  return S.Seer:createSkill{
    name = name,
    category = S.Skill.Status,
    tags = { S.Skill.Ability, S.Skill.Compulsory },
    target = "self",
    triggers = { [event_klass] = trig_spec },
  }
end

-- ============================================================================
section("环境与注册表")

check(S ~= nil, "seer-core 能载入（lua/seer.lua 返回了类表）")
eq(S.Seer:getSpecies("布布种子") ~= nil, true, "图鉴里有布布种子")
eq(S.Seer:getSpecies(2) ~= nil, true, "按图鉴编号也能取到种族")
eq(S.Seer:getSpecies("不存在"), nil, "取不存在的种族返回 nil")
check(S.Seer.skills["火花"] ~= nil, "技能表里有火花")
check(S.Seer.skills["#茂盛_1_trig"] ~= nil,
  "特性茂盛被骨架拆出子对象 #茂盛_1_trig 并登记进技能表")
eq(S.Seer.skills["茂盛"].related_skills[1].name, "#茂盛_1_trig",
  "子对象挂在主技能的 related_skills 上")
eq(S.Seer.skills["#茂盛_1_trig"].main_skill.name, "茂盛", "子对象能找回主技能")
eq(S.Seer.skills["#茂盛_1_trig"].visible, false, "# 开头的子对象不显示在技能栏")
eq(S.Seer:getTiming("Damage") ~= nil, true, "伤害时机已登记")
eq(S.Seer:getTiming("RoundEnd") ~= nil, true, "回合结束时时机已登记")
eq(S.Skill.isPlayerSkill, S.Skill.isActorSkill, "Skill 保留了 core 的 isPlayerSkill 别名")
eq(S.Damage.STAB, 1.5, "本系加成常量是 1.5")

-- 确定性：同一个 spec 造两次，子对象序号必须一样
do
  local spec = {
    name = "确定性测试技",
    category = S.Skill.Status,
    triggers = {
      [S.SeerTiming.Damage] = { priority = 1, on_trigger = function() return false end },
      [S.SeerTiming.Damaged] = { priority = 1, on_trigger = function() return false end },
    },
  }
  local names1, names2 = {}, {}
  for _, s in ipairs(S.Seer:createSkill(spec).related_skills) do
    table.insert(names1, s.name)
  end
  for _, s in ipairs(S.Seer:createSkill(spec).related_skills) do
    table.insert(names2, s.name)
  end
  eq(table.concat(names1, ","), table.concat(names2, ","),
    "重复构造同一个 spec 得到相同的子对象名（spec.triggers 遍历顺序必须确定）")
end

-- ============================================================================
section("精灵：能力值计算")

do
  local bu = makePet("布布种子", {
    level = 50,
    ivs = { hp = 31, attack = 20, defense = 31, sp_attack = 31, sp_defense = 31, speed = 28 },
    evs = { hp = 252, defense = 4, sp_defense = 252 },
    nature = "胆小",
    skills = { "撞击" },
  })

  -- 手算一遍对答案：体力 = ⌊(45×2+31+⌊252/4⌋)×50/100⌋ + 50 + 10
  eq(bu.max_hp, 152, "体力按公式算出 152")
  eq(bu.hp, 152, "不填 hp 时按满血创建")
  -- 攻击：⌊(49×2+20+0)×50/100⌋+5 = 64，性格胆小降攻击 ×0.9 → 57
  eq(bu.attack, 57, "性格降低的攻击力被算进去（64 × 0.9）—— 直接读字段")
  -- 速度：⌊(45×2+28)×50/100⌋+5 = 64，性格胆小加速度 ×1.1 → 70
  eq(bu.speed, 70, "性格提升的速度被算进去（64 × 1.1）")
  eq(bu.nature, "speed-attack", "性格名被解析成稳定的键名")
  eq(bu:getPanelStat("attack"), 57, "getPanelStat 是不含能力等级的面板值")
  eq(bu.species:getPrimaryElement(), "草", "主属性是草")
  eq(bu.species:isDual(), false, "布布种子是单属性")

  local neutral = makePet("布布种子", { level = 50, ivs = { attack = 20 }, nature = "坦率", skills = { "撞击" } })
  eq(neutral.attack, 64, "无修正性格攻击力是 64")
  eq(neutral.nature, "attack-attack", "坦率也是键名（无修正）")

  local dual = makePet("演示双属性", { level = 50, skills = { "水枪" } })
  eq(dual.species:isDual(), true, "演示双属性是双属性")
end

do
  -- 学习力总和超过 510 要被夹住
  local p = makePet("布布种子", {
    level = 50,
    evs = { hp = 255, attack = 255, defense = 255 },
    skills = { "撞击" },
  })
  local total = p.evs.hp + p.evs.attack + p.evs.defense
  eq(total, 510, "学习力总和被夹到 510")
  eq(p.evs.hp, 255, "夹的时候从后面往前砍，前面的项保留")
end

do
  local p = makePet("布布种子", { level = 50, skills = { "撞击" } })
  eq(p:getStatStage("attack"), 0, "初始能力等级是 0")
  eq(p:getStageMultiplier("attack"), 1.0, "0 级倍率是 1.0")
  eq(p:setStatStage("attack", 2), 2, "+2 全部生效")
  eq(p:getStageMultiplier("attack"), 2.0, "+2 级倍率 2.0")
  eq(p:setStatStage("attack", 10), 4, "被 +6 上限吃掉一部分（只再加 4）")
  eq(p:getStatStage("attack"), 6, "停在 +6")
  eq(p:getStageMultiplier("attack"), 4.0, "+6 级倍率 4.0")
  p:resetStages()
  eq(p:getStatStage("attack"), 0, "resetStages 清空能力等级")
  eq(p:setStatStage("defense", -8), -6, "下降也夹在 -6")
  eq(p:getStatStage("defense"), -6, "停在 -6")
end

-- ============================================================================
section("精灵：体力、状态、技能、序列化")

do
  local p = makePet("布布种子", { level = 50, skills = { "撞击", "藤鞭" } })
  local max = p.max_hp
  eq(p:takeDamage(30), 30, "扣血返回实际扣掉的量")
  eq(p.hp, max - 30, "体力正确减少")
  eq(p:takeDamage(max * 10), max - 30, "扣血不会把体力扣成负数")
  eq(p.hp, 0, "体力下限是 0")
  eq(p:isFainted(), true, "体力 0 就是倒下")
  eq(p:heal(20), 0, "倒下时回血无效")
  p:revive()
  eq(p.hp, max, "复活回满血")
  eq(p:isFainted(), false, "复活后不再是倒下状态")
  p:takeDamage(30)
  eq(p:heal(10), 10, "受伤后能回血")
  eq(p:heal(99999), 20, "回血不会超过最大体力（补满剩下的 20）")
  eq(p.hp, max, "补满后正好是最大体力")
  eq(p:getHpRatio(), 1.0, "满血比例是 1.0")
end

do
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })

  eq(bu:hasMark("poison"), false, "初始身上没有印记")

  local mark = logic:applyMark{ target = bu, mark = "poison", turns = 3, source = huo }
  check(mark ~= nil, "挂中毒成功（返回印记实例）")
  eq(mark.key, "poison", "印记的键")
  eq(mark:getName(), "中毒", "印记的名字")
  eq(mark:getType(), S.Mark.TYPE.WEAKEN, "中毒是弱化类")
  eq(mark:isStatus(), true, "弱化类算异常状态")
  eq(mark.turns, 3, "持续回合数按传进去的算")
  eq(mark.source, huo, "记下了是谁挂的")
  eq(bu:hasMark("poison"), true, "查询得到")
  eq(bu:hasStatus("poison"), true, "它也是异常状态")
  eq(bu:getMarkKeys()[1], "poison", "印记键列表是排序过的")

  -- 印记真的装上了被动触发器（"之后一直管"靠的就是它）
  eq(#mark.triggers > 0, true, "印记带上了时机触发器")
  local owner_ok = true
  for _, trig in ipairs(mark.triggers) do
    if not trig:isActorTrigger(bu, true) then owner_ok = false end
  end
  eq(owner_ok, true, "触发器都归属到中毒的那只精灵身上")

  -- 增益印记也是印记，但**不算异常状态**（所以"解除异常"不会误伤它）
  local shield = logic:applyMark{ target = bu, mark = "shield" }
  check(shield ~= nil, "挂护盾成功")
  eq(shield:getType(), S.Mark.TYPE.BUFF, "护盾是增益类")
  eq(shield:isStatus(), false, "增益印记不算异常状态")
  eq(bu:hasMark("shield"), true, "但它确实在身上的印记表里")
  eq(bu:hasStatus("shield"), false, "而 hasStatus 不认它")
  eq(#bu:getMarks(), 2, "身上共两个印记")
  eq(#bu:getStatusMarks(), 1, "其中异常状态只有一个")

  -- 解除异常状态只清弱化/控制类，不动增益印记
  eq(logic:cureStatus(bu), 1, "解除异常状态：清掉一个")
  eq(bu:hasStatus("poison"), false, "中毒没了")
  eq(bu:hasMark("shield"), true, "护盾还在（增益印记不受影响）")

  eq(logic:removeMark(bu, "shield", "test"), true, "单独摘掉护盾")
  eq(#bu:getMarks(), 0, "身上干净了")
  eq(bu:hasMark("shield"), false, "护盾没了")
end

do
  -- 印记的持续回合会递减、到期自动消失
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "mark-tick")
  logic:applyMark{ target = bu, mark = "fear" }   -- 害怕：持续 1 回合
  eq(bu:getMark("fear").turns, 1, "害怕挂上时剩 1 回合")
  logic:endRound()
  eq(bu:hasMark("fear"), false, "过了一个回合就消失了")
  eq(countLog(logic, "timing", "MarkRemoved"), 1, "摘掉时走了 MarkRemoved 时机")

  -- 永久印记（中毒没写 duration）不会自己掉
  logic:applyMark{ target = bu, mark = "poison" }
  for _ = 1, 5 do logic:endRound() end
  eq(bu:hasMark("poison"), true, "没写持续回合的印记不会自己消失")
end

do
  -- 印记的**持续数值倍率**要真的算进字段里
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "mark-mult")
  local speed_before = bu.speed

  logic:applyMark{ target = bu, mark = "paralysis" }
  eq(bu.speed, math.max(1, math.floor(speed_before * 0.5)),
    ("麻痹让速度字段直接减半（%d -> %d）"):format(speed_before, bu.speed))
  eq(bu:getPanelStat("speed"), speed_before, "面板值不受印记影响（印记只改当前值）")

  logic:removeMark(bu, "paralysis", "test")
  eq(bu.speed, speed_before, "摘掉之后速度恢复")

  local attack_before = bu.attack
  logic:applyMark{ target = bu, mark = "empower" }   -- 攻击/特攻 ×1.5
  eq(bu.attack, math.max(1, math.floor(attack_before * 1.5)), "增益印记把攻击提到 1.5 倍")
end

do
  local p = makePet("布布种子", { level = 50, skills = { "藤鞭", "蓄能" } })
  eq(#p:getSkills(), 2, "带了两个技能")
  eq(p:getSkill("藤鞭").name, "藤鞭", "按名字取技能")
  eq(p:getSkill(2).name, "蓄能", "按槽位取技能")
  eq(p:getPP("藤鞭"), 25, "初始 PP 取自技能定义")
  eq(p:usePP("藤鞭", 5), true, "消耗 5 点 PP 成功")
  eq(p:getPP("藤鞭"), 20, "PP 正确扣减")
  eq(p:usePP("藤鞭", 999), false, "PP 不够时返回 false")
  eq(p:getPP("藤鞭"), 20, "PP 不够时不会扣")
  p:restoreAllPP()
  eq(p:getPP("藤鞭"), 25, "restoreAllPP 回满")
  eq(p:hasSkill("藤鞭"), true, "hasSkill 按名字查得到")
  eq(p:hasSkill("不存在"), false, "hasSkill 查不到返回 false")
  eq(p:isSkillSealed("藤鞭"), false, "初始没被封印")
  p:sealSkill("藤鞭")
  eq(p:isSkillSealed("藤鞭"), true, "封印生效")
  p:unsealSkill("藤鞭")
  eq(p:isSkillSealed("藤鞭"), false, "解封生效")
end

do
  -- 特性：种族自带的、不占技能格的那个技能
  local p = makePet("布布种子", { level = 50, skills = { "撞击" } })
  eq(p:getAbility() ~= nil, true, "种族特性被自动挂上")
  eq(p:getAbility().name, "茂盛", "特性是茂盛")
  eq(p:hasSkill("茂盛"), true, "hasSkill 也算上特性")
  eq(p:isAbility("茂盛"), true, "isAbility 认得它")
  eq(#p:getSkills(), 1, "特性不占携带技能格")
end

-- ============================================================================
section("精灵：当前数值是字段，不是表")

do
  local bu = makePet("布布种子", {
    level = 50,
    ivs = { hp = 31, attack = 20, defense = 31, sp_attack = 31, sp_defense = 31, speed = 28 },
    evs = { hp = 252, defense = 4, sp_defense = 252 },
    nature = "胆小",
    skills = { "撞击" },
  })

  -- 六项数值是**独立字段**，不是 pet.stats.xxx 那种表查找
  eq(bu.stats, nil, "不再有 stats 这张表（数值直接挂在精灵身上）")
  for _, field in ipairs(S.Pet.STAT_FIELDS) do
    eq(type(bu[field]), "number", ("字段 pet.%s 是个数字"):format(field))
  end
  eq(S.Pet.STAT_FIELDS[1], "hp", "字段顺序从体力开始")
  eq(#S.Pet.STAT_FIELDS, 6, "一共六项")

  -- 种族值（静态图鉴数据）仍然在种族上，是一张表——那是天生适合用表的东西
  eq(type(bu.species.base_stats), "table", "种族值还在 species.base_stats 上")
  eq(bu.species.base_stats.speed, 45, "种族值能按字段名取到")
  eq(bu.species:getBaseStat("speed"), 45, "也有 getBaseStat 方法")

  -- 手算对答案：速度 = ⌊((45×2+28+0)×50/100)+5⌋ ×1.1 = 64 ×1.1 → 70
  eq(bu.speed, 70, "速度字段含性格修正")
  eq(bu:getPanelStat("speed"), 70, "面板值（不含能力等级）此时相同")
  eq(bu.sp_defense, 117, "特防字段 = ⌊(65×2+31+63)×0.5⌋+5 = 117")

  -- 改能力等级 → 字段**立刻**跟着变（不用手动重算，也不用记着乘倍率）
  eq(bu.sp_attack, 69, "强化前特攻 69")
  eq(bu:setStatStage("sp_attack", 2), 2, "+2 生效")
  eq(bu.sp_attack, 138, "特攻字段立刻变成 138（面板 69 × 2）")
  eq(bu:getPanelStat("sp_attack"), 69, "面板值不受能力等级影响")
  eq(bu:getStat("sp_attack"), 138, "按名字取也是同一个数（给遍历/协议用）")

  bu:resetStages()
  eq(bu.sp_attack, 69, "清空能力等级后字段回到面板值")

  -- 体力没有能力等级
  local ok, err = pcall(function() bu:setStatStage("hp", 1) end)
  eq(ok, false, "给体力加能力等级会报错（体力没有能力等级这回事）")
  check(tostring(err):find("体力") ~= nil, "报错信息说明了原因", err)

  -- 给协议/UI 遍历用的快照
  local snap = bu:getStatSnapshot()
  local n = 0
  for k, v in pairs(snap) do
    n = n + 1
    check(type(v) == "number", ("快照里的 %s 是数字"):format(k))
  end
  eq(n, 6, "快照里正好六项")
  eq(snap.speed, bu.speed, "快照与字段一致")
end

do
  -- 最大体力和当前体力是两个字段，分得清清楚楚
  local bu = makePet("布布种子", { level = 50, skills = { "撞击" } })
  eq(bu.max_hp, 105, "最大体力按公式算出来")
  eq(bu.hp, 105, "不填 hp 时按满血创建")
  eq(bu.hp, bu.max_hp, "初始两者相等")

  bu:takeDamage(30)
  eq(bu.hp, 75, "当前体力掉了")
  eq(bu.max_hp, 105, "最大体力不受影响")
  check(bu.hp < bu.max_hp, "受伤后当前体力小于最大体力")

  -- 等级变了，最大体力跟着变，当前体力自动夹在上限内
  local p2 = makePet("布布种子", { level = 50, skills = { "撞击" } })
  local old_max = p2.max_hp
  p2.level = 60
  p2:recalcStats()
  check(p2.max_hp > old_max, ("升级后最大体力变大（%d -> %d）"):format(old_max, p2.max_hp), p2.max_hp)
  check(p2.hp <= p2.max_hp, "当前体力不会超过最大体力")

  -- 复活/回血都是改当前体力，不动最大体力
  local p3 = makePet("布布种子", { level = 50, hp = 1, skills = { "撞击" } })
  eq(p3.hp, 1, "可以带着残血创建")
  p3:heal(9999)
  eq(p3.hp, p3.max_hp, "回满血")
  eq(p3.max_hp, 105, "最大体力还是 105")
end

-- ============================================================================
section("技能栏：4 个普通技能 + 第五技能（单独一个属性）")

do
  local bu = makePet("布布种子", {
    level = 50, skills = { "撞击", "藤鞭", "蓄能", "麻痹粉" },
    fifth = "元气电光球",
  })

  eq(#bu:getSkills(), 4, "普通技能有 4 个")
  eq(bu:getFifthSkill().name, "元气电光球", "第五技能单独一个属性")
  eq(#bu:getAllSkills(), 5, "全部技能 = 4 + 第五技能")

  -- 最关键的一条：第五技能**不占普通技能格**
  eq(bu:getSkill(5), nil, "第 5 个普通技能槽是空的（第五技能不是 slots[5]）")
  eq(bu:isFifthSkill("元气电光球"), true, "isFifthSkill 认得它")
  eq(bu:isFifthSkill("藤鞭"), false, "普通技能不算第五技能")
  eq(bu:getSkill("元气电光球").name, "元气电光球",
    "按名字仍然取得到（find 会把第五技能一起找）")

  -- 特性既不在普通技能里，也不在"全部技能"里（它是另一个概念）
  eq(bu:getAbility().name, "茂盛", "特性是单独的属性")
  eq(table.find(bu:getAllSkills(), function(s) return s.name == "茂盛" end), nil,
    "特性不出现在技能栏里")
  eq(bu:hasSkill("茂盛"), true, "但 hasSkill 认它（触发者归属判断要用）")

  -- 技能槽越界要报错，而不是偷偷把技能丢掉
  local ok, err = pcall(function() bu:setSkillSlot(5, "撞击") end)
  eq(ok, false, "往第 5 个普通技能槽塞技能会报错")
  check(tostring(err):find("技能槽") ~= nil, "报错信息指向技能槽", err)

  -- PP：跟着技能走，第五技能的 PP 也是独立的
  eq(bu:getPP("元气电光球"), 10, "第五技能有自己的 PP（元气电光球 PP 10）")
  eq(bu:getPP("藤鞭"), 25, "普通技能的 PP")
  eq(bu:usePP("元气电光球", 1), true, "消耗第五技能的 PP")
  eq(bu:getPP("元气电光球"), 9, "第五技能 PP 正确扣减")
  eq(bu:getPP("藤鞭"), 25, "不影响别的技能")
  bu:restoreAllPP()
  eq(bu:getPP("元气电光球"), 10, "restoreAllPP 连第五技能一起回满")

  -- 整组换普通技能时不该顺手把第五技能清掉
  bu:setSkills{ "撞击" }
  eq(#bu:getSkills(), 1, "普通技能整组换掉了")
  eq(bu:getFifthSkill().name, "元气电光球", "第五技能还在（换普通技能不影响它）")

  -- 技能栏本身也是个独立对象，能直接拿来用
  local set = bu:getSkillSet()
  eq(set:count(), 1, "SkillSet:count 数的是普通技能")
  eq(set:has("元气电光球"), true, "SkillSet:has 把第五技能算进去")
  eq(set:isFifth(set:getFifth().name), true, "SkillSet:isFifth")
  eq(set:getSlots()[1].name, "撞击", "SkillSet:getSlots 给普通技能")
end

do
  -- 技能名写错要立刻报错（而不是等战斗里才发现这个技能不存在）
  local ok = pcall(function()
    return makePet("布布种子", { level = 5, skills = { "撞击" }, fifth = "根本没有这个第五技" })
  end)
  eq(ok, false, "第五技能名字写错会立刻报错")
end

do
  -- "能不能用"有三个来源，而且必须是**同一个判断**：
  --   1. PP 空了；2. 被封印（pet:sealSkill）；3. 技能自己写了条件（spec 的 usable）。
  -- 演示包里备了两个现成的：背水一击（体力低于一半才可用）、被封印的演示技（usable = false）
  local bu = makePet("布布种子", {
    level = 50, skills = { "撞击", "背水一击", "被封印的演示技" },
  })
  local foe = makePet("小火猴", { level = 50, side = 1, seat = 2, skills = { "撞击" } })
  local logic = makeBattle({ bu, foe })

  -- 1) 技能自己的条件（usable = function）
  local ok, reason, text = bu:checkSkillUsable("背水一击")
  eq(ok, false, "体力还满的时候『背水一击』不可用")
  eq(reason, S.Skill.Unusable.CONDITION, "原因是『条件不满足』")
  check(type(text) == "string" and #text > 0, "顺便带回一句给玩家看的说明", text)
  eq(bu:canUseSkill("撞击"), true, "同一只精灵的普通技能不受影响")

  bu.hp = math.floor(bu.max_hp * 0.3) -- 测试里直接压体力，不走流程
  eq(bu:checkSkillUsable("背水一击"), true, "体力掉到一半以下之后就能用了")

  -- 2) usable = false：写死的"禁止使用"
  local ok2, reason2 = bu:checkSkillUsable("被封印的演示技")
  eq(ok2, false, "usable = false 的技能永远不可用")
  eq(reason2, S.Skill.Unusable.FORBIDDEN, "原因是『被禁止使用』")

  -- 3) 封印：记在精灵身上（技能对象是全局共享的，不能改它）
  bu:sealSkill("撞击")
  eq(bu:checkSkillUsable("撞击"), false, "被封印的技能不可用")
  eq(select(2, bu:checkSkillUsable("撞击")), S.Skill.Unusable.SEALED, "原因是『被封印』")
  eq(bu:getSealedSkills()[1], "撞击", "能查出被封印了哪些")
  bu:sealSkills{ "背水一击" }
  eq(#bu:getSealedSkills(), 2, "sealSkills 可以一次封一组")
  bu:unsealAllSkills()
  eq(#bu:getSealedSkills(), 0, "unsealAllSkills 一次解掉")
  eq(bu:checkSkillUsable("撞击"), true, "解封之后又能用了")

  -- 4) PP：最常用的那个来源
  bu.skill_set.pp["撞击"] = 0 -- PP 记在技能栏上
  local ok3, reason3 = bu:checkSkillUsable("撞击")
  eq(ok3, false, "PP 为 0 时不可用")
  eq(reason3, S.Skill.Unusable.NO_PP, "原因是『PP 已用完』")
  bu:restoreAllPP()

  -- 5) 流程层面也会拦，而且把原因带回去
  bu.hp = bu.max_hp
  local r = logic:useSkill{ source = bu, target = foe, skill = bu:getSkill("背水一击") }
  eq(r.prevented, true, "不可用的技能在流程里被拦下")
  eq(r.used, false, "没算用出去，PP 也不扣")
  eq(r.prevent_reason, S.Skill.Unusable.CONDITION, "流程把原因带回来了（UI 要显示它）")
  eq(bu:getPP("背水一击"), 5, "PP 没动")
  eq(foe.hp, foe.max_hp, "对手一点血没掉")

  -- 没传使用者时不该崩，而是明确地说"没有使用者"
  eq(select(2, bu:getSkill("撞击"):checkUsable(nil)), S.Skill.Unusable.NO_PET,
    "没有使用者时给得出原因")

  -- 原因常量都要有对应的说明文字（不然 UI 会显示 nil）
  for key, reason in pairs(S.Skill.Unusable) do
    check(type(S.Skill.UnusableText[reason]) == "string",
      ("每个原因都有说明文字：%s"):format(key), reason)
  end
end

do
  -- 第五技能和普通技能在机制上**完全一样**：一样有 PP、一样会被扣光、
  -- 一样走同一个 checkUsable。它和普通技能的区别只在"摆在哪个技能位"。
  local bu = makePet("布布种子", {
    level = 50, skills = { "撞击" }, fifth = "演示第五技·藤皇斩",
  })
  local foe = makePet("小火猴", { level = 50, side = 1, seat = 2, skills = { "撞击" } })
  local logic = makeBattle({ bu, foe })

  eq(bu:checkSkillUsable("演示第五技·藤皇斩"), true, "第五技能有 PP 时就是可用的（不需要什么前提）")
  eq(bu:getPP("演示第五技·藤皇斩"), 5, "它的 PP 和普通技能一样是记在技能栏上的")

  local r = logic:useSkill{ source = bu, target = foe, skill = bu:getFifthSkill() }
  eq(r.used, true, "第五技能正常用出去")
  eq(bu:getPP("演示第五技·藤皇斩"), 4, "用一次扣一点 PP（和普通技能同一条路径）")

  bu:usePP("演示第五技·藤皇斩", 4) -- 把剩下的 PP 用光
  local ok, reason = bu:checkSkillUsable("演示第五技·藤皇斩")
  eq(ok, false, "PP 用光之后第五技能就用不了了")
  eq(reason, S.Skill.Unusable.NO_PP, "原因也是『PP 已用完』——没有任何第五技能专属规则")

  bu:sealSkill("演示第五技·藤皇斩")
  eq(select(2, bu:checkSkillUsable("演示第五技·藤皇斩")), S.Skill.Unusable.SEALED,
    "被封印时同样是『sealed』")
end

do
  -- "问玩家要指令"时不会把不可用的技能列进候选，但会把**原因**一起发出去，
  -- 这样客户端能把技能摆成灰的并说明为什么。
  local bu = makePet("布布种子", {
    level = 50, skills = { "撞击", "背水一击", "被封印的演示技" },
    fifth = "演示第五技·藤皇斩",
  })
  local foe = makePet("小火猴", { level = 50, side = 1, seat = 2, skills = { "撞击" } })
  local logic = makeBattle({ bu, foe })
  logic.interactive = true

  -- 用 request_hook 走"真问"的那条路（它就地作答、不挂起），好看到候选清单
  local seen
  logic.request_hook = function(room, request) seen = request; return { skill = request.skills[1] } end
  eq(logic:askForAction(bu) ~= nil, true, "拿到了指令")
  check(seen ~= nil, "request_hook 收到了请求")

  local function why(name)
    return table.find(seen.unusable or {}, function(u) return u.name == name end)
  end

  eq(table.find(seen.skills, function(n) return n == "撞击" end) ~= nil, true, "能用的技能在候选里")
  eq(table.find(seen.skills, function(n) return n == "演示第五技·藤皇斩" end) ~= nil, true,
    "第五技能和普通技能一样进候选（它只是摆在另一个位上）")
  eq(table.find(seen.skills, function(n) return n == "背水一击" end), nil,
    "条件不满足的技能不在候选里")
  eq(why("背水一击").reason, S.Skill.Unusable.CONDITION, "但它连同原因一起发了出去")
  eq(why("被封印的演示技").reason, S.Skill.Unusable.FORBIDDEN, "usable = false 的原因也对")
  eq(seen.fifth, "演示第五技·藤皇斩", "另外告诉外面『第五技能是哪个』（纯粹给 UI 摆位）")

  -- 条件满足后它自己会回到候选里
  bu.hp = math.floor(bu.max_hp * 0.3)
  logic:askForAction(bu)
  eq(table.find(seen.skills, function(n) return n == "背水一击" end) ~= nil, true,
    "条件满足后『背水一击』出现在候选里")
  eq(why("背水一击"), nil, "也不再出现在不可用列表里")

  -- 无头降级（不 interactive、没 hook）也能问出指令
  local logic2 = makeBattle({ bu, foe })
  check(logic2:askForAction(bu) ~= nil, "无头模式下也能问出指令")

  -- interactive 但没 hook、又在协程外硬调：要给一句看得懂的报错
  local logic3 = makeBattle({ bu, foe })
  logic3.interactive = true
  local ok, err = pcall(function() logic3:askForAction(bu) end)
  eq(ok, false, "在协程外硬要挂起会报错")
  check(tostring(err):find("logic:start") ~= nil, "报错信息告诉你怎么改", err)
end

do
  -- 第五技能挂在时机上的钩子也会被登记进战局（registerPet 用的是 getAllSkills）
  local fifth_trigger_skill = S.Seer:createSkill{
    name = "测试_第五技带钩子",
    category = S.Skill.Status,
    triggers = {
      [S.SeerTiming.RoundEnd] = {
        priority = 0,
        on_trigger = function() return false end,
      },
    },
  }
  local bu = makePet("布布种子", { level = 50, skills = { "撞击" }, fifth = fifth_trigger_skill })
  local foe = makePet("小火猴", { level = 50, side = 1, seat = 2, skills = { "撞击" } })
  local logic = makeBattle({ bu, foe })

  local trig = logic:getTrigger("#测试_第五技带钩子_1_trig")
  check(trig ~= nil, "第五技能的时机触发器被登记了（否则第五技能的效果会静默失效）")
  eq(table.contains(logic.trigger_table[S.SeerTiming.RoundEnd] or {}, trig), true,
    "它挂在正确的时机上")
  eq(trig:isActorTrigger(bu, true), true, "归属判断认得出这是这只精灵的")
end

do
  -- 客户端点了一个现在用不出来的技能（PP 空了、被封印、条件不满足）时，
  -- 不能闷声不响地把这一回合跳过去——要把原因播出去，否则玩家会以为点了没反应。
  local bu = makePet("布布种子", {
    level = 50, side = 0, seat = 1, skills = { "撞击", "背水一击" },
  })
  local huo = makePet("小火猴", { level = 50, side = 1, seat = 2, skills = { "撞击" } })
  local logic, room = makeBattle({ bu, huo }, "reject-skill")
  logic.interactive = true

  -- 假玩家故意点"体力低于一半才能用"的背水一击
  logic.request_hook = function() return { skill = "背水一击" } end

  local move, _, reject = logic:askForAction(bu)
  eq(move, nil, "选了用不出来的技能 → 这一回合拿不到技能")
  eq(reject.name, "背水一击", "但知道玩家点的是哪个技能")
  eq(reject.reason, S.Skill.Unusable.CONDITION, "也带回了原因")

  -- 走到回合一览里：这条原因会跟着 NoAction 事件播出去
  local turn = S.GameEvent.Turn:create(S.Data.TurnData:create{
    round = 1, turn = 1, who = bu, move = nil, reject = reject, reason = "game_rule",
  }, room)
  logic:runEvent(turn)

  local no = table.find(room.notified, function(e) return e.type == "NoAction" end)
  check(no ~= nil, "播了一条『这回合没出手』")
  eq(no.skill, "背水一击", "事件里点明是哪个技能")
  eq(no.reason, S.Skill.Unusable.CONDITION, "带着原因")
  eq(no.text, S.Skill.UnusableText[S.Skill.Unusable.CONDITION], "还有给玩家看的提示语", no.text)

  -- 连一个能用的技能都没有时，也要说清楚
  local stuck = makePet("布布种子", { level = 50, side = 0, seat = 3, skills = { "撞击" } })
  local foe2 = makePet("小火猴", { level = 50, side = 1, seat = 4, skills = { "撞击" } })
  local logic2 = makeBattle({ stuck, foe2 }, "reject-all")
  stuck:sealSkill("撞击")
  local m2, _, r2 = logic2:askForAction(stuck)
  eq(m2, nil, "全部技能都用不了")
  eq(r2.reason, S.Skill.Unusable.NO_USABLE_SKILL, "原因是『没有可以使用的技能』")
end

-- ============================================================================
section("技能：spec 方式创建")

do
  local huo = S.Seer:getSkill("火花")
  eq(huo:getElement(), "火", "技能属性")
  eq(huo:isSpecial(), true, "火花是特殊攻击")
  eq(huo:isPhysical(), false, "火花不是物理攻击")
  eq(huo:getPower(), 40, "威力 40")
  eq(huo:getPP(), 25, "PP 25")
  eq(huo:getAccuracy(), 100, "命中率 100")
  eq(huo:getPriority(), 0, "先制度 0")
  eq(huo:getTarget(), "enemy", "目标是敌方单体")
  eq(huo:isDamaging(), true, "会造成伤害")
  eq(#huo.effects, 1, "火花带了 1 个效果 spec")

  local su = S.Seer:getSkill("先制突击")
  eq(su:getPriority(), 1, "先制突击的先制度是 1")
  eq(su:hasTag(S.Skill.Contact), true, "带 Contact 标签")
  eq(su:hasTag(S.Skill.SureHit), false, "不带必中标签")

  local xu = S.Seer:getSkill("蓄能")
  eq(xu:isStatus(), true, "蓄能是属性技")
  eq(xu:isDamaging(), false, "属性技不造成伤害")
  eq(xu:getAccuracy(), nil, "命中率 <= 0 视为必中（返回 nil）")
  eq(xu:getTarget(), "self", "蓄能的目标是自己")

  local bu = makePet("布布种子", { level = 50, skills = { "撞击" } })
  local jj = S.Seer:getSkill("藤鞭")
  eq(jj:getElement(bu), "草", "技能写了属性就用技能的")
  local zj = S.Seer:getSkill("撞击")
  eq(zj:getElement(bu), "普通", "撞击写的是普通系")
  local unnamed = S.Skill:new{ name = "无属性测试技" }
  eq(unnamed:getElement(bu), "草", "技能没写属性时取使用者本属性")
end

do
  -- 骨架：主技能 + 各时机子对象
  local sk = S.Seer:getSkill("茂盛")
  local skel = sk:getSkeleton()
  eq(skel ~= nil, true, "能拿到技能骨架")
  eq(skel.name, "茂盛", "骨架名")
  eq(#skel.effects, 2, "骨架造出了 2 个对象（主技能 + 1 个时机子对象）")
  eq(#skel.effect_spec_list, 1, "spec 里声明了 1 条 triggers")
  eq(sk:hasTag(S.Skill.Ability), true, "特性标签透传到主技能")
  eq(sk.related_skills[1].timing, S.SeerTiming.HpChanged, "子对象挂在 HpChanged 时机上")
  eq(sk.related_skills[1].priority, 0, "子对象的优先级（必发特性写 0，不会被拿去问玩家）")
end

do
  local ok, err = pcall(function()
    return S.Skill:new{ name = "" }
  end)
  eq(ok, false, "空名字的技能会被拒绝")
  check(tostring(err):find("name") ~= nil, "报错信息里指明了是 name 的问题", err)

  local ok2 = pcall(function()
    return makePet("布布种子", { level = 5, skills = { "根本没有这个技能" } })
  end)
  eq(ok2, false, "带一个不存在的技能会立刻报错（而不是等到战斗里才炸）")
end

-- ============================================================================
section("效果：类型、概率、持续回合、叠层")

do
  local ok, err = pcall(function()
    return S.Effect:new{ kind = "不存在的类型" }
  end)
  eq(ok, false, "未注册的效果类型会报错")
  check(tostring(err):find("registerKind") ~= nil, "报错信息提示要用 registerKind", err)
  eq(S.Effect.kinds.damage.name, "伤害", "内置效果类型 damage 已注册")
  eq(S.Effect.kinds.status.name, "异常状态", "内置效果类型 status 已注册")
  eq(S.Effect.kinds.modifier.name, "数值修正", "内置效果类型 modifier 已注册")
end

do
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })

  -- 固定伤害是立即结算的
  local hp = huo.hp
  local eff = S.Effect:create({ kind = "damage", value = 30 }, bu, huo)
  eq(eff:apply(logic, { source = bu, target = huo }), true, "伤害效果生效")
  eq(huo.hp, hp - 30, "目标正好掉 30 血")
  eq(eff.applied, true, "效果被标记为已生效")

  -- 概率 0 的效果不会生效
  local eff0 = S.Effect:create({ kind = "damage", value = 50, probability = 0 }, bu, huo)
  eq(eff0:apply(logic, { source = bu, target = huo }), false, "概率 0 的效果不生效")
  eq(huo.hp, hp - 30, "不生效时目标体力不变")

  -- 回血
  local healed = S.Effect:create({ kind = "heal", value = 12 }, bu, huo)
  eq(healed:apply(logic, { source = bu, target = huo }), true, "回复效果生效")
  eq(huo.hp, hp - 30 + 12, "回了 12 血")

  -- 能力等级变化（作用在自己身上）
  local stat = S.Effect:create({ kind = "stat", target = "self", stages = { sp_attack = 2 } }, huo, bu)
  eq(stat:apply(logic, { source = huo, target = bu }), true, "能力变化效果生效")
  eq(huo:getStatStage("sp_attack"), 2, "使用者特攻 +2")
  eq(bu:getStatStage("sp_attack"), 0, "没打到不该打的人身上")
end

do
  -- 异常状态：挂上去之后每大回合末掉血。
  -- 它就是"弱化类印记"：行为写在印记自己的**被动触发器**里(core/mark/status.lua)，
  -- 战局一行状态相关的代码都不用有。
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })

  local eff = S.Effect:create({ kind = "status", status = "poison", probability = 100 }, huo, bu)
  eq(eff:apply(logic, { source = huo, target = bu }), true, "中毒效果生效")
  eq(bu:hasStatus("poison"), true, "目标身上有中毒状态")
  eq(#bu:getMark("poison").triggers > 0, true, "印记自带被动触发器（不再靠战局装固定处理器）")
  eq(bu:getMark("poison").source, huo, "状态记下了来源")

  -- 回合末掉 max_hp / 8
  local expected = math.max(1, math.floor(bu.max_hp / 8))
  local hp = bu.hp
  logic:endRound()
  eq(hp - bu.hp, expected, ("回合末按最大体力的 1/8 掉血（%d）"):format(expected))

  -- 解除之后立刻不再掉血（状态只有一份真相，不存在"触发器残留"）
  eq(logic:removeMark(bu, "poison", "test"), true, "解除中毒")
  local hp2 = bu.hp
  logic:endRound()
  eq(bu.hp, hp2, "解除后回合末不再掉血")
end

do
  -- 概率类状态（麻痹）：行动有 block_chance 的概率失败
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "paralysis-seed")
  logic:applyMark{ target = huo, mark = "paralysis" }
  eq(huo:hasStatus("paralysis"), true, "挂上麻痹")

  local prevented = 0
  for _ = 1, 50 do
    if logic:beginAction(huo, S.Seer:getSkill("撞击")) then prevented = prevented + 1 end
  end
  check(prevented > 0, ("麻痹有时会让行动失败（50 次里 %d 次）"):format(prevented), prevented)
  check(prevented < 50, "但不是每次都失败", prevented)

  -- block_all 类状态（睡眠/冰冻/害怕）则是"完全无法行动"
  local bu2, huo2 = makeStandardPets()
  local logic2 = makeBattle({ bu2, huo2 })
  logic2:applyMark{ target = huo2, mark = "sleep" }
  eq(logic2:beginAction(huo2, S.Seer:getSkill("撞击")), true, "睡眠中无法行动")
  logic2:applyMark{ target = huo2, mark = "freeze" }
  eq(logic2:beginAction(huo2, S.Seer:getSkill("撞击")), true, "冰冻中无法行动")

  -- 状态到期会自己消失（睡眠 1~3 回合）
  local bu3, huo3 = makeStandardPets()
  local logic3 = makeBattle({ bu3, huo3 }, "sleep-turns")
  logic3:applyMark{ target = huo3, mark = "sleep" }
  check(huo3:getMark("sleep").turns ~= nil, "睡眠带了持续回合数", huo3:getMark("sleep").turns)
  for _ = 1, 5 do logic3:endRound() end
  eq(huo3:hasStatus("sleep"), false, "几个回合后睡眠自然结束")
end

do
  -- 烧伤：回合末掉血，并且物理攻击威力减半
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  logic:applyMark{ target = huo, mark = "burn" }

  local plain = (function()
    local bu_x, huo_x = makeStandardPets()
    local logic_x = makeBattle({ bu_x, huo_x }, logic.seed)
    return logic_x:damage{ source = huo_x, target = bu_x, power = 80, category = S.Skill.Physical }.damage
  end)()
  local burned = logic:damage{ source = huo, target = bu, power = 80, category = S.Skill.Physical }
  check(burned.damage < plain, ("烧伤让物理攻击威力减半（%d -> %d）"):format(plain, burned.damage), burned.damage)
end

do
  -- 概率判定用 logic 的确定性随机数发生器
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "probability-seed")
  local hits = 0
  for i = 1, 200 do
    local eff = S.Effect:create({ kind = "damage", value = 1, probability = 50 }, bu, huo)
    eff.name = "#prob_" .. i -- 避免叠层
    if eff:apply(logic, { source = bu, target = huo }) then hits = hits + 1 end
    huo.hp = huo.max_hp -- 复位，避免被打死
  end
  check(hits > 60 and hits < 140, ("50%% 概率长期命中率落在合理区间（%d/200）"):format(hits), hits)
end

do
  -- 持续回合：3 回合后自动过期
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  local eff = S.Effect:create({ kind = "modifier", duration = 3, target = "self",
    extra = { timing = "DetermineDamage", apply = function() return false end } }, bu, bu)
  eq(eff:apply(logic, { source = bu, target = bu }), true, "持续效果生效")
  eq(eff.remaining, 3, "剩余 3 回合")
  eq(#eff.triggers, 1, "注册了 1 个时机触发器")
  eq(eff:tick(logic), false, "第 1 次递减没过期")
  eq(eff.remaining, 2, "剩余 2 回合")
  eff:tick(logic)
  eq(eff:tick(logic), true, "第 3 次递减过期")
  eq(#bu:getEffects(), 0, "过期后从精灵身上摘掉")
end

do
  -- 叠层：同一个印记再挂一次是叠层，而不是各挂一份（默认 max_stacks = 1，也就是不叠）
  local bu2, huo2 = makeStandardPets()
  local logic2 = makeBattle({ bu2, huo2 })

  -- 先用一个"可叠"的印记来说明机制（战局自带的那些默认都不叠）
  S.Mark.register("test_stack", {
    name = "测试可叠印记", desc = "最多 3 层", mark_type = S.Mark.TYPE.BUFF, max_stacks = 3,
  })
  local m1 = logic2:applyMark{ target = bu2, mark = "test_stack" }
  eq(m1.stacks, 1, "初始 1 层")
  local m2 = logic2:applyMark{ target = bu2, mark = "test_stack" }
  eq(m2, m1, "再挂一次拿到的是同一个印记实例")
  eq(m1.stacks, 2, "叠到 2 层")
  eq(#bu2:getMarks(), 1, "精灵身上只有一份印记")

  -- 不可叠的（默认 max_stacks = 1）再挂还是 1 层
  logic2:applyMark{ target = bu2, mark = "poison" }
  logic2:applyMark{ target = bu2, mark = "poison" }
  eq(bu2:getMark("poison").stacks, 1, "默认不叠层：再中一次还是 1 层")
end

do
  -- modifier：挂在时机上改数值（演示包的"荆棘护体"就是一个）
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })

  local before = logic:damage{ source = huo, target = bu, power = 80, category = S.Skill.Physical }
  local plain = before.damage
  check(plain > 0, "先打一下记下基准伤害", plain)

  local eff = S.Effect:create({
    kind = "modifier", duration = 3, target = "self",
    extra = {
      timing = "DetermineDamage",
      apply = function(effect_self, data)
        if data.target ~= effect_self.target_pet then return false end
        data.damage = math.max(1, math.floor(data.damage * 0.5))
        return false
      end,
    },
  }, bu, bu)
  eq(eff:apply(logic, { source = bu, target = bu }), true, "减伤效果生效")

  local after = logic:damage{ source = huo, target = bu, power = 80, category = S.Skill.Physical }
  check(after.damage < plain, ("减半效果在 DetermineDamage 时机生效（%d -> %d）")
    :format(plain, after.damage), after.damage)
  eq(after.damage, math.max(1, math.floor(plain / 2)), "正好减半")
end

-- ============================================================================
section("事件：优先级、打断、次数、refresh")

do
  -- 优先级：越大越先被问到
  local bu, huo = makeStandardPets()
  local order = {}
  local function mk(name, priority, tag)
    return makeTriggerSkill(name, S.SeerTiming.RoundEnd, {
      priority = priority,
      on_trigger = function() table.insert(order, tag) return false end,
    })
  end
  local low = mk("测试_低优先", 1, "low")
  local high = mk("测试_高优先", 5, "high")
  local mid = mk("测试_中优先", 3, "mid")

  bu:setSkills{ low, mid, high }
  local logic = makeBattle({ bu, huo })
  logic:endRound()
  eq(table.concat(order, ","), "high,mid,low", "触发顺序按优先级降序")

  -- 同优先级按名字升序（本项目为保证确定性所做的一处加强）
  local order2 = {}
  local function mk2(name, tag)
    return makeTriggerSkill(name, S.SeerTiming.RoundEnd, {
      priority = 2,
      on_trigger = function() table.insert(order2, tag) return false end,
    })
  end
  local b_skill = mk2("测试_同优_B", "B")
  local a_skill = mk2("测试_同优_A", "A")
  local bu2, huo2 = makeStandardPets()
  bu2:setSkills{ b_skill, a_skill }
  local logic2 = makeBattle({ bu2, huo2 })
  logic2:endRound()
  eq(table.concat(order2, ","), "A,B", "同优先级按名字升序（不看注册顺序）")
end

do
  -- 打断：on_trigger 返回 true 之后，后面的触发者不再被问到
  local bu, huo = makeStandardPets()
  local called = {}
  local first = makeTriggerSkill("测试_打断者", S.SeerTiming.RoundEnd, {
    priority = 5,
    on_trigger = function() table.insert(called, "first") return true end,
  })
  local second = makeTriggerSkill("测试_被挡住的", S.SeerTiming.RoundEnd, {
    priority = 1,
    on_trigger = function() table.insert(called, "second") return false end,
  })
  bu:setSkills{ first, second }
  local logic = makeBattle({ bu, huo })
  logic:endRound()
  eq(table.concat(called, ","), "first", "高优先级返回 true 之后，低优先级不再发动")
end

do
  -- breakCheck：伤害被防止之后，后面的时机不该再问
  local bu, huo = makeStandardPets()
  local seen = {}
  local function watcher(name, event_klass, priority)
    return makeTriggerSkill(name, event_klass, {
      priority = priority,
      on_trigger = function() table.insert(seen, name) return false end,
    })
  end
  local pre = watcher("测试_伤害前", S.SeerTiming.PreDamage, 5)
  local deter = watcher("测试_定数值", S.SeerTiming.DetermineDamage, 4)
  local dam = watcher("测试_伤害后", S.SeerTiming.Damaged, 3)
  -- 这个触发器在"伤害开始算"时把伤害整个防止掉
  local preventer = makeTriggerSkill("测试_防止伤害", S.SeerTiming.PreDamage, {
    priority = 10,
    on_trigger = function(self, event, target, pet, data)
      data:preventDamage()
      return false
    end,
  })
  bu:setSkills{ pre, deter, dam, preventer }
  local logic = makeBattle({ bu, huo })

  local r = logic:damage{ source = huo, target = bu, power = 50, category = S.Skill.Physical }
  eq(r.damage, 0, "伤害被防止，实际伤害是 0")
  eq(r.prevented, true, "结果里标了 prevented")
  eq(bu.hp, bu.max_hp, "目标一点血没掉")
  eq(table.find(seen, "测试_定数值"), nil, "防止伤害后不再走 DetermineDamage")
  eq(table.find(seen, "测试_伤害后"), nil, "防止伤害后不再走 Damaged")
end

do
  -- 次数上限：trigger_times 决定单精灵单时机内最多发动几次
  local bu, huo = makeStandardPets()
  local count = 0
  local sk = makeTriggerSkill("测试_限三次", S.SeerTiming.RoundEnd, {
    priority = 1,
    trigger_times = function() return 3 end,
    on_trigger = function() count = count + 1 return false end,
  })
  bu:setSkills{ sk }
  local logic = makeBattle({ bu, huo })
  logic:endRound()
  eq(count, 3, "trigger_times = 3 时同一时机内发动 3 次")

  -- 默认只发动 1 次
  local count2 = 0
  local sk2 = makeTriggerSkill("测试_默认一次", S.SeerTiming.RoundEnd, {
    priority = 1,
    on_trigger = function() count2 = count2 + 1 return false end,
  })
  local bu2, huo2 = makeStandardPets()
  bu2:setSkills{ sk2 }
  local logic2 = makeBattle({ bu2, huo2 })
  logic2:endRound()
  eq(count2, 1, "不写 trigger_times 时默认只发动 1 次")
end

do
  -- 锁定技（priority <= 0）不问玩家；正优先级会问
  local bu, huo = makeStandardPets()
  local compulsory = makeTriggerSkill("测试_锁定的", S.SeerTiming.RoundEnd, {
    priority = 0,
    on_trigger = function() return false end,
  })
  bu:setSkills{ compulsory }
  local logic, room = makeBattle({ bu, huo })
  logic:endRound()
  local asked_for_compulsory = table.find(room.asked, function(a)
    for _, c in ipairs(a.params.choices or {}) do
      if c == "#测试_锁定的_1_trig" then return true end
    end
    return false
  end)
  eq(asked_for_compulsory, nil, "锁定技（priority 0）不询问玩家")

  -- 正优先级必须问玩家
  local bu2, huo2 = makeStandardPets()
  local optional = makeTriggerSkill("测试_可选的", S.SeerTiming.RoundEnd, {
    priority = 1,
    on_trigger = function() return false end,
  })
  bu2:setSkills{ optional }
  local logic2, room2 = makeBattle({ bu2, huo2 })
  logic2:endRound()
  check(#room2.asked > 0, "正优先级会通过 askToChoice 询问玩家", #room2.asked)
  local choices_ok = false
  for _, a in ipairs(room2.asked) do
    for _, c in ipairs(a.params.choices or {}) do
      if c == "#测试_可选的_1_trig" then choices_ok = true end
    end
  end
  eq(choices_ok, true, "询问的选项里带着触发者的名字")
end

do
  -- refresh 阶段：early 在触发之前，late 在触发之后
  local bu, huo = makeStandardPets()
  local log = {}
  local sk = makeTriggerSkill("测试_刷新顺序", S.SeerTiming.RoundEnd, {
    priority = 1,
    can_refresh = function() return true end,
    on_refresh = function() table.insert(log, "refresh") end,
    on_trigger = function() table.insert(log, "trigger") return false end,
  })
  bu:setSkills{ sk }
  -- 只放一只精灵，环上只有它自己，顺序才好断言
  local logic = makeBattle({ bu })
  logic:endRound()
  eq(table.concat(log, ","), "refresh,trigger", "early refresh 在触发之前；late_refresh 为假时触发后不再 refresh")

  -- late_refresh 的 refresh 要排到触发之后
  local bu2, huo2 = makeStandardPets()
  local log2 = {}
  local sk2 = makeTriggerSkill("测试_晚刷新", S.SeerTiming.RoundEnd, {
    priority = 1,
    late_refresh = true,
    can_refresh = function() return true end,
    on_refresh = function() table.insert(log2, "refresh") end,
    on_trigger = function() table.insert(log2, "trigger") return false end,
  })
  bu2:setSkills{ sk2 }
  local logic2 = makeBattle({ bu2 })
  logic2:endRound()
  eq(table.concat(log2, ","), "trigger,refresh", "late_refresh 的 refresh 在触发之后")

  -- refresh/触发都是"每只参战精灵各来一轮"：两只见习时 refresh 会跑两次
  local bu3, huo3 = makeStandardPets()
  local log3 = {}
  local sk3 = makeTriggerSkill("测试_两只刷新", S.SeerTiming.RoundEnd, {
    priority = 1,
    can_refresh = function() return true end,
    on_refresh = function(self, event, target, pet) table.insert(log3, "refresh:" .. pet.name) end,
    on_trigger = function(self, event, target, pet) table.insert(log3, "trigger:" .. pet.name) return false end,
  })
  bu3:setSkills{ sk3 }
  local logic3 = makeBattle({ bu3, huo3 })
  logic3:endRound()
  eq(table.concat(log3, ","),
    "refresh:布布种子,refresh:小火猴,trigger:布布种子",
    "每只参战精灵各走一轮（环上的每一只都会被问到）")
end

do
  -- 事件 id 递增 + 事件流被记录下来（回放要用）
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  local n0 = logic.current_timing_id
  logic:endRound()
  check(logic.current_timing_id > n0, "时机编号在递增", logic.current_timing_id)
  check(#logic.event_log > 0, "事件流里有记录", #logic.event_log)
  local entry = logic.event_log[1]
  check(entry.name ~= nil and entry.id ~= nil, "事件流记录的字段够用（id/name/data）", entry.name)
  -- 嵌套触发也要正确（RoundEnd 里中毒掉血会再触发一串伤害时机）
  local ids = {}
  for _, e in ipairs(logic.event_log) do table.insert(ids, e.id) end
  eq(#ids, #logic.event_log, "每条事件都有编号")
end

do
  -- 嵌套触发：回合末的中毒伤害本身也是一条完整的伤害链
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  S.Effect:create({ kind = "status", status = "burn" }, huo, bu):apply(logic, { source = huo, target = bu })
  logic.event_log = {}
  logic:endRound()
  local names = table.map(logic.event_log, function(e) return e.name end)
  check(table.contains(names, "RoundEnd"), "回合末时机在事件流里")
  check(table.contains(names, "PreDamage"), "回合末掉血触发了伤害链（嵌套时机）")
  check(table.contains(names, "Damaged"), "伤害链走完整了")
  -- 缩进正确：嵌套的事件是在 RoundEnd 的 exec 里发生的
  eq(names[1], "RoundEnd", "RoundEnd 是第一条（它先执行，嵌套的伤害链跟在后面）")
end

do
  -- 全局触发者（global = true）不属于任何精灵，环上每只精灵都会被问到它。
  -- 但**要不要发动**由 can_trigger 决定：
  --   * 不写 can_trigger 时用默认实现，它要求"受动者就是当前这只精灵"，
  --     而回合末这类时机的受动者只有一个，所以默认只发动一次；
  --   * 想每只精灵都发动（场地/天气类效果）就在 can_trigger 里自己放行。
  local bu, huo = makeStandardPets()
  local default_hits = 0
  local sk = makeTriggerSkill("测试_全局默认", S.SeerTiming.RoundEnd, {
    priority = 0,
    global = true,
    on_trigger = function() default_hits = default_hits + 1 return false end,
  })
  bu:setSkills{ sk }
  local logic = makeBattle({ bu, huo })
  logic:endRound()
  eq(default_hits, 1, "全局触发者用默认 can_trigger 时只发动一次（受动者只有一个）")

  local each_hits = 0
  local sk2 = makeTriggerSkill("测试_全局每只", S.SeerTiming.RoundEnd, {
    priority = 0,
    global = true,
    can_trigger = function() return true end,
    on_trigger = function() each_hits = each_hits + 1 return false end,
  })
  local bu2, huo2 = makeStandardPets()
  bu2:setSkills{ sk2 }
  local logic2 = makeBattle({ bu2, huo2 })
  logic2:endRound()
  eq(each_hits, 2, "can_trigger 放行后，全局触发者对每只精灵各发动一次")
end

-- ============================================================================
section("属性克制")

do
  eq(S.Element.getMultiplier("草", { "水" }), 2, "草打水是 2 倍")
  eq(S.Element.getMultiplier("草", { "火" }), 0.5, "草打火是 0.5 倍")
  eq(S.Element.getMultiplier("电", { "地面" }), 0, "电打地面免疫")
  eq(S.Element.getMultiplier("水", { "水", "飞行" }), 0.5, "双属性相乘（水打水/飞行 = 0.5 × 1）")
  eq(S.Element.getMultiplier("草", { "水", "飞行" }), 1, "双属性相乘（草打水/飞行 = 2 × 0.5 = 1）")
  eq(S.Element.getMultiplier("龙", { "普通" }), 1, "表里没写的组合按 1 倍")
  eq(S.Element.getMultiplier("未知属性", { "水" }), 1, "没登记的攻击属性按 1 倍")
  eq(S.Element.getMultiplier(nil, { "水" }), 1, "属性为 nil 时按 1 倍")
  eq(S.Element.describe(2), "效果拔群", "倍率描述")
  eq(S.Element.describe(0), "没有效果", "免疫描述")
  eq(S.Element.isImmune(0), true, "isImmune 认得 0")
end

do
  -- 用图鉴导出的表整表替换（证明"数据与机制分家"）
  local backup = S.Element.MULTIPLIERS
  S.Element.loadTable({ ["测试属性"] = { ["水"] = 3 } })
  eq(S.Element.getMultiplier("测试属性", { "水" }), 3, "整表替换后立刻生效")
  eq(S.Element.getMultiplier("草", { "水" }), 1, "旧表被完全替换掉了")
  S.Element.MULTIPLIERS = backup
  eq(S.Element.getMultiplier("草", { "水" }), 2, "换回原表")
end

-- ============================================================================
section("伤害结算")

do
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })

  -- 1) 固定伤害：不吃克制、不吃暴击
  local r1 = logic:damage{ source = huo, target = bu, fixed = 40 }
  eq(r1.damage, 40, "固定伤害就是 40")

  -- 2) 克制倍率体现在结果里
  local r2 = logic:damage{ source = bu, target = huo, skill = S.Seer:getSkill("水枪") }
  check(r2.damage > 0, "水枪能打出伤害", r2.damage)

  -- 3) 克制倍率会记在结果里（打自己来观察：草打草 = 0.5 倍）
  local grass_on_grass = logic:damage{ source = bu, target = bu, skill = S.Seer:getSkill("藤鞭") }
  eq(grass_on_grass.effectiveness, 0.5, "草打草的克制倍率是 0.5")

  -- 4) 本系加成：技能属性和精灵本属性相同才吃 STAB
  local huo_fire = logic:damage{ source = huo, target = bu, power = 60, element = "火" }
  eq(huo_fire.stab, true, "火系精灵用火属性技能吃本系加成")
  local huo_water = logic:damage{ source = huo, target = bu, power = 60, element = "水" }
  eq(huo_water.stab, false, "火系精灵用水属性技能不吃本系加成")
  local bu_grass = logic:damage{ source = bu, target = bu, power = 60, element = "草" }
  eq(bu_grass.stab, true, "草系精灵用草属性技能吃本系加成")
  check(huo_fire.damage > huo_water.damage, "同样条件本系打得更疼（1.5 倍）", huo_fire.damage)

  -- 5) 属性技不造成伤害
  local status_dmg = logic:damage{
    source = bu, target = huo, skill = S.Seer:getSkill("蓄能"),
  }
  eq(status_dmg.damage, 0, "属性技不造成伤害")

  -- 6) 伤害把目标打死 → 触发倒下时机 + 通知
  local r6 = logic:damage{ source = huo, target = bu, fixed = bu.hp }
  eq(bu:isFainted(), true, "致命伤害让目标倒下")
  eq(r6.fainted, true, "结果里标了 fainted")
  local faint_notice = table.find(logic.room.notified, function(n) return n.type == "PetFainted" end)
  check(faint_notice ~= nil, "倒下会通过 notifyPlayers 通知 C++（§5.4 的边界）")
end

do
  -- 倒下会清空身上的状态与能力等级
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  logic:applyMark{ target = bu, mark = "poison" }
  bu:setStatStage("attack", 3)
  logic:damage{ source = huo, target = bu, fixed = bu.hp }
  eq(bu:hasStatus("poison"), false, "倒下后异常状态被清空")
  eq(bu:getStatStage("attack"), 0, "倒下后能力等级被清空")
end

do
  -- 一方全倒 → 结束这一局
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  eq(logic.game_over, nil, "刚开始没有结束")
  logic:damage{ source = huo, target = bu, fixed = bu.hp }
  eq(logic.game_over, true, "一方全倒后这一局结束")
  eq(logic.winner, 1, "获胜方是火系那边（side = 1）")
  local over = table.find(logic.room.notified, function(n) return n.type == "GameOver" end)
  check(over ~= nil, "结束会通知 C++ 去结算战绩（Lua 不碰数据库）")
  eq(over.reason, "all_fainted", "结束原因是全员倒下")
end

-- ============================================================================
section("完整出手：useSkill 走完使用→命中→伤害→效果")

do
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })

  local hp = huo.hp
  local r = logic:useSkill{ source = bu, target = huo, skill = S.Seer:getSkill("藤鞭") }
  eq(r.used, true, "技能用出去了")
  eq(r.missed, false, "100 命中的技能不会打空")
  check(r.damage > 0, "打出了伤害", r.damage)
  eq(hp - huo.hp, r.damage, "掉血量与结果一致")
end

do
  -- 附带效果会真的生效：麻痹粉命中时 100% 让对方麻痹。
  -- 注意麻痹粉命中率是 75，会打空，所以要允许重试——**打空时绝对不能有附加效果**，
  -- 这一点顺便一起验证。
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  local powder = S.Seer:getSkill("麻痹粉")

  local applied = false
  local miss_seen = false
  for _ = 1, 40 do
    logic:removeMark(huo, "paralysis", "test")
    local r = logic:useSkill{ source = bu, target = huo, skill = powder }
    if r.missed then
      miss_seen = true
      eq(huo:hasStatus("paralysis"), false, "打空时不挂任何附加效果")
    elseif huo:hasStatus("paralysis") then
      applied = true
      break
    end
  end
  eq(applied, true, "命中时麻痹粉让对手麻痹了")
  check(miss_seen, "75 命中的技能在 40 次里确实会打空", miss_seen)
end

do
  -- 麻痹会让行动被掐掉（block_chance = 25，用确定性种子总能撞上一次）
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "paralysis-seed")
  logic:applyMark{ target = huo, mark = "paralysis" }
  local prevented_count = 0
  for i = 1, 50 do
    logic.turn = 0
    if logic:beginAction(huo, S.Seer:getSkill("撞击")) then
      prevented_count = prevented_count + 1
    end
  end
  check(prevented_count > 0, ("麻痹有时会让行动失败（50 次里 %d 次）"):format(prevented_count), prevented_count)
  check(prevented_count < 50, "但不是每次都失败", prevented_count)
end

do
  -- 睡眠是"完全无法行动"
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  logic:applyMark{ target = huo, mark = "sleep" }
  eq(logic:beginAction(huo, S.Seer:getSkill("撞击")), true, "睡眠中无法行动")
end

do
  -- 换精灵/接战局：registerPet 把技能与特性的触发器挂进战局
  local bu, huo = makeStandardPets()
  bu:setSkills{ S.Seer:createSkill{
    name = "测试_接战局",
    category = S.Skill.Status,
    triggers = {
      [S.SeerTiming.RoundEnd] = {
        priority = 0,
        on_trigger = function() return false end,
      },
    },
  } }
  local logic = makeBattle({ bu, huo })
  local trig_name = "#测试_接战局_1_trig"
  check(logic:getTrigger(trig_name) ~= nil, "技能的子触发器能被按名字取回（Timing:exec 需要）")
  eq(logic.dynamic_triggers[trig_name], nil, "技能来源的触发器走全局技能表，不进 dynamic_triggers")
  eq(table.contains(logic.trigger_table[S.SeerTiming.RoundEnd] or {}, logic:getTrigger(trig_name)), true,
    "触发器被挂到了正确的时机上")

  -- 摘掉之后就不在表里了
  logic:unregisterPet(bu)
  eq(table.contains(logic.trigger_table[S.SeerTiming.RoundEnd] or {}, logic:getTrigger(trig_name)), false,
    "unregisterPet 把触发器摘掉了")
end

-- ============================================================================
section("真实 spec 的端到端：演示包的『茂盛』特性")

do
  -- 前面所有事件测试用的都是现造的测试技。这里验证**真实数据包里的写法**也能跑通：
  -- 演示包里『茂盛』是个特性（种族自带），挂在 HpChanged 时机上，条件写的是
  -- "自己掉到 1/3 体力以下"。它的 on_trigger 会打一条日志，所以用日志来观察。
  local old_sink, old_level = S.Log.sink, S.Log.min_level

  local function watch()
    local captured = {}
    S.Log.sink = function(level, msg) table.insert(captured, msg) end
    S.Log.min_level = "info"
    return captured
  end
  local function unwatch()
    S.Log.sink, S.Log.min_level = old_sink, old_level
    S.Log.min_level = "critical"
  end

  local captured = watch()
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  -- 打到 1/3 以下但没打死
  logic:damage{ source = huo, target = bu, fixed = math.floor(bu.max_hp * 0.75) }
  local bloom = table.find(captured, function(m) return m:find("茂盛") ~= nil end)
  unwatch()
  check(bloom ~= nil, "体力掉到 1/3 以下时特性发动了", #captured)
  check(bu:getHpRatio() < 1 / 3, "此时体力确实低于 1/3", bu:getHpRatio())

  -- 体力还高的时候不该发动
  captured = watch()
  local bu2, huo2 = makeStandardPets()
  local logic2 = makeBattle({ bu2, huo2 })
  logic2:damage{ source = huo2, target = bu2, fixed = 5 }
  local bloom2 = table.find(captured, function(m) return m:find("茂盛") ~= nil end)
  unwatch()
  eq(bloom2, nil, "体力高于 1/3 时特性不发动")

  -- 特性是种族自带的，不需要玩家配技能
  eq(bu:getAbility().name, "茂盛", "特性来自种族定义（不占技能格）")
end

-- ============================================================================
section("确定性（架构文档 §2.3）")

do
  --- 跑一整局，把每一步的体力记下来
  local function playOut(seed)
    local bu, huo = makeStandardPets()
    local logic = makeBattle({ bu, huo }, seed)
    local trace = {}
    local skills = { "藤鞭", "撞击", "水枪", "撞击" }
    for i = 1, 6 do
      local skill_name = skills[(i - 1) % #skills + 1]
      local sk = S.Seer:getSkill(skill_name)
      logic:useSkill{ source = bu, target = huo, skill = sk }
      logic:useSkill{ source = huo, target = bu, skill = S.Seer:getSkill("火花") }
      logic:endRound()
      table.insert(trace, ("%d/%d"):format(bu.hp, huo.hp))
      if bu:isFainted() or huo:isFainted() then break end
    end
    return table.concat(trace, "|"), logic
  end

  local a, logic_a = playOut("same-seed")
  local b = playOut("same-seed")
  eq(a, b, "同一个种子跑两遍，每一步体力完全一致（可回放）")

  local c = playOut("different-seed")
  check(a ~= c, "不同种子会跑出不同结果（说明随机真的在起作用）", c)

  -- 事件流也能用来复盘
  check(#logic_a.event_log > 10, "事件流记录了足够多的步骤", #logic_a.event_log)
  local kinds = {}
  for _, e in ipairs(logic_a.event_log) do kinds[e.name] = true end
  check(kinds["DetermineDamage"], "事件流里有伤害定值时机")
end

do
  -- 随机数发生器本身的行为
  local r1, r2 = S.Rng:new(12345), S.Rng:new(12345)
  local same = true
  for _ = 1, 100 do
    if r1:random(1, 1000) ~= r2:random(1, 1000) then same = false end
  end
  eq(same, true, "同种子的随机序列完全一致")

  local st = r1:getState()
  local v1 = r1:random(1, 100000)
  r1:setState(st)
  eq(r1:random(1, 100000), v1, "导出/恢复状态后序列能接上（存档要用的）")

  eq(S.Rng:new(1):chance(0), false, "概率 0 恒不中")
  eq(S.Rng:new(1):chance(100), true, "概率 100 恒中")
  eq(S.Rng:new(1):chance(nil), true, "概率 nil 视为必定")

  -- chance 在边界值上不能消耗随机数，否则改一个概率值会让整局后续错位
  local r3 = S.Rng:new(7)
  r3:chance(0)
  r3:chance(100)
  local r4 = S.Rng:new(7)
  eq(r3:random(1, 1000000), r4:random(1, 1000000),
    "边界概率（0/100）不消耗随机数，不会打乱后续序列")
end

-- ============================================================================

-- ============================================================================
section("standard 包：雷伊 / 盖亚 与「效果拼装」的技能")

do
  -- 标准包是多文件合并出来的（skills.lua + species.lua），要确认两半都在
  local lei = S.Seer:getSpecies("雷伊")
  local gaiya = S.Seer:getSpecies("盖亚")
  check(lei ~= nil, "雷伊在种族表里")
  check(gaiya ~= nil, "盖亚在种族表里")
  eq(lei.elements[1], "电", "雷伊是电系")
  eq(gaiya.elements[1], "战斗", "盖亚是战斗系")
  eq(S.Seer.species_by_id[70], lei, "图鉴编号按图鉴登记（雷伊 70）")
  eq(lei.base_stats.speed, gaiya.base_stats.speed, "两只真实速度一样（都是 105）")
  check(gaiya.base_stats.attack > lei.base_stats.attack, "盖亚物攻更高（119 vs 108）")
  check(lei.base_stats.sp_attack > gaiya.base_stats.sp_attack, "雷伊特攻更高（101 vs 96）")

  -- 纯效果拼装的技能：一张表 = 一个对象，**不走骨架**
  local skill = S.Seer:getSkill("电击光束")
  check(skill ~= nil, "电击光束在技能表里")
  eq(skill:getSkeleton(), nil, "纯效果技能没有骨架（这就是「主要靠 effect 拼装」）")
  eq(#skill.related_skills, 0, "也没有拆出一堆子对象")
  eq(#skill.effects, 1, "它有一个效果 spec")

  -- 带时机钩子的（特性）才走骨架、才有子对象
  local ability = S.Seer:getSkill("静电庇护")
  check(ability:getSkeleton() ~= nil, "特性有骨架（它挂在时机上）")
  check(S.Seer:getSkill("#静电庇护_1_trig") ~= nil, "特性拆出了时机子对象")

  -- 第五技能是个单独的技能对象，能按名字查
  check(S.Seer:getSkill("元气电光球") ~= nil, "第五技能在技能表里")
end

do
  -- 造一只雷伊：技能栏 4 个普通技能 + 第五技能
  local lei = makePet("雷伊", {
    level = 50, side = 0, seat = 1,
    ivs = { hp = 31, sp_attack = 31, speed = 31 },
    evs = { sp_attack = 252, speed = 198 },
    nature = "胆小",
    skills = { "抓", "电击光束", "充电", "惊雷切" },
    fifth = "元气电光球",
  })
  eq(lei.species.name, "雷伊", "种族解析对了")
  eq(#lei:getSkills(), 4, "四个普通技能")
  eq(lei:getFifthSkill().name, "元气电光球", "第五技能单独挂着")
  eq(lei:getAbility().name, "静电庇护", "特性来自种族")
  eq(lei.elements ~= nil, false, "Pet 上没有 elements 这个字段（属性在 species 上）")
  eq(lei.species.elements[1], "电", "属性从种族上读")

  -- 第五技能**没有**专属的使用条件：它和普通技能一样，只看 PP / 封印 / spec 的 usable。
  -- （需求上明确过：赛尔号的第五技能一样有 PP，机制上和普通技能没区别。）
  eq(lei:canUseSkill("元气电光球"), true, "第五技能有 PP 就能用，不需要先满足什么前提")
  eq(lei:canUseSkill("电击光束"), true, "普通技能照常可用")
  eq(lei:getPP("元气电光球"), 10, "它自己的 PP")
  lei.skill_set.pp["元气电光球"] = 0
  eq(select(2, lei:checkSkillUsable("元气电光球")), S.Skill.Unusable.NO_PP,
    "PP 用完之后，理由是『PP 已用完』——和普通技能同一套理由")
end

do
  -- 效果拼装：吸取（按**结果**算的效果，要读 ctx.damage）
  local drain_skill = S.Seer:createSkill{
    name = "测试_吸取", element = "电", category = S.Skill.Special,
    power = 60, pp = 10, accuracy = 100,
    effects = { { kind = "drain", ratio = 0.5 } },
  }
  local lei = makePet("雷伊", { level = 50, side = 0, seat = 1,
    skills = { drain_skill }, evs = { sp_attack = 100 } })
  local gaiya = makePet("盖亚", { level = 50, side = 1, seat = 2, skills = { "叩击" } })
  local logic = makeBattle({ lei, gaiya }, "drain-test")

  lei:takeDamage(80)                     -- 先掉点血，好观察回复
  local before_hp = lei.hp
  local r = logic:useSkill{ source = lei, target = gaiya, skill = drain_skill }

  check(r.damage > 0, ("吸取技打出了伤害（%d）"):format(r.damage), r.damage)
  check(lei.hp > before_hp, ("吸取把自己治了（%d -> %d）"):format(before_hp, lei.hp), lei.hp)
  -- ratio = 0.5：回复量应当是伤害的一半（四舍五入向下）
  eq(lei.hp - before_hp, math.max(1, math.floor(r.damage * 0.5)), "正好回了伤害的一半")
end

do
  -- 反作用力：自己承担造成伤害的一部分
  local recoil_skill = S.Seer:createSkill{
    name = "测试_舍身", element = "战斗", category = S.Skill.Physical,
    power = 120, pp = 5, accuracy = 100,
    effects = { { kind = "recoil", ratio = 0.34 } },
  }
  local gaiya = makePet("盖亚", { level = 50, side = 1, seat = 2,
    skills = { recoil_skill }, evs = { attack = 252 } })
  local lei = makePet("雷伊", { level = 50, side = 0, seat = 1, skills = { "抓" } })
  local logic = makeBattle({ lei, gaiya }, "recoil-test")

  local hp0 = gaiya.hp
  local r = logic:useSkill{ source = gaiya, target = lei, skill = recoil_skill }
  local self_lost = hp0 - gaiya.hp
  check(self_lost > 0, ("日月皆伤让自己也掉血了（%d）"):format(self_lost), self_lost)
  check(self_lost < r.damage, "自己掉的比打出去的少（1/3 左右）", self_lost)
  local expected = math.max(1, math.floor(r.damage * 0.34))
  eq(self_lost, expected, "比例对得上（1/3，向下取整）")
end

do
  -- 连击：打 N 次、每次独立结算
  local gaiya = makePet("盖亚", { level = 50, side = 1, seat = 2,
    skills = { "连环摔投" }, evs = { attack = 252 } })
  local lei = makePet("雷伊", { level = 50, side = 0, seat = 1, skills = { "抓" } })
  -- 用固定次数方便断言：不改技能，直接看连击是不是真的打了多次
  local logic = makeBattle({ lei, gaiya }, "multi-hit")
  local scope = S.GameEvent.Turn

  local before = countLog(logic, "game_event", "GameEvent.Damage")
  local r = logic:useSkill{ source = gaiya, target = lei, skill = S.Seer:getSkill("连环摔投") }
  local after = countLog(logic, "game_event", "GameEvent.Damage")

  local resolved = after - before
  check(resolved >= 2, ("连击打出了多次独立伤害结算（%d 次）"):format(resolved), resolved)
  -- 注意：**实际结算次数可能少于报出的连击次数**——目标中途倒下时，剩下几下就不打了。
  -- 这是刻意的（死人不用再挨打），所以断言写成"不超过"。
  check(resolved <= r.data.damage_result.hits,
    ("实际结算 %d 次 ≤ 报出的连击次数 %d"):format(resolved, r.data.damage_result.hits),
    r.data.damage_result.hits)
  if not lei:isFainted() then
    eq(resolved, r.data.damage_result.hits, "目标没倒的话，结算次数就等于连击次数")
  end
end

do
  -- 解除异常 + 按比例回复（神经修复）
  local cure_skill = S.Seer:createSkill{
    name = "测试_康复", category = S.Skill.Status, pp = 10, target = "self",
    effects = {
      { kind = "cure", target = "self" },
      { kind = "heal", target = "self", ratio = 1 / 3 },
    },
  }
  local gaiya = makePet("盖亚", { level = 50, side = 1, seat = 2, skills = { cure_skill } })
  local lei = makePet("雷伊", { level = 50, side = 0, seat = 1, skills = { "抓" } })
  local logic = makeBattle({ lei, gaiya }, "cure-test")

  logic:applyMark{ target = gaiya, mark = "poison" }
  gaiya:takeDamage(math.floor(gaiya.max_hp * 0.6))
  eq(gaiya:hasStatus("poison"), true, "先让它中个毒")
  local hp0 = gaiya.hp

  logic:useSkill{ source = gaiya, target = lei, skill = cure_skill }

  eq(gaiya:hasStatus("poison"), false, "康复技解除了异常状态")
  local healed = gaiya.hp - hp0
  check(healed > 0, ("并且回了血（%d）"):format(healed), healed)
  eq(healed, math.max(1, math.floor(gaiya.max_hp / 3)), "回复量是最大体力的 1/3")
end

do
  -- 特性的归属：**只有拥有它的那只精灵才会触发**
  -- （这是 demo 里抓到的真 bug：盖亚的特性曾经给雷伊加了攻击）
  local lei = makePet("雷伊", { level = 50, side = 0, seat = 1, skills = { "抓" } })
  local gaiya = makePet("盖亚", { level = 50, side = 1, seat = 2, skills = { "叩击" } })
  local logic = makeBattle({ lei, gaiya }, "ability-owner")

  -- 把双方都打到半血以下：只有盖亚的特性 不灭战意 该发动
  lei:takeDamage(math.floor(lei.max_hp * 0.6))
  gaiya:takeDamage(math.floor(gaiya.max_hp * 0.6))

  local before_lei = lei:getStatStage("attack")
  local before_gaiya = gaiya:getStatStage("attack")
  -- 掉血时机要在流程里跑：直接调 damage（走完整流程）来触发
  logic:damage{ source = gaiya, target = lei, fixed = 1 }
  logic:damage{ source = lei, target = gaiya, fixed = 1 }

  eq(lei:getStatStage("attack"), before_lei, "雷伊的攻击等级没被盖亚的特性改动")
  check(gaiya:getStatStage("attack") > before_gaiya,
    ("盖亚自己的特性发动了（攻击 %d -> %d）"):format(before_gaiya, gaiya:getStatStage("attack")),
    gaiya:getStatStage("attack"))
end

do
  -- 事件顺序：先播报"使用了"，再报伤害，最后才报倒下
  local lei = makePet("雷伊", { level = 50, side = 0, seat = 1, skills = { "电击光束" } })
  local gaiya = makePet("盖亚", { level = 50, side = 1, seat = 2, skills = { "叩击" } })
  gaiya.hp = 1   -- 一击必倒，好观察顺序
  local logic = makeBattle({ lei, gaiya }, "order-test")

  logic:useSkill{ source = lei, target = gaiya, skill = S.Seer:getSkill("电击光束") }

  local types = table.map(logic.room.notified, function(e) return e.type end)
  local i_use = table.indexOf(types, "UseSkill")
  local i_dmg = table.indexOf(types, "Damage")
  local i_faint = table.indexOf(types, "PetFainted")
  check(i_use ~= nil and i_dmg ~= nil and i_faint ~= nil, "三件事都通知了",
    table.concat(types, ","))
  check(i_use < i_dmg, "「使用了技能」在伤害之前（客户端要先把动画放出来）",
    table.concat(types, ","))
  check(i_dmg < i_faint, "伤害在倒下之前（不然玩家先看到人躺下、后看到伤害数字）",
    table.concat(types, ","))
end

do
  -- 技能使用条件的统一判断：不可用的技能在流程里会被拦下，而且原因要能带出去
  local lei = makePet("雷伊", { level = 50, side = 0, seat = 1, skills = { "抓" } })
  local gaiya = makePet("盖亚", { level = 50, side = 1, seat = 2, skills = { "叩击" } })
  local logic = makeBattle({ lei, gaiya }, "usable-test")
  local sealed = S.Seer:getSkill("抓")

  lei:sealSkill("抓")
  eq(lei:canUseSkill(sealed), false, "被封印的技能不可用")
  local r = logic:useSkill{ source = lei, target = gaiya, skill = sealed }
  eq(r.used, false, "流程里也被拦下了")
  eq(r.prevent_reason, S.Skill.Unusable.SEALED, "原因是『被封印』")
  eq(gaiya.hp, gaiya.max_hp, "对手没掉血")
  local notice = table.find(logic.room.notified, function(e) return e.type == "SkillUnusable" end)
  check(notice ~= nil, "并且通知了外面「技能用不出来」")
  eq(notice.reason, S.Skill.Unusable.SEALED, "播报里也带着原因（客户端要显示它）")

  -- 标准包里的第五技能没有任何专属条件：有 PP 就能用，PP 空了就不能用
  local lei2 = makePet("雷伊", { level = 50, side = 0, seat = 3, skills = { "抓" },
                                 fifth = "元气电光球" })
  eq(lei2:checkSkillUsable("元气电光球"), true, "第五技能有 PP 时直接可用（没有隐藏前提）")
  lei2.skill_set.pp["元气电光球"] = 0
  eq(select(2, lei2:checkSkillUsable("元气电光球")), S.Skill.Unusable.NO_PP,
    "PP 用完就只剩『PP 已用完』这一个理由")
end

-- ============================================================================
section("印记：异常状态与增益印记共用一个基类")

do
  -- 枚举与分类：官方的分法就是"控制类/弱化类异常状态"
  eq(S.Mark.TYPE.CONTROL, "control", "控制类")
  eq(S.Mark.TYPE.WEAKEN, "weaken", "弱化类")
  eq(S.Mark.TYPE.BUFF, "buff", "增益类")
  eq(S.Mark.TYPE_NAME[S.Mark.TYPE.CONTROL], "控制类", "类型有中文名")

  local paralysis = S.Mark.defs.paralysis
  eq(paralysis.name, "麻痹", "麻痹注册过")
  eq(paralysis.mark_type, S.Mark.TYPE.CONTROL, "麻痹是控制类（和官方描述一致）")
  eq(S.Mark.isStatusKey("paralysis"), true, "控制类算异常状态")
  eq(S.Mark.isStatusKey("poison"), true, "弱化类也算异常状态")
  eq(S.Mark.isStatusKey("shield"), false, "增益印记不算异常状态")

  -- 每个印记都有 name / desc / 类型 / 触发器（用户要求的那几项）
  for key, def in pairs(S.Mark.defs) do
    check(type(def.name) == "string" and def.name ~= "", ("印记 %s 有 name"):format(key))
    check(type(def.desc) == "string", ("印记 %s 有 desc"):format(key))
  end
  check(S.Mark.defs.poison.desc:find("1/8") ~= nil, "中毒的描述写了掉多少血", S.Mark.defs.poison.desc)
  eq(S.Mark.defs.sleep.min_turns, 1, "睡眠的最短回合")
  eq(S.Mark.defs.sleep.max_turns, 3, "睡眠的最长回合")
end

do
  -- 控制类印记真的能掐掉行动
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "control-mark")
  logic:applyMark{ target = huo, mark = "freeze" }
  eq(logic:beginAction(huo, nil), true, "冰冻让它动不了")

  -- 弱化类印记在回合末掉血（数值来自 def，改数据不用改代码）
  local bu2, huo2 = makeStandardPets()
  local logic2 = makeBattle({ bu2, huo2 }, "weaken-mark")
  logic2:applyMark{ target = bu2, mark = "poison" }
  local expected = math.max(1, math.floor(bu2.max_hp / 8))
  local hp = bu2.hp
  logic2:endRound()
  eq(hp - bu2.hp, expected, ("中毒按 def 里的 1/8 掉血（%d）"):format(expected))
end

do
  -- 增益印记：护盾抵挡一次攻击后自己消失
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "shield-mark")
  logic:applyMark{ target = bu, mark = "shield" }
  eq(bu:hasMark("shield"), true, "护盾挂上了")

  local r = logic:damage{ source = huo, target = bu, fixed = 50 }
  eq(r.damage, 0, "护盾把这一下挡掉了")
  eq(bu.hp, bu.max_hp, "一点血没掉")
  eq(bu:hasMark("shield"), false, "护盾用完就消失了")

  local r2 = logic:damage{ source = huo, target = bu, fixed = 50 }
  eq(r2.damage, 50, "第二下就挡不住了")
end

do
  -- 包可以注册自己的印记（standard 包里的 dot30：3 回合每回合 30 点固定伤害）
  check(S.Mark.defs.dot30 ~= nil, "standard 包注册了自己的印记")
  eq(S.Mark.defs.dot30.mark_type, S.Mark.TYPE.WEAKEN, "它是弱化类")

  local bu = makePet("雷伊", { level = 50, side = 0, seat = 1, skills = { "抓" } })
  local huo = makePet("盖亚", { level = 50, side = 1, seat = 2, skills = { "末日宣告" } })
  local logic = makeBattle({ bu, huo }, "dot30")
  -- 注意：技能必须是这只精灵**带着的**——带不着的技能 PP 是 0，直接在硬性检查那里被拦掉
  eq(huo:canUseSkill("末日宣告"), true, "盖亚带着末日宣告")
  logic:useSkill{ source = huo, target = bu, skill = S.Seer:getSkill("末日宣告") }

  if bu:hasMark("dot30") then
    local mark = bu:getMark("dot30")
    eq(mark.turns, 3, "持续 3 回合")
    bu.hp = bu.max_hp      -- 先回满：不然"掉 30"会被血量上限截断，看不出是不是真的 30
    local hp = bu.hp
    logic:endRound()
    eq(hp - bu.hp, 30, ("每回合末额外掉 30 点（实际 %d）"):format(hp - bu.hp))
    eq(bu:getMark("dot30").turns, 2, "回合数递减")
  else
    check(false, "末日宣告应该挂上 dot30 印记")
  end
end

-- ============================================================================
section("效果的复用：一个 kind + 参数，拼出不同的技能")

do
  -- 消强 / 解弱：同一个 kind，只有 side 参数不同
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "clear-stages")

  bu:setStatStage("attack", 2)
  bu:setStatStage("defense", 1)
  eq(bu:getStatStage("attack"), 2, "先给自己强化起来")

  -- 消强：清掉对方的「提升」
  local clear_up = S.Effect:create({ kind = "clear_stages", side = "up" }, huo, bu)
  clear_up:apply(logic, { source = huo, target = bu })
  eq(bu:getStatStage("attack"), 0, "消强把+2 清掉了")
  eq(bu:getStatStage("defense"), 0, "防御的+1 也清了")

  -- 解弱：清掉自己的「下降」
  bu:setStatStage("speed", -2)
  eq(bu:getStatStage("speed"), -2, "先给自己挂个下降")
  local clear_down = S.Effect:create({ kind = "clear_stages", side = "down", target = "self" }, bu, huo)
  clear_down:apply(logic, { source = bu, target = huo })
  eq(bu:getStatStage("speed"), 0, "解弱把自己的下降清掉了")

  -- 官方技能表里"消强"出现了两次（日月皆伤/石破天惊），只有威力不同——这就是复用
  local a = S.Seer:getSkill("日月皆伤")
  local b = S.Seer:getSkill("石破天惊")
  eq(a.effects[1].kind, b.effects[1].kind, "两个技能用的是同一个效果 kind")
  eq(a.effects[1].side, b.effects[1].side, "参数也一样")
  check(a:getPower() ~= b:getPower(), "只有威力不同（140 / 150）")
end

do
  -- "消除成功则令对方 XX"：then_effects 把两个模板串起来
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "then-effects")

  -- 自定义一个"消强成功就让对方烧伤"的效果，参数换成冻伤就是另一个技能
  local spec = {
    kind = "clear_stages", side = "up",
    then_effects = { { kind = "mark", mark = "burn", probability = 100 } },
    condition = function(effect, ctx)
      -- 只在对方身上真的有提升时才发动（"消除成功"）
      local target = ctx.target
      if target == nil then return false end
      for _, field in ipairs(S.Pet.STAGE_FIELDS) do
        if target:getStatStage(field) > 0 then return true end
      end
      return false
    end,
  }

  huo:setStatStage("attack", 1)
  S.Effect:create(spec, bu, huo):apply(logic, { source = bu, target = huo })
  eq(huo:getStatStage("attack"), 0, "提升被消除了")
  eq(huo:hasStatus("burn"), true, "而且成功附加了烧伤（then_effects 生效）")

  -- 换成冻伤，只改一个参数
  local bu2, huo2 = makeStandardPets()
  local logic2 = makeBattle({ bu2, huo2 }, "then-effects2")
  local spec2 = table.simpleClone(spec)
  spec2.then_effects = { { kind = "mark", mark = "frostbite", probability = 100 } }
  huo2:setStatStage("defense", 1)
  S.Effect:create(spec2, bu2, huo2):apply(logic2, { source = bu2, target = huo2 })
  eq(huo2:hasStatus("frostbite"), true, "换成冻伤还是同一段代码")

  -- 条件不满足时（对方没有提升）不该发动
  local bu3, huo3 = makeStandardPets()
  local logic3 = makeBattle({ bu3, huo3 }, "then-effects3")
  S.Effect:create(spec, bu3, huo3):apply(logic3, { source = bu3, target = huo3 })
  eq(huo3:hasStatus("burn"), false, "对方没有提升时，condition 挡住了整个效果")
end

do
  -- 增伤（官方 37/42/88）：条件 + 倍率，而且是**伤害之前**生效的
  local bu = makePet("雷伊", { level = 50, side = 0, seat = 1,
    skills = { "惊雷切" }, evs = { attack = 100 } })
  local huo = makePet("盖亚", { level = 50, side = 1, seat = 2, skills = { "叩击" } })
  local logic = makeBattle({ bu, huo }, "power-mod")

  eq(S.Effect.kinds.power_modifier.phase, "before", "增伤是前置效果（要在伤害算出来之前改威力）")

  -- 惊雷切：自身 HP 小于 1/2 时威力 ×2
  local skill = S.Seer:getSkill("惊雷切")
  bu.hp = bu.max_hp                       -- 满血：不增伤
  local full = logic:useSkill{ source = bu, target = huo, skill = skill }
  local hp_full = full.damage
  bu.hp = math.max(1, math.floor(bu.max_hp * 0.4))   -- 残血：触发增伤
  local low = logic:useSkill{ source = bu, target = huo, skill = skill }
  check(low.damage > hp_full, ("残血时威力翻倍，伤害更高（%d -> %d）")
    :format(hp_full, low.damage), low.damage)
end

do
  -- 附加固定伤害（官方 29/38/60）：本次伤害之外再打一笔
  local bu = makePet("雷伊", { level = 50, side = 0, seat = 1, skills = { "抓" } })
  local huo = makePet("盖亚", { level = 50, side = 1, seat = 2,
    skills = { "渗透劲" }, evs = { sp_attack = 100 } })
  local logic = makeBattle({ bu, huo }, "add-damage")

  local before = bu.hp
  logic:useSkill{ source = huo, target = bu, skill = S.Seer:getSkill("渗透劲") }
  local total = before - bu.hp

  -- 渗透劲本身威力只有 20，但额外附加 50 点固定伤害
  local plain = 0
  do
    local bu2 = makePet("雷伊", { level = 50, side = 0, seat = 1, skills = { "抓" } })
    local huo2 = makePet("盖亚", { level = 50, side = 1, seat = 2, skills = { "渗透劲" } })
    local logic2 = makeBattle({ bu2, huo2 }, "add-damage")
    local hp0 = bu2.hp
    logic2:damage{ source = huo2, target = bu2, power = 20,
      category = S.Skill.Special, element = "战斗" }
    plain = hp0 - bu2.hp
  end
  check(total > plain, ("附加伤害让总伤害更高（无附加 %d → 有附加 %d）"):format(plain, total), total)
  check(total >= plain + 50, "至少多打了 50 点", total)
end

do
  -- 连击（官方 31）：每次独立结算，所以减伤是逐下生效的
  local bu = makePet("雷伊", { level = 50, side = 0, seat = 1, skills = { "抓" } })
  local huo = makePet("盖亚", { level = 50, side = 1, seat = 2,
    skills = { "连环摔投" }, evs = { attack = 100 } })
  local logic = makeBattle({ bu, huo }, "combo-real")
  local n_before = countLog(logic, "game_event", "GameEvent.Damage")
  logic:useSkill{ source = huo, target = bu, skill = S.Seer:getSkill("连环摔投") }
  local n_after = countLog(logic, "game_event", "GameEvent.Damage")
  check(n_after - n_before >= 2, ("连环摔投打了多次（%d 次）"):format(n_after - n_before),
    n_after - n_before)
end

-- ============================================================================
section("流程事件：GameEvent 基类与管理器")

do
  -- 基类的两个通用事件
  eq(S.GameEvent.Game ~= nil, true, "根事件 GameEvent.Game 存在")
  eq(S.GameEvent.ClearEvent ~= nil, true, "清场事件 GameEvent.ClearEvent 存在")
  eq(S.GameEvent.Game:isSubclassOf(S.GameEvent), true, "Game 是 GameEvent 的子类")
  eq(S.GameEvent.ClearEvent:isSubclassOf(S.GameEvent), true, "ClearEvent 是 GameEvent 的子类")

  -- 类型判断（含派生类）——本项目把它做成了显式函数，不靠 __eq 魔法
  eq(S.GameEvent.isType(S.GameEvent.Damage, S.GameEvent.Damage), true, "isType：自己等于自己")
  eq(S.GameEvent.isType(S.GameEvent.Damage, S.GameEvent.ChangeHp), false, "isType：不是同族就是 false")
  eq(S.GameEvent.isType(S.GameEvent.ClearEvent, S.GameEvent), true, "isType：派生类算基本类")
  eq(S.GameEvent.Damage:getBaseClass().name, "GameEvent.Damage",
    "getBaseClass：没有派生的类返回自己")

  -- 时机和流程事件是两套编号，各数各的
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  eq(logic.current_timing_id, 0, "时机编号从 0 起")
  eq(logic.current_event_id, 0, "流程事件编号从 0 起")
  eq(logic.game_event_stack.p, 0, "还没开始跑，事件栈是空的")
end

do
  -- prepare() 返回 true = 整个事件跳过（连栈都不进，main/clear/exit 都不会跑）
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })

  local Skipped = S.GameEvent:subclass("测试_被跳过的事件")
  function Skipped:prepare() return true end
  function Skipped:main() self.ran_main = true end
  function Skipped:clear() self.ran_clear = true end

  local ev = Skipped:create(nil, logic.room)
  local interrupted = logic:runEvent(ev)
  eq(interrupted, true, "prepare 返回 true 时 runEvent 报『已结束』")
  eq(ev.ran_main, nil, "被跳过的事件 main 不执行")
  eq(ev.ran_clear, nil, "被跳过的事件 clear 也不执行")
  eq(logic.game_event_stack.p, 0, "被跳过的事件不进栈")
  eq(logic.current_event_id, 0, "被跳过的事件不分配编号")
end

do
  -- breakEvent：打断自己。后面的代码不执行、exit 不执行，但 clear 一定会执行。
  -- 这是整套系统最微妙的一点：**"必须发生的事"要写在 clear 里**
  -- （因为被 kill 的事件协程会被直接 close，main 后半段和 exit 都作废）。
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })

  local Breakable = S.GameEvent:subclass("测试_会打断的事件")
  function Breakable:main()
    local logic = self.room.logic
    self.ran_main = true
    logic:breakEvent(false)
    self.after_break = true   -- 不该被执行到
  end
  function Breakable:clear() self.ran_clear = true end
  function Breakable:exit() self.ran_exit = true end

  local ev = Breakable:create(nil, logic.room)
  local interrupted, exec_ret = logic:runEvent(ev)
  eq(ev.ran_main, true, "打断之前的部分执行了")
  eq(ev.after_break, nil, "breakEvent 之后的代码不执行（协程被关掉了）")
  eq(ev.ran_exit, nil, "被打断的事件不执行 exit（照抄 freekill 的语义）")
  eq(ev.ran_clear, true, "但 clear 一定会执行——收尾只能放这里")
  eq(interrupted, true, "被打断的事件返回 interrupted = true")
  eq(exec_ret, false, "breakEvent 的参数就是 exec_ret")
  eq(logic.game_event_stack.p, 0, "跑完之后事件栈清空")
  eq(logic.cleaner_stack.p, 0, "清场栈也清空")
end

do
  -- 杀掉当前事件 → 时机只做 refresh 不做触发（两层事件的交叉语义）
  local bu, huo = makeStandardPets()
  local order = {}
  local sk = makeTriggerSkill("测试_被杀事件里的时机", S.SeerTiming.RoundEnd, {
    priority = 1,
    can_refresh = function() return true end,
    on_refresh = function() table.insert(order, "refresh") end,
    on_trigger = function() table.insert(order, "trigger") return false end,
  })
  bu:setSkills{ sk }
  local logic = makeBattle({ bu })

  local Killer = S.GameEvent:subclass("测试_杀掉自己的事件")
  function Killer:main()
    local lg = self.room.logic
    self.killed = true          -- 假装"这件事被终止一切结算了"
    lg:trigger(S.SeerTiming.RoundEnd, self.room.pets[1], S.Data.TurnData:create{ round = 1 })
  end

  logic:runEvent(Killer:create(nil, logic.room))
  eq(table.concat(order, ","), "refresh",
    "当前流程事件被 kill 时，时机只 refresh 不触发（照抄 core 的 refresh_only 逻辑）")
end

do
  -- 事件栈与 parent 链、end_id 区间
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })

  local Outer = S.GameEvent:subclass("测试_外层事件")
  local Inner = S.GameEvent:subclass("测试_内层事件")
  function Inner:main() self.room.logic:notify{ type = "inner_ran" } end
  function Outer:main()
    local lg = self.room.logic
    lg:notify{ type = "outer_before" }
    Inner:create(nil, self.room):exec()      -- 插一个子事件
    lg:notify{ type = "outer_after" }
  end

  local outer = Outer:create(nil, logic.room)
  logic:runEvent(outer)

  local notices = table.map(logic.room.notified, function(n) return n.type end)
  local before_idx = table.indexOf(notices, "outer_before")
  local inner_idx = table.indexOf(notices, "inner_ran")
  local after_idx = table.indexOf(notices, "outer_after")
  eq(before_idx < inner_idx and inner_idx < after_idx, true,
    "子事件插在外层事件中间执行（插进去、走完、再回来）")

  local inner_events = logic.event_recorder[S.GameEvent]
  check(#logic.all_game_events > 0, "事件都登记进 all_game_events 了", logic.current_event_id)
  eq(outer.parent, nil, "最外层事件没有父事件")
  check(outer.end_id > outer.id, ("外层事件的 end_id 包住了子事件（%d -> %d）")
    :format(outer.id, outer.end_id), outer.end_id)

  local damage_inside = outer:searchEvents(Inner, 5)
  eq(#damage_inside, 1, "searchEvents 能在区间里找到子事件")
  eq(outer:searchEvents(Inner, 5)[1].class.name, "测试_内层事件", "找到的类型正确")
  eq(outer:searchEvents(Inner, 1)[1] ~= nil, true, "n 参数限制条数（取 1 条）")
  -- 区间是闭区间 [id, end_id]（和 freekill 一致），所以查自己的类型会查到自己
  eq(#outer:searchEvents(Outer, 1), 1, "区间包含自己（闭区间 [id, end_id]）")
  eq(outer:searchEvents(Outer, 1)[1], outer, "查到的就是自己")
end

do
  -- pushEvent 的不变式：事件必须属于本战局
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  local bu2, huo2 = makeStandardPets()
  local logic2 = makeBattle({ bu2, huo2 })

  local foreign = S.GameEvent.ChangeHp:create(
    S.Data.HpChangedData:new{ who = bu2, num = -1 }, logic2.room)
  local ok, err = pcall(function() logic:pushEvent(foreign) end)
  eq(ok, false, "把别的战局的事件压进本战局会立刻报错（而不是静默错乱）")
  check(tostring(err):find("room") ~= nil, "报错信息指向 room 参数", err)
  eq(logic.game_event_stack.p, 0, "报错后栈没有被污染")
end

do
  -- 在协程外也能跑流程事件（runEvent 会自己起一个协程）
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  eq(coroutine.isyieldable(), false, "测试主体确实不在协程里")

  local hp = huo.hp
  local r = logic:damage{ source = bu, target = huo, fixed = 20 }
  eq(r.damage, 20, "协程外调用 logic:damage 也能正常结算")
  eq(huo.hp, hp - 20, "血量确实变了")
  eq(logic.game_event_stack.p, 0, "跑完之后事件栈是干净的")
  eq(logic.cleaner_stack.p, 0, "清场栈也是干净的")
end

-- ============================================================================
section("回合流程：Round / Turn / UseSkill")

do
  -- 先制度优先，然后比速度
  local slow_fast = makePet("布布种子", { level = 50, side = 0, seat = 1, skills = { "撞击" } })
  local fast = makePet("小火猴", { level = 50, side = 1, seat = 2, skills = { "撞击" } })
  -- 让 seat=2 的更快：给它灌满速度学习力（evs 是六项齐全的表，只改其中一项）
  fast.evs.speed = 255
  fast:recalcStats()
  check(fast.speed > slow_fast.speed, "构造出速度差",
    ("%d vs %d"):format(fast.speed, slow_fast.speed))

  local logic = makeBattle({ slow_fast, fast })
  local round = S.GameEvent.Round:create(S.Data.TurnData:create{ round = 0 }, logic.room)
  local order = round:buildTurnOrder()
  eq(#order, 2, "出手顺序里有两项")
  eq(order[1].who, fast, "速度快的先出手")
  eq(order[2].who, slow_fast, "速度慢的后出手")

  -- 先制度压倒速度：给慢的那只配一个先制技
  local priority_skill = S.Seer:createSkill{
    name = "测试_先制", category = S.Skill.Physical, power = 40, pp = 10,
    accuracy = 100, priority = 2,
  }
  slow_fast:setSkillSlot(1, priority_skill)
  local round2 = S.GameEvent.Round:create(S.Data.TurnData:create{ round = 1 }, logic.room)
  local order2 = round2:buildTurnOrder()
  eq(order2[1].who, slow_fast, "先制度高的先出手，哪怕速度慢")
end

do
  -- 跑完整局：两层事件都跑起来，胜负分出来
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "flow-e2e")
  eq(logic.round, 0, "还没开始跑，回合数是 0")

  local kind = logic:start()
  eq(kind, "finished", "logic:start() 跑到整局结束")
  eq(logic.game_over, true, "对局结束了")
  eq(logic.winner ~= nil, true, "分出了胜负")
  check(logic.round >= 1, "至少打了一个大回合", logic.round)
  eq(logic.game_event_stack.p, 0, "事件栈清空")
  eq(logic.cleaner_stack.p, 0, "清场栈清空")

  -- 流程事件（GameEvent）层
  eq(countLog(logic, "game_event", "GameEvent.Game"), 1, "根事件只跑了一个")
  eq(countLog(logic, "game_event", "GameEvent.Round"), logic.round, "每回合一个 Round 事件")
  check(countLog(logic, "game_event", "GameEvent.Turn") >= 2, "至少跑了两次行动",
    countLog(logic, "game_event", "GameEvent.Turn"))
  eq(countLog(logic, "game_event", "GameEvent.UseSkill"),
    countLog(logic, "game_event", "GameEvent.Turn"), "每次行动都用了一次技能")
  check(countLog(logic, "game_event", "GameEvent.Damage") >= 1, "至少造成了一次伤害")
  check(countLog(logic, "game_event", "GameEvent.ChangeHp") >= 1, "体力变化走的是 ChangeHp 流程事件")

  -- 时机（Timing）层
  eq(countLog(logic, "timing", "GameStartEvent"), 1, "对局开始只触发一次")
  eq(countLog(logic, "timing", "GameOverEvent"), 1, "对局结束只触发一次")
  eq(countLog(logic, "timing", "RoundStart"), logic.round, "每回合一次 RoundStart 时机")
  eq(countLog(logic, "timing", "RoundEnd"), logic.round, "每回合一次 RoundEnd 时机")
  eq(countLog(logic, "timing", "PetFainted") >= 1, true, "有人倒下了")
  eq(countLog(logic, "timing", "BeforeHpChanged") > 0, true, "每次体力变化都过了 BeforeHpChanged")

  -- 事件树的父子关系：这是"流程事件"和"时机"能接上的关键
  local dmg = logic.event_recorder[S.GameEvent.Damage][1]
  check(dmg:findParent(S.GameEvent.UseSkill) ~= nil, "伤害事件挂在一次技能使用里面")
  check(dmg:findParent(S.GameEvent.Turn) ~= nil, "技能使用挂在一次行动里面")
  check(dmg:findParent(S.GameEvent.Round) ~= nil, "行动挂在一个大回合里面")
  eq(dmg:findParent(S.GameEvent.Damage), nil, "include_self 默认 false，找不到自己")
  eq(dmg:findParent(S.GameEvent.Damage, true), dmg, "include_self = true 时能找到自己")

  -- 历史查询
  local round1 = logic.event_recorder[S.GameEvent.Round][1]
  local dmg_in_round1 = round1:searchEvents(S.GameEvent.Damage, 10)
  eq(#dmg_in_round1 >= 1, true, "能在第一回合的区间里查到伤害事件")
  local use_in_round1 = round1:searchEvents(S.GameEvent.UseSkill, 10)
  eq(#use_in_round1 >= 1, true, "也能查到技能使用事件")
  -- getCurrentEvent 在流程外是 nil；这里用区间查询替代（它们是等价的用法）
  eq(#round1:searchEvents(S.GameEvent.UseSkill, 1), 1, "n 限制生效")
end

do
  -- 倒下/被掐掉的行动：prepare 直接跳过，不触发 TurnStart/TurnEnd
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  logic:applyMark{ target = huo, mark = "sleep" }

  local turn = S.GameEvent.Turn:create(S.Data.TurnData:create{
    who = huo, move = S.Seer:getSkill("撞击"), reason = "test",
  }, logic.room)
  local skipped = logic:runEvent(turn)
  eq(skipped, true, "睡着的精灵这次行动被整个跳过")
  eq(countLog(logic, "timing", "TurnStart"), 0, "被跳过的行动不触发 TurnStart")
  eq(countLog(logic, "timing", "BeforeAction"), 1, "但『行动前』时机跑了（就是它掐掉的）")
  eq(logic.game_event_stack.p, 0, "跳过之后栈是干净的")
end

do
  -- 999 回合安全阀：打不完就判平局，别让服务器一直转
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "flow-valve")
  logic.round = 998
  logic:start()
  eq(logic.game_over, true, "触发了安全阀，对局结束")
  eq(logic.winner, nil, "平局（没有赢家）")
  eq(logic.round, S.BattleLogic.MAX_ROUNDS,
    "照 freekill：走到第 999 轮时判平局（不是真的打完 999 轮）")
end

-- ============================================================================
section("生命值流程：ChangeHp / Damage / Recover")

do
  -- changeHp 是唯一改 hp 的入口
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  local hp = bu.hp

  -- 满血时回血是"没意义的变化"，会被拦住（而且不产生事件）
  local full = logic:changeHp(bu, 999, "recover")
  eq(full, false, "满血时回血被拦住（没有意义的变化）")
  eq(bu.hp, bu.max_hp, "体力不会超过上限")
  eq(countLog(logic, "timing", "HpChanged"), 0, "没有意义的体力变化不触发 HpChanged")
  -- 注意 BeforeHpChanged **还是会跑**：它正是"判断这次变化有没有意义"的那个时机
  eq(countLog(logic, "timing", "BeforeHpChanged"), 1, "但仍然过了『体力变化前』时机")

  local before_count = countLog(logic, "timing", "BeforeHpChanged")
  local ok, data = logic:changeHp(bu, -30, "loseHp", "测试掉血")
  eq(ok, true, "changeHp 成功")
  eq(bu.hp, hp - 30, "体力真的掉了")
  eq(data.actual, -30, "data.actual 是**带符号**的真实变化量（掉血为负）")
  eq(countLog(logic, "timing", "BeforeHpChanged"), before_count + 1, "过了『体力变化前』时机")
  eq(countLog(logic, "timing", "HpChanged"), 1, "过了『体力变化后』时机")

  -- 回血走同一条路
  local ok2, data2 = logic:changeHp(bu, 10, "recover")
  eq(ok2, true, "回血也走 changeHp")
  eq(data2.actual, 10, "回了 10 点（带符号为正）")
  eq(countLog(logic, "timing", "HpChanged"), 2, "回血同样触发 HpChanged")

  -- 已经空血时继续掉血也拦得住
  logic:changeHp(bu, -99999, "damage")
  eq(bu.hp, 0, "体力下限是 0")
end

do
  -- 回复流程：满血时 Recover 事件在 prepare 阶段就被整个跳过
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  eq(logic:recover{ target = bu, num = 20 }, 0, "满血回复返回 0")
  eq(countLog(logic, "timing", "BeforeRecover"), 0, "满血时连 Recover 流程都不跑")
  eq(countLog(logic, "game_event", "GameEvent.Recover"), 0, "prepare 直接跳过，事件没进栈")

  bu:takeDamage(40)
  eq(logic:recover{ target = bu, num = 20 }, 20, "受伤后回复 20")
  eq(countLog(logic, "game_event", "GameEvent.Recover"), 1, "跑了一次 Recover 流程事件")
  eq(countLog(logic, "timing", "BeforeRecover"), 1, "过了『回复前』时机")
  eq(countLog(logic, "timing", "Recover"), 1, "过了『回复后』时机")

  local missing = bu.max_hp - bu.hp
  eq(logic:recover{ target = bu, num = 99999 }, missing,
    ("回复量按剩余体力截断（只回了缺的 %d）"):format(missing))
  eq(bu.hp, bu.max_hp, "回满之后不超上限")
end

do
  -- 伤害被防止：整条链被打断，DamageFinished 也不触发（freekill 语义）
  local bu, huo = makeStandardPets()
  local seen = {}
  local function watcher(name, timing_klass)
    return makeTriggerSkill(name, timing_klass, {
      priority = 5,
      on_trigger = function() table.insert(seen, name) return false end,
    })
  end
  local preventer = makeTriggerSkill("测试_防止伤害2", S.SeerTiming.PreDamage, {
    priority = 10,
    on_trigger = function(self, timing, target, pet, data)
      data:preventDamage()
      return false
    end,
  })
  bu:setSkills{
    preventer,
    watcher("测试_定数值2", S.SeerTiming.DetermineDamage),
    watcher("测试_伤害后2", S.SeerTiming.Damaged),
    watcher("测试_伤害结束2", S.SeerTiming.DamageFinished),
  }
  local logic = makeBattle({ bu, huo })

  local r = logic:damage{ source = huo, target = bu, power = 60, category = S.Skill.Physical }
  eq(r.damage, 0, "伤害被防止")
  eq(r.prevented, true, "结果标了 prevented")
  eq(bu.hp, bu.max_hp, "一点血没掉")
  eq(table.find(seen, "测试_定数值2"), nil, "被防止后不再走 DetermineDamage")
  eq(table.find(seen, "测试_伤害后2"), nil, "被防止后不再走 Damaged")
  eq(table.find(seen, "测试_伤害结束2"), nil,
    "被防止后连 DamageFinished 都不触发（整条流程被 breakEvent 掐掉）")
  eq(countLog(logic, "game_event", "GameEvent.ChangeHp"), 0, "没有体力变化事件（流程提前结束）")
end

do
  -- 防止"体力变化"（绕开伤害，直接拦 changeHp）
  local bu, huo = makeStandardPets()
  local blocker = makeTriggerSkill("测试_防止体力变化", S.SeerTiming.BeforeHpChanged, {
    priority = 10,
    on_trigger = function(self, timing, target, pet, data)
      if data.num < 0 then
        data.num = 0
        data.prevented = true
      end
      return false
    end,
  })
  bu:setSkills{ blocker }
  local logic = makeBattle({ bu, huo })

  local hp = bu.hp
  local r = logic:damage{ source = huo, target = bu, fixed = 50 }
  eq(r.damage, 0, "体力变化被拦住，伤害为 0")
  eq(bu.hp, hp, "血量没变")
  eq(countLog(logic, "timing", "HpChanged"), 0, "被拦住的体力变化不触发『变化后』时机")
end

do
  -- 倒下只有一条路径：任何来源的掉血都会走 PetFainted
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  logic:changeHp(bu, -bu.hp, "loseHp", "直接掉光")
  eq(bu:isFainted(), true, "掉光就倒下")
  eq(countLog(logic, "timing", "BeforePetFaint"), 1, "走了『倒下前』时机")
  eq(countLog(logic, "timing", "PetFainted"), 1, "走了『倒下』时机")
  local notice = table.find(logic.room.notified, function(n) return n.type == "PetFainted" end)
  check(notice ~= nil, "倒下会通知 C++")
end

do
  -- 状态伤害（中毒）也是同一套流程：Damage → ChangeHp → 倒下判断
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo })
  logic:applyMark{ target = bu, mark = "poison" }
  -- 把血调到刚好能被一次中毒打死
  bu.hp = math.max(1, math.floor(bu.max_hp / 8))
  logic:endRound()
  eq(bu:isFainted(), true, "中毒掉血把人打死了")
  eq(countLog(logic, "timing", "PetFainted"), 1, "状态伤害同样走倒下流程")
  eq(countLog(logic, "game_event", "GameEvent.ChangeHp") >= 1, true, "状态伤害也走 ChangeHp")
end

-- ============================================================================
section("挂起与恢复：Lua 等外部回话（架构文档 §5.3）")

do
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "interactive")
  logic.interactive = true   -- 真挂起，等外部回话

  local kind = logic:start()
  eq(kind, "request", "开局后立刻挂起，等玩家下指令")
  check(logic.pending_request ~= nil, "挂起时带着待办的请求")
  eq(logic.pending_request.kind, "AskForAction", "请求类型是『要指令』")
  eq(logic.pending_request.pet, 1, "先问 1 号位的精灵")
  check(#logic.pending_request.skills >= 1, "请求里带着可用的技能名", #logic.pending_request.skills)

  -- 外部（将来是 C++）把玩家的选择送回来
  local asked = 0
  local guard = 0
  while kind == "request" and guard < 200 do
    guard = guard + 1
    asked = asked + 1
    kind = logic:resume{ skill = logic.pending_request.skills[1], target = 2 }
  end

  eq(kind, "finished", "一路喂完指令之后，整局跑完")
  eq(logic.game_over, true, "对局结束")
  check(asked >= 2, ("每回合每只精灵各问一次（一共问了 %d 次）"):format(asked), asked)
  eq(logic.game_event_stack.p, 0, "事件栈清空")
end

do
  -- request_hook：无头模式就地作答，一步都不挂起
  local bu, huo = makeStandardPets()
  local room = makeRoom()
  room.pets = { bu, huo }
  local hook_calls = 0
  local logic = S.BattleLogic:new(room, {
    seed = "hook", actors = room.pets,
    request_hook = function(r, request)
      hook_calls = hook_calls + 1
      return { skill = request.skills[1] }
    end,
  })
  logic:registerAllPets()
  logic.interactive = true

  local kind = logic:start()
  eq(kind, "finished", "配了 request_hook 就不会挂起，一次跑到结束")
  check(hook_calls >= 2, ("hook 被调用了 %d 次"):format(hook_calls), hook_calls)
  eq(logic.pending_request, nil, "没有挂起中的请求")
  eq(logic.game_over, true, "对局正常结束")
end

-- ============================================================================
section("异常状态类：弱化类 / 控制类（mark/status.lua）")

do
  -- 枚举与模块：异常状态的键都在 Status.KEY 里，不再散字符串
  eq(S.Mark.Status.KEY.POISON, "poison", "中毒在枚举里")
  eq(S.Mark.Status.KEY.PARALYSIS, "paralysis", "麻痹在枚举里")
  eq(S.Mark.Status.KEY.FROSTBITE, "frostbite", "冻伤在枚举里")
  eq(S.Mark.Status.KEY_NAME.poison, "中毒", "枚举有中文名表")
  eq(S.Mark.Status.CLASS.WEAKEN, "weaken", "弱化类")
  eq(S.Mark.Status.CLASS.CONTROL, "control", "控制类")

  -- 类层次：Mark → StatusMark → (WeakenStatus | ControlStatus)
  check(S.StatusMark:isSubclassOf(S.Mark), "异常状态基类继承 Mark")
  check(S.WeakenStatus:isSubclassOf(S.StatusMark), "弱化类继承异常状态基类")
  check(S.ControlStatus:isSubclassOf(S.StatusMark), "控制类继承异常状态基类")
  check(S.BuffMark:isSubclassOf(S.Mark), "增益印记也继承 Mark")
  eq(S.Mark.classOf("poison"), S.WeakenStatus, "中毒该用弱化类的实例")
  eq(S.Mark.classOf("paralysis"), S.ControlStatus, "麻痹该用控制类的实例")
  eq(S.Mark.classOf("shield"), S.BuffMark, "护盾该用增益印记的实例")

  -- 枚举清单（注册顺序，确定性）。
  -- 注意 standard 包里还注册了一个弱化类印记 `dot30`，所以数量 ≥ 7，
  -- 这里只钉"核心那 7 个都在"。
  local keys = S.Mark.Status.list()
  check(#keys >= 7, ("异常状态有 %d 个（核心 7 个 + 包内注册的）"):format(#keys), #keys)
  local key_set = Util.array2hash(keys)
  for _, k in ipairs({ "paralysis", "sleep", "freeze", "fear",
                       "poison", "burn", "frostbite" }) do
    check(key_set[k] == true, ("核心异常状态 %s 注册过"):format(k))
  end
  eq(keys[1], "paralysis", "按注册顺序排列")
  eq(S.Mark.Status.is("poison"), true, "Status.is 认异常状态")
  eq(S.Mark.Status.is("shield"), false, "增益印记不是异常状态")
end

do
  -- 实例拿到的是**类别的子类**（不是光秃秃的 Mark）：
  -- 类别行为（掉多少血、几成概率动不了）都挂在子类上
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "status-class")

  local poison = logic:applyMark{ target = huo, mark = "poison", source = bu }
  check(poison:isInstanceOf(S.WeakenStatus), "中毒是弱化类实例")
  eq(poison:getClass(), "weaken", "getClass")
  eq(poison:getClassName(), "弱化类", "getClassName")
  eq(poison:isStatus(), true, "它算异常状态")
  eq(poison:isBuff(), false, "不是增益")

  -- 查询方法能直接单测，不用真打一回合
  eq(poison:getTurnEndDamage(), math.max(1, math.floor(huo.max_hp / 8)),
    "中毒每回合掉最大体力的 1/8")
  eq(poison:getAttackMultiplier(S.Skill.Physical), nil, "中毒不影响攻击威力")

  local burn = logic:applyMark{ target = huo, mark = "burn", source = bu }
  eq(burn:getTurnEndDamage(), math.max(1, math.floor(huo.max_hp / 16)), "烧伤掉 1/16")
  eq(burn:getAttackMultiplier(S.Skill.Physical), 0.5, "烧伤让物理伤害减半")
  eq(burn:getAttackMultiplier(S.Skill.Special), nil, "特殊伤害不受影响")

  -- 控制类：概率是数据；100% 的必不能动，0% 的必能动
  local para = logic:applyMark{ target = huo, mark = "paralysis", source = bu }
  check(para:isInstanceOf(S.ControlStatus), "麻痹是控制类实例")
  eq(para:getBlockChance(), 25, "麻痹的失手概率来自 def.block_chance")

  local sleep = logic:applyMark{ target = huo, mark = "sleep", source = bu }
  eq(sleep:getBlockChance(), 100, "睡眠没写 block_chance → 必不能动")
  eq(sleep:rollsActionBlock(logic), true, "必不能动")
end

do
  -- 加一个新的异常状态只要一张表：类别行为（掉血/掐行动）由类自动补上，
  -- 这正是"异常状态类写好一点"的目的——不用把同一段钩子抄第五遍
  S.Mark.register("测试_剧毒", {
    name = "测试剧毒",
    desc = "测试用弱化类异常状态，只在测试里注册",
    mark_type = S.Mark.TYPE.WEAKEN,
    turn_end_damage = { 1, 4 },
  })
  local def = S.Mark.defs["测试_剧毒"]
  check(def ~= nil, "注册成功")
  check(def.triggers[S.SeerTiming.RoundEnd] ~= nil, "弱化类默认的『回合末掉血』钩子自动补上了")
  eq(def.max_stacks, 1, "默认不叠加")

  -- 还能自己覆盖默认钩子（作者写的优先）
  S.Mark.register("测试_必中控制", {
    name = "测试必中控制",
    mark_type = S.Mark.TYPE.CONTROL,
    block_chance = 0,                       -- 0% = 永远动得了（用来测"不触发"）
  })
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "status-custom")
  local mark = logic:applyMark{ target = huo, mark = "测试_剧毒", source = bu }
  eq(mark:isStatus(), true, "自注册的状态也是异常状态")
  eq(mark:getTurnEndDamage(), math.max(1, math.floor(huo.max_hp / 4)), "数据说了算")
  eq(logic:cureStatus(huo, "测试_剧毒"), 1, "能被解除异常状态处理掉")

  local never = logic:applyMark{ target = huo, mark = "测试_必中控制", source = bu }
  eq(never:rollsActionBlock(logic), false, "block_chance = 0 时不会掐掉行动")

  -- 挂载/摘除钩子（封招、光环这类"挂上去要做事、摘掉要撤销"的印记要用）
  local hook_log = {}
  S.Mark.register("测试_带钩子的印记", {
    name = "测试带钩子的印记",
    mark_type = S.Mark.TYPE.BUFF,
    duration = 1,
    on_attach = function(m, lg, pet) table.insert(hook_log, "attach:" .. pet.seat) end,
    on_detach = function(m, lg, pet, reason) table.insert(hook_log, "detach:" .. tostring(reason)) end,
  })
  local m2 = logic:applyMark{ target = huo, mark = "测试_带钩子的印记", source = bu }
  eq(hook_log[1], "attach:" .. huo.seat, "on_attach 被调用了")
  logic:removeMark(huo, "测试_带钩子的印记", "expired")
  eq(hook_log[2], "detach:expired", "on_detach 拿到原因")
  eq(m2.pet, nil, "摘掉之后不再指向那只精灵")

  -- 实例私有数据：同一种印记挂在不同精灵身上可以带不同参数
  S.Mark.register("测试_带数据的印记", {
    name = "测试带数据的印记", mark_type = S.Mark.TYPE.BUFF,
  })
  local m3 = logic:applyMark{ target = huo, mark = "测试_带数据的印记", extra = { note = "甲" } }
  eq(m3.extra.note, "甲", "extra 传到了实例上")
  eq(m3:serialize().extra.note, "甲", "序列化里带着它")
end

-- ============================================================================
section("效果的注册点：核心内置 + 包内自造")

do
  -- 内置效果类型的清单（"有哪些效果可用"的目录）
  local builtin = S.Effect.kinds_builtin
  eq(#builtin, 12, "核心内置 12 种效果类型")
  eq(table.contains(builtin, "damage"), true, "伤害在里面")
  eq(table.contains(builtin, "mark"), true, "挂印记在里面")
  for _, key in ipairs(builtin) do
    check(S.Effect.kinds[key] ~= nil, ("目录里的 %s 确实注册过"):format(key))
  end

  -- 包内注册的新效果类型（lua/specs/standard/effects.lua）——
  -- 这就是"新效果写在哪里"的答案：写在包里，不改核心
  for _, key in ipairs({ "steal_stages", "hp_ratio_damage", "seal_skill", "endure" }) do
    local def = S.Effect.kinds[key]
    check(def ~= nil, ("包内效果 %s 注册成功"):format(key))
    check(type(def.name) == "string" and def.name ~= "", ("%s 有人可读的名字"):format(key))
  end
  eq(S.Effect.kinds.seal_skill.instant, false, "封招是持续型（挂到精灵身上）")
  eq(S.Effect.kinds.steal_stages.instant, true, "偷取是当场结算")

  -- 测试里也能现场注册一种：先注册，再造实例，就能用
  S.Effect.registerKind("测试_喊话", {
    name = "喊话（测试）",
    instant = true,
    validate = function(spec)
      if type(spec.value) ~= "string" then return false, "需要字符串 value" end
      return true
    end,
    on_apply = function(effect, pet, ctx)
      effect.logic:notify{ type = "Shout", pet = pet.seat, text = effect.value }
    end,
  })
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "effect-kind")
  local eff = logic:applyEffect(S.Effect:create({ kind = "测试_喊话", value = "你好" }, bu, huo))
  eq(eff, true, "现场注册的效果类型能用")
  local shout = table.find(logic.room.notified, function(e) return e.type == "Shout" end)
  check(shout ~= nil and shout.text == "你好", "它按 spec 里的参数做事", shout and shout.text)

  -- 没注册的类型要立刻报错（不是静静不生效）
  local ok, err = pcall(function() return S.Effect:create{ kind = "根本没有这个效果" } end)
  eq(ok, false, "未注册的效果类型会报错")
  check(tostring(err):find("registerKind") ~= nil, "报错里告诉你怎么注册", err)
end

-- ============================================================================
section("技能效果 vs 身上的回合类效果：同一个 Effect，两种寿命")

do
  -- 瞬时效果：算完就结束，不进 pet.effects
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "effect-life")
  local instant = S.Effect:create({ kind = "damage", value = 10 }, bu, huo)
  eq(instant:isPersistent(), false, "damage 是瞬时效果")
  logic:applyEffect(instant)
  eq(huo:hasEffect(instant.name), false, "瞬时效果不挂到精灵身上")

  -- 持续效果：挂进 pet.effects，之后每个大回合自己动
  local endure = S.Effect:create(
    { kind = "endure", duration = 3, target = "self" }, bu, bu)
  eq(endure:isPersistent(), true, "endure 是持续效果")
  logic:applyEffect(endure)
  eq(bu:hasEffect(endure.name), true, "持续效果挂在精灵身上（pet.effects 表）")
  eq(bu:countEffects(), 1, "计数")
  eq(bu:getEffectsByKind("endure")[1], endure, "能按类型筛出来")
  eq(bu:getEffects()[1].name, endure.name, "遍历按名字排序返回数组")

  -- 抵挡致死伤害：把"会打死人"的那一下压到只剩 1 点体力，然后用完即走
  local hp0 = bu.hp
  local lethal = logic:damage{ source = huo, target = bu, fixed = bu.hp + 500 }
  eq(bu.hp, 1, "被挡住了，只剩 1 点体力")
  eq(lethal.damage, hp0 - 1, "那一下被削成『打到剩 1 点』")
  eq(bu:hasEffect(endure.name), false, "挡完就自己摘掉了")

  -- 打不死的时候不消耗它
  bu.hp = math.floor(bu.max_hp * 0.8)
  local endure2 = S.Effect:create({ kind = "endure", duration = 3, target = "self" }, bu, bu)
  logic:applyEffect(endure2)
  logic:damage{ source = huo, target = bu, fixed = 5 }
  eq(bu:hasEffect(endure2.name), true, "没被打死就留着")
  eq(bu:removeEffectsByKind("endure"), 1, "按类型清理")
  eq(bu:countEffects(), 0, "清干净了")
end

do
  -- 封招：包内注册的**持续型效果**，和上一轮做的"能不能用"直接打通
  local lei = makePet("雷伊", { level = 100, side = 0, seat = 1,
    skills = { "试作·封印之雷" }, evs = { sp_attack = 252 } })
  local gaiya = makePet("盖亚", { level = 100, side = 1, seat = 2,
    skills = { "气力", "渗透劲", "叩击" } })
  local logic = makeBattle({ lei, gaiya }, "seal-skill")

  -- 盖亚手上威力最高的是「叩击」（气力 0 / 渗透劲 20 / 叩击 40）——
  -- 先自己算一遍，别猜：挑法必须和实现一样是"威力降序 + 名字升序"的确定性排序
  local best, best_power = nil, -1
  for _, sk in ipairs(gaiya:getAllSkills()) do
    local p = sk:getPower()
    if p > best_power or (p == best_power and best ~= nil and sk.name < best.name) then
      best, best_power = sk, p
    end
  end
  eq(best.name, "叩击", "威力最高的是叩击（40）")

  local r = logic:useSkill{ source = lei, target = gaiya, skill = S.Seer:getSkill("试作·封印之雷") }
  eq(r.used, true, "封招技用出去了")
  eq(gaiya:isSkillSealed("叩击"), true, "对手威力最高的技能被封锁")
  eq(gaiya:checkSkillUsable("叩击"), false, "被封的技能用不出来")
  eq(select(2, gaiya:checkSkillUsable("叩击")), S.Skill.Unusable.SEALED,
    "原因就是『被封印』——可用性判断只有一份实现")
  eq(gaiya:checkSkillUsable("渗透劲"), true, "别的技能不受影响")

  -- 效果挂在**对手**身上（封的是他）
  local seal_effect = table.find(gaiya:getEffects(), function(e) return e.kind == "seal_skill" end)
  check(seal_effect ~= nil, "封招是挂在对手身上的持续效果")

  -- 持续 2 回合：走两次回合末就到期，效果自己摘掉并解封
  logic:endRound()
  eq(gaiya:isSkillSealed("叩击"), true, "第 1 回合还封着")
  logic:endRound()
  eq(gaiya:isSkillSealed("叩击"), false, "到期自动解封（on_expire 收尾）")
  eq(gaiya:checkSkillUsable("叩击"), true, "解封之后又能用了")

  -- 也可以指定封哪个技能（试作·锁喉 封「气力」）
  local ok_skill = S.Seer:getSkill("试作·锁喉")
  check(ok_skill ~= nil, "试作·锁喉 在技能表里")
  local lei2 = makePet("雷伊", { level = 100, side = 0, seat = 3, skills = { "试作·锁喉" } })
  local gaiya2 = makePet("盖亚", { level = 100, side = 1, seat = 4, skills = { "气力", "叩击" } })
  local logic2 = makeBattle({ lei2, gaiya2 }, "seal-skill-2")
  logic2:useSkill{ source = lei2, target = gaiya2, skill = ok_skill }
  eq(gaiya2:isSkillSealed("气力"), true, "按名字指定封「气力」")
  eq(gaiya2:isSkillSealed("叩击"), false, "没被封的不动")
  eq(#gaiya2:getSealedSkills(), 1, "封印记录在精灵身上")
end

do
  -- 偷取能力等级：对方失去，自己拿到（官方"偷取对手能力提升状态"的形状）
  local lei = makePet("雷伊", { level = 100, side = 0, seat = 1,
    skills = { "试作·雷霆回响" }, evs = { sp_attack = 252 } })
  local gaiya = makePet("盖亚", { level = 100, side = 1, seat = 2, skills = { "叩击" } })
  local logic = makeBattle({ lei, gaiya }, "steal-stages")
  gaiya:setStatStage("defense", 2)
  gaiya:setStatStage("speed", 1)
  eq(lei:getStatStage("defense"), 0, "偷之前自己没强化")

  logic:useSkill{ source = lei, target = gaiya, skill = S.Seer:getSkill("试作·雷霆回响") }

  eq(gaiya:getStatStage("defense"), 0, "对方的防御提升没了")
  eq(gaiya:getStatStage("speed"), 0, "对方的加速也没了")
  eq(lei:getStatStage("defense"), 2, "加到了自己身上")
  eq(lei:getStatStage("speed"), 1, "速度同样搬过来了")
  local stolen = table.find(logic.room.notified, function(e) return e.type == "StagesStolen" end)
  check(stolen ~= nil, "播报了『偷取』事件")
end

do
  -- 按体力比例造成的固定伤害（不吃克制/暴击）
  local lei = makePet("雷伊", { level = 100, side = 0, seat = 1, skills = { "叩击" } })
  local gaiya = makePet("盖亚", { level = 100, side = 1, seat = 2, skills = { "试作·逆流碎击" } })
  local logic = makeBattle({ lei, gaiya }, "hp-ratio")
  local hp0 = lei.hp
  local r = logic:useSkill{ source = gaiya, target = lei, skill = S.Seer:getSkill("试作·逆流碎击") }
  local expected_extra = math.max(1, math.floor(lei.max_hp / 6))
  check(r.damage > expected_extra, ("总伤害 %d 里含那笔按比例算的固定伤害"):format(r.damage), r.damage)
  check(hp0 - lei.hp >= expected_extra, "掉的血不少于那笔固定伤害")
end

-- ============================================================================
section("请求机制：Request / RequestHandler（抄自 freekill-core）")

do
  -- 类都在：Request 描述"问什么"，四个处理器决定"谁去答"
  check(S.Request ~= nil, "有 Request 类")
  eq(S.RequestHandler:isSubclassOf(S.RequestHandler), false, "基类不是自己的子类（占位检查）")
  eq(S.CliHandler:isSubclassOf(S.RequestHandler), true, "CliHandler 是一个 RequestHandler")
  eq(S.RpcHandler:isSubclassOf(S.RequestHandler), true, "RpcHandler 也是一个")
  eq(S.AiHandler:isSubclassOf(S.RequestHandler), true, "AiHandler 也是")
  eq(S.DefaultHandler:isSubclassOf(S.RequestHandler), true, "无头降级那个也是")

  -- freekill 那三个"特殊答复"的约定照抄（换成常量，别散字面量）
  eq(S.Request.CANCEL, "", "空串 = 取消")
  eq(S.Request.CANCEL_EXPLICIT, "__cancel", "明确取消")
  eq(S.Request.FAILED_IN_RACE, "__failed_in_race", "抢答失败")
  eq(S.Request.TIMER_REASON, "request_timer", "超时的唤醒理由")
  eq(S.Request.isCancel(""), true, "空串算取消")
  eq(S.Request.isCancel({ skill = "撞击" }), false, "正常答复不算取消")

  -- 一个请求：问谁、问什么、默认答复是什么
  local bu, huo = makeStandardPets()
  local logic = makeBattle({ bu, huo }, "request-basic")
  local req = S.Request.AskForChoice(logic, bu, {
    prompt = "选一个", choices = { "甲", "乙" },
  })
  eq(req.command, "AskForChoice", "command 就是发给外面的 kind")
  eq(#req.players, 1, "只有一个参与者")
  eq(req.n, 1, "收到 1 个有效答复就能结束")
  local payload = req:toJson(bu)
  eq(payload.kind, "AskForChoice", "toJson 里带 kind")
  eq(payload.pet, bu.seat, "带座位号")
  eq(payload.choices[1], "甲", "带选项")
  eq(req:getDefaultReply(bu), "甲", "没给兜底答复就选第一个（决策固定 = 可复现）")

  -- 超时/没人答 → 用默认答复（这就是"流程永远不会卡死"的那道保险）
  eq(req:getResult(bu), "甲", "无头环境下拿到默认答复")
  eq(logic.last_request, req, "问完记在 last_request 上（重连/复盘要用）")
  eq(logic.current_request, nil, "问完清掉 current_request")

  -- 取消（空串）与"没有答复"是两件事
  eq(S.Request.isCancel(req:getResult(bu)), false, "这个是正常答复，不是取消")
end

do
  -- 每轮开始时确实会问"这回合用什么技能"：请求里带着候选、原因和第五技能
  local lei = makePet("雷伊", { level = 100, side = 0, seat = 1,
    skills = { "电击光束", "雷祭" }, fifth = "元气电光球" })
  local gaiya = makePet("盖亚", { level = 100, side = 1, seat = 2, skills = { "叩击" } })
  local logic, room = makeBattle({ lei, gaiya }, "request-round")

  local seen = {}
  logic.request_hook = function(_, request)
    table.insert(seen, request)
    return { skill = request.skills[1] }
  end

  logic:start()

  eq(#seen > 0, true, "开局就问过技能了（这就是『每轮开始寻求玩家使用技能』）")
  eq(seen[1].kind, "AskForAction", "问的是『用哪个技能』")
  eq(seen[1].pet, 1, "先问 1 号座位")
  eq(#seen[1].skills, 3, "候选 = 2 个普通技能 + 第五技能")
  eq(seen[1].fifth, "元气电光球", "并且告诉外面哪个是第五技能")
  check(seen[1].seq > 0, "请求带编号（日志/回放要靠它区分第几次询问）", seen[1].seq)
  check(seen[2] == nil or seen[2].seq == seen[1].seq + 1, "编号逐个递增")
  check(seen[1].timeout ~= nil, "带超时字段（0 = 一直等）", seen[1].timeout)

  -- 焦点通知：外面据此显示"正在等谁"
  local focus = table.find(room.notified, function(e) return e.type == "MoveFocus" end)
  check(focus ~= nil, "询问时会播一条 MoveFocus（freekill 的 notifyMoveFocus）")
end

-- ============================================================================
section("单机版：命令行选择技能 → 回到流程正常使用技能")

do
  -- 一份"脚本化的终端"：输入来自一张表，输出收进 out。
  -- 这样跑的是**真的 CliHandler**（同一份代码），只是不用开终端。
  local lei = makePet("雷伊", { level = 100, side = 0, seat = 1,
    skills = { "电击光束", "雷祭" }, fifth = "元气电光球" })
  local gaiya = makePet("盖亚", { level = 100, side = 1, seat = 2,
    skills = { "叩击", "神经修复" }, fifth = "联盟的审判" })
  local logic, room = makeBattle({ lei, gaiya }, "cli-single")

  local lines = {
    "9",        -- 乱输：应该提示"没有第 9 个技能"并重问
    "?",        -- 帮助
    "2",        -- 第 2 个技能 = 雷祭（属性技，命中 50%）
    "1 2",      -- 用第 1 个技能打 2 号座位
    "a",        -- 交给 AI
    "",         -- 直接回车 = 第一个技能
  }
  local idx, out = 0, {}
  local cli = S.CliHandler:new{
    logic = logic,
    input = function() idx = idx + 1; return lines[idx] end,
    output = function(text) table.insert(out, text) end,
  }
  eq(cli:isInstanceOf(S.RequestHandler), true, "CliHandler 就是一个 RequestHandler")

  -- 人类挂命令行；对手挂 AI —— **一局里两种答复者共存**，这就是"谁答"可替换
  logic:setRequestHandler(lei, cli)
  logic:setRequestHandler(gaiya, S.AiHandler:new{
    logic = logic,
    fn = function(_, request)
      if request.kind ~= "AskForAction" then return nil end
      for _, name in ipairs(request.skills) do
        if name == "叩击" then return { skill = name, target = 1 } end
      end
      return { skill = request.skills[1], target = 1 }
    end,
  })

  local kind = logic:start()
  local printed = table.concat(out, "\n")

  eq(kind, "finished", "单机模式不需要挂起，一次跑完（没有 interactive）")
  eq(logic.pending_request, nil, "全程没有挂起中的请求")
  eq(logic.game_over, true, "打完了")

  -- 1) 提示打得出来，而且看得懂
  check(printed:find("第 1 回合 · 轮到 雷伊") ~= nil, "提示里有回合和轮到谁")
  check(printed:find("电击光束") ~= nil and printed:find("元气电光球") ~= nil,
    "候选技能都列出来了（含第五技能）")
  check(printed:find("第五技能") ~= nil, "第五技能被标出来了")

  -- 2) 乱输会被指出，并且**不会**当成答复
  check(printed:find("没有第 9 个技能") ~= nil, "乱输会提示并重问")
  check(printed:find("怎么玩") ~= nil, "输入 ? 会打印帮助")

  -- 3) 选了就用：第 1 回合脚本选的是 2 号技能（雷祭）
  local used1 = table.find(room.notified, function(e)
    return e.type == "UseSkill" and e.source == 1
  end)
  check(used1 ~= nil, "雷伊出手了")
  eq(used1.skill, "雷祭", "用的是命令行里选的那个技能（流程照常往下走）")

  -- 4) 对手那一边走的是 AI 处理器，用的是 AI 选的技能
  local used2 = table.find(room.notified, function(e)
    return e.type == "UseSkill" and e.source == 2
  end)
  check(used2 ~= nil, "盖亚也出手了（同一个战局里两种答复者并存）")
  eq(used2.skill, "叩击", "AI 处理器选的技能生效了")

  -- 5) 请求内容就是协议内容：历史里能看到每次问了什么
  eq(cli.history[1].kind, "AskForAction", "第一次问的就是『用哪个技能』")
  eq(cli.history[1].pet, 1, "先问人类这边")
  check(#cli.history >= 2, ("命令行这边整局被问了 %d 次"):format(#cli.history), #cli.history)
  for _, ask in ipairs(cli.history) do
    eq(ask.pet, 1, "命令行处理器只会收到 1 号座位的问题（AI 那边走 AiHandler）")
  end
  -- AI 那边确实被问过（它选出来的技能真的用出去了，见上面 used2）
  check(used2 ~= nil, "对手那一边由 AI 处理器作答")
end

do
  -- 技能用不了的时候，命令行也会说清楚原因（和客户端拿到的 unusable 是同一份数据）
  local lei = makePet("雷伊", { level = 100, side = 0, seat = 1,
    skills = { "电击光束", "雷祭", "万丈光芒" } })
  local gaiya = makePet("盖亚", { level = 100, side = 1, seat = 2, skills = { "叩击" } })
  local logic = makeBattle({ lei, gaiya }, "cli-unusable")
  lei:sealSkill("雷祭")                       -- 被封印
  lei.skill_set.pp["万丈光芒"] = 0             -- PP 用完
  -- 剩下"电击光束"还能用，所以照样会问，只是候选里少两个

  local out = {}
  local cli = S.CliHandler:new{
    logic = logic,
    input = function() return "1" end,
    output = function(t) table.insert(out, t) end,
  }
  logic:setRequestHandler(lei, cli)
  logic:setRequestHandler(gaiya, S.AiHandler:new{ logic = logic,
    fn = function() return { skill = "叩击", target = 1 } end })

  logic:start()
  local printed = table.concat(out, "\n")
  check(printed:find("万丈光芒 现在用不了：PP 已用完") ~= nil,
    "PP 用完的原因打出来了", printed:match("（[^）]*用不了[^）]*）"))
  check(printed:find("雷祭 现在用不了：技能被封印") ~= nil, "被封印的原因也打出来了")
  check(printed:find("%[1%] 电击光束") ~= nil, "候选里只剩还能用的那个（编号从 1 开始）")
  check(printed:find("%[2%] ") == nil, "用不了的技能不进候选列表")
end

do
  -- 玩家按 q：不算"流程崩了"，而是走"取消"这条路——
  -- 回合流程会播一条带原因的 NoAction（和客户端点不了技能时同一个兜底）
  local lei = makePet("雷伊", { level = 100, side = 0, seat = 1, skills = { "电击光束" } })
  local gaiya = makePet("盖亚", { level = 100, side = 1, seat = 2, skills = { "叩击" } })
  local logic, room = makeBattle({ lei, gaiya }, "cli-quit")

  local quit_called, cancels = false, 0
  local cli = S.CliHandler:new{
    logic = logic,
    input = function() return "q" end,
    output = function() end,
    on_quit = function() quit_called = true; logic:gameOver(gaiya.side, "surrender") end,
  }
  -- 记一下"询问被撤掉"（对应 freekill 的 CancelRequest）：结束时 UI 得关掉询问框
  local base_cancel = cli.cancel
  cli.cancel = function(self, request) cancels = cancels + 1; return base_cancel(self, request) end
  logic:setRequestHandler(lei, cli)
  logic:setRequestHandler(gaiya, S.AiHandler:new{ logic = logic,
    fn = function() return { skill = "叩击", target = 1 } end })

  logic:start()

  eq(cli.quit, true, "命令行记下了『玩家退出』")
  eq(quit_called, true, "并且回调了 on_quit（单机主程序靠它收尾）")
  eq(logic.game_over, true, "这一局结束了")
  eq(logic.winner, gaiya.side, "退出 = 认输，判对手赢")
  eq(cancels, 1, "结束时会通知答复者『把这次询问撤掉』（客户端要关掉询问框）")
end

do
  -- 不带 on_quit 的取消（比如"这一手不出招"）：回合流程会播一条带原因的 NoAction，
  -- 而不是静默跳过——客户端拿它提示玩家，而不是让人以为点了没反应。
  local lei = makePet("雷伊", { level = 100, side = 0, seat = 1, skills = { "电击光束" } })
  local gaiya = makePet("盖亚", { level = 100, side = 1, seat = 2, skills = { "叩击" } })
  local logic, room = makeBattle({ lei, gaiya }, "cli-cancel")

  local n = 0
  local cli = S.CliHandler:new{
    logic = logic,
    output = function() end,
    input = function()          -- 第一手取消，之后正常打
      n = n + 1
      return n == 1 and "q" or "1"
    end,
  }
  logic:setRequestHandler(lei, cli)
  logic:setRequestHandler(gaiya, S.AiHandler:new{ logic = logic,
    fn = function() return { skill = "叩击", target = 1 } end })

  logic:start()

  local no = table.find(room.notified, function(e)
    return e.type == "NoAction" and e.pet == 1
  end)
  check(no ~= nil, "取消的那一手播了 NoAction（不是静默跳过）")
  eq(no.reason, S.Skill.Unusable.NO_SKILL_CHOSEN, "原因是『这回合没有选择技能』")
  eq(logic.game_over, true, "取消一手不影响后续回合，整局照样打完")
end

do
  -- **换一层就变联机**：同一局、同样的答复，一个走命令行、一个走挂起（RpcHandler），
  -- 结果必须一模一样——这正是"之后换成 Unity 也能正常运行"的保证。
  local function run(mode)
    local lei = makePet("雷伊", { level = 100, side = 0, seat = 1,
      skills = { "电击光束", "雷祭" } })
    local gaiya = makePet("盖亚", { level = 100, side = 1, seat = 2, skills = { "叩击" } })
    local logic, room = makeBattle({ lei, gaiya }, "same-seed")

    if mode == "cli" then
      local i = 0
      logic:setRequestHandler(lei, S.CliHandler:new{
        logic = logic, output = function() end,
        input = function() i = i + 1; return i % 2 == 0 and "1" or "2" end,
      })
      logic:setRequestHandler(gaiya, S.AiHandler:new{ logic = logic,
        fn = function() return { skill = "叩击", target = 1 } end })
      logic:start()
    else
      -- 挂起那条路：外面（C++/Unity）每收到一个请求就回一个答复
      logic.interactive = true
      logic:setRequestHandler(gaiya, S.AiHandler:new{ logic = logic,
        fn = function() return { skill = "叩击", target = 1 } end })
      local kind = logic:start()
      local n = 0
      while kind == "request" and n < 100 do
        n = n + 1
        local ask = logic.pending_request
        if ask.kind == "AskForAction" then
          kind = logic:resume{ skill = ask.skills[(n % 2 == 0) and 1 or 2], target = 2 }
        else
          kind = logic:resume(nil)
        end
      end
    end
    return logic, room
  end

  local logic_cli, room_cli = run("cli")
  local logic_rpc, room_rpc = run("rpc")

  eq(logic_cli.winner, logic_rpc.winner, "两条路的胜负一样")
  eq(logic_cli.round, logic_rpc.round, "回合数一样")

  local function damage_totals(room)
    local t = 0
    for _, e in ipairs(room.notified) do
      if e.type == "Damage" then t = t + (e.damage or 0) end
    end
    return t
  end
  eq(damage_totals(room_cli), damage_totals(room_rpc),
    "整局打出的总伤害一样（同样的答复 → 同样的结果，与界面无关）")
end

do
  -- 超时：外面回一个 "request_timer"（freekill 的烧条到头），
  -- 流程必须用**兜底答复**继续走下去，而不是卡死
  local lei = makePet("雷伊", { level = 100, side = 0, seat = 1, skills = { "电击光束" } })
  local gaiya = makePet("盖亚", { level = 100, side = 1, seat = 2, skills = { "叩击" } })
  local logic, room = makeBattle({ lei, gaiya }, "request-timeout")
  logic.interactive = true

  local kind = logic:start()
  eq(kind, "request", "先挂起等玩家")
  check(logic.current_request ~= nil, "挂起时 current_request 是那个 Request 对象")
  eq(logic.current_request.command, "AskForAction", "挂起时等的是『用哪个技能』")
  eq(#logic.current_request.overtimes, 0, "还没人超时")
  eq(logic.pending_request.kind, "AskForAction", "给外面的包就是这份请求")

  kind = logic:resume(S.Request.TIMER_REASON)   -- 超时
  eq(kind == "finished" or kind == "request", true, "超时后流程继续（不卡死）", kind)
  eq(#logic.last_request.winners > 0, true, "超时的那个人用兜底答复补上了")

  -- 一路用超时喂完，整局照样能结束
  local guard = 0
  while kind == "request" and guard < 500 do
    guard = guard + 1
    kind = logic:resume(S.Request.TIMER_REASON)
  end
  eq(logic.game_over, true, "全程超时也能打完（AI 托管走的就是这条）")
  check(#logic.last_request.overtimes > 0, "最后那次询问记下了超时的人",
    #logic.last_request.overtimes)
end

-- ============================================================================
section("日志与重复定义告警")

do
  -- 重复定义要能报出来：两个包定义了同名技能时，线上表现是"某个包的技能莫名
  -- 被另一个包覆盖"，不报警几乎查不出来（freekill 的 Engine:addSkill 也这么做）
  local captured = {}
  local old_sink, old_level = S.Log.sink, S.Log.min_level
  S.Log.sink = function(level, msg) table.insert(captured, level .. ":" .. msg) end
  S.Log.min_level = "info"

  S.Seer:createSkill{ name = "测试_撞名", category = S.Skill.Status }
  S.Seer:createSkill{ name = "测试_撞名", category = S.Skill.Status }

  local warned = table.find(captured, function(m) return m:find("测试_撞名") ~= nil end)
  check(warned ~= nil, "重复定义同名技能会告警（而不是静静覆盖）", #captured)
  check(warned ~= nil and warned:startsWith("warning:"), "告警级别是 warning", warned)

  -- 种族撞图鉴编号也要报
  captured = {}
  S.Seer:addSpecies{ id = 9999, name = "测试_种族甲", elements = { "普通" } }
  S.Seer:addSpecies{ id = 9999, name = "测试_种族乙", elements = { "普通" } }
  warned = table.find(captured, function(m) return m:find("9999") ~= nil end)
  check(warned ~= nil, "图鉴编号被两个种族占用会告警", warned)

  -- 恢复真实 sink
  S.Log.sink, S.Log.min_level = old_sink, old_level
  S.Log.min_level = "critical"
end

do
  -- 整份 RPC 层（jsonrpc + stdio + peer + dispatchers + session）在本进程里直接调一遍。
  -- 真起子进程的端到端版本见 examples/rpc_demo.lua。
  local entry = dofile(PKG_ROOT .. "/lua/server/rpc/entry.lua")
  local d = entry.dispatchers

  eq(d.ping(), true, "ping 成功")
  eq(select(2, d.ping()), "PONG", "ping 回 PONG")
  check(type(d.version) == "string", "方法表里带版本号（热更新要对比它）", d.version)

  local ok, res = d.startGame{
    roomId = 7, seed = "rpc-seed",
    players = {
      { playerId = 1, pets = { { species = "布布种子", level = 50, skills = { "藤鞭", "撞击" }, side = 0 } } },
      { playerId = 2, pets = { { species = "小火猴", level = 50, skills = { "火花", "撞击" }, side = 1 } } },
    },
  }
  eq(ok, true, "startGame 成功")
  eq(res.pets, 2, "造出了两只精灵")
  eq(res.pet_stats[1].seat, 1, "座位号排好了（出手顺序/选目标都要用）")
  eq(#res.stat_fields, 6, "回包带着六项数值的字段名（界面要显示）")
  eq(res.pet_stats[1].max_hp, res.pet_stats[1].stats.hp, "最大体力就是体力那一项")
  check(res.pet_stats[1].skills ~= nil, "也带着技能栏", #res.pet_stats[1].skills)

  -- 开跑：一直算到"非问人不可"才回来
  local ok2, task = d.runGame{ roomId = 7 }
  eq(ok2, true, "runGame 成功")
  check(task.ask ~= nil, "返回了『要玩家决定的事』")
  eq(task.ask.kind, "AskForAction", "第一件事是问指令")
  eq(task.ask.pet, 1, "先问 1 号座位")

  -- 挂着的时候送一个不认识的操作：要报错，而且不能把挂起状态搞乱。
  -- 注意 dispatcher 的返回值是 (成功吗, 错误名, 详细说明)——照抄 freekill 的约定，
  -- 于是 jsonrpc 能把"业务失败"翻成一条规范的 error 包。
  local bad_ok, bad_name, bad_err = d.handlePlayerAction{ roomId = 7, action = { type = "突然跳舞" } }
  eq(bad_ok, false, "不认识的操作返回 false")
  eq(bad_name, "invalid_params", "错误名是标准的那几个之一")
  check(tostring(bad_err):find("跳舞") ~= nil, "详细说明里带上不认识的操作名", bad_err)
  eq(entry.Session.get(7).logic.pending_request ~= nil, true, "报错后挂起状态还在")

  -- 一路喂完，直到打完
  local guard, asked = 0, 0
  while task.ask and guard < 300 do
    guard = guard + 1
    asked = asked + 1
    local reply
    if task.ask.kind == "AskForAction" then
      reply = { type = "UseSkill", skillName = task.ask.skills[1], targetId = 3 - task.ask.pet }
    else
      -- AskForChoice 之类：挑第一个选项
      reply = { type = "Choose", choice = task.ask.choices[1] }
    end
    local dok, dres = d.handlePlayerAction{ roomId = 7, playerId = task.ask.pet, action = reply }
    eq(dok, true, ("第 %d 次操作被接受"):format(asked))
    task = dres
  end
  eq(task.finished, true, "喂完指令之后整局打完")
  eq(task.winner ~= nil, true, "分出了胜负")
  check(asked > 2, ("一问一答走了 %d 轮"):format(asked), asked)
  check(task.events ~= nil, "结束回包带着整局事件流（回放用）", #(task.events or {}))
  eq(entry.Session.get(7).logic.game_event_stack.p, 0, "打完时事件栈是干净的")

  local no_ok, no_name, no_room = d.handlePlayerAction{ roomId = 404, action = {} }
  eq(no_ok, false, "房间不存在时返回 false")
  eq(no_name, "invalid_params", "错误名是 invalid_params")
  check(tostring(no_room):find("404") ~= nil, "详细说明里有房间号", no_room)

  -- 会话概况（管理/调试用）
  local rooms = entry.Session.list()
  eq(#rooms, 1, "会话列表里有一个房间")
  eq(rooms[1].roomId, 7, "房间号对得上")
  eq(rooms[1].over, true, "而且已经打完了")
end

print(("\n%s%d 项检查，%d 项失败%s"):format(
  failures == 0 and GREEN or RED, checks, failures, RESET))
if failures > 0 then
  os.exit(1)
end
print("全部通过。")
