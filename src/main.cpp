// SPDX-License-Identifier: GPL-3.0-or-later
//
// 服务端入口。只做"组装"：解析参数、建 io_context、建业务对象、跑事件循环。
// 具体逻辑全部在 server/ 和 network/ 里——main 不应该有业务逻辑。

#include "common/log.h"
#include "common/net.h"
#include "common/protocol.h"
#include "server/chat_server.h"

#include <csignal>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>

int main(int argc, char *argv[]) {

  //设置服务器端口，默认protocol里的port 9527
  std::uint16_t port = seer::kDefaultPort;//用无符号16进制设置端口
  if (argc > 1) {//如果有传入canasta
    try {
      const int p = std::stoi(argv[1]);//字符串改为数字
      if (p <= 0 || p > 65535) throw std::out_of_range("port");//若不在数组内抛出异常进行catch
      port = static_cast<std::uint16_t>(p);//int 转化为端口参数
    } catch (...) {
      std::fprintf(stderr, "端口不合法: %s\n用法: %s [port]\n", argv[1], argv[0]);
      return 1;
    }
  }

  //总线
  net::io_context io;

  // 优雅退出：把 Ctrl+C / SIGTERM 变成"停掉事件循环"，而不是让进程被信号杀死。
  // 这也代替了手写 POSIX 版里的 signal handler + volatile 标志位。
  //监听操作系统信号 SIGINT = Ctrl + C  ； SIGTERM = Ctrl D
  /*
    可以理解为
    创建一个信号监听器
    它属于 io
    监听 Ctrl+C 和 SIGTERM
  */
  net::signal_set signals(io, SIGINT, SIGTERM);
  //异步等待，这类
  signals.async_wait([&io](const seer::error_code &ec,int signal_number) {
    if (!ec) {
      //记录信号
      std::string signalName;

      if (signal_number == SIGINT) {
        signalName = "SIGINT";
      } else if (signal_number == SIGTERM) {
        signalName = "SIGTERM";
      } else {
        signalName = "UNKNOWN";
      }
      const std::string message =
      "收到退出信号:" + signalName + ",准备退出";

      seer::logLine(message);
      io.stop();
    }
  });

  seer::ChatServer server(io, port);
  server.start();

  seer::logLine("聊天服务端已启动（Ctrl+C 退出）");
  io.run();
  seer::logLine("服务端已退出。");
  return 0;
}
