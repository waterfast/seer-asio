// SPDX-License-Identifier: GPL-3.0-or-later
//
// 选择用哪个 Asio。
//
// 独立版 Asio（<asio.hpp>）和 Boost.Asio（<boost/asio.hpp>）本质上是同一套 API 的
// 两种发行方式：独立版轻、不依赖 Boost；Boost 版就是独立版 + Boost 生态的胶水。
// 这里用一个 net 命名空间别名统一起来，编译时用 -DSEER_USE_BOOST_ASIO 切换。
//
// 我们自己默认用独立版 Asio；隔壁 freekill-asio 用的是 Boost.Asio，想对照它源码时
// 切到 Boost 版即可，两边的调用方式一模一样（boost::asio::io_context 对应 asio::io_context）。

#pragma once

#ifdef SEER_USE_BOOST_ASIO

#include <boost/asio.hpp>
#include <boost/asio/awaitable.hpp>
#include <boost/asio/co_spawn.hpp>
#include <boost/asio/detached.hpp>
#include <boost/asio/use_awaitable.hpp>
#include <boost/asio/redirect_error.hpp>
#include <boost/asio/posix/stream_descriptor.hpp>
#include <boost/asio/signal_set.hpp>
#include <boost/system/error_code.hpp>

namespace net = boost::asio;

#else

#include <asio.hpp>
#include <asio/awaitable.hpp>
#include <asio/co_spawn.hpp>
#include <asio/detached.hpp>
#include <asio/use_awaitable.hpp>
#include <asio/redirect_error.hpp>
#include <asio/posix/stream_descriptor.hpp>
#include <asio/signal_set.hpp>

namespace net = asio;

#endif

// 两种 Asio 的错误码类型名字不一样：
//   独立版：asio::error_code（= std::error_code）
//   Boost 版：boost::system::error_code（boost::asio 里没有 error_code 这个别名）
// 所以这里统一一个 seer::error_code，代码里只用它。
namespace seer {
#ifdef SEER_USE_BOOST_ASIO
using error_code = boost::system::error_code;
#else
using error_code = asio::error_code;
#endif
} // namespace seer
