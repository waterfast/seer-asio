# seer-asio —— 赛尔号同人联机游戏服务端

边做边学的服务端项目。目标是最终写出一个赛尔号同人联机游戏的服务端，
按学习路线一步一步来：先把基础 socket 搞懂，再快速切到现代的 **Asio + C++20 协程**。

参考实现（隔壁目录，别改它）：`../freekill-asio`，一个房间制、回合制的卡牌游戏服务端，
用 C++20 + Boost.Asio + CBOR。本项目的分层就是照着它搭的。

## 进度

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| 项目 1 | Console Chat Server：客户端发字符串，服务端广播 | ✅ 完成（Asio + 协程） |
| 项目 2 | Command Server：解析 `LOGIN` / `USE_SKILL` / `SURRENDER` 等命令 | ✅ 完成 |
| 项目 3 | JSON Protocol：每条消息换成 JSON 对象 | ⬜ 未开始 |
| Lua 战斗核 | `packages/seer-core`：精灵/技能/**效果拼装**/**印记** + 两层事件 + 回合/生命值流程 + RPC | ✅ 能跑完整局（870 项测试） |

详细路线见 `docs/learning-path.md`，环境依赖见 `docs/environment.md`。

## 目录结构

```
seer-asio/
├── CMakeLists.txt / Makefile   # Makefile 只是 cmake 的便捷包装
├── src/
│   ├── main.cpp                # 服务端入口：只组装，不写业务
│   ├── client/
│   │   ├── main.cpp            # 客户端入口（薄）
│   │   └── console_client.{h,cpp}   # 客户端逻辑：stdin/socket 两条协程
│   ├── common/
│   │   ├── protocol.h          # 协议常量（端口 9527、行长上限…）
│   │   ├── net.h               # 选 Asio 品种（独立版 / Boost），统一 net:: 与 seer::error_code
│   │   └── log.h               # 极简日志
│   ├── network/
│   │   ├── server_socket.{h,cpp}    # 监听 + accept + 新连接回调
│   │   └── client_socket.{h,cpp}    # 单条连接：读行、发送队列、断开回调
│   └── server/
│       └── chat_server.{h,cpp}      # 业务层：命名、广播
├── packages/
│   └── seer-core/             # Lua 侧战斗核（战斗大脑，纯 Lua 5.4）
│       ├── lua/seer.lua       #   载入入口
│       ├── lua/core/          #   基类：timing(时机)/trigger_data/skill/effect/pet/registry
│       ├── lua/server/battle/ #   timing 时机表 / game_event 流程事件基类
│       │                      #   hp 生命值流程 / gameflow 回合流程
│       │                      #   logic 事件管理器 / damage 伤害 / element 克制
│       ├── lua/server/rpc/    #   给 C++ 的 RPC 方法表（传输层留给项目 6）
│       ├── lua/specs/         #   图鉴与技能的声明式数据（spec）
│       ├── lua/server/rpc/    #   RPC（jsonrpc/stdio/peer/dispatchers/entry，抄自新月杀）
│       ├── lua/specs/standard/#   雷伊（电系）/ 盖亚（战斗系），图鉴真实数据
│       ├── examples/         #   battle_demo（跑一局看战报）/ rpc_demo（跨进程 RPC）
│       ├── tests/test_core.lua#   870 项单跑测试（不需要 C++）
│       └── README.md          #   设计说明、两层事件的说明、名词对照表
└── tests/
    ├── smoke_test.py           # 冒烟测试（19 项，真的起服务端连客户端）
    └── pty_session.py          # 伪终端交互测试
```

## 为什么这样分层？（对应你问的"ServerSocket 为什么独立出来"）

freekill-asio 把网络层拆成 `ServerSocket`（监听）和 `ClientSocket`（单条连接），
业务层 `Server` 用**回调**把两层接起来。核心是**网络与业务解耦**：

```
main.cpp          只负责组装：建 io_context、建 ChatServer、io.run()
   │
   ▼
ChatServer(业务)   不知道 socket；只关心"来了个人、收到一行、有人走了"
   │  通过回调（set_new_connection_callback / set_message_got_callback）
   ▼
ServerSocket       bind/listen/accept，accept 到一个 socket 就回调上层
ClientSocket       收发、按 '\n' 分帧、发送队列、断开回调；不知道这行字啥意思
```

这么做的好处：

1. **职责单一**：一个类只干一件事，读起来不费劲，改起来不牵连。
2. **可替换**：以后要加 TLS、加 UDP 服务器发现（freekill-asio 就有个 `udpListener`
   专门响应 `fkDetectServer`），只动 `ServerSocket`，业务代码一行不用改。
3. **可测试**：可以单独给 `ClientSocket` 喂数据测分帧，不必起整套服务器。
4. **和参考项目对齐**：读 freekill-asio 源码时能直接对上号。

注意：业务状态（这里只有"玩家名字"）**不要**塞进 `ClientSocket`——它是纯网络层。
本项目用 `ChatServer` 里的 `unordered_map<ClientSocket*, std::string>` 存名字，
连接断开时再擦掉。freekill-asio 同理，它把业务状态放在 `ServerPlayer`/`UserManager`。

## 编译与运行

需要 `cmake` + `g++`（C++20）+ Asio（本机已装，见 `docs/environment.md`）。

```bash
make                  # = cmake -S . -B build && cmake --build build
                      # 产出 build/seer-server 和 build/seer-client
make run-server       # 服务端，默认监听 0.0.0.0:9527
make run-client       # 客户端，默认连 127.0.0.1:9527
make test             # Lua 战斗核测试 + 冒烟测试 + 伪终端交互测试
make test-lua         # 只跑 Lua 战斗核测试（不需要编译 C++，只要 lua5.4）
make example          # 跑一局：雷伊 vs 盖亚（真实数据）+ 每种机制巡演一遍
make example-rpc      # 同一局，但战斗核在子进程里、用 JSON-RPC 驱动
make play             # 单机版：在命令行里和 AI 打一局（每轮自己选技能）
make clean
```

Lua 战斗核（`packages/seer-core`）只需要 **lua5.4**，和 C++ 服务端完全解耦——
这就是"规则放 Lua"的直接好处：结算逻辑能脱离网络单独测。设计说明见
`packages/seer-core/README.md`。

默认用**独立版 Asio**（`#include <asio.hpp>`，轻）。想换成 **Boost.Asio**
（freekill-asio 用的那个）只改一个开关，API 完全一样：

```bash
make clean && make CMAKE_ARGS="-DSEER_USE_BOOST_ASIO=ON"
```

客户端用法：`./build/seer-client [host] [port]`，例如连局域网 `./build/seer-client 192.168.1.20`。

## 协议（项目 1 版）

纯文本、UTF-8、**以 `'\n'` 作为一条消息的边界**。TCP 是字节流，没有"消息"概念，
收方必须自己分帧——本项目在 `ClientSocket::reader()` 里用"固定缓冲 + 找 `'\n'`"来切。

| 方向 | 内容 |
| --- | --- |
| 客户端 → 服务端 | 任意一行文本 = 一句发言 |
| 服务端 → 客户端 | `[玩家N] 内容` = 别人的发言；`*** ... ***` = 系统消息（进入/离开） |

服务端不回显给发送者本人；单条消息上限 4096 字节（超长截断），
一条连接收不到换行的"垃圾"上限 64KB（超限断开）。

## 从手写 socket 到 Asio：同一件事的两种写法

项目 1 第一版是纯 POSIX（`poll` + 手写缓冲区），现在已经删掉、换成 Asio。
对照一下，能很清楚地看到"框架替我们做了什么"：

| 要解决的问题 | 手写 socket（旧版） | Asio（现在） |
| --- | --- | --- |
| 同时等很多连接 | `poll()` 手动拼 fd 列表、查 revents | `io_context` + `co_spawn`，每条连接一个协程 |
| 分帧 | 手写 `in` 缓冲区 + `find('\n')` | `async_read_some` + 同样的思路，但不需要自己算 EAGAIN |
| 发送排队 | 手写 `out` 缓冲区 + 记 `POLLOUT` | `send()` 入 `deque` + `writer()` 协程 `async_write` |
| 优雅退出 | `signal()` + `volatile sig_atomic_t` | `net::signal_set` + `async_wait` |
| 生命周期 | 手管裸指针/unique_ptr | `shared_from_this` + 协程抓 `self` |
| stdin 也能异步读 | 手写 `read()`（还踩过 `recv` 对管道报 ENOTSOCK 的坑） | `net::posix::stream_descriptor` 把 stdin/stdout 包成流 |

协程的关键心智模型：`co_await` 不是阻塞线程，而是"挂起这个协程、把线程让出去"，
io_context 单线程就能驱动成百上千条连接——没有锁、没有竞态，和 freekill-asio 同一套。

## 已知的从简之处（项目 1 故意不做的）

- 没有身份认证，名字自动分配（`玩家1`、`玩家2`…）。
- 没有房间/大厅、没有心跳超时踢人（加心跳只需一个 `net::steady_timer`）。
- 明文传输，没有加密压缩。
- 日志用 `printf`，freekill-asio 用的是 spdlog（本机已装，后面切）。

## 下一步

1. **项目 3（JSON Protocol）**：把"一行文本命令"换成 JSON 消息，分帧改成长度前缀。
2. **给 Lua 战斗核填图鉴数据**：`packages/seer-core/lua/specs/` 下的 spec 现在是占位示例，
   属性克制表、异常状态数值、性格名都标注了"待与图鉴核对"。
3. **补完回合状态机**（换精灵/道具/逃跑）：`Round`/`Turn` 已经能跑完整局了，
   缺的是这些赛尔号真实回合里的分支。
4. 之后按 `docs/architecture.md` §10 的路线：Router/User → Lobby/Room → Lua 子进程 + RPC（项目 6）。
