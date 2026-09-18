-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 单机版：在命令行里打一局 ============================
--
-- 跑法：
--
--     make play            （或者 cd packages/seer-core && lua5.4 examples/single_player.lua）
--
-- 你操作雷伊（Lv.100），电脑操作盖亚。每轮开始时程序会问你"这回合用什么技能"，
-- 输入编号（可加目标座位）回车即可；`?` 看帮助，`a` 交给 AI，`q` 退出。
--
-- ---------------------------- 这局为什么能"单机"跑起来 ----------------------------
--
-- 因为**游戏流程只跟"谁来答"打交道**，不关心答案从哪来（见 server/request/）：
--
--   本文件：  给雷伊挂一个 CliHandler（读终端），给盖亚挂一个 AiHandler（算一个）
--   联机时：  两边都挂 RpcHandler（挂起，请求包发给 C++/Unity，等它回话）
--
-- 换的就这一层。战斗规则、回合流程、技能结算、事件通知——一行都不用改。
-- 所以"单机能跑通"就等于"联机只差一个网络往返"。
--
-- ---------------------------- 复盘：一次询问的完整来回 ----------------------------
--
--   1. Round 事件开始（`Round:main`）→ 问双方"这回合用什么"（`buildTurnOrder`）
--   2. `logic:askForAction(pet)` 造一个 `Request.AskForAction`（候选技能 + 用不了的原因）
--   3. `Request:ask()` 把问题发给这个座位的处理器：
--        · CliHandler  → 打到终端，`io.read()` 读你敲的那行（本文件就是走这条）
--        · RpcHandler  → `coroutine.yield` 出去，`logic:start()` 返回 "request"
--   4. 答复 → `(技能, 目标)` → 按先制度/速度排出出手顺序 → `GameEvent.UseSkill` 结算
--   5. 打完了：`logic:start()` 返回 "finished"，`winner` 是赢的那一方

-- 从本文件的位置反推核心目录，这样从仓库根目录跑还是从包里跑都能work
local HERE = debug.getinfo(1, "S").source:sub(2)
local ROOT = HERE:match("^(.*)/examples/[^/]+$") or "."
local S = dofile(ROOT .. "/lua/seer.lua")

-- ============================ 一、造双方 ============================

local function make_pet(species_name, seat, side, skills, fifth)
  return S.Pet:new{
    species = species_name,
    level = 100,
    seat = seat,
    side = side,
    skills = skills,
    fifth = fifth,
    -- 随便配一点努力值，让数值看起来正常些（不是平衡数据）
    evs = { hp = 100, attack = 100, sp_attack = 100, defense = 50, sp_defense = 50, speed = 100 },
  }
end

local you = make_pet("雷伊", 1, 0,
  { "电击光束", "惊雷切", "万丈光芒", "雷祭" }, "元气电光球")
local cpu = make_pet("盖亚", 2, 1,
  { "气力", "渗透劲", "日月皆伤", "神经修复" }, "联盟的审判")

-- ============================ 二、战报 ============================
--
-- room:notifyPlayers 是战斗核唯一的"对外播报"出口。命令行版就把它打印出来；
-- 接 Unity 时，同一个入口换成"把事件推给客户端"即可。

local room = { pets = { you, cpu } }

function room:getAlivePets()
  local ret = {}
  for _, p in ipairs(self.pets) do
    if not p:isFainted() then table.insert(ret, p) end
  end
  return ret
end

local function who(seat)
  for _, p in ipairs(room.pets) do
    if p.seat == seat then return p.name end
  end
  return "?"
end

function room:notifyPlayers(evt)
  if evt.type == "RoundStart" then
    print(("\n===== 第 %d 回合 ====="):format(evt.round))
  elseif evt.type == "UseSkill" then
    local tag = evt.fifth and "【第五技能】" or ""
    print(("  %s 使用了 %s%s"):format(who(evt.source), tag, evt.skill))
  elseif evt.type == "SkillMissed" then
    print("    → 打空了！")
  elseif evt.type == "SkillUnusable" then
    print(("    → %s 用不出来（%s）"):format(evt.skill, evt.text or evt.reason or "不可用"))
  elseif evt.type == "Damage" and (evt.damage or 0) > 0 then
    local extra = (evt.effectiveness or 1) > 1 and "（效果拔群）"
      or ((evt.effectiveness or 1) < 1 and "（效果不佳）" or "")
    print(("    → %s 受到 %d 点伤害%s"):format(who(evt.target), evt.damage, extra))
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
  elseif evt.type == "StatCleared" then
    print(("    → %s 的能力提升被消除了"):format(who(evt.target)))
  elseif evt.type == "MarkApplied" then
    print(("    → %s 陷入%s"):format(who(evt.target), evt.name))
  elseif evt.type == "MarkRemoved" then
    print(("    → %s 的%s解除了"):format(who(evt.target), evt.name))
  elseif evt.type == "ActionPrevented" then
    local def = S.Mark.defs[evt.reason]
    print(("    → %s 因为%s没能行动"):format(who(evt.pet), def and def.name or tostring(evt.reason)))
  elseif evt.type == "NoAction" then
    print(("    → %s 这回合没有出手（%s）")
      :format(who(evt.pet), evt.text or evt.reason or "没有选择技能"))
  elseif evt.type == "SkillSealed" then
    print(("    → %s 的技能「%s」被封住了"):format(who(evt.pet), evt.skill))
  elseif evt.type == "SkillUnsealed" then
    print(("    → %s 的技能「%s」解封了"):format(who(evt.pet), evt.skill))
  elseif evt.type == "PetFainted" then
    print(("  *** %s 倒下了 ***"):format(who(evt.pet or evt.seat)))
  elseif evt.type == "GameOver" then
    if evt.winner ~= nil then
      print(("  *** 对局结束：%s 获胜（%s）***")
        :format(who(evt.winner == 0 and 1 or 2), tostring(evt.reason)))
    else
      print(("  *** 对局结束：平局（%s）***"):format(tostring(evt.reason)))
    end
  end
end

-- ============================ 三、两个答复者 ============================

local logic = S.BattleLogic:new(room, {
  seed = "single-player",
  actors = room.pets,
})

--- 电脑那一边：一个很朴素的 AI（血少先回复，其次挑威力大的打）。
--- 它就是上一节说的 AiHandler —— 就地作答，一步都不挂起。
local function cpu_ai(req_room, request)
  if request.kind ~= "AskForAction" then return nil end

  -- AI 只拿到请求包（座位上的人是谁），没有对象引用——这点和真人客户端一样。
  -- 所以"按座位找回精灵"这一步是所有答复者都要做的。
  local pet = cpu
  for _, p in ipairs(room.pets) do
    if p.seat == request.pet then pet = p end
  end
  local foe = you

  -- 血少了先回复
  if pet:getHpRatio() < 0.35 then
    for _, name in ipairs(request.skills) do
      local sk = S.Seer:getSkill(name)
      if sk then
        for _, spec in ipairs(sk.effects or {}) do
          if spec.kind == "heal" or spec.kind == "drain" then
            return { skill = name, target = foe.seat }
          end
        end
      end
    end
  end

  -- 否则挑威力最大的（破坏性最小的确定性策略）。
  -- 第五技能刻意压到最后用：它 PP 少、威力大，一上来就放会让这一局一回合结束，
  -- 看不到别的机制（和 battle_demo 里那个 AI 的取舍一样）。
  local best, best_power = request.skills[1], -1
  for _, name in ipairs(request.skills) do
    if name ~= request.fifth or foe:getHpRatio() < 0.4 then
      local sk = S.Seer:getSkill(name)
      if sk and (sk:getPower() or 0) > best_power then best, best_power = name, sk:getPower() end
    end
  end
  return { skill = best, target = foe.seat }
end

--- 你这一边：命令行。所有界面交互都在这个类里，战斗核不知道有终端。
local cli = S.CliHandler:new{
  logic = logic,
  on_quit = function()
    -- 退出 = 认输：直接判对手赢，让这一局正常收尾
    logic:gameOver(cpu.side, "surrender")
  end,
}

logic:registerAllPets()
logic:setRequestHandler(you, cli)          -- 你：读终端
logic:setRequestHandler(cpu, S.AiHandler:new{ logic = logic, fn = cpu_ai })  -- 电脑：AI

-- ============================ 四、开打 ============================

print("================================================================================")
print("单机对战：你操作 雷伊（座位 1） vs 电脑 盖亚（座位 2）")
print("每轮开始会让你选技能：输入编号，或 `a` 交给 AI，`?` 看帮助，`q` 退出。")
print("（这套界面只是 RequestHandler 的一个实现；换成 Unity 客户端时，")
print("  同样的请求会以 JSON 从 RPC 层发出去，战斗核一行都不用改。）")
print("================================================================================")
print(("  雷伊  体力 %d  特攻 %d  速度 %d"):format(you.max_hp, you.sp_attack, you.speed))
print(("  盖亚  体力 %d  攻击 %d  速度 %d"):format(cpu.max_hp, cpu.attack, cpu.speed))

local kind = logic:start()

print()
if cli.quit then
  print("你退出了这一局。")
else
  print(("打完了：%s，共 %d 回合"):format(kind, logic.round))
  print(("  雷伊  剩余体力 %d/%d"):format(you.hp, you.max_hp))
  print(("  盖亚  剩余体力 %d/%d"):format(cpu.hp, cpu.max_hp))
end
