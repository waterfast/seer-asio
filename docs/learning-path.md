# 学习路线与设计笔记

> 这份文档是给"以后接着做"的自己看的：每一步做什么、怎么算做完、坑在哪。
>
> ## ⚠️ 本文档描述的是**重构前**的状态，以代码为准
>
> 里面的"设计笔记 / 踩坑记录"部分（为什么这么设计、错在哪）仍然值得读，
> 但**具体文件与 API 已经变了**，别照着抄：
>
> * `core/registry.lua` → `core/engine.lua`；`core/timing.lua` / `core/trigger_data.lua`
>   → `core/trigger_event.lua` + `core/events/`（18 个时机类）；
> * `server/battle/*` 整个删除 → `server/gamelogic.lua`（`GameLogic`）；
> * `core/effect/kinds.lua`（效果类型注册表）、`Effect.registerKind`、
>   `SkillSet` / `TriggerSkill` / `SkillSkeleton` 都已删除；
> * `Status.register` / `Mark:attach` / `logic:applyMark` / `pet.marks` / `pet.effects` /
>   `pet:recalcStats` 这些印记与状态 API **随重构一起没了**，印记体系待重建
>   （缺什么见 `packages/seer-core/lua/core/mark/init.lua` 文件头）；
> * `docs/effects-marks-status.md` **已删除**（描述的就是那套待重建的效果/印记结构），
>   本文里所有指向它的链接都失效了；
> * `make test-lua` / `tests/test_core.lua`（870 项）也已删除，新的测试还没写。
>
> 当前真实结构与"还缺什么"，看 `packages/seer-core/README.md` 的 §1 / §1.1。

## 总体路线

```
项目 1  Console Chat Server   纯 socket + 广播            ← 已完成
项目 2  Command Server        服务端解析命令              ← 下一步
项目 3  JSON Protocol         每条消息是一个 JSON 对象
--------------------------------------------------------------
战斗核  Lua 战斗规则           精灵/技能/效果/事件 + 时机调度   ← 已搭好骨架
--------------------------------------------------------------
之后    登录/账号、房间/大厅、精灵与对战逻辑、数据持久化……
```

参考项目 `../freekill-asio`（房间制回合制卡牌服务端）里值得对照阅读的文件：

| 主题 | 文件 |
| --- | --- |
| 整体架构导览 | `docs/architecture-learning.md`（先看这个） |
| 监听与连接管理 | `src/network/server_socket.h` / `.cpp` |
| 单条连接、收发队列、断开 | `src/network/client_socket.h` / `.cpp` |
| 消息分发 | `src/network/router.h` / `.cpp` |
| 业务层（用户、房间、大厅） | `src/server/server.h` / `src/server/room/*` |
| 和 Lua 子进程的 RPC | `src/server/rpc-lua/jsonrpc.h` / `.cpp` |

注意 freekill-asio 的网络层是 **Boost.Asio + C++20 协程**，线上协议是 **CBOR 二进制**
（不是 JSON 文本）。我们按学习路线先用文本，等协议定型再考虑换二进制/异步。

---

## 项目 1：Console Chat Server ✅

**目标**：客户端连上来发字符串，服务端广播给其它所有人。

**代码**（Asio + C++20 协程版）：

- 网络层：`src/network/server_socket.{h,cpp}`、`src/network/client_socket.{h,cpp}`
- 业务层：`src/server/chat_server.{h,cpp}`
- 入口：`src/main.cpp`（服务端）、`src/client/main.cpp` + `src/client/console_client.{h,cpp}`（客户端）
- 协议常量：`src/common/protocol.h`

**这一课真正学到的**：

- 基础：`socket/bind/listen/accept/connect` 各自在干什么；TCP 是字节流，必须自己分帧
- 分层：为什么把 `ServerSocket`（监听）和 `ClientSocket`（单条连接）独立出来、用回调接起来
  —— 网络与业务解耦、职责单一、可替换、可测试，且和 freekill-asio 对齐
- 现代范式：`io_context` 单线程 + `co_spawn`，每条连接两个协程（reader/writer），
  `co_await` 挂起不阻塞线程，没有锁没有竞态
- 发送队列为什么还是必须有：并发写同一个 socket 是未定义行为，得排队经过 writer
- 生命周期：detached 协程里抓 `shared_from_this()`（freekill 用 `weak_from_this` + lock，等价）
- 分帧用 `async_read_some` + 手找 `'\n'`，而不是 `async_read_until`——实测后者的 streambuf
  在收不到分隔符时会无限增长（`max_size` 挡不住），手写才能精确限制"半包上限"
- 优雅退出用 `net::signal_set`；stdin/stdout 用 `net::posix::stream_descriptor` 包成流
- 两种 Asio 的差别：独立版 `asio::error_code`（=std）vs Boost 的 `boost::system::error_code`，
  用 `src/common/net.h` 里的 `seer::error_code` 统一掉，一个 `-DSEER_USE_BOOST_ASIO` 切换

**验收**：`make test` —— 19 项冒烟检查 + pty 交互检查，独立版 Asio 和 Boost.Asio 各跑一遍全绿。

---

## 项目 2：Command Server ⬜

> 完整任务书在 `docs/project2-command-server.md`，这一步由你自己动手实现。

**目标**：不再随便传字符串，而是传命令，服务端解析并作出反应。

```
LOGIN nk
USE_SKILL 1001
SURRENDER
```

**动手位置**：`src/server/chat_server.cpp` 的 `ChatServer::onMessage()`，那里已经留了注释标记。
建议把命令解析拆成独立文件（例如 `src/server/command.h/.cpp`），
freekill-asio 是用 `src/network/router.cpp` 做消息分发这件事的。

**建议的实现顺序**：

1. **切词**：`std::istringstream` 或按空格 `split`，顺手处理多个空格/首尾空白。
2. **命令表**：`std::unordered_map<std::string, Handler>`，比一长串 `if/else` 好扩展，
   也是 freekill-asio `Router` 的思路。
3. **每个连接挂状态**：`Client` 里加 `bool loggedIn`、`std::string account`、
   `int roomId` 之类。这就是"会话状态"的雏形。
4. **错误处理要统一**：未知命令、参数个数不对、没登录就 `USE_SKILL`，
   都回一条固定的错误消息（例如 `ERR 401 未登录`），不要让客户端猜。
5. **服务端主动推送**：广播系统消息的机制项目 1 已经有了，直接复用。

**要定的约定**（可以在这一步就把"协议味"做出来）：

- 命令名统一大写，参数用空格分隔；参数里要带空格时后面再考虑引号或 JSON。
- 服务端回包前缀：`OK <命令> ...` / `ERR <码> <说明>`。
- 暂定这几条命令就够跑通流程：

  | 命令 | 参数 | 含义 | 服务端反应 |
  | --- | --- | --- | --- |
  | `LOGIN` | 昵称 | 登录 | 记下昵称，广播上线；重复登录报错 |
  | `SAY` | 文本 | 发言 | 广播（= 项目 1 的行为） |
  | `USE_SKILL` | 技能 id | 使用技能 | 先只做校验 + 广播，战斗结算留给后面 |
  | `SURRENDER` | 无 | 认输 | 广播认输 |
  | `QUIT` | 无 | 主动退出 | 回一条再见再断开 |

**验收标准**：

- 用 `nc 127.0.0.1 9527` 手敲命令能跑通全部命令，包括各种错误输入（未知命令、
  少参数、没登录就 `USE_SKILL`），服务端不崩、给得出人能看懂的报错。
- 新增一组自动化测试（在 `tests/` 里加，风格照抄 `smoke_test.py`）。

---

## 项目 3：JSON Protocol ⬜

> 任务书（松版）在 `docs/project3-json-protocol.md`。下面这些是历史草稿里的
> 具体建议，**只当参考，不是规定**——以松版任务书为准。

**目标**：每条消息不再是一行文本，而是一个 JSON 对象。

```json
{ "type": "UseSkill", "skillId": 1001 }
```

**要解决的新问题**（这些才是这一步的价值所在）：

1. **长度前缀还是行分隔？**
   JSON 里可以出现换行，所以"按 `'\n'` 分行"开始变得别扭。业界常见做法是
   "4 字节长度前缀 + 消息体"，收方要先读 4 字节、再按长度读满。
   freekill-asio 的 `Packet` 结构里就有 `_len` 字段，正是这个思路。
2. **谁来做 JSON？**
   - 想省事：`nlohmann/json`（单头文件，freekill-asio 用的就是它）。
   - 想练手：自己写个小解析器，看清楚"转义、嵌套、数字"这些坑。
3. **请求/响应要能对上号**：客户端一次发好几条请求时，回包得知道对应哪一条。
   freekill-asio 的 `Packet` 里有 `requestId`，就是这个用途。
4. **错误码体系**：JSON 之后错误也用结构化字段表达（`{"type":"Error","code":401,...}`）。
5. **要不要换 Boost.Asio？** 到这一步网络逻辑开始变复杂，可以考虑：
   - 这台机器目前没有 Boost / 独立 asio，也没 cmake，`sudo` 需要密码装不了包；
   - 可行方案：把 header-only 的独立版 asio 下载到 `src/3rdparty/asio/`（纯头文件，不需要装系统包），
     或者用户自己 `sudo apt install libasio-dev cmake`。

**验收标准**：

- 所有消息都是 JSON，非法 JSON、未知 `type`、字段缺失都有明确错误回包。
- 收方对"粘包/半包"（一次读到 1.5 条消息）处理正确——用测试脚本故意拼包来验证。
- 客户端和服务端共用同一份"消息类型"定义（`src/common/` 下），不各写一套。

---

---

## 跨阶段：Lua 侧战斗核的类框架 ✅

> 这一步不在原来的 1/2/3 编号里——它是**提前把"战斗大脑"的骨架搭起来**。
> 完整设计说明见 `packages/seer-core/README.md`，这里只记"为什么现在做、学到了什么"。

**为什么可以提前做**：架构文档 §2 的第 2 条（逻辑与 IO 分离）意味着战斗核**不需要**
socket、不需要数据库、也不需要 C++。它只要 Lua 5.4 就能跑。所以它不必等项目 4/5/6
排完队——而且越早做，越早能验证"规则放 Lua"这个决定对不对。

**做出来的东西**（`packages/seer-core/`）：

- **两层事件**（这是这一步最重要的认知）：
  * **时机**（Timing，抄 `lua/core/trigger_event.lua`）：一个"时刻"，把这一刻想插一脚的人
    （技能钩子、效果触发器）按优先级同步问一遍。refresh 前后两轮、`breakCheck` 打断、
    次数上限、问玩家取选项，语义都对齐。
  * **流程事件**（GameEvent，抄 `lua/server/gameevent.lua`）：一个"过程"，
    用协程实现，所以能**中途停下来等**（等玩家下指令）、能**插子事件**
    （打伤害时插"倒下"流程，走完再回来接着算）、能**被打断**（伤害被防止 → 整条链作废）。
  * 我第一版只做了时机这一层，结果一遇到"结算到一半要停下来等"就写不下去了 ——
    两层是**上下层关系**（流程事件执行到某一步时去触发时机），不是继承关系。
- **技能 / 效果 / 精灵**：按 freekill 的**spec 方式**做——规则作者只写声明式表，
  核心建"骨架"把表造运行时对象；一个技能横跨多个时机时，自动拆成主对象 + 子对象。
- **生命值与回合的流程**（抄 `hp.lua` / `gameflow.lua`）：掉血这件事被拆成
  Damage（算数值）→ ChangeHp（唯一改 hp 的地方）→ 倒下判定，所以"防止伤害"
  只有一处要拦；回合被拆成 Round（一大回合）→ Turn（一次行动）→ UseSkill → Damage。
- 顺带的配套：确定性随机（自带种子/状态导出）、属性克制、伤害公式、
  **事件树查询**（"这次伤害是哪次技能使用引起的"能直接回答）、事件流记录（两层都记，可回放）、
  给 C++ 的 RPC 方法表，以及"挂起/恢复"（`logic:start()` 返回 `"request"`，
  C++ 把玩家的选择 `logic:resume(答复)` 送回来）—— 这正是架构文档 §5.3 那个来回。

**这一课真正学到的**：

- **数据与代码分家**的价值：`Status.register("poison", { turn_end_damage = {1,8} })`（⚠ 旧 API）
  就是"中毒每回合掉 1/8 血"这条规则本身。改数值 = 改数据，不动一行逻辑。
  连"加一种全新效果类型"都只是往注册表里塞一份说明书（⚠ `Effect.registerKind` 与
  `core/effect/kinds.lua` **已随重构删除**，效果现在是"一张 spec 造一个 Effect 实例"，
  创建入口 `Seer:createEffect`）。
- **事件系统是这套架构的骨架**：所有玩法最终都化成"在某个时机做某件事"。
  所以**时机的粒度就是这套系统的表达力上限**——想不出"对手出手前"这个时机，
  就永远写不出"降低对手攻击"的效果。
- **确定性是要主动维护的**：不能用 `math.random`（全局状态，别人一调序列就变），
  甚至 `pairs` 的遍历顺序都会影响结果——凡是"遍历一张表并产生顺序"的地方都得排序。
  这条在单机游戏里无所谓，在"要回放、要断线重连、要争议裁决"的服务器里是硬要求。
- **"状态"和"它产生的触发器"不能有两份真相**：最开始的写法是"状态只是一张表 +
  战局里几个固定处理器"（处理器读状态表干活），结果状态和行为分在两处，
  漏一条清理路径就出现"状态没了却还在每回合掉血"的幽灵 bug。
  中途试过反过来（每个状态实例带一撮触发器），又有"忘了摘触发器"的风险。
  最终定的是第三种：**状态自己带触发器，但挂/摘只留一个入口**
  （`Mark:attach` 装、`Mark:detach` 无条件摘干净，挂/摘都只走
  `logic:applyMark` / `logic:removeMark`，到期/被治/被清除全是同一条路）。
  —— 这是写完之后重构出来的一处设计，比一开始想清楚的更值钱。
- **"效果"和"印记"要分开，但共用底层**：一次技能造成的后果里，有的是**机制**
  （这 3 回合受伤减半、被打了反击），有的是**状态**（你现在中毒了，要显示在状态栏、
  要能被"解除异常状态"精确地挑出来）。所以精灵身上是两张表：`pet.effects`（Effect）
  和 `pet.marks`（Mark/异常状态），但触发器装载、数值重算、回合末递减三处共用同一份实现。
  而**技能上的效果和挂在身上的回合类效果是同一个 `Effect` 类**，区别只有寿命
  （`instant` + `duration`）——分析原本在 `docs/effects-marks-status.md`，**该文档已删除**。
- **类层次用来消灭重复，表用来写数据**：异常状态分弱化类/控制类，同一类的钩子代码
  一模一样（只有"掉几分之几""几成概率动不了"不同），所以"这一类怎么动"写进子类
  （`WeakenStatus` / `ControlStatus`），具体状态只写 5 行数据
  （`Status.register("poison", { class = "weaken", turn_end_damage = {1,8} })`）。
  再往前一步：加效果类型也只是一个注册表项——**扩展性靠注册点，不靠改核心**。
- **共享可变状态 + 嵌套执行 = 死循环**。这个坑在这一步踩了三次，每次都表现为
  "整个房间的 Lua 进程卡住"：
  1. 编队用 `.next` 串成环（freekill 的做法），而嵌套的伤害流程会**重建那个环**，
     外层还没走完的一圈踩在被改过的链上，环接不回起点 → 死循环。
     改成每次取一份**数组快照**（只读，嵌套多少层都不干扰）。
  2. 清场事件用 `stack:pop()` 退栈（假定"我在栈顶"），但它跑 `clear()` 时可能又插进来
     一串新事件，那时栈顶已经不是它 → 它永远留在栈上，主循环一轮轮 resume 死协程。
     改成 `stack:remove(自己)`（按身份摘）。
  3. 创建事件时没显式传 `room`，于是退化成"当前战局"—— 单测里同时存在好几个战局时，
     事件会挂到**别人的**栈上 → "像没跑一样"然后原地打转。
     现在统一显式传，并在 `pushEvent` 里钉了不变式断言。
  **教训**：凡是"多个流程共享的可变状态 + 会被重入"，都要么改成快照、要么按身份操作、
  要么立刻断言。这类 bug 不会报错，只会安静地卡住。
- **"必须发生的事"要写在 `clear()` 里，不是 `exit()` 里**：被 kill 的事件协程会被直接
  close，`main` 后半段和 `exit` 都不会执行，只有清场事件保证会跑。
- **数据与代码分家**已经在技能/效果那一课学到了，这一步又多了一个例子：
  生命值变化的**唯一入口**（ChangeHp）让"防止伤害"只需要拦一处。
- **"会变的数值"做成字段，"静态数据"才用表**：`pet.speed` 是字段（每只都不同、每回合
  都可能变），`species.base_stats.speed` 是表（图鉴数据、全服一份、只读）。
  把会变的数值塞进表里，就会到处出现 `pet.stats.xxx` 这种查找，而且"能力等级要不要乘"
  这种事容易在某处漏掉——漏了不报错，只是数字悄悄不对。做成字段之后，
  伤害/出手顺序/UI 读的是同一个数。
- **第五技能单独一个属性，而不是 slots[5]**：不占普通技能格（图鉴写的就是"4+1"）、
  配招和 UI 上都单独摆一个位置。塞进数组的话，每处用到技能的地方都要判断
  "这是第 5 个吗"，漏一处就会把第五技能当普通技能用出去。
  但注意：**它只是"摆在哪个位"的区别，机制上就是普通技能**——一样有 PP、
  一样会被封印、一样走 `Skill:checkUsable`。不要因为"它是第五技能"就给它加规则。
- **"能不能用"要收敛成一个带原因的判断**：PP 空了、被封印、技能自己写了条件
  （`usable`），三个来源共用 `Skill:checkUsable`，返回 `no_pp` / `sealed` /
  `forbidden` / `condition`。选技能和执行技能走同一个判断，就不会出现"界面能选、
  真用被拒"；带原因返回，客户端才能把技能摆成灰的并说明为什么。
  另外，封印记在**精灵**身上：技能对象是全局共享的，改它会波及全场所有精灵。
- **"问玩家一件事"本身要建模**：一开始就是一句 `coroutine.yield`，然后立刻遇到三个问题——
  有人超时怎么办、有人掉线怎么办、答的东西不合法怎么办。抄 freekill 的 `Request`
  之后这些都有位置：每个参与者能登记**兜底答复**（超时/托管就用它，流程永不卡死）、
  取消和抢答失败在收尾时统一规范化。**"谁去答"则被拆成 `RequestHandler`**：
  命令行、AI、真人客户端是同一个接口的不同实现，所以单机版和联机版共用同一份规则——
  测试里有一组对照：同样的答复走两条路，胜负/回合/总伤害完全一致。
  这就是"以后换成 Unity 也能正常跑"的保证（`make play` 是命令行那一版）。
- **诚实标注实现边界**：RPC 传输层没做，就直接在执行时报错退出，不假装在等消息；
  属性克制表/异常状态数值是占位数据，就在注释和 README 里写明白。
  半个能用的东西比明说"还没做"更浪费时间。

⚠ 原来这里指向 `docs/effects-marks-status.md`（讲效果类型写在哪、印记和异常状态的关系、
"我要加 X 该改哪个文件"）——**那份文档已随重构删除**，因为它描述的效果/印记结构正是
现在待重建的部分。重建时的零件清单在 `packages/seer-core/lua/core/mark/init.lua` 文件头。

**验收**（⚠ 旧的 `make test-lua` / 870 项测试 / `make play` / `make example-rpc`
都已失效：`tests/` 与 `examples/` 被删除）：
现在能自动跑的是加载自检 `cd packages/seer-core && lua5.4 lua/seer.lua`
（应当打印"种族 2，技能 39，时机 18"）；`GameLogic:run()` 能把一整局打完并分出胜负；
交互式询问（单机命令行 / 真人客户端）**还没接上**（见 `server/gamelogic.lua` 的 TODO）。

---

## 之后的游戏侧设计（初步想法，做到再说）

- **账号**：登录、注册、封禁、在线状态。freekill-asio 放在 `src/server/user/`。
- **房间/大厅**：赛尔号的对战是 1v1 或多人，需要房间、观战、准备、断线重连。
- **战斗**：回合制；服务端必须是唯一权威（客户端只发"我要用技能 1001"，
  伤害计算、命中、状态变化全在服务端算完再广播）。
- **数据**：精灵/技能先从配置文件或 SQLite 读；赛尔号的数据量不小，别硬编码在 C++ 里。
- **反作弊底线**：任何时候都不相信客户端发来的"我造成了 9999 点伤害"。
