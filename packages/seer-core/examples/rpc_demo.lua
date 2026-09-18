#!/usr/bin/env lua5.4
-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ RPC 示例：两个进程跑同一局 ============================
--
-- ```bash
-- cd packages/seer-core && lua5.4 examples/rpc_demo.lua
-- ```
--
-- 这个示例做的事和 `battle_demo.lua` 一样（雷伊 vs 盖亚打一局），但方式完全不同：
--
--   * 战斗核跑在**另一个 Lua 进程**里（`lua/server/rpc/entry.lua`）
--   * 两个进程之间只有 stdin/stdout 两条管道，说的是 **JSON-RPC 2.0**
--   * 这边扮演"将来的 C++"：开局、要指令、把玩家的选择送回去、收事件
--
-- 也就是说，架构文档 §5 那条边界是真的被跨过去了：**中间只过序列化消息**。
-- 把这个文件里的"假玩家策略"换成"问真人客户端"，再把两个 Lua 进程换成
-- C++ RoomThread + Lua 子进程，就是最终形态——协议一个字都不用改。
--
-- ---------------------------- 怎么做出双向管道 ----------------------------
--
-- 纯 Lua 没有"起子进程同时读写"的设施（io.popen 只能单向）。这里用两个 **FIFO**
-- （命名管道）绕过：一个喂子进程的 stdin，一个收它的 stdout。`mkfifo` 是 coreutils
-- 自带的，所以不需要装 lua-socket / lua-posix 之类的依赖。

local HERE = debug.getinfo(1, "S").source:sub(2)
local ROOT = HERE:match("^(.*)/examples/[^/]+$") or "."

package.path = table.concat({
  ROOT .. "/lua/lib/?.lua", ROOT .. "/lua/?.lua", ROOT .. "/lua/?/init.lua", package.path,
}, ";")

local json = require "json"
local jsonrpc = require "server.rpc.jsonrpc"

-- ============================ 一、起子进程 + 两条 FIFO ============================

local base = (os.getenv("TMPDIR") or "/tmp") .. "/seer-rpc-demo-" .. tostring(os.time())
local to_child = base .. "-in"     -- 我们写、子进程读（它的 stdin）
local from_child = base .. "-out"  -- 子进程写、我们读（它的 stdout）

os.execute(("mkfifo %s %s"):format(to_child, from_child))

-- 2 是 stderr：子进程的日志全走它，直接接到我们这个终端上（stdout 是协议通道，不能碰）
local cmd = ("cd %s && lua5.4 lua/server/rpc/entry.lua < %s > %s 2>&1 1>&2"):format(
  ROOT, to_child, from_child)
-- 上面的写法让 stdout 走管道、stderr 留在终端：`1>&2` 把 stderr 指向终端，
-- 但那样 stdout 也去了终端……所以换一种：先把 stderr 存成 fd 9，再让 stdout 走管道
local child_err = base .. "-err"
cmd = ("cd %s && exec lua5.4 lua/server/rpc/entry.lua < %s > %s 2>%s &"):format(
  ROOT, to_child, from_child, child_err)
os.execute(cmd)

-- 打开 FIFO：open 会阻塞到对面也打开为止，所以这两行同时也是一次"握手"。
--
-- **顺序不能反**：子进程启动时先做的是 `< 输入管道` 这个重定向，也就是先等我们打开
-- 写端。所以必须**先开写端、再开读端**——反了就两边各等各的，死锁（现象是"一行输出都没有"）。
local child_in = assert(io.open(to_child, "w"), "打不开子进程的输入管道")
child_in:setvbuf("no")
local child_out = assert(io.open(from_child, "r"), "打不开子进程的输出管道")

-- ============================ 二、客户端这一侧的 RPC ============================
--
-- 和子进程里 `peer.lua` 是同一套协议，只是传输换成了这两个 FIFO。
-- 这也顺带证明了 jsonrpc.lua 是**传输无关**的：换管道、换 socket 都不用改它。

local rpc = {
  next_id = 1,
  exchanges = 0,
}

local function send(packet)
  child_in:write(json.encode(packet), "\n")
  child_in:flush()
end

--- 收一条消息并处理。
---@return table|string|nil @ 响应包 / "handled"（通知或请求，已就地处理） / nil（管道断了）
local function pump()
  local line = child_out:read("l")
  if line == nil then return nil end

  local ok, packet = pcall(json.decode, line)
  if not ok then
    print("[客户端] 收到不是 JSON 的东西（说明对面把日志写到 stdout 了！）：" .. tostring(line))
    return nil
  end
  rpc.exchanges = rpc.exchanges + 1

  -- 对面发来的**通知**（没有 id）：不需要回复
  if packet[jsonrpc.key_method] and not packet[jsonrpc.key_id] then
    local method = packet[jsonrpc.key_method]
    local params = packet[jsonrpc.key_params] or {}
    if method == "hello" then
      print(("[客户端] 子进程握手：core=%s version=%s mode=%s"):format(
        tostring(params.core), tostring(params.version), tostring(params.mode)))
      print(("[客户端] 它支持六项数值字段：%s"):format(table.concat(params.statFields or {}, "/")))
    elseif method == "log" then
      print(("[Lua 日志/%s] %s"):format(tostring(params.level), tostring(params.msg)))
    elseif method == "notifyPlayers" then
      -- 这就是"Lua 让 C++ 代发"的那批事件（架构文档 §5.4）。
      -- 真实服务端在这里会把它们推给客户端；示例里直接打印。
      for _, evt in ipairs(params.events or {}) do
        print_battle_event(evt)
      end
    else
      print(("[客户端] 收到通知 %s"):format(method))
    end
    -- 注意返回 "handled" 而不是 nil：nil 是"管道断了"的意思，
    -- 两者混在一起的话，第一条通知（hello）就会被当成管道断掉。
    return "handled"
  end

  -- 对面发来的**请求**：我们得回一条（示例里没有这种情况，留个口子）
  if packet[jsonrpc.key_method] then
    print(("[客户端] 对面请求 %s（示例里没实现，回 error）"):format(packet[jsonrpc.key_method]))
    send(jsonrpc.response_error(packet, "method_not_found"))
    return "handled"
  end

  return packet
end

--- 发一条请求并等答复（等的过程里照常处理对面发来的东西）
local function call(method, params)
  local req = jsonrpc.request(method, params)
  req[jsonrpc.key_id] = rpc.next_id
  rpc.next_id = rpc.next_id + 1

  send(req)
  while true do
    local packet = pump()
    if packet == nil then
      print("[客户端] 管道断了（子进程退出了？）")
      return nil
    end
    if packet ~= "handled" and packet[jsonrpc.key_id] == req[jsonrpc.key_id] then
      if packet[jsonrpc.key_error] then
        print(("[客户端] %s 出错：%s"):format(method,
          tostring(packet[jsonrpc.key_error][jsonrpc.key_error_message])))
        return nil
      end
      return packet[jsonrpc.key_result]
    end
    -- 不是给我的答复 → 上面 pump 已经把它当通知/请求处理掉了
  end
end

-- ============================ 三、战报打印（和 battle_demo 一样）============================

local seat_names = {}

function print_battle_event(evt)
  local function who(seat) return seat_names[seat] or ("座位" .. tostring(seat)) end

  if evt.type == "RoundStart" then
    print(("\n===== 第 %d 回合 ====="):format(evt.round))
  elseif evt.type == "UseSkill" then
    local tag = evt.fifth and "【第五技能】" or ""
    local hits = (evt.hits or 1) > 1 and (" × %d 连击"):format(evt.hits) or ""
    print(("  %s 使用了 %s%s%s"):format(who(evt.source), tag, evt.skill, hits))
  elseif evt.type == "Damage" and (evt.damage or 0) > 0 then
    local extra = {}
    if evt.crit then table.insert(extra, "暴击") end
    if (evt.effectiveness or 1) > 1 then table.insert(extra, "效果拔群") end
    local suffix = #extra > 0 and ("（" .. table.concat(extra, "/") .. "）") or ""
    print(("    → %s 受到 %d 点伤害%s"):format(who(evt.target), evt.damage, suffix))
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
    print(("    → %s 陷入了异常状态 %s"):format(who(evt.target), tostring(evt.status)))
  elseif evt.type == "PetFainted" then
    print(("  *** %s 倒下了 ***"):format(who(evt.pet or evt.seat)))
  elseif evt.type == "GameOver" then
    print(("  *** 对局结束（%s）***"):format(tostring(evt.reason)))
  end
end

-- ============================ 四、驱动一整局 ============================

print("[客户端] 子进程已启动，开始 RPC")

local started = call("startGame", {
  roomId = 1,
  seed = "rpc-lei-vs-gaiya",
  players = {
    {
      playerId = 1001,
      pets = {
        {
          species = "雷伊", level = 100, side = 0, seat = 1,
          ivs = { hp = 31, sp_attack = 31, speed = 31, sp_defense = 20 },
          evs = { hp = 60, sp_attack = 252, speed = 198 },
          nature = "胆小",
          skills = { "电击光束", "惊雷切", "万丈光芒", "雷祭" },
          fifth = "元气电光球",
        },
      },
    },
    {
      playerId = 1002,
      pets = {
        {
          species = "盖亚", level = 100, side = 1, seat = 2,
          ivs = { hp = 31, attack = 31, speed = 31, defense = 25 },
          evs = { hp = 252, attack = 252, speed = 6 },
          nature = "固执",
          skills = { "气力", "渗透劲", "日月皆伤", "神经修复" },
          fifth = "联盟的审判",
        },
      },
    },
  },
})

if started == nil then
  print("[客户端] 开局失败")
  os.exit(1)
end

print(("[客户端] 开局成功，房间 %d，%d 只精灵"):format(started.roomId, started.pets))
for _, p in ipairs(started.pet_stats) do
  seat_names[p.seat] = p.name
  print(("  %s Lv.%d %s  体力 %d/%d  攻击 %d 特攻 %d 防御 %d 特防 %d 速度 %d")
    :format(p.name, p.level, table.concat(p.elements, "/"), p.hp, p.max_hp,
      p.stats.attack, p.stats.sp_attack, p.stats.defense, p.stats.sp_defense, p.stats.speed))
  print(("    技能栏：%s   第五技能：%s   特性：%s")
    :format(table.concat(p.skills, "/"), tostring(p.fifth), tostring(p.ability)))
end

--- 一个很笨的"假玩家"：先把没试过的技能都用一遍，最后才动第五技能
--- （第五技能一样有 PP，也走同一个可用性判断——它只是摆在单独一个技能位上）。
--- 真实服务端在这里会把 offer 发给真人客户端，等客户端回一个操作。
---
--- offer 里除 `skills`（现在能用的技能名）之外还有 `unusable`（用不了的技能 + 原因），
--- 客户端拿它把技能摆成灰的。这里顺手打出来，证明协议里真的带着这个字段。
local used_once = {}
local told_unusable = {}
local function decide(ask)
  for _, u in ipairs(ask.unusable or {}) do
    if not told_unusable[u.name] then
      told_unusable[u.name] = true
      print(("[客户端]    （%s 用不了：%s）"):format(u.name, u.text or u.reason))
    end
  end

  local prefer = { "气力", "神经修复", "电击光束", "惊雷切", "日月皆伤", "渗透劲" }
  for _, want in ipairs(prefer) do
    for _, name in ipairs(ask.skills) do
      if name == want and not used_once[name] then
        used_once[name] = true
        return name
      end
    end
  end
  for _, name in ipairs(ask.skills) do
    if name == ask.fifth then return name end
  end
  return ask.skills[1]
end

local task = call("runGame", { roomId = 1 })
local turns = 0

while task and task.ask and turns < 200 do
  turns = turns + 1
  local ask = task.ask

  if ask.kind == "AskForAction" then
    local skill_name = decide(ask)
    print(("[客户端] → 给 %s（座位 %d）下指令：%s"):format(
      tostring(ask.name), ask.pet, tostring(skill_name)))
    task = call("handlePlayerAction", {
      roomId = 1,
      playerId = ask.pet,
      action = { type = "UseSkill", skillName = skill_name, target = 3 - ask.pet, targetId = 3 - ask.pet },
    })
  elseif ask.kind == "AskForChoice" then
    print(("[客户端] → 要选择：%s，选项 %s"):format(
      tostring(ask.prompt), table.concat(ask.choices or {}, "/")))
    task = call("handlePlayerAction", {
      roomId = 1,
      action = { type = "Choose", choice = (ask.choices or {})[1] },
    })
  else
    print(("[客户端] 不认识的询问：%s"):format(tostring(ask.kind)))
    break
  end
end

print()
if task and task.finished then
  print(("[客户端] 打完了：共 %d 回合，事件流 %d 条"):format(
    task.round or 0, #(task.events or {})))
else
  print("[客户端] 没打完（示例策略太笨，或者哪里卡住了）")
end
print(("[客户端] 一共来回了 %d 条 RPC 消息"):format(rpc.exchanges))

-- ============================ 五、收摊 ============================

call("bye", {})
child_in:close()
child_out:close()
os.execute(("rm -f %s %s"):format(to_child, from_child))
print("[客户端] 已关掉子进程连接")
