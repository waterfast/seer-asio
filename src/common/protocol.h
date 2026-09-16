// SPDX-License-Identifier: GPL-3.0-or-later
//
// 服务端与客户端共用的协议常量。
//
// 项目 1 的协议：纯文本、UTF-8、以 '\n' 作为"一条消息的结束"。
//
//   客户端 --(用户输入的任意一行文本)--> 服务端 --(广播给其它连接)--> 其它客户端
//   服务端主动下发的提示统一以 "*** " 开头，例如 "*** 玩家2 进入了聊天室 ***"
//
// 为什么先用文本行？
//   TCP 是字节流，没有"消息"的概念，收方只能自己定边界。用 '\n' 做边界是最省事
//   的一种分帧（framing）方式：收方把收到的字节攒进缓冲区，见 '\n' 才切出一条完整
//   消息，剩下的留在缓冲区里等下一次 recv。这个模式后面换成 JSON 也一样用。
//
// 后续演进：
//   项目 2（Command Server）：这一行变成命令，如 "LOGIN nk"、"USE_SKILL 1001"。
//   项目 3（JSON Protocol）：这一行变成一个 JSON 对象，如 {"type":"UseSkill","skillId":1001}。
//                            到那时可以考虑换成 Boost.Asio 的异步模型（参考 freekill-asio）。

#pragma once

#include <cstddef>
#include <cstdint>

namespace seer {

// 监听端口。同目录 freekill-asio 用的是 1103（TCP）+ 1104（UDP），
// 我们自己的项目先用 9527 把流程跑通。
inline constexpr std::uint16_t kDefaultPort = 9527;

// 客户端默认连本机；想连局域网里的服务端就把服务端 IP 作为第一个参数传进去。
inline constexpr const char *kDefaultHost = "127.0.0.1";

// listen() 的等待队列长度（内核帮我们排队的、还没 accept 的连接数上限）。
inline constexpr int kListenBacklog = 64;

// 单条消息的长度上限，超长会被服务端截断，避免一条消息吃掉整个缓冲区。
inline constexpr std::size_t kMaxLineLength = 4096;

// 一条连接接收缓冲区的上限。正常客户端不会攒这么多，超过说明对端在灌没有换行的数据。
inline constexpr std::size_t kMaxPendingBytes = 64 * 1024;

} // namespace seer
