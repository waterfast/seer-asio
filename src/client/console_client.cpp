// SPDX-License-Identifier: GPL-3.0-or-later

#include "client/console_client.h"

#include "common/protocol.h"

#include <csignal>
#include <cstdio>
#include <array>
#include <cstddef>
#include <string>

#include <fcntl.h>
#include <unistd.h>

namespace seer {

ConsoleClient::ConsoleClient(std::string host, std::uint16_t port)
    : m_host(std::move(host)),
      m_port(port),
      m_io(),
      m_socket(m_io),
      m_stdin(m_io, ::dup(STDIN_FILENO)),
      m_stdout(m_io, ::dup(STDOUT_FILENO)),
      m_signals(m_io) {}

int ConsoleClient::run() {
  seer::error_code ec;

  // 1. 解析主机名并连接（asio 的 resolver + connect 会挨个尝试所有解析结果）
  net::ip::tcp::resolver resolver(m_io);
  auto endpoints = resolver.resolve(m_host, std::to_string(m_port), ec);
  if (ec) {
    std::fprintf(stderr, "解析地址失败: %s\n", ec.message().c_str());
    return 1;
  }
  net::connect(m_socket, endpoints, ec);
  if (ec) {
    std::fprintf(stderr, "连接失败: %s（目标 %s:%u，服务端起了吗？）\n",
                 ec.message().c_str(), m_host.c_str(), m_port);
    return 1;
  }
  m_socket.set_option(net::ip::tcp::no_delay(true));

  // 2. 启动提示。用普通 printf：此刻还没进事件循环，也没有协程来抢 stdout。
  std::printf("已连接 %s:%u。输入文字回车发送，Ctrl+C 或 Ctrl+D 退出。\n",
              m_host.c_str(), m_port);
  std::fflush(stdout);

  // 3. 把 stdin/stdout 设成非阻塞再交给 asio，否则读满/写满时会把整个事件循环卡住。
  //    （dup 出来的 fd 是同一份 open file description，改 flags 对进程的 stdin/stdout 同样生效）
  ::fcntl(STDIN_FILENO, F_SETFL, ::fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
  ::fcntl(STDOUT_FILENO, F_SETFL, ::fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK);

  // 4. Ctrl+C 优雅退出（和 main 里的 signal_set 一个套路）
  m_signals.add(SIGINT);
  m_signals.add(SIGTERM);
  m_signals.async_wait([this](const seer::error_code &ec, int) {
    if (!ec) {
      m_socket.close();
      m_io.stop();
    }
  });

  // 5. 两条协程，各管一个方向
  net::co_spawn(m_io, stdinToSocket(), net::detached);
  net::co_spawn(m_io, socketToScreen(), net::detached);

  m_io.run();
  return 0;
}

// 键盘 -> 服务端。和服务端 reader 一样：固定缓冲 + 按 '\n' 切行。
net::awaitable<void> ConsoleClient::stdinToSocket() {
  std::array<char, 4096> data{};
  std::string pending;
  seer::error_code ec;

  for (;;) {
    const std::size_t n = co_await m_stdin.async_read_some(
        net::buffer(data), net::redirect_error(net::use_awaitable, ec));
    if (ec) {
      if (ec == net::error::eof) {
        // 键盘输入读完（Ctrl+D，或输入被重定向且读完了）：告诉服务端"我不再发了"，
        // 但仍能继续收——相当于只关发送方向。
        m_socket.shutdown(net::ip::tcp::socket::shutdown_send, ec);
      }
      break;
    }

    pending.append(data.data(), n);
    std::size_t pos = 0;
    while ((pos = pending.find('\n')) != std::string::npos) {
      std::string line = pending.substr(0, pos);
      pending.erase(0, pos + 1);
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (line.empty()) continue;
      if (line.size() > seer::kMaxLineLength) line.resize(seer::kMaxLineLength);

      // line 是具名局部变量，活到这次 async_write 完成，buffer 不会悬空
      const std::string out = line + "\n";
      co_await net::async_write(m_socket, net::buffer(out),
                                net::redirect_error(net::use_awaitable, ec));
      if (ec) break;
    }
    if (ec) break;
  }
  co_return;
}

// 服务端 -> 屏幕。
net::awaitable<void> ConsoleClient::socketToScreen() {
  std::array<char, 4096> data{};
  std::string pending;
  seer::error_code ec;

  for (;;) {
    const std::size_t n = co_await m_socket.async_read_some(
        net::buffer(data), net::redirect_error(net::use_awaitable, ec));
    if (ec) {
      if (ec == net::error::eof) {
        const std::string bye = "\n[服务端关闭了连接]\n";
        co_await net::async_write(m_stdout, net::buffer(bye),
                                  net::redirect_error(net::use_awaitable, ec));
      }
      break;
    }

    pending.append(data.data(), n);
    std::size_t pos = 0;
    while ((pos = pending.find('\n')) != std::string::npos) {
      std::string line = pending.substr(0, pos);
      pending.erase(0, pos + 1);
      if (!line.empty() && line.back() == '\r') line.pop_back();

      // "\r\033[K" 清掉当前行，避免服务端消息和你正在敲的半行字糊在一起
      const std::string out = "\r\033[K" + line + "\n";
      co_await net::async_write(m_stdout, net::buffer(out),
                                net::redirect_error(net::use_awaitable, ec));
      if (ec) break;
    }
    if (ec) break;
  }

  // 服务端没了，把客户端整体停掉（会让 stdinToSocket 里挂起的读被取消）
  m_socket.close();
  m_io.stop();
  co_return;
}

} // namespace seer
