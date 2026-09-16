#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""在真实终端（伪终端 pty）里跑一遍 client，验证交互用法。

smoke_test.py 里客户端用的是管道 stdin；这里换成 pty，模拟"人坐在终端前敲键盘"，
顺便确认客户端对终端（canonical mode）也工作正常。

    python3 tests/pty_session.py
"""

from __future__ import annotations

import os
import pty
import re
import select
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD_DIR = os.environ.get("SEER_BUILD_DIR", "build")
SERVER_BIN = os.path.join(ROOT, BUILD_DIR, "seer-server")
CLIENT_BIN = os.path.join(ROOT, BUILD_DIR, "seer-client")
PORT = int(os.environ.get("SEER_TEST_PORT", "9529"))


def read_available(fd: int, timeout: float) -> str:
    out = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], max(0.0, deadline - time.time()))
        if not r:
            break
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    return out.decode("utf-8", "replace")


def main() -> int:
    server = subprocess.Popen(
        [SERVER_BIN, str(PORT)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    watcher = None
    try:
        # 等服务端开始监听
        deadline = time.time() + 5
        while True:
            try:
                watcher = socket.create_connection(("127.0.0.1", PORT), timeout=0.3)
                break
            except OSError:
                if time.time() > deadline:
                    print("服务端没有启动")
                    return 1
                time.sleep(0.05)
        watcher.settimeout(2.0)
        watcher.recv(65536)  # 吃掉 watcher 自己的欢迎语

        # 在一个 pty 里启动 client：master/slave 两端，client 把 slave 当成真终端
        master, slave = pty.openpty()
        client = subprocess.Popen(
            [CLIENT_BIN, "127.0.0.1", str(PORT)], stdin=slave, stdout=slave, stderr=slave
        )
        os.close(slave)

        banner = read_available(master, 2.0)
        print("--- client 在 pty 里的输出 ---")
        print(banner.strip())
        ok = True

        def expect(cond: bool, desc: str) -> None:
            nonlocal ok
            print(("PASS " if cond else "FAIL ") + desc)
            ok = ok and cond

        expect("已连接 127.0.0.1" in banner, "client 打印连接成功提示")
        expect(re.search(r"你是 玩家\d+", banner) is not None, "client 收到欢迎语")

        # 像人在终端里那样敲一行字并回车（pty 是 canonical mode，'\n' 才会交付给 read）
        os.write(master, "终端里的一句话\n".encode("utf-8"))
        time.sleep(0.3)
        got = watcher.recv(65536).decode("utf-8")
        expect(re.search(r"\[玩家\d+\] 终端里的一句话\n", got) is not None,
               f"服务端把消息广播出去了（实际: {got!r}）")

        # Ctrl+D 结束输入
        os.write(master, b"\x04")
        time.sleep(0.3)
        tail = read_available(master, 1.0)
        print("--- 输入 Ctrl+D 之后 ---")
        print(tail.strip())
        expect("服务端关闭了连接" in (banner + tail) or "输入结束" in (banner + tail),
               "client 对 Ctrl+D / 服务端关闭有反应")

        client.wait(timeout=5)
        expect(client.returncode == 0, f"client 正常退出（返回码 {client.returncode}）")
        os.close(master)
        return 0 if ok else 1
    finally:
        if watcher is not None:
            watcher.close()
        server.kill()
        server.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(main())
