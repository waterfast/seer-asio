// SPDX-License-Identifier: GPL-3.0-or-later

#include "network/server_socket.h"

#include "network/client_socket.h"

#include "common/log.h"

#include <string>

namespace seer {
//socket在初始化时，接收器先初始化
ServerSocket::ServerSocket(net::io_context &io, net::ip::tcp::endpoint endpoint)
    : m_acceptor(io) {
  m_acceptor.open(endpoint.protocol());//开启监听对应套接字，先设置对应协议
  // 服务器重启时端口可能还在 TIME_WAIT，加上这个选项可以立刻重新 bind。
  m_acceptor.set_option(net::socket_base::reuse_address(true));//设置复用选项
  m_acceptor.bind(endpoint);//绑定监听端口
  m_acceptor.listen(net::socket_base::max_listen_connections);//开始监听

  logLine("监听 " + endpoint.address().to_string() + ":" + std::to_string(endpoint.port()));
}

void ServerSocket::start() {
  net::co_spawn(m_acceptor.get_executor(), listener(), net::detached);
}

net::awaitable<void> ServerSocket::listener() {
  for (;;) {
    seer::error_code ec;
    auto socket = co_await m_acceptor.async_accept(
        net::redirect_error(net::use_awaitable, ec));

    if (ec) {
      if (ec == net::error::operation_aborted) break; // 服务停止
      logLine("accept 失败: " + ec.message());
      continue;
    }

    auto client = std::make_shared<ClientSocket>(std::move(socket));
    if (m_newConnection) m_newConnection(client); // 先让业务绑好回调
    client->start();                              // 再开始读
  }
  co_return;
}

} // namespace seer
