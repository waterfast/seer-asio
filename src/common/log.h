// SPDX-License-Identifier: GPL-3.0-or-later
//
// 极简日志：时间戳 + 一行文本，直接写到 stdout。
// 以后想换成异步写盘 / 按大小滚动，可以上 spdlog（freekill-asio 用的就是 spdlog，
// 本机已装好 libspdlog-dev）。这里先保持零依赖，别让日志喧宾夺主。

#pragma once

#include <chrono>
#include <cstdio>
#include <ctime>
#include <string>

namespace seer {

inline std::string nowString() {
  const std::time_t t = std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
  std::tm tm{};
  localtime_r(&t, &tm);
  char buf[16];
  std::strftime(buf, sizeof buf, "%H:%M:%S", &tm);
  return buf;
}

inline void logLine(const std::string &msg) {
  std::printf("[%s] %s\n", nowString().c_str(), msg.c_str());
  std::fflush(stdout); // 日志要及时刷出来，尤其被重定向到文件/管道时
}

} // namespace seer
