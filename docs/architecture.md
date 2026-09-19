# 赛尔号同人联机服务器 —— 架构与规格（spec）

> 这是**架构规划文档**，不是实现。目标是先想清楚"长什么样、谁负责什么、两边怎么说话"，
> 让后续每一步实现都有据可依。会随开发持续修订。
>
> ## ⚠️ 本文档描述的是**重构前**的状态，以代码为准
>
> 正在进行的重构已经改掉了下面这些（本文件只在关键处做了标注，没有逐节重写）：
>
> * `packages/seer-core/lua/core/registry.lua` → **`core/engine.lua`**；
>   `core/timing.lua` / `core/trigger_data.lua` → **`core/trigger_event.lua` +
>   `core/events/`（TriggerData 基类 + 18 个时机类）**——不是本文档别处说的"31 个时机"；
> * **`server/battle/` 整个目录已删除**：现在是 `server/gamelogic.lua`（`GameLogic`，
>   `run()` 直接循环跑完整局）+ `server/gameevent.lua`（协程式流程事件基类，**待接**）；
> * `SkillSet` / `TriggerSkill` / `SkillSkeleton` / `core/effect/kinds.lua`
>   （效果类型注册表）**已删除**；`core/mark/*`（印记/异常状态）**整体待重建**；
> * `Pet` 上的战斗状态（当前体力 / 能力等级 / 印记 / PP / 封印 / 濒死 / side / seat）
>   **已全部删除**；`examples/` 与 `tests/test_core.lua` 也已删除。
>
> 当前真实结构与本轮清理后"还缺什么"，看 `packages/seer-core/README.md` 的 §1 / §1.1
> 与 `packages/seer-core/lua/seer.lua` 的文件头。

---

## 1. 一句话定位

一个**回合制精灵对战**的联机服务器：C++ 负责网络 / 房间 / 存储 / 进程管理，
**战斗规则放独立的 Lua 进程**，两边通过一条 RPC 管道通信。客户端只发"意图"，不发"结果"。

参考实现：隔壁 `freekill-asio`（房间制回合制卡牌服务端）。它就是这个架构：
`RoomThread`（C++ 线程 + Lua 子进程）用 stdin/stdout 管道 + RPC 通信，
Lua 出规则、C++ 出 IO，本 spec 基本沿用并简化它。

---

## 2. 核心原则（不可妥协的底线）

1. **服务器权威（server-authoritative）**
   客户端只发送意图：`我要用技能 1001`。伤害、命中、暴击、克制、状态、胜负——全在服务器算。
   任何时候都不信客户端算出来的任何数字。

2. **逻辑与 IO 分离**
   战斗规则（Lua）不碰 socket、不碰数据库、不直接拿墙钟时间；
   网络/存储/定时器（C++）不懂游戏规则。
   两边只通过一个**窄的 RPC 接口**见面——就像现在 `ServerSocket` 和 `ChatServer` 的关系，
   只是这次中间隔着进程。

3. **确定性（determinism）**
   同一局、同一串事件序列 → 同一结果。这是回放、断线重连、争议裁决的基础。
   随机数必须由战斗逻辑自己管理种子，不能用墙钟/进程随机。

4. **进程隔离**
   Lua 崩溃/卡死不能拖垮整个服务器。一个房间绑定一个（或少数几个）Lua 进程，
   崩了回收这个房间，别的不受影响。

5. **可热更新**
   改战斗规则 = 换 Lua 脚本，不重启 C++ 服务。参考 freekill：房间对脚本做 md5 校验，
   版本旧了就标记 `isOutdated` 自然淘汰。

---

## 3. 总体架构

```
                  ┌────────────────────────────────────────────┐
                  │               C++ 服务端进程（权威 IO 外壳）   │
客户端 ── TCP ──>  │  ServerSocket / ClientSocket               │
  (只发意图)       │        │                                   │
                  │  Router（按消息 type 分发）                   │
                  │        │                                   │
                  │  User / Session（登录、在线、封禁）           │
                  │        │                                   │
                  │  Lobby / RoomManager / Room（建房、进房、观战）│
                  │        │ 投递玩家操作                        │
                  │  RoomThread（io_context + 线程）             │
                  │        │ stdin/stdout 管道 + RPC            │
                  └────────┼────────────────────────────────────┘
                           ▼
                  ┌────────────────────────────────────────────┐
                  │      Lua 子进程（战斗大脑，每房间一个）        │
                  │  规则、结算、状态机、事件、随机数、回放          │
                  └────────────────────────────────────────────┘
                           ▲
                  ┌────────┴────────────────────────────────────┐
                  │   C++ 侧：SQLite（账号/精灵/战绩/存档）        │
                  │            Admin Shell（管理命令）           │
                  └────────────────────────────────────────────┘
```

关键的一句话：**Lua 是大脑，C++ 是身体。** Lua 想"延时 800ms 再继续"或"告诉所有客户端
某人被打掉了 200 血"，它自己做不到（它没有 socket、没有定时器），于是它发一个"信号"给 C++，
让 C++ 去干。这个**双向信号**是整套架构最容易被误解、也最重要的部分，见 §5。

---

## 4. 为什么战斗逻辑放独立 Lua 进程？

你问的"用单独 lua 进程完成战斗逻辑？"——**对，而且这是正确选择**，理由：

| 理由 | 说明 |
| --- | --- |
| 崩溃隔离 | 战斗规则是最容易出错、最可能被恶意输入触发 bug 的地方；独立进程崩了只影响一个房间 |
| 沙箱 | Lua 默认碰不到 C++ 的内存/网络/文件系统，只能调我们显式暴露的那几个函数 |
| 热更新 | 改规则 = 换脚本，不重启服务 |
| 并行 | 多个 Lua 进程跑在不同线程，多房间互不阻塞 |
| 分工 | 写规则的人只写 Lua，不用懂 asio |

**为什么不用替代方案：**

- **内嵌 Lua（sol2 / lua C API 直接嵌进程内）**：热更新和崩溃隔离得自己造；Lua 单线程，
  一个房间卡住就卡死整个进程。
- **纯 C++ 写规则**：改规则要重编译、重启、全服掉线，迭代太慢。

**代价（要提前知道，别后面才踩）：**

- 每次 C++ ↔ Lua 都要**过管道 + 序列化**，有开销。freekill 一开始用 JSON，后来因性能换成了
  CBOR——我们也可以"先 JSON 跑通，真到瓶颈再换 CBOR"。
- 进程管理变复杂：fork/exec、管道、超时、回收、脚本版本。
- 跨进程调试比内嵌难，得做好日志和"能单跑 Lua 脚本"的测试入口。

---

## 5. RPC 协议：C++ 和 Lua 怎么说话（本 spec 的核心）

### 5.1 传输

- 载体：子进程的 **stdin/stdout 管道**（Lua 从 stdin 读、往 stdout 写）。
- 分帧：**长度前缀**（4 字节大端长度 + 消息体），和项目 3 要做的客户端协议同款思路。
- 序列化：**先 JSON**（人可读、好调试），预留换 CBOR 的口子——这是 freekill 走过的路。

### 5.2 消息类型

| 类型 | 方向 | 有 id 吗 | 说明 |
| --- | --- | --- | --- |
| Request | 双向 | 有 | 要对方回一条 Response |
| Response | 双向 | 有（对应请求） | 带 result 或 error |
| Notification | 双向 | 无 | 单向，不回 |

形如（JSON-RPC 2.0 的简化版，freekill 的 `jsonrpc.h` 就是这么定义的）：

```json
// 请求
{ "method": "handlePlayerAction", "params": { ... }, "id": 42 }
// 响应
{ "id": 42, "result": { ... } }            // 或 { "id": 42, "error": { "code":..., "message":... } }
// 通知（无 id）
{ "method": "notifyPlayers", "params": { ... } }
```

### 5.3 事件流：一个"用技能"的完整来回

这是理解整套架构的关键示例。假设玩家 3 对玩家 5 用技能 1001：

```
1. C++ → Lua  (request)      玩家操作到达
   { "method":"handlePlayerAction", "params":{
       "roomId":1, "playerId":3,
       "action":{ "type":"UseSkill", "skillId":1001, "targetId":5 }
     }, "id":42 }

2. Lua 内部结算（伤害/命中/克制/状态），然后……

3. Lua → C++  (notification) 让 C++ 把结果推给所有客户端看
   { "method":"notifyPlayers", "params":{
       "roomId":1,
       "events":[ { "type":"SkillUsed", "playerId":3, "skillId":1001,
                    "targetId":5, "damage":200, "crit":true } ]
     } }

4. Lua → C++  (request)      Lua 要一个 800ms 的定时器（等客户端播动画）
   { "method":"delay", "params":{ "roomId":1, "ms":800 }, "id":7 }
   C++ → Lua  (response)
   { "id":7, "result":null }

5. （800ms 后）
   C++ → Lua  (notification) 定时器到点，唤醒 Lua
   { "method":"timerFired", "params":{ "roomId":1, "reason":"skill_anim" } }

6. Lua → C++  (notification) 继续推下一阶段（比如目标倒下）
   { "method":"notifyPlayers", "params":{ "roomId":1, "events":[ { "type":"PetFainted", "petId":9 } ] } }
```

**注意方向是双向的**：不是"C++ 单向调用 Lua"，而是 Lua 作为大脑，反过来通过信号
（`notifyPlayers` / `delay` / `gameOver` …）**命令 C++ 去执行 IO**。C++ 是 Lua 的手和脚。

### 5.4 C++ 需要暴露给 Lua 的信号（Lua → C++ 的方法）

这是 C++ 侧 `RpcLua` 要注册的方法表（对照 freekill 的 `RoomThread` 信号）：

| 方法 | 含义 |
| --- | --- |
| `notifyPlayers(roomId, events)` | 把一批事件推给房间里的客户端 |
| `notifyPlayer(roomId, playerId, event)` | 推给单个玩家（含私密信息，如手牌/精灵） |
| `delay(roomId, ms)` | 请求一个定时器 |
| `timerFired(roomId, reason)` | （C++→Lua 通知）定时器到点 |
| `setPlayerState(...)` | 通知 C++ 某玩家状态变了（如已准备/已掉线） |
| `gameOver(roomId, result)` | 一局结束，C++ 负责结算战绩、落盘 |
| `log(level, msg)` | Lua 的日志交给 C++ 统一记录 |

### 5.5 C++ 会发给 Lua 的请求（C++ → Lua 的方法）

| 方法 | 含义 |
| --- | --- |
| `handlePlayerAction(roomId, playerId, action)` | 玩家操作（用技能/换精灵/用道具/逃跑/认输） |
| `onPlayerJoin / onPlayerLeave` | 玩家进房、掉线、重连 |
| `startGame(config)` | 开局（房主确认后） |
| `loadScript(version)` / `ping` | 版本校验、心跳 |

---

## 6. 战斗系统设计要点（Lua 侧，spec 层面）

- **回合制状态机**：`等待输入 → 结算 → 广播 → （延时）→ 等待输入`。Lua 是唯一状态拥有者。
- **事件驱动**：一切动作都是"事件"，Lua 消费事件、产生新事件（伤害、状态、胜负），
  再由 `notifyPlayers` 吐给 C++。**事件流本身就能当回放/复盘**。
- **随机数**：战斗内用 Lua 自己 `math.randomseed(seed)` 的确定性随机，种子可记录，
  保证重放一致。
- **属性克制 / 状态 / 命中 / 暴击**：这些规则都在 Lua 里，与网络层彻底无关。
- **延时的作用**：客户端要看技能动画，服务器不能"瞬间算完"，所以 Lua 用 `delay` 让
  C++ 帮它等一下再继续。这就是 freekill `RoomThread::delay` 存在的意义。
- **断线重连**：因为权威在 Lua、事件可重放，重连 = 把"从开局到现在的状态快照 + 事件"补发。

**目前实现到哪一步**（细节见 `packages/seer-core/README.md`）：

> ⚠️ 已过时：下面这一节描述的是重构前的两层事件实现，**已不成立**——
> 时机现在是 `core/trigger_event.lua` + `core/events/`（18 个时机类，基类只管定义，
> 调度在 `GameLogic:trigger` 里按优先级跑一遍）；**流程事件（GameEvent）的事件栈
> 还没有移植进新的 `GameLogic`**，`server/gameevent.lua` 目前只保证能 require。
> 面向玩家的"问选择"（Request 层）也还没接进回合循环。

- ⬜ **两层事件**（重构中）：
  * **时机**：`core/trigger_event.lua`（TriggerEvent 基类）+ `core/events/`（18 个时机类）；
    `GameLogic:trigger` 按优先级降序跑一遍。原来那套 refresh 两轮 / 打断计数 /
    问玩家取选项还没搬回来；
  * **流程事件**：`server/gameevent.lua`（协程、ClearEvent）——**能 require，但没接进流程**：
    `logic:getCurrentEvent/pushEvent/resumeEvent`、`game_event_stack` 这些原 BattleLogic
    的入口在新的 `GameLogic` 上还不存在。
- ✅ 技能/精灵是 **spec 驱动**的：规则作者只写声明式表，核心负责造对象。
- ⬜ 效果（Effect）只有类 + `Seer:createEffect` 这个创建入口，
  **执行/挂载那一层还没重建**；效果类型注册表（旧 `core/effect/kinds.lua`）已删除；
  异常状态（`core/mark/*`）待重建。
- ✅ 生命值与回合的流程（照 freekill 的 `hp.lua` / `gameflow.lua`）：
  `ChangeHp`（唯一改 hp 的入口）/ `Damage` / `Recover`、
  `Round`（一大回合）/ `Turn`（一次行动）/ `UseSkill`。
- ✅ 确定性随机（xoshiro256\*\*，自带种子与状态导出）、事件流记录（两层都记，可回放）、
  属性克制与伤害公式；`logic:start()` 已经能把一整局打完并分出胜负。
- ✅ 事件树查询：`findParent` / `searchEvents` —— "这次伤害是哪次技能使用引起的"能直接回答。
- ✅ 询问机制（抄 freekill 的 `Request` / `RequestHandler`）：规则只说"我要问这件事"，
  "谁去答"由处理器决定 —— 单机命令行（`make play`）、AI（`request_hook`）、
  真人客户端（挂起 + `logic:resume(答复)`）都是同一个接口的不同实现，
  请求内容只有一处定义（`Request:toJson`）。
- 🔶 RPC 层**已经能用了**（jsonrpc + stdio + peer + dispatchers，整份抄自新月杀的核心包），
  `make example-rpc` 就是"两个真进程 + 真管道"跑完一整局；
  挂起/恢复（`logic:start()` 返回 `"request"`、`logic:resume(答复)`）也已就位。
  缺的只是**把对面换成 C++ 的 RoomThread** —— 项目 6。
- ⬜ 回合状态机里剩下的分支：换精灵、道具、逃跑 —— 项目 7。
- ⚠️ 属性克制表、异常状态数值、性格名、示例图的种族值都是**占位数据**，需按图鉴替换。

---

## 7. 数据模型与持久化（谁管什么）

| 数据 | 类别 | 谁管 | 放哪 |
| --- | --- | --- | --- |
| 精灵图鉴、技能表、属性克制表 | 静态配置 | Lua 启动时读 | 配置文件 / SQLite 只读表（随 Lua 包分发） |
| 账号、密码哈希、封禁 | 动态 | C++（`User`） | SQLite |
| 玩家拥有的精灵、等级、个体值 | 动态 | C++ | SQLite |
| 战绩、胜率 | 动态 | C++（结算时落盘） | SQLite |
| 对局进行中的状态 | 临时 | Lua 内存 | 不落盘，结束即弃（或存档） |

**边界铁律：Lua 不直接写数据库。** Lua 算完战斗，用 `gameOver(roomId, result)` 把结果交回
C++，由 C++ 决定怎么存。这样数据库访问永远只有一个入口，也符合"逻辑与 IO 分离"。

---

## 8. 安全与反作弊

- 只信意图：客户端消息里凡是"数字结果"一律拒绝，服务端重算。
- 消息校验：字段类型、取值范围、是否你的回合、是否你的精灵——C++ 先粗筛，Lua 再细筛。
- 限流：每条连接每秒钟的消息数上限（现在 `ClientSocket` 的 `kMaxPendingBytes` 是字节层面的，
  以后加条数层面的）。
- 对局超时：Lua 的 `delay` 机制天然能实现"回合限时"，超时视为放弃操作。
- 观战只能看公开状态：`notifyPlayer`（私密）和 `notifyPlayers`（公开）必须分开，别泄露手牌/精灵。

---

## 9. 目录结构规划（从当前项目演进）

```
seer-asio/
├── src/                         # C++ 服务端
│   ├── main.cpp
│   ├── common/                  # protocol / net / log（已有）
│   ├── network/                 # ServerSocket / ClientSocket（已有）
│   ├── router/                  # 按消息 type 分发（项目 3/4）
│   ├── user/                    # 登录、Session、封禁
│   ├── room/                    # Lobby / Room / RoomManager
│   ├── gamelogic/               # RoomThread、RpcLua（对应 freekill 同名目录）
│   ├── db/                      # SQLite 封装
│   └── admin/                   # 管理员命令行
├── packages/
│   └── seer-core/               # Lua 战斗规则（对应 freekill 的 packages/freekill-core）✅ 已落地
│       ├── lua/seer.lua         #   载入入口（对应 freekill.lua + fk_ex.lua）
│       ├── lua/core/            #   基类：engine(注册表 Seer) / skill / pet /
│       │                        #   trigger_event(时机基类) / elements(属性克制) / gameobject
│       │   ├── events/          #   时机：TriggerData 基类 + 18 个时机类
│       │   │                    #   （gameflow 流程类 / attack 出手与伤害链）
│       │   ├── effect/          #   效果：effect.lua（Effect 类；⚠ 没有 init.lua）
│       │   └── mark/            #   印记：init + status + buff —— ⚠ 待重建，暂不加载
│       ├── lua/server/gamelogic.lua # 战斗逻辑 GameLogic：run() 就是整局主循环
│       ├── lua/server/gameevent.lua # 流程事件基类（协程；事件栈尚未移植）
│       ├── lua/server/request/  #   询问机制：Request + 处理器（命令行/AI/RPC）
│       ├── lua/server/rpc/      #   RPC：jsonrpc / stdio / peer / dispatchers / entry
│       ├── lua/specs/           #   图鉴与技能的声明式数据（spec），可由扩展包替换
│       │                        #   standard/：雷伊与盖亚（纯数据；旧 demo/effects 已删）
│       └── lua/seer.lua         #   也是"加载自检"的入口：lua5.4 lua/seer.lua
├── server/                      # SQL 建表脚本
└── tests/                       # C++ 侧的冒烟/交互测试
```

命名刻意对齐 freekill，读它源码时能直接对上。四个基类的设计说明、与 freekill 的
名词对照、以及"现在**没有**做什么"的诚实清单，都在 `packages/seer-core/README.md`。

---

## 10. 分阶段路线（衔接现有进度）

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 项目 1 | socket 广播（Asio + 协程） | ✅ 完成 |
| 项目 2 | 命令解析（文本协议） | ✅ 完成 |
| 项目 3 | JSON 协议（长度前缀 + JSON 消息） | ⬜ 下一个 |
| 项目 4 | Router + User/Session（登录、账号雏形） | ⬜ |
| 项目 5 | Lobby / Room / RoomManager（建房、进房、准备、观战） | ⬜ |
| — | **Lua 侧战斗核**：精灵/技能/效果 + 两层事件（时机 + 流程）+ 回合/生命值流程 | ✅ 能跑完整局 |
| 项目 6 | **Lua 子进程 + RPC 骨架**：C++ 拉起一个 Lua，来回 ping/pong 先跑通 | ⬜ 关键里程碑（Lua 侧方法表已就位） |
| 项目 7 | 最小战斗：两只精灵、回合制、克属 + 伤害、一个 `delay` 动画 | 🔶 出战顺序/克制/伤害已能跑；换精灵/道具/逃跑待做 |
| 项目 8 | SQLite 持久化、断线重连、回放、Admin Shell | ⬜ |

**项目 6 是分水岭**：之前都是在 C++ 单进程里练手（你已经做了 1、2，正在做 3），
项目 6 开始才真正进入"两个进程 + RPC"的架构。所以 3、4、5 尽量把"进程边界"留在心里——
Router、Room、消息格式都要设计成"将来跨进程也能用"。

---

## 11. 开放问题（待定，实现时再拍板）

1. 一个 Lua 进程管一个房间，还是管一组房间？（freekill 是 `RoomThread` 管多个 `Room`，容量可配）
2. RPC 用 JSON 还是直接上 CBOR？（建议先 JSON，性能真出问题再换）
3. 精灵/技能配置表用什么格式？Lua 原生 table、JSON，还是 SQLite？
4. 观战是否允许看"未出手玩家的精灵"？（涉及信息可见性，要在 §8 的私密/公开边界里定死）
5. 是否做"回放"？如果做，事件流就要从一开始按可重放标准记录。

---

## 12. 本 spec 想达到的效果

读完它，任何接手的人应该能回答：

- 为什么战斗逻辑在 Lua、而不在 C++？
- 一条玩家操作从客户端到"屏幕上的伤害数字"，经过哪些模块、走了几趟管道？
- Lua 想延时/想广播，它自己做不到，靠什么让 C++ 代劳？
- 什么东西该进数据库、什么东西该留在 Lua 内存？
- 下一阶段该先做哪件事、为什么？
