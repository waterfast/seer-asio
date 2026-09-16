# 学习路线与设计笔记

> 这份文档是给"以后接着做"的自己看的：每一步做什么、怎么算做完、坑在哪。

## 总体路线

```
项目 1  Console Chat Server   纯 socket + 广播            ← 已完成
项目 2  Command Server        服务端解析命令              ← 下一步
项目 3  JSON Protocol         每条消息是一个 JSON 对象
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

## 之后的游戏侧设计（初步想法，做到再说）

- **账号**：登录、注册、封禁、在线状态。freekill-asio 放在 `src/server/user/`。
- **房间/大厅**：赛尔号的对战是 1v1 或多人，需要房间、观战、准备、断线重连。
- **战斗**：回合制；服务端必须是唯一权威（客户端只发"我要用技能 1001"，
  伤害计算、命中、状态变化全在服务端算完再广播）。
- **数据**：精灵/技能先从配置文件或 SQLite 读；赛尔号的数据量不小，别硬编码在 C++ 里。
- **反作弊底线**：任何时候都不相信客户端发来的"我造成了 9999 点伤害"。
