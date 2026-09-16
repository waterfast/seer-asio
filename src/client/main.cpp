// SPDX-License-Identifier: GPL-3.0-or-later
//
// 客户端入口：解析参数后把活交给 ConsoleClient（逻辑在 client/console_client.cpp）。
// main 保持很薄，不写业务。

#include "client/console_client.h"
#include "common/protocol.h"

#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <string>

int main(int argc, char *argv[]) {
  std::string host = seer::kDefaultHost;
  std::uint16_t port = seer::kDefaultPort;

  if (argc > 1) host = argv[1];
  if (argc > 2) {
    try {
      const int p = std::stoi(argv[2]);
      if (p <= 0 || p > 65535) throw std::out_of_range("port");
      port = static_cast<std::uint16_t>(p);
    } catch (...) {
      std::fprintf(stderr, "端口不合法: %s\n用法: %s [host] [port]\n", argv[2], argv[0]);
      return 1;
    }
  }

  seer::ConsoleClient client(host, port);
  return client.run();
}
