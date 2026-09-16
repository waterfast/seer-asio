import socket, subprocess, time, select
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
probe = socket.socket()
probe.bind(('127.0.0.1', 0))
port = probe.getsockname()[1]
probe.close()
p = subprocess.Popen([str(ROOT / 'build/seer-server'), str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
clients = []
def connect():
    s = socket.create_connection(('127.0.0.1', port), timeout=2)
    clients.append(s)
    return s
def send(s, text):
    s.sendall((text + '\n').encode())
def line(s):
    data = b''
    while not data.endswith(b'\n'):
        part = s.recv(1)
        assert part, 'unexpected EOF'
        data += part
    return data.decode().rstrip('\n')
def quiet(s):
    assert not select.select([s], [], [], .15)[0], 'unexpected message'
try:
    for _ in range(100):
        try:
            a = connect()
            break
        except ConnectionRefusedError:
            if p.poll() is not None:
                raise RuntimeError(p.stderr.read().decode())
            time.sleep(.02)
    else:
        raise RuntimeError('startup timeout')
    b = connect()
    quiet(a); quiet(b)
    for command in ('help', 'HElP', 'H', 'h'):
        send(a, command)
        help_text = line(a)
        assert help_text.startswith('OK HELP ')
        assert 'WHO/W' in help_text and 'USE_SKILL/U' in help_text
        quiet(a); quiet(b)
    send(a, 'h extra'); assert line(a).startswith('ERR 402 ')
    for command in ('who', 'w', 's hello', 'u 雷神觉醒'):
        send(a, command); assert line(a).startswith('ERR 401 ')
    send(a, 'he'); assert line(a).startswith('ERR 400 ')
    send(a, 'SAY hello'); assert line(a).startswith('ERR 401 '); quiet(b)
    for command in ('LOGIN', 'LOGIN Alice extra'):
        send(a, command); assert line(a).startswith('ERR 402 '); quiet(a); quiet(b)
    send(a, 'l Alice'); assert line(a) == 'OK LOGIN'
    assert line(b) == '*** Alice 进入了聊天室 ***'; quiet(a)
    send(a, 'w'); assert line(a) == 'OK WHO 1 1:Alice'; quiet(b)
    send(a, 'LOGIN Changed'); assert line(a).startswith('ERR 403 '); quiet(b)
    send(b, 'LoGiN Alice'); assert line(b) == 'OK LOGIN'
    assert line(a) == '*** Alice 进入了聊天室 ***'
    send(a, 'WhO'); assert line(a) == 'OK WHO 2 1:Alice 2:Alice'
    send(a, 'w extra'); assert line(a).startswith('ERR 402 ')
    for command in ('SAY', 'SAY hello world'):
        send(a, command); assert line(a).startswith('ERR 402 '); quiet(b)
    send(a, 's Hello'); assert line(b) == '[Alice] Hello'; quiet(a)
    c = connect(); send(c, 'SAY hello'); assert line(c).startswith('ERR 401 ')
    c.close(); quiet(a); quiet(b)
    b.close(); assert line(a) == '*** Alice 离开了聊天室 ***'; quiet(a)
    d = connect(); send(d, 'SAY hello'); assert line(d).startswith('ERR 401 ')
    send(d, 'LOGIN Bob'); assert line(d) == 'OK LOGIN'
    assert line(a) == '*** Bob 进入了聊天室 ***'
    send(a, 'who'); assert line(a) == 'OK WHO 2 1:Alice 3:Bob'
    # Unknown commands keep their own error code even before login.
    e = connect()
    send(e, 'FOO'); assert line(e).startswith('ERR 400 ')
    send(e, 'USE_SKILL 1'); assert line(e).startswith('ERR 401 ')
    send(e, 'QUIT extra'); assert line(e).startswith('ERR 402 ')
    send(e, 'q'); assert line(e) == 'OK QUIT'; assert e.recv(1) == b''
    quiet(a); quiet(d)

    for command in ('USE_SKILL', 'USE_SKILL 雷神 觉醒',
                    'USE_SKILL ' + '雷' * 41, 'USE_SKILL ' + 'a' * 121):
        send(a, command); assert line(a).startswith('ERR 402 ')
        quiet(a); quiet(d)
    for name in ('雷神觉醒', '石破天机', '雷' * 40, 'a' * 120, '雷神Awake123', '🔥' * 10, '1001'):
        send(a, 'USE_SKILL ' + name); assert line(a) == 'OK USE_SKILL'
        assert line(d) == '[Alice] 使用了技能 ' + name; quiet(a); quiet(d)
    for command in ('u', 'use_skill', 'UsE_sKiLl'):
        send(a, command + ' 石破天机'); assert line(a) == 'OK USE_SKILL'
        assert line(d) == '[Alice] 使用了技能 石破天机'
    send(a, 'QUIT extra'); assert line(a).startswith('ERR 402 ')
    # Commands following QUIT in the same read must not produce side effects.
    a.sendall(b'QUIT\nSAY ghost\nUSE_SKILL 1\nLOGIN Ghost\nQUIT\n')
    assert line(a) == 'OK QUIT'; assert a.recv(1) == b''
    assert line(d) == '*** Alice 离开了聊天室 ***'; quiet(d)
    send(d, 'USE_SKILL 0'); assert line(d) == 'OK USE_SKILL'
    send(d, 'QUIT'); assert line(d) == 'OK QUIT'; assert d.recv(1) == b''
    assert p.poll() is None
    print('PASS: commands, HELP/WHO, aliases, mixed case, UTF-8 skills, validation and QUIT')
finally:
    for s in clients:
        s.close()
    p.terminate()
    p.communicate(timeout=3)
