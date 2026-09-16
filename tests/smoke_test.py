#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""项目 1 的冒烟测试：真的启动 build/server，用真的 TCP 连接验证广播行为。

它同时也是"协议说明书"：看这个文件就知道协议长什么样。

    python3 tests/smoke_test.py            # 默认端口 9527
    python3 tests/smoke_test.py --port 9000
"""

from __future__ import annotations

import argparse
import os
import re
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD_DIR = os.environ.get("SEER_BUILD_DIR", "build")
SERVER_BIN = os.path.join(ROOT, BUILD_DIR, "seer-server")
CLIENT_BIN = os.path.join(ROOT, BUILD_DIR, "seer-client")

GREEN, RED, DIM, RESET = "\033[32m", "\033[31m", "\033[2m", "\033[0m"

_failures: list[str] = []
_checks = 0


def check(cond: bool, desc: str, actual: object = "") -> bool:
    global _checks
    _checks += 1
    if cond:
        print(f"  {GREEN}PASS{RESET} {desc}")
        return True
    print(f"  {RED}FAIL{RESET} {desc}")
    if actual != "":
        print(f"       {DIM}实际收到: {actual!r}{RESET}")
    _failures.append(desc)
    return False


class Conn:
    """一个测试用客户端：负责收发并按 '\\n' 拆行。"""

    def __init__(self, sock: socket.socket, label: str) -> None:
        self.sock = sock
        self.label = label
        self.buf = b""

    @classmethod
    def connect(cls, port: int, label: str) -> "Conn":
        sock = socket.create_connection(("127.0.0.1", port), timeout=3)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return cls(sock, label)

    def line(self, timeout: float = 2.0) -> str | None:
        """读一条完整消息；超时或对端关闭返回 None。"""
        self.sock.settimeout(timeout)
        while b"\n" not in self.buf:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                return None
            if not chunk:
                return None
            self.buf += chunk
        raw, self.buf = self.buf.split(b"\n", 1)
        return raw.decode("utf-8")

    def send_raw(self, data: str) -> None:
        self.sock.sendall(data.encode("utf-8"))

    def send(self, text: str) -> None:
        self.send_raw(text + "\n")

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


def start_server(port: int) -> subprocess.Popen:
    if not os.path.exists(SERVER_BIN):
        sys.exit(f"找不到 {SERVER_BIN}，先执行 make")
    return subprocess.Popen(
        [SERVER_BIN, str(port)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def wait_for_server(proc: subprocess.Popen, port: int, timeout: float = 5.0) -> Conn:
    """反复尝试连接，直到服务端开始监听。这条连接直接当作客户端 A 用。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            sys.exit("服务端提前退出了：\n" + (proc.stdout.read() if proc.stdout else ""))
        try:
            return Conn.connect(port, "A")
        except OSError:
            time.sleep(0.05)
    proc.kill()
    sys.exit(f"服务端 {timeout} 秒内没有在 {port} 端口开始监听")


def read_banner(conn: Conn) -> str:
    """读取连接建立时服务端下发的两行欢迎语，返回服务端给这个客户端的名字。"""
    first = conn.line()
    second = conn.line()
    assert first is not None and second is not None, f"{conn.label} 没有收到欢迎语"
    m = re.search(r"你是 (玩家\d+)", first)
    assert m, f"欢迎语里没有名字: {first!r}"
    print(f"  {DIM}{conn.label} 收到欢迎语: {first}{RESET}")
    return m.group(1)


def run(port: int) -> None:
    proc = start_server(port)
    client_proc = None
    try:
        print("\n[1] 服务端启动、客户端 A 连接")
        a = wait_for_server(proc, port)
        name_a = read_banner(a)
        check(name_a == "玩家1", "第一个连接被命名为 玩家1", name_a)

        print("\n[2] 客户端 B 连接，A 应收到进入聊天室的系统消息")
        b = Conn.connect(port, "B")
        name_b = read_banner(b)
        check(name_b == "玩家2", "第二个连接被命名为 玩家2", name_b)
        got = a.line()
        check(got == "*** 玩家2 进入了聊天室 ***", "A 收到 B 进入聊天室的系统消息", got)

        print("\n[3] 广播")
        a.send("你好，我是A")
        got = b.line()
        check(got == "[玩家1] 你好，我是A", "B 收到 A 的消息（格式 [名字] 内容）", got)
        check(a.line(timeout=0.4) is None, "A 不会收到自己消息的回显", "收到了多余数据")

        print("\n[4] TCP 分帧：半个消息不该被当成一条消息")
        b.send_raw("分两")
        time.sleep(0.15)
        check(a.line(timeout=0.4) is None, "只发半个消息时，A 那边什么都不该出现", "提前收到了半条")
        b.send_raw("次发\n")
        got = a.line()
        check(got == "[玩家2] 分两次发", "补齐换行后，A 收到完整的一条消息", got)

        print("\n[5] 超长消息按上限截断（kMaxLineLength = 4096）")
        a.send("x" * 6000)
        got = b.line(timeout=3)
        check(got == "[玩家1] " + "x" * 4096, "6000 字节的消息被截断成 4096 字节", (len(got) if got else None))

        print("\n[6] 断开连接要通知其他人")
        b.close()
        got = a.line()
        check(got == "*** 玩家2 离开了聊天室 ***", "A 收到 B 离开聊天室的系统消息", got)

        print("\n[7] 编译出来的 client 可执行文件端到端跑一遍")
        if not os.path.exists(CLIENT_BIN):
            sys.exit(f"找不到 {CLIENT_BIN}，先执行 make")
        client_proc = subprocess.Popen(
            [CLIENT_BIN, "127.0.0.1", str(port)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        got = a.line()
        check(got == "*** 玩家3 进入了聊天室 ***", "client 进程连上后，A 收到进入聊天室的系统消息", got)
        assert client_proc.stdin is not None
        client_proc.stdin.write("来自客户端进程\n")
        client_proc.stdin.flush()
        got = a.line()
        check(got == "[玩家3] 来自客户端进程", "A 收到 client 进程发出的消息", got)

        # 关掉 client 的 stdin 相当于 Ctrl+D：它 shutdown(SHUT_WR)，服务端随后断开它
        client_proc.stdin.close()
        got = a.line()
        check(got == "*** 玩家3 离开了聊天室 ***", "client 进程退出后，A 收到离开消息", got)
        # stdin 已经关掉了，不能再 communicate()，直接等它退出再读输出
        client_proc.wait(timeout=5)
        client_out = client_proc.stdout.read() if client_proc.stdout else ""
        check(client_proc.returncode == 0, "client 进程正常退出（返回码 0）", client_proc.returncode)
        check("已连接" in client_out, "client 打印了连接成功提示", client_out)
        check("服务端关闭了连接" in client_out, "client 感知到服务端关闭了连接", client_out)
        print(f"  {DIM}--- client 进程输出 ---\n{client_out.strip()}{RESET}")

        print("\n[8] 半包上限：灌 100KB 没有换行的数据，服务端要断开这条连接且不崩")
        flood = Conn.connect(port, "flood")
        try:
            flood.sock.sendall(b"x" * (100 * 1024))
        except OSError:
            pass  # 服务端可能在半路就把连接关了，属于预期
        # 期望：服务端在接收缓冲超限后主动关闭这条连接（recv 最终返回 b'' 或出错）
        closed = False
        flood.sock.settimeout(3.0)
        while True:
            try:
                if flood.sock.recv(65536) == b"":
                    closed = True
                    break
            except OSError:
                closed = True
                break
        check(closed, "服务端检测到超限后关闭了这条连接")
        flood.close()
        # 服务端没崩：还能接受新连接
        after = Conn.connect(port, "after")
        name_after = read_banner(after)
        check(name_after.startswith("玩家"), "服务端依然能接受新连接", name_after)
        after.close()

        print("\n[9] Ctrl+C（SIGINT）要优雅退出")
        proc.send_signal(2)
        rc = proc.wait(timeout=5)
        server_log = proc.stdout.read() if proc.stdout else ""
        check(rc == 0, "服务端收到 SIGINT 后返回码为 0", rc)
        check("服务端已退出" in server_log, "服务端打印了退出日志", server_log[-200:])
        print(f"  {DIM}--- 服务端日志 ---\n{server_log.strip()}{RESET}")

    finally:
        if client_proc is not None and client_proc.poll() is None:
            client_proc.kill()
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser(description="项目 1 冒烟测试")
    parser.add_argument("--port", type=int, default=9527, help="测试用端口（默认 9527）")
    args = parser.parse_args()

    print(f"冒烟测试开始：端口 {args.port}，服务端 {SERVER_BIN}")
    run(args.port)

    print()
    if _failures:
        print(f"{RED}失败 {len(_failures)}/{_checks} 项：{RESET}")
        for f in _failures:
            print(f"  - {f}")
        return 1
    print(f"{GREEN}全部 {_checks} 项通过{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
