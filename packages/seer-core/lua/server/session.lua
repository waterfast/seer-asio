-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 会话：一局对战在 Lua 侧的全部状态 ============================
--
-- 一个 `roomId` 对应一个会话。里面装着：房间适配器、`GameLogic`、以及这一局的精灵。
--
-- BattleRoom 保存局内对象、效果来源和事件队列；Session 只添加协议适配。
-- 规则效果通过对象挂载，GameLogic:run 在 BattleStart 前登记双方来源。
-- 交互式询问尚未接入 GameLogic，下面的 askToChoice 保留同步协议入口。
--
-- ---------------------------- 事件为什么要攒着批量发 ----------------------------
--
-- 一次 `runGame` 可能一口气算完好几个回合，中间会产生几十条事件。
-- 每条都单独发一次 RPC 的话，光管道来回就够呛。所以 `notifyPlayers` 只**攒进队列**，
-- 等"要把控制权交回对面"的时候（`Session.flush`）一次性推过去——
-- 这也和架构文档 §5.3 第 3 步的形状一致（`events` 是个数组）。
--
-- ---------------------------- 当前状态：交互式询问还没接上 ----------------------------
--
-- 重构后的 `GameLogic:run()` 是"一跑到底"的（直接循环，内部 `pickAction` 自动选招，
-- 见 server/gamelogic.lua 的 TODO），没有 `start()` / `resume(reply)` 那套
-- "算到要问人就停下"的机制。所以：
--   * `Dispatchers.runGame` 现在一次就把整局跑完，返回 finished 结果；
--   * `Dispatchers.handlePlayerAction` 暂时没有挂起点可恢复 → 明确返回 not_implemented。
--   `Session.next_task` 的形状先保持不变（`{ finished, winner, round, events }`），
--   等 Request 层接进 GameLogic、`run()` 能中途停下问人之后，这里再加 `{ ask = ... }`。

Session = {}

---@class Session
---@field public room_id integer
---@field public room BattleRoom @ 局内状态容器
---@field public logic GameLogic
---@field public pets Pet[]
---@field public players table @ playerId --> { side = ..., pets = ... }

--- 所有活着的会话：roomId --> Session
Session.sessions = {}

-- ---------------------------- 事件出队前的净化 ----------------------------
--
-- `GameLogic:notify` 发出来的是"事件表"，里面**挂着活对象**：`target = <Pet>`、
-- `source = <Pet>` 这样的字段（见 server/gamelogic.lua 的 changeHp / doAttack）。
-- 这种东西过不了 JSON/CBOR——轻则把整棵 Pet + 技能表都序列化出去（体积爆炸），
-- 重则遇到环直接递归到崩（表现是"子进程莫名其妙没了"）。
-- 所以在**入队时**就把 Pet 换成标识（座位优先，没座位用名字）：协议对面认的是
-- 座位号 / 名字，不是内存地址。
local PET_KEYS = { target = true, source = true, pet = true, who = true }

---@param evt table
---@return table
local function plainEvent(evt)
  if type(evt) ~= "table" then return evt end
  local ret = {}
  for k, v in pairs(evt) do
    if PET_KEYS[k] and type(v) == "table" then
      ret[k] = v.seat or v.name
    elseif k == "pets" and type(v) == "table" then
      -- 数组形式的精灵列表（MoveFocus 那种）
      local ids = {}
      for _, p in ipairs(v) do
        ids[#ids + 1] = (type(p) == "table") and (p.seat or p.name) or p
      end
      ret[k] = ids
    else
      ret[k] = v
    end
  end
  return ret
end

---@param room_id integer
---@return Session?
---@return string? err
function Session.get(room_id)
  if type(room_id) ~= "number" then return nil, "缺 roomId" end
  local session = Session.sessions[room_id]
  if session == nil then return nil, ("房间 %s 不存在"):format(tostring(room_id)) end
  return session
end

--- 造一个会话：把对面传来的玩家数据变成能参战的精灵，接进战局。
---@param room_id integer
---@param params table @ `{ seed, players = { { playerId, pets = { PetSpec... } } } }`
---@return Session
function Session.create(room_id, params)
  local pets = {}
  local players = {}
  local units = {}

  for side, player in ipairs(params.players or {}) do
    local player_pets = {}
    for _, pet_spec in ipairs(player.pets or {}) do
      -- 玩家分组通过 Unit 传给逻辑层，房间另行维护全局协议座位。
      local pet = Pet:new(pet_spec)
      table.insert(pets, pet)
      table.insert(player_pets, pet)
    end
    players[player.playerId] = { side = side - 1, pets = player_pets }
    units[side] = Unit:new{ id = player.playerId, name = player.name, pets = player_pets }
  end

  local room = BattleRoom:new{ id = room_id, units = units, pets = pets }

  --- 非"真挂起"模式下问玩家选择：这里只能同步问对面一次。
  --- TODO(交互式询问未接)：新的 GameLogic 还没接 Request 层，现在没人会调它；
  --- 等接上之后再按 `logic.pending_request` / `logic:resume` 那套改回来。
  function room:askToChoice(pet, params)
    return Peer.call("askToChoice", {
      roomId = self.id,
      pet = self:seatOf(pet),
      prompt = params.prompt,
      choices = params.choices,
    })
  end

  -- 种子必须由对面给：战斗内不能自己取时间当种子，否则同一局重放不一致。
  room.logic = nil
  local logic = GameLogic:new({
    units = units,
    room = room,
    rng_seed = params.seed or ("room-" .. room_id .. "-game-1"),
  })
  -- 事件出口：GameLogic 每 notify 一条，就攒进 room.events（由 Session.flush 推出去）
  logic.on_notify = function(_, evt)
    table.insert(room.events, plainEvent(evt))
  end
  room.logic = logic
  Seer:setLogic(logic)

  local session = {
    room_id = room_id,
    room = room,
    logic = logic,
    pets = pets,
    players = players,
  }
  Session.sessions[room_id] = session
  return session
end

--- 把攒下的事件推给对面。
--- 用**单向通知**（不等回复）：推事件是"尽力而为"的旁路，绝不该因为它卡住战斗。
function Session.flush(session)
  local events = session.room.events
  if #events == 0 then return 0 end
  session.room.events = {}

  -- round/turn 让对面知道这些事发生在什么时候（客户端要按顺序播动画）
  Peer.notify("notifyPlayers", {
    roomId = session.room_id,
    round = session.logic.round,
    events = events,
  })
  return #events
end

--- 下一个"要对面处理的事情"。所有 dispatcher 方法的返回值都是它。
---@param session Session
---@param kind string @ 兼容位：原 BattleLogic 的 `logic:start()/resume` 返回值（"request"/"finished"）。
---   新的 `GameLogic` 没有这两个入口，现在只会传 "finished"。
---@return table
function Session.next_task(session, kind)
  -- 交回控制权之前先把攒的事件推出去：客户端得先看到"刚刚发生了什么"，
  -- 才谈得上"接下来要我做什么"
  Session.flush(session)

  local logic = session.logic
  if kind == "finished" or logic.game_over then
    return {
      finished = true,
      winner = logic.winner,
      round = logic.round,
      -- 整局事件流（回放用）。**必须是可序列化的**：
      -- logic.event_log 里存的是活的 TriggerEvent 对象（它们的 `data` 是 TriggerData，
      -- 里面还挂着 Pet、甚至互相引用成环），直接塞进返回值会让 json.encode 递归到崩——
      -- 表现是"子进程莫名其妙没了"。所以这里只挑纯数据的字段出来。
      events = Session.serializeLog(logic.event_log),
    }
  end

  -- TODO(交互式询问未接)：原来这里是
  --   local request = logic.pending_request
  --   if request ~= nil then return { ask = request } end
  -- 但 `pending_request` 是原 BattleLogic 的字段，新的 GameLogic 上还没有
  -- （它一跑到底，不会停在"要问人"的地方）。所以现在只可能返回"跑完了"，
  -- 剩下的情况当作出错报回去，别让对面拿到一个看不懂的空包。
  return {
    finished = false,
    round = logic.round,
    error = "logic_not_interactive",
    message = "GameLogic 还没接 Request 层：无法停在需要玩家操作的地方",
  }
end

--- 把事件流压成**纯数据**（去掉活对象），好让它能过 JSON/CBOR。
--- 回放要的是"发生了哪些事、什么顺序"，不是内存里的对象图。
---
--- 注意事件流里装的是 **TriggerEvent 实例**（`logic.event_log` 里 append 的，
--- 见 server/gamelogic.lua 的 `GameLogic:trigger`），它们的字段是
--- id / target / data / broken / break_reason，时机名要从类上取（`e.class.name`）。
--- 这里只取纯数据；`target` 是 Pet 对象，所以只留名字。
---@param event_log table[]
---@return table[]
function Session.serializeLog(event_log)
  local ret = {}
  for _, e in ipairs(event_log or {}) do
    local data = e.data
    table.insert(ret, {
      id = e.id,
      -- 时机名（BattleStart / BeforeAttack / …）
      kind = e.class and e.class.name or nil,
      target = e.target and e.target.name or nil,
      broken = e.broken,
      break_reason = e.break_reason,
      round = type(data) == "table" and data.turn_number or nil,
    })
  end
  return ret
end

--- 开局时交给对面的"这一局长什么样"：每只精灵的当前六项数值、技能栏等等。
--- 战斗界面要有东西显示，靠的就是这份数据（边界：Lua 只管算，显示交给对面）。
function Session.describe(session)
  return {
    roomId = session.room_id,
    pets = #session.pets,
    stat_fields = Pet.STAT_FIELDS,
    pet_stats = table.map(session.pets, function(p)
      return {
        -- 协议座位（全场唯一）：会话层自己编的号，不是 GameLogic 那个"阵营内序号"
        seat = session.room:seatOf(p),
        name = p.name,
        level = p.level,
        elements = p.species.elements,
        -- 当前体力/上限是战斗逻辑的运行时状态（GameLogic 开局时挂到 pet 上）
        hp = p.hp,
        max_hp = p.max_hp,
        -- 六项属性值：`getStats()`（Pet 上已无 getStatSnapshot）
        stats = p:getStats(),
        -- 种族值也一并给出去：界面显示面板时要用（静态数据，对面也存了一份，但省一次查询）
        base_stats = p.species.base_stats,
        skills = table.map(p:getSkills(), function(sk) return sk.name end),
        fifth = p:getFifthSkill() and p:getFifthSkill().name or nil,
        -- 特性（ability）**暂时不给了**：Pet / PetSpecies 上已经没有这个字段
        -- （见 core/pet.lua 与 specs/standard/species.lua 的说明），特性体系待重建。
      }
    end),
  }
end

--- 所有会话的概况（管理/调试用）
function Session.list()
  local ret = {}
  for room_id, session in pairs(Session.sessions) do
    table.insert(ret, {
      roomId = room_id,
      round = session.logic.round,
      over = session.logic.game_over or false,
      pets = table.map(session.pets, function(p)
        return { seat = session.room:seatOf(p), name = p.name, hp = p.hp }
      end),
    })
  end
  table.sort(ret, function(a, b) return a.roomId < b.roomId end)
  return ret
end

return Session
