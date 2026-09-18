-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- ============================ 会话：一局对战在 Lua 侧的全部状态 ============================
--
-- 一个 `roomId` 对应一个会话。里面装着：房间适配器、`BattleLogic`、以及这一局的精灵。
--
-- ---------------------------- 房间适配器是什么 ----------------------------
--
-- `BattleLogic` 需要房间提供三件事（见 logic.lua 的注释）：
--   * `getAlivePets()`  —— 场上还站着的精灵
--   * `notifyPlayers()` —— "有事发生，告诉客户端"（Lua 没 socket，得让对面代发）
--   * `askToChoice()`   —— "要玩家做个选择"
--
-- 在 RPC 模式下，前两者的出口都是 `peer`。这里就是那个适配器。
--
-- ---------------------------- 事件为什么要攒着批量发 ----------------------------
--
-- 一次 `runGame` 可能一口气算完好几个回合，中间会产生几十条事件。
-- 每条都单独发一次 RPC 的话，光管道来回就够呛。所以 `notifyPlayers` 只**攒进队列**，
-- 等"要把控制权交回对面"的时候（`Session.flush`）一次性推过去——
-- 这也和架构文档 §5.3 第 3 步的形状一致（`events` 是个数组）。

Session = {}

---@class Session
---@field public room_id integer
---@field public room table @ 给 BattleLogic 用的房间适配器
---@field public logic BattleLogic
---@field public pets Pet[]
---@field public players table @ playerId --> { side = ..., pets = ... }

--- 所有活着的会话：roomId --> Session
Session.sessions = {}

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

  for side, player in ipairs(params.players or {}) do
    local player_pets = {}
    for _, pet_spec in ipairs(player.pets or {}) do
      -- 阵营按"第几个玩家"算；**座位号必须在这里排**：出手顺序、
      -- 目标选择（reply.target 就是座位号）、事件流记录都用它。
      pet_spec.side = pet_spec.side or (side - 1)
      pet_spec.seat = pet_spec.seat or (#pets + 1)
      local pet = Pet:new(pet_spec)
      table.insert(pets, pet)
      table.insert(player_pets, pet)
    end
    players[player.playerId] = { side = side - 1, pets = player_pets }
  end

  local room = {
    id = room_id,
    pets = pets,
    events = {},     -- 攒着待发的事件
  }

  function room:getAlivePets()
    local ret = {}
    for _, p in ipairs(self.pets) do
      if not p:isFainted() then table.insert(ret, p) end
    end
    return ret
  end

  --- 有事发生 → 先攒着（真正发出去在 Session.flush）
  function room:notifyPlayers(evt)
    table.insert(self.events, evt)
  end

  --- 非"真挂起"模式下问玩家选择：这里只能同步问对面一次。
  --- （`logic.interactive = true` 时走的是 doRequest 挂起那条路，不会到这儿）
  function room:askToChoice(pet, params)
    return Peer.call("askToChoice", {
      roomId = self.id,
      pet = pet and pet.seat or nil,
      prompt = params.prompt,
      choices = params.choices,
    })
  end

  -- 种子必须由对面给：战斗内不能自己取时间当种子，否则同一局重放不一致（§2.3）
  room.logic = nil
  local logic = BattleLogic:new(room, {
    seed = params.seed or ("room-" .. room_id .. "-game-1"),
    actors = pets,
  })
  logic:registerAllPets()

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
---@param kind string @ logic:start()/resume 的返回值："request" / "finished" / ...
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
      -- 整局事件流（回放用，架构文档 §6）。**必须是可序列化的**：
      -- logic.event_log 里那些条目的 `data` 是活的 TriggerData（里面还挂着 Pet 对象、
      -- 甚至互相引用成环），直接塞进返回值会让 json.encode 递归到崩——
      -- 表现是"子进程莫名其妙没了"。所以这里只取纯数据的那几个字段。
      events = Session.serializeLog(logic.event_log),
    }
  end

  local request = logic.pending_request
  if request == nil then
    return { finished = true, winner = logic.winner, round = logic.round }
  end
  return { ask = request }
end

--- 把事件流压成**纯数据**（去掉活对象），好让它能过 JSON/CBOR。
--- 回放要的是"发生了哪些事、什么顺序"，不是内存里的对象图。
---@param event_log table[]
---@return table[]
function Session.serializeLog(event_log)
  local ret = {}
  for _, e in ipairs(event_log) do
    table.insert(ret, {
      kind = e.kind,
      name = e.name,
      id = e.id,
      round = e.round,
      turn = e.turn,
      target = e.target,
      broken = e.broken,
    })
  end
  return ret
end

--- 开局时交给对面的"这一局长什么样"：每只精灵的当前六项数值、技能栏等等。
--- 战斗界面要有东西显示，靠的就是这份数据（架构文档的边界：Lua 只管算，显示交给对面）。
function Session.describe(session)
  return {
    roomId = session.room_id,
    pets = #session.pets,
    interactive = true,
    stat_fields = Pet.STAT_FIELDS,
    pet_stats = table.map(session.pets, function(p)
      return {
        seat = p.seat,
        name = p.name,
        level = p.level,
        elements = p.species.elements,
        hp = p.hp,
        max_hp = p.max_hp,
        stats = p:getStatSnapshot(),
        -- 种族值也一并给出去：界面显示面板时要用（静态数据，对面也存了一份，但省一次查询）
        base_stats = p.species.base_stats,
        skills = table.map(p:getSkills(), function(sk) return sk.name end),
        fifth = p:getFifthSkill() and p:getFifthSkill().name or nil,
        ability = p.ability and p.ability.name or nil,
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
      pets = table.map(session.pets, function(p) return { seat = p.seat, name = p.name, hp = p.hp } end),
    })
  end
  table.sort(ret, function(a, b) return a.roomId < b.roomId end)
  return ret
end

return Session
