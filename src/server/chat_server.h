// SPDX-License-Identifier: GPL-3.0-or-later
//
// 业务层：聊天室。对应 freekill-asio 的 src/server/server.h（它是个大单例 Server，
// 我们这里是简化的 ChatServer，但思路一样：业务层持有网络层，用回调接起来）。
//
// 它持有 ServerSocket，把"新连接"变成"一个命名的成员"，把"收到一行"变成"广播"。
// 网络细节它一概不碰——都在 ServerSocket / ClientSocket 里。

#pragma once

#include "common/net.h"

#include "network/server_socket.h"

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace seer {

class ClientSocket;

class ChatServer {
public:
  ChatServer(net::io_context &io, std::uint16_t port);

  void start();

private:
  void onNewConnection(const std::shared_ptr<ClientSocket> &client);
  void onMessage(ClientSocket &client, const std::string &line);
  void onDisconnected(ClientSocket &client, const std::string &reason);
  void broadcast(const std::string &msg, ClientSocket *except);

  ServerSocket m_serverSocket;
  std::vector<std::shared_ptr<ClientSocket>> m_clients;

  struct PlayerState {
    std::uint64_t id = 0; // 0 表示尚未分配，成功登录后分配编号
    std::string name;
    bool loggedIn = false;
    bool quitting = false; // 等待退出响应发完时，不再处理后续命令
  };

  // 每条连接一份登录状态，连接断开时由 onDisconnected 擦掉。
  std::unordered_map<ClientSocket *, PlayerState> m_states;
  std::uint64_t m_nextId = 0; // 本次服务器运行中已分配的最后一个编号

  //处理命令函数
  void handleCommand(ClientSocket &client,std::string &command , const std::vector<std::string> &args );
  void PlayerLogin(ClientSocket &client , const std::vector<std::string> &args);
  void PlayerSay(ClientSocket &client ,const std::vector<std::string> &args);
  void PlayerUseSkill(ClientSocket &client, const std::vector<std::string> &args);
  void PlayerQuit(ClientSocket &client, const std::vector<std::string> &args);
  void PlayerHelp(ClientSocket &client, const std::vector<std::string> &args);
  void PlayerWho(ClientSocket &client, const std::vector<std::string> &args);
};

} // namespace seer
