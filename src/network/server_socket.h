// SPDX-License-Identifier: GPL-3.0-or-later
//
// 监听套接字。对应 freekill-asio 的 src/network/server_socket.h。
//
// 它只负责一件事：bind/listen、accept 新连接，然后把新连接交给上层回调。
// 它不知道"新连接上来以后要干嘛"——那是 ChatServer 的事。
//
// 为什么要把监听独立出来（而不是塞进 main 或业务类）？
//   1) 网络层与业务层解耦：ServerSocket 不认识业务，业务也不认识 socket；
//   2) 职责单一、可测试、可替换：以后要加 TLS、加 UDP 服务器发现（freekill-asio
//      就有个 udpListener 专门响应 "fkDetectServer"），只动这一层，业务代码不用改；
//   3) 和 freekill-asio 分层对齐，读它源码时能直接对上。

#pragma once

#include "common/net.h"

#include <functional>
#include <memory>

namespace seer {

class ClientSocket;

class ServerSocket {
public:
  ServerSocket(net::io_context &io, net::ip::tcp::endpoint endpoint);

  void start();

  void set_new_connection_callback(std::function<void(std::shared_ptr<ClientSocket>)> f) {
    m_newConnection = std::move(f);
  }

private:
  net::awaitable<void> listener();

  net::ip::tcp::acceptor m_acceptor;//专门接受tcp连接的对象
  std::function<void(std::shared_ptr<ClientSocket>)> m_newConnection;
};

} // namespace seer
