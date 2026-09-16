// SPDX-License-Identifier: GPL-3.0-or-later
//
// 控制台客户端。
//
// 和手写 poll 的旧版相比，这里不再自己维护"stdin + socket"两路事件轮询：
// 两条协程各自只负责一个方向，io_context 帮我们调度。
//   * stdinToSocket()：键盘输入 -> 服务端
//   * socketToScreen()：服务端 -> 屏幕
// stdin/stdout 用 net::posix::stream_descriptor 包起来，于是它们也能像 socket 一样
// 用 async_read_some / async_write（这正是 asio 比裸 poll 省心的地方）。

#pragma once

#include "common/net.h"

#include <cstdint>
#include <string>

namespace seer {

class ConsoleClient {
public:
  ConsoleClient(std::string host, std::uint16_t port);

  int run();

private:
  net::awaitable<void> stdinToSocket();
  net::awaitable<void> socketToScreen();

  std::string m_host;
  std::uint16_t m_port;

  net::io_context m_io;
  net::ip::tcp::socket m_socket;
  net::posix::stream_descriptor m_stdin;
  net::posix::stream_descriptor m_stdout;
  net::signal_set m_signals;
};

} // namespace seer
