# 便捷入口，实际构建交给 CMake（和 freekill-asio 一样）。
#
#   make             配置并编译出 build/seer-server 和 build/seer-client
#   make test        跑冒烟测试 + 伪终端交互测试
#   make run-server  直接跑服务端
#   make run-client  直接跑客户端
#   make clean       清掉 build/
#
# 想用 Boost.Asio 而不是独立版 Asio：
#   make CMAKE_ARGS="-DSEER_USE_BOOST_ASIO=ON"

BUILD_DIR  := build
CMAKE_ARGS ?=

.PHONY: all clean test test-smoke test-pty run-server run-client

all:
	cmake -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=Debug $(CMAKE_ARGS)
	cmake --build $(BUILD_DIR) -j

test: all test-smoke test-pty

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
