// SPDX-License-Identifier: GPL-3.0-or-later
//
// 一条客户端连接。对应 freekill-asio 的 src/network/client_socket.h。
//
// 它只管"这一条 TCP 连接"本身，完全不懂业务：
//   * reader 协程：async_read_some + 按 '\n' 分帧，读满一行就回调 message_got；
//   * send()：把字节塞进发送队列，writer 协程按顺序发出去；
//   * 断开（对端关闭 / 读出错 / 被踢）都会回调 disconnected，且只回调一次。
//
// 至于"这一行文字代表什么"、"要广播给谁"，由上层（ChatServer）通过回调决定。
// 项目 2 加命令、项目 3 换 JSON 时，只需要改回调里传给上层的数据类型，网络层不用动。

#pragma once

#include "common/net.h"

#include <deque>
#include <functional>
#include <memory>
#include <string>

namespace seer {

class ClientSocket : public std::enable_shared_from_this<ClientSocket> {
public:
  explicit ClientSocket(net::ip::tcp::socket socket);

  // 开始读。由 ServerSocket 在"上层绑好回调"之后调用。
  void start();

  void send(const std::shared_ptr<std::string> &msg);

  // 优雅关闭：先发完发送队列里的数据，再真正断开。
  void disconnectFromHost(const std::string &reason);

  std::string_view peerAddress() const { return m_peer; }

  void set_message_got_callback(std::function<void(ClientSocket &, const std::string &)> f) {
    m_messageGot = std::move(f);
  }
  void set_disconnected_callback(std::function<void(ClientSocket &, const std::string &)> f) {
    m_disconnected = std::move(f);
  }

private:
  net::awaitable<void> reader();
  net::awaitable<void> writer();
  void doClose();

  net::ip::tcp::socket m_socket;//客户端socket
  std::deque<std::shared_ptr<std::string>> m_sendQueue;//发送队列
  std::string m_peer;//端口
  std::string m_disconnectReason = "unknown";

  bool m_writing = false;
  bool m_closing = false;

  std::function<void(ClientSocket &, const std::string &)> m_messageGot;
  std::function<void(ClientSocket &, const std::string &)> m_disconnected;
};

} // namespace seer
