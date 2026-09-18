# 便捷入口，实际构建交给 CMake（和 freekill-asio 一样）。
#
#   make             配置并编译出 build/seer-server 和 build/seer-client
#   make test        跑 Lua 战斗核测试 + 冒烟测试 + 伪终端交互测试
#   make test-lua    只跑 Lua 战斗核测试（不需要编译 C++，只要 lua5.4）
#   make example     跑 Lua 战斗示例：雷伊 vs 盖亚打一局，打印战报
#   make example-rpc 同一局，但让战斗核跑在**另一个进程**里、用 JSON-RPC 驱动
#   make play        单机版：在命令行里和 AI 打一局（每轮自己选技能）
#   make run-server  直接跑服务端
#   make run-client  直接跑客户端
#   make clean       清掉 build/
#
# 想用 Boost.Asio 而不是独立版 Asio：
#   make CMAKE_ARGS="-DSEER_USE_BOOST_ASIO=ON"

BUILD_DIR  := build
CMAKE_ARGS ?=
LUA        ?= lua5.4

.PHONY: all clean test test-lua example example-rpc play test-smoke test-pty run-server run-client

all:
	cmake -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=Debug $(CMAKE_ARGS)
	cmake --build $(BUILD_DIR) -j

test: test-lua all test-smoke test-pty

# Lua 侧的战斗核（packages/seer-core）是纯 Lua，不依赖 C++ 服务端：
# 不起服务端、不起客户端就能把精灵/技能/效果/事件全测一遍。
# 这正是"规则放 Lua"的好处之一（见 docs/architecture.md §4）。
test-lua:
	$(LUA) packages/seer-core/tests/test_core.lua

# 战斗示例：standard 包里的雷伊（电系）和盖亚（战斗系）打一局。
# 顺便当"怎么用这套核心"的说明书看。
example:
	$(LUA) packages/seer-core/examples/battle_demo.lua

# 同一局，但战斗核在子进程里，两个进程只通过 JSON-RPC（stdin/stdout）说话。
# 这就是将来 C++ 那一端要接的位置。
example-rpc:
	$(LUA) packages/seer-core/examples/rpc_demo.lua

# 单机版：同一份战斗核，把"谁来答"换成命令行（CliHandler）。
# 换成联机只是把这一层换成 RpcHandler（请求包发给 C++/Unity），规则一行不改。
play:
	$(LUA) packages/seer-core/examples/single_player.lua

test-smoke: all
	python3 tests/smoke_test.py

# 在伪终端里跑客户端，验证真实终端下的交互
test-pty: all
	python3 tests/pty_session.py

run-server: all
	$(BUILD_DIR)/seer-server

run-client: all
	$(BUILD_DIR)/seer-client

clean:
	rm -rf $(BUILD_DIR)
