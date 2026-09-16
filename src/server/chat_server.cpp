// SPDX-License-Identifier: GPL-3.0-or-later

#include "server/chat_server.h"

#include "network/client_socket.h"

#include "common/log.h"
#include "common/protocol.h"

#include <algorithm>
#include <memory>
#include <sstream>
#include <string>
#include <string_view>

namespace seer {

namespace {

std::shared_ptr<std::string> str(std::string s) {
  return std::make_shared<std::string>(std::move(s));
}

} // namespace

ChatServer::ChatServer(net::io_context &io, std::uint16_t port)
    : m_serverSocket(io, net::ip::tcp::endpoint(net::ip::tcp::v4(), port)) {
  // 网络层不知道业务，业务不知道网络：用回调把两层接起来。
  // 这就回答了"为什么 ServerSocket 要独立出来"——两边只通过这个窄接口见面。
  m_serverSocket.set_new_connection_callback(
      [this](const std::shared_ptr<ClientSocket> &c) { onNewConnection(c); });
}

void ChatServer::start() { m_serverSocket.start(); }

void ChatServer::onNewConnection(const std::shared_ptr<ClientSocket> &client) {
  client->set_message_got_callback(
      [this](ClientSocket &c, const std::string &line) { onMessage(c, line); });
  client->set_disconnected_callback(
      [this](ClientSocket &c, const std::string &reason) { onDisconnected(c, reason); });

  m_states.emplace(client.get(), PlayerState{});
  m_clients.push_back(client);

  logLine("新连接 " + std::string(client->peerAddress()) + "（未登录）" +
          "，当前在线 " + std::to_string(m_clients.size()) + " 人");
}

void ChatServer::onMessage(ClientSocket &client, const std::string &line) {
  //流式切词,将传入的命令 切分
  std::istringstream iss(line);
  std::vector<std::string> tokens;  
  std::string t;
  while (iss >> t) tokens.push_back(t); 
  if (tokens.empty()) return ; //空格则抛弃

  std::string &command = tokens[0];
  // 只转换命令中的 ASCII 小写字母，名字和技能参数保持原样。
  for (char &ch : command) {
    if (ch >= 'a' && ch <= 'z') ch = static_cast<char>(ch - 'a' + 'A');
  }
  std::vector<std::string> args(tokens.begin() + 1, tokens.end());  

  //接入命令处理
  handleCommand(client,command ,args);
  // 日志只留前 120 个字符，免得有人贴一大段东西刷爆终端
  /*
  const std::string preview = line.size() > 120 ? line.substr(0, 120) + "…（略）" : line;
  logLine(name + " 说: " + preview);
  */
  // 项目 1：不做解析，原样广播。项目 2 在这里加命令解析，项目 3 换成 JSON 对象。
}

void ChatServer::onDisconnected(ClientSocket &client, const std::string &reason) {
  auto it = m_states.find(&client);
  if (it == m_states.end()) return; // 已处理过（doClose 保证只回调一次，这里再兜底）

  const PlayerState state = it->second; // 删除记录后仍要使用名字和登录状态
  m_states.erase(it);
  std::erase_if(m_clients, [&client](const auto &c) { return c.get() == &client; });

  logLine("断开 " + state.name + "（" + std::string(client.peerAddress()) + "）：" + reason);
  if (state.loggedIn) {
    broadcast("*** " + state.name + " 离开了聊天室 ***\n", nullptr);
  }
}

void ChatServer::broadcast(const std::string &msg, ClientSocket *except) {
  for (const auto &c : m_clients) {
    if (c.get() == except) continue;
    c->send(str(msg));
  }
}

//**命令处理 */
//登录
void ChatServer::PlayerLogin(ClientSocket &client , const std::vector<std::string> &args){
  auto &state = m_states.at(&client);
  if (state.loggedIn) {
    client.send(str("ERR 403 已经登录\n"));
    return;
  }
  if (args.size() != 1) {
    client.send(str("ERR 402 用法: LOGIN <名字>\n"));
    return;
  }

  state.name = args[0];
  state.id = ++m_nextId;
  state.loggedIn = true;
  client.send(str("OK LOGIN\n"));
  broadcast("*** " + state.name + " 进入了聊天室 ***\n", &client);
}
//说话
void ChatServer::PlayerSay(ClientSocket &client , const std::vector<std::string> &args){
  const auto &state = m_states.at(&client);
  if (args.size() != 1) {
    client.send(str("ERR 402 用法: SAY <文本>\n"));
    return;
  }

  const std::string &line = args[0];
  const std::string &name = state.name;//获取名字

  const std::string preview = line.size() > 120 ? line.substr(0, 120) + "…（略）" : line;
  logLine( name + " 说: " + preview);
  broadcast("[" + name + "] " + line + "\n", &client);

}

//使用技能
void ChatServer::PlayerUseSkill(ClientSocket &client, const std::vector<std::string> &args) {
  if (args.size() != 1) {
    client.send(str("ERR 402 用法: USE_SKILL <技能名>\n"));
    return;
  }

  const auto &skillName = args[0];
  if (skillName.size() > 120) {
    client.send(str("ERR 402 技能名不能超过120字节\n"));
    return;
  }

  const auto &state = m_states.at(&client);
  broadcast("[" + state.name + "] 使用了技能 " + skillName + "\n", &client);
  client.send(str("OK USE_SKILL\n"));
}

//退出
void ChatServer::PlayerQuit(ClientSocket &client, const std::vector<std::string> &args) {
  if (!args.empty()) {
    client.send(str("ERR 402 用法: QUIT\n"));
    return;
  }

  m_states.at(&client).quitting = true;
  client.send(str("OK QUIT\n"));
  client.disconnectFromHost("主动退出"); // 网络层会先发完队列，再关闭连接
}

//帮助
void ChatServer::PlayerHelp(ClientSocket &client, const std::vector<std::string> &args) {
  if (!args.empty()) {
    client.send(str("ERR 402 用法: HELP\n"));
    return;
  }
  client.send(str("OK HELP 命令不区分大小写；LOGIN/L <名字> 登录；"
                  "SAY/S <文本> 发言；USE_SKILL/U <技能名> 使用技能（最多120字节）；"
                  "WHO/W 在线玩家；QUIT/Q 退出；HELP/H 帮助；"
                  "SAY、USE_SKILL、WHO 需要登录，参数不含空格\n"));
}

//谁
void ChatServer::PlayerWho(ClientSocket &client, const std::vector<std::string> &args) {
  if (!args.empty()) {
    client.send(str("ERR 402 用法: WHO\n"));
    return;
  }
  std::string players;
  std::size_t count = 0;
  for (const auto &connection : m_clients) {
    const auto &state = m_states.at(connection.get());
    if (!state.loggedIn || state.quitting) continue;
    players += " " + std::to_string(state.id) + ":" + state.name;
    ++count;
  }
  client.send(str("OK WHO " + std::to_string(count) + players + "\n"));
}

typedef void (ChatServer::*room_cb)(ClientSocket &, const std::vector<std::string> & );

//命令处理
void ChatServer::handleCommand(ClientSocket &client ,
  std::string &command,const std::vector<std::string> &args) {
  // 固定别名先转换成正式命令，共用同一套权限和参数检查。
  static const std::unordered_map<std::string_view, std::string_view> aliases = {
    {"L", "LOGIN"}, {"S", "SAY"}, {"U", "USE_SKILL"},
    {"Q", "QUIT"}, {"H", "HELP"}, {"W", "WHO"},
  };
  if (const auto alias = aliases.find(command); alias != aliases.end()) {
    command = alias->second;
  }
  
  static const std::unordered_map<std::string_view, room_cb> actions = {
    {"LOGIN", &ChatServer::PlayerLogin},
    {"SAY", &ChatServer::PlayerSay},
    {"USE_SKILL", &ChatServer::PlayerUseSkill},
    {"QUIT", &ChatServer::PlayerQuit},
    {"HELP", &ChatServer::PlayerHelp},
    {"WHO", &ChatServer::PlayerWho},
  };

  const auto state = m_states.find(&client);
  if (state == m_states.end() || state->second.quitting) return;
  
  auto iter = actions.find(command);
  if (iter == actions.end()) {
    client.send(str("ERR 400 未知命令\n"));
    return;
  } 
  // 先识别命令，再统一检查权限；登录、退出和帮助无需先登录。
  if (command != "LOGIN" && command != "QUIT" && command != "HELP" &&
      !state->second.loggedIn) {
    client.send(str("ERR 401 未登录\n"));
    return;
  }
  auto func = iter->second;
  (this->*func)(client, args);
  
}




} // namespace seer
