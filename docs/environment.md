# 开发环境说明

## 这台机器实测情况

| 项 | 状态 |
| --- | --- |
| `g++` 13.3 / `make` | ✅ 有 |
| `sudo` | ⚠️ 需要密码（agent 自己装不了系统包） |
| cmake | ❌ 没有 |
| Boost / 独立版 asio | ❌ 都没有 |
| nlohmann-json / spdlog / sqlite3 / openssl / zlib / libgit2 / libcbor | ❌ 都没有 |
| 网络（GitHub、PyPI、apt 源） | ✅ 通 |

**项目 1 和项目 2 不需要任何新依赖**，`Makefile` + `g++` 就够。下面这些是项目 3
和"想直接读/编译隔壁 freekill-asio"时才需要的。

## 推荐：apt 一次装齐

依赖清单来自 `../freekill-asio/CMakeLists.txt` 与 `../freekill-asio/distro/static-build/alpine-build.sh`
（那里是 Alpine 的 `apk` 包名，下面是 Ubuntu 的对应包）。

```bash
sudo apt update && sudo apt install -y \
  build-essential cmake ninja-build git \
  libasio-dev libboost-dev \
  nlohmann-json3-dev libspdlog-dev \
  libsqlite3-dev libssl-dev zlib1g-dev \
  libgit2-dev libcbor-dev libreadline-dev \
  lua5.4
```

各包是干什么的：

| 包 | 用途 |
| --- | --- |
| `cmake` `ninja-build` `build-essential` | 构建工具（freekill-asio 要求 cmake ≥ 3.18，noble 源里是 3.28.3） |
| `libasio-dev` | **独立版 Asio**：`#include <asio.hpp>`，不依赖 Boost，轻 |
| `libboost-dev` | **Boost.Asio/Beast**：`#include <boost/asio.hpp>`，隔壁 freekill-asio 用的就是这个 |
| `nlohmann-json3-dev` | 项目 3 的 JSON 库（单头文件、MIT） |
| `libspdlog-dev` | 日志库，freekill-asio 在用，我们以后可以用它替掉裸 `printf` |
| `libsqlite3-dev` | 存档/账号数据库 |
| `libssl-dev` | OpenSSL，加密与哈希（freekill-asio 用它的 AES/SHA/RSA） |
| `zlib1g-dev` | 压缩 |
| `libgit2-dev` | freekill-asio 用它拉游戏包（`libgit2`） |
| `libcbor-dev` | freekill-asio 的线上协议是 CBOR 二进制 |
| `libreadline-dev` | 命令行编辑（freekill-asio 的管理员 shell 用） |
| `lua5.4` | 跑 freekill-asio 要用它 exec 子进程；只是想编译它的话不需要 |

只要最小集合（够我们自己的项目走到项目 3）：

```bash
sudo apt install -y cmake libasio-dev nlohmann-json3-dev
```

## 备选：完全不用 sudo（我已实测可行）

如果不想动系统包，这两条路都能走：

1. **头文件库直接放进 `src/3rdparty/`**
   - 独立版 Asio：`https://github.com/chriskohlhoff/asio/archive/refs/tags/asio-1-30-2.tar.gz`
     （用 `asio/include` 里的头文件，编译加 `-DASIO_STANDALONE -pthread`）
   - nlohmann/json：`https://github.com/nlohmann/json/releases/download/v3.11.3/json.hpp`（单头文件）
   - 实测：`g++ -std=c++20 -DASIO_STANDALONE -I asio/include` 编译通过（asio 1.30.2）。
2. **cmake 用官方预编译二进制**
   - `https://github.com/Kitware/CMake/releases/download/v3.30.5/cmake-3.30.5-linux-x86_64.tar.gz`
   - 解压即用，实测 `cmake --version` → 3.30.5（注意 `~/.local/bin` 不在 PATH 里，
     要用绝对路径或自己加 PATH）。

## 装完怎么验证

```bash
cmake --version                       # ≥ 3.18
g++ -std=c++20 -DASIO_STANDALONE -pthread \
    -x c++ - -o /tmp/asio_check <<'EOF'
#include <asio.hpp>
#include <iostream>
int main() {
  asio::io_context io;
  asio::ip::tcp::acceptor a(io, {asio::ip::tcp::v4(), 0});
  std::cout << "asio OK, port " << a.local_endpoint().port() << "\n";
}
EOF
/tmp/asio_check
```

再顺手确认我们的项目没被影响：

```bash
cd seer-asio && make clean && make && make test
```
