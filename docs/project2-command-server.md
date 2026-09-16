# 项目 2 任务书：Command Server

> 当前学习版调整：`USE_SKILL <技能名>` 接受非空且不超过120字节的技能名，不含空格，不检查字符编码，
> 例如 `USE_SKILL 雷神觉醒`。无需数据库或技能存在性检查，成功回 `OK USE_SKILL`，
> 并向其他连接广播 `[名字] 使用了技能 雷神觉醒`。
> 以下原任务书中关于技能数字 ID 的校验要求，由这条规则替代。

当前实现支持命令大小写混用（参数保持原样），固定简写为：
`L=LOGIN`、`S=SAY`、`U=USE_SKILL`、`Q=QUIT`、`H=HELP`、`W=WHO`。
`HELP` 无需登录，返回一行命令帮助；`WHO` 需要登录，返回
`OK WHO <人数> <ID>:<名字> ...`，只统计已登录且未进入退出流程的玩家。
两条命令都不接受参数。简写按固定表匹配，不接受任意前缀。

> 这一课你自己动手。目标：让服务端不再"收到什么就广播什么"，而是**解析命令并做出响应**。
> 网络层（`ClientSocket` / `ServerSocket`）一行都不用改——正好验证分层的价值。

---

## 0. 一句话总结

把消息从"随便一句话"升级成 **`命令 [参数…]`**，服务端解析后：
- 合法的命令 → 回 `OK ...`
- 非法的命令 → 回 `ERR <码> <说明>`

传输层不变（还是 `'\n'` 分帧）。改的是**应用层协议**。

---

## 1. 先分清两个"协议"（别混）

| 层次 | 干什么 | 在代码哪里 | 项目 2 动它吗 |
| --- | --- | --- | --- |
| 传输/分帧 | 把 TCP 字节流按 `'\n'` 切成一条条消息 | `ClientSocket::reader()` | ❌ 不动 |
| 应用协议 | 一条消息 = 命令 + 参数；服务端怎么回 | `ChatServer::onMessage()` | ✅ 在这里做 |

**为什么分帧不该动**：分帧只管"消息边界"，不关心消息内容。现在改的是"内容长什么样"，
这是两个正交的问题。以后换 JSON、换二进制（CBOR），分帧可能才需要跟着变（变成"长度前缀"），那是项目 3+ 的事。

---

## 2. 消息格式规范 v1（文本版）

### 客户端 → 服务端（请求）

```
命令 [参数1] [参数2] ...
```

- 命令：大写字母，不含空格（实现里可以大小写不敏感，统一 `toupper`）。
- 参数：空格分隔。参数里**不带空格**（带空格的文本以后用 JSON/引号解决）。
- 一条消息 = 一行 = 命令 + 参数，正好和现有的 `'\n'` 分帧对上。

### 服务端 → 客户端（响应）

```
OK <命令> [结果…]
ERR <错误码> <人类能看懂的说明>
```

- 每条请求**必须有且仅有一条响应**（除了 `SAY` 这种广播给别人的，不给自己回显）。
- 错误码先定这一小组（以后按需加）：

| 码 | 含义 |
| --- | --- |
| 400 | 未知命令 |
| 401 | 未登录就执行需要登录的命令 |
| 402 | 参数错误（个数不对、类型不对） |
| 403 | 状态不对（例如重复 LOGIN） |

---

## 3. 命令清单（先做这 5 个）

| 命令 | 参数 | 含义 | 服务端行为 |
| --- | --- | --- | --- |
| `LOGIN` | `<名字>` | 登录 | 记住名字，回 `OK LOGIN`，并向别人广播 `*** <名字> 进入了聊天室 ***` |
| `SAY` | `<文本>` | 发言 | 广播 `[名字] <文本>` 给**除自己外**的人（= 项目 1 行为，但要先登录） |
| `USE_SKILL` | `<技能id>` | 使用技能 | 校验 id 是数字，广播 `<名字> 使用了技能 <id>`（先占位，不做战斗结算） |
| `SURRENDER` | 无 | 认输 | 广播 `<名字> 认输了` |
| `QUIT` | 无 | 主动退出 | 回 `OK QUIT` 再断开连接 |

（可选加分项：`HELP` 列出所有命令、`WHO` 列出在线名单——但别在第一步做，先跑通上面 5 个。）

### 会话状态（每条连接一份）

```
struct PlayerState {
  std::string name;
  bool loggedIn = false;
};
```

放哪？**不要**塞进 `ClientSocket`（它是纯网络层）。放在 `ChatServer` 里，
用一个 `std::unordered_map<ClientSocket*, PlayerState>` 存——和现在存名字的 `m_names` 一个道理，
只是把"名字"扩展成"状态"。连接断开时（`onDisconnected`）记得 `erase`。

---

## 4. 动手清单（按顺序）

### 步骤 1：切词

在 `src/server/chat_server.cpp` 里把 `onMessage` 收到的 `line` 拆成 token。
用 `std::istringstream` 最省事：

```cpp
std::istringstream iss(line);
std::vector<std::string> tokens;
std::string t;
while (iss >> t) tokens.push_back(t);   // 自动处理多个空格
```

空行 → `tokens.empty()` → 直接忽略。命令 = `tokens[0]` 转大写，参数 = `tokens[1..]`。

### 步骤 2：命令表（别写一长串 if/else）

用一个 map 把"命令名"映射到"处理函数"，这样加命令只加一行：

```cpp
using Handler = std::function<void(ClientSocket&, const std::vector<std::string>&)>;
std::unordered_map<std::string, Handler> m_commands;

// 构造时注册：
m_commands["LOGIN"]      = [this](auto &c, const auto &a){ handleLogin(c, a); };
m_commands["SAY"]        = ...;
m_commands["USE_SKILL"]  = ...;
m_commands["SURRENDER"]  = ...;
m_commands["QUIT"]       = ...;
```

然后 `onMessage` 变成：

```cpp
void ChatServer::onMessage(ClientSocket &client, const std::string &line) {
  // 1. 切词
  // 2. 查命令表；查不到 → send("ERR 400 未知命令\n")
  // 3. 查到了 → 调 handler
}
```

这就是 freekill-asio 里 `Router` 的雏形（它按 `Packet.command` 分发）。

### 步骤 3：每个 handler 只做三件事

1. 校验（登录了没、参数对不对）；
2. 改状态或广播；
3. 回一条 `OK` / `ERR`。

例如：

```cpp
void ChatServer::handleUseSkill(ClientSocket &client, const std::vector<std::string> &args) {
  auto &st = m_states[&client];
  if (!st.loggedIn) { client.send(str("ERR 401 未登录\n")); return; }
  if (args.size() != 1) { client.send(str("ERR 402 用法: USE_SKILL <技能id>\n")); return; }

  int skillId = 0;
  try {
    skillId = std::stoi(args[0]);          // stoi 对非数字会抛异常，必须 try/catch
  } catch (...) {
    client.send(str("ERR 402 技能id必须是数字\n"));
    return;
  }

  broadcast("[" + st.name + "] 使用了技能 " + std::to_string(skillId) + "\n", &client);
  client.send(str("OK USE_SKILL\n"));
}
```

### 步骤 4：客户端（可选，做一点点）

`src/client/console_client.cpp` 基本不用动——它已经把 `OK`/`ERR` 当普通文本打印出来了。
可以顺手做两件小事：给输入加个 `>` 提示符；收到 `ERR` 时用不同方式显示（纯加分，不影响验收）。

---

## 5. 验收标准（做到这些算完成）

1. `make` 无警告编译通过。
2. 用 `nc`（netcat）手敲能跑通全部 5 条命令，包括各种**错误输入**，服务端不崩、报错看得懂：
   - `FOO` → `ERR 400`
   - 没 `LOGIN` 就 `SAY hi` / `USE_SKILL 1` / `SURRENDER` → `ERR 401`
   - `LOGIN` 后再 `LOGIN` → `ERR 403`
   - `USE_SKILL abc` → `ERR 402`
   - `USE_SKILL` 不带参数 → `ERR 402`
3. 写一个自动化测试脚本（照抄 `tests/smoke_test.py` 的风格），把上面这些场景 + 广播行为都断言一遍。
4. `make test` 里旧的 19 项冒烟测试仍然全绿（不能把项目 1 的行为搞坏）。

---

## 6. 容易踩的坑

- **`std::stoi` 会抛异常**：非数字、溢出都抛，务必 `try/catch`，否则一个 `USE_SKILL abc` 就能让协程异常退出。
- **忘了擦状态**：`onDisconnected` 里要同时 `erase` 掉 `PlayerState`，否则 map 越攒越多（内存泄漏）。
- **响应数量要守恒**：每条请求一条响应；广播是发给别人的，不算"给自己"的响应。
- **广播时别发给自己**：`SAY`/`USE_SKILL`/`SURRENDER` 用 `broadcast(..., &client)` 排除自己，和现在 `onMessage` 一样。
- **空行/只有空格的行**：切词后 `tokens.empty()` 要忽略，别当成"未知命令"报 400。
- **名字去重**：`LOGIN` 两个一样的名字怎么办？最简单的做法是**允许重名**（先不管），
  因为重名在"名字只是显示"的场景无所谓；真要唯一性，等做账号系统时再管。

---

## 7. 和项目 3 的关系（心里有数即可）

项目 2 的 `命令 + 参数` 到项目 3 会变成 **JSON 对象**：

```
项目 2（文本）:   USE_SKILL 1001
项目 3（JSON）:   { "type": "UseSkill", "skillId": 1001 }
```

对应 freekill-asio 的 `Packet`：`command`（类型）+ `data`（结构化参数）。
所以你现在把"命令表 + 分发"的架子搭好，项目 3 只是把"切词"换成"解析 JSON"，
**命令表的分发逻辑不用动**——这就是为什么这一步值得认真做。
