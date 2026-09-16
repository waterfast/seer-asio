// SPDX-License-Identifier: GPL-3.0-or-later

#include "network/client_socket.h"

#include "common/protocol.h"

#include <array>
#include <cstddef>
#include <string>

namespace seer {

ClientSocket::ClientSocket(net::ip::tcp::socket socket) : m_socket(std::move(socket)) {
  // 把对端地址在构造时就存好：连接断开后再调 remote_endpoint() 会抛异常。
  // freekill-asio 的 ClientSocket 也是这么干的（它的 m_peer_address）。
  m_peer = m_socket.remote_endpoint().address().to_string() + ":" +
           std::to_string(m_socket.remote_endpoint().port());

  // 聊天消息是一行行的小包，关掉 Nagle 让它们尽快发出去。
  m_socket.set_option(net::ip::tcp::no_delay(true));
}

void ClientSocket::start() {
  net::co_spawn(m_socket.get_executor(), reader(), net::detached);
}

void ClientSocket::send(const std::shared_ptr<std::string> &msg) {
  if (m_closing) return;
  m_sendQueue.push_back(msg);
  if (m_writing) return; // 已经有一个 writer 协程在发，别重复起
  m_writing = true;
  net::co_spawn(m_socket.get_executor(), writer(), net::detached);
}

void ClientSocket::disconnectFromHost(const std::string &reason) {
  if (m_closing) return;
  m_closing = true;
  m_disconnectReason = reason;
  if (m_sendQueue.empty()) {
    doClose();
  }
  // 否则等 writer 把队列发完，它会在末尾看到 m_closing 再 doClose()。
  // 这正是 freekill-asio 的 disconnectFromHost + is_closing 思路。
}

// 读循环：固定缓冲 + async_read_some，自己按协议边界切分。
// freekill-asio 的 reader() 也是这个套路——它读 CBOR 包，我们读以 '\n' 结尾的行。
//
// 为什么不用 async_read_until？它内部其实也是"读 + 找分隔符"，但它的 streambuf
// 在一直收不到分隔符时会无限增长（实测 max_size 挡不住），没法做"半包上限"。
// 手写这一步既能看清分帧到底在干什么，又能精确控制缓冲区大小。
net::awaitable<void> ClientSocket::reader() {
  // 关键：协程是 detached 的，生命周期可能比 this 长。这里抓一个 shared_ptr，
  // 让对象活到读循环结束为止。freekill-asio 用的是 weak_from_this + lock，两种等价。
  auto self = shared_from_this();

  std::array<char, 4096> data{};
  //等待
  std::string pending; // 还没凑齐 '\n' 的半行，

  for (;;) {
    seer::error_code ec;
    //buffer 缓冲
    const std::size_t n = co_await m_socket.async_read_some(
        net::buffer(data), net::redirect_error(net::use_awaitable, ec));

    if (ec) {
      if (ec == net::error::eof) {
        m_disconnectReason = "对端关闭了连接";
      } else if (ec != net::error::operation_aborted) {
        m_disconnectReason = ec.message();
      }
      // operation_aborted 说明是我们主动关的（disconnectFromHost/doClose），原因已设好
      break;
    }

    pending.append(data.data(), n);
    if (pending.size() > seer::kMaxPendingBytes) {
      m_disconnectReason = "接收缓冲超过上限（对端在灌没有换行的数据？）";
      break;
    }

    std::size_t pos = 0;
    while ((pos = pending.find('\n')) != std::string::npos) {
      std::string line = pending.substr(0, pos);
      pending.erase(0, pos + 1);
      if (!line.empty() && line.back() == '\r') line.pop_back(); // 兼容 Windows 的 \r\n
      if (line.empty()) continue;
      if (line.size() > seer::kMaxLineLength) line.resize(seer::kMaxLineLength);
      if (m_messageGot) m_messageGot(*this, line);
    }
  }

  doClose();
  co_return;
}

// 发送循环：队列里有东西就 async_write，发完队首再发下一个。
// 并发写同一个 socket 是未定义行为，所以所有发送都必须排队经过这一个协程。
// （freekill-asio 用回调递归的 send_loop 做同一件事，协程写法更直白。）
net::awaitable<void> ClientSocket::writer() {
  auto self = shared_from_this();

  seer::error_code ec;
  while (!m_sendQueue.empty()) {
    const auto &msg = m_sendQueue.front();
    // msg 是队列里的 shared_ptr<string>，只要还没 pop 就活着，buffer 不会悬空
    co_await net::async_write(m_socket, net::buffer(*msg),
                              net::redirect_error(net::use_awaitable, ec));
    if (ec) {
      m_disconnectReason = "发送失败: " + ec.message();
      break;
    }
    m_sendQueue.pop_front();
  }

  m_writing = false;
  if (ec || m_closing) doClose();
  co_return;
}

// 真正关闭，并保证"断开回调只触发一次"。
void ClientSocket::doClose() {
  if (!m_socket.is_open()) return; // 已经关过了

  seer::error_code ec;
  m_socket.shutdown(net::ip::tcp::socket::shutdown_both, ec);
  m_socket.close(ec);

  if (m_disconnected) m_disconnected(*this, m_disconnectReason);

  // 清掉回调：reader/writer 之后再走 doClose 也不会重复通知
  m_disconnected = {};
  m_messageGot = {};
}

} // namespace seer
