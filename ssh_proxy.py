#!/usr/bin/env python3
"""SSH ProxyCommand via SOCKS5 relay.
~/.ssh/config: ProxyCommand python3 /path/to/ssh_proxy.py %h %p
Credentials from environment variables.
"""
import os, socket, struct, sys, threading


def socks5_connect(ph, pp, user, pw, dh, dp):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(30); s.connect((ph, pp))
    s.sendall(b"\x05\x02\x00\x02")
    r = s.recv(2)
    if r[1] == 2:
        s.sendall(b"\x01" + bytes([len(user)]) + user.encode() + bytes([len(pw)]) + pw.encode())
        if s.recv(2)[1] != 0:
            raise ConnectionError("auth failed")
    hb = dh.encode()
    s.sendall(b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb + struct.pack(">H", dp))
    c = s.recv(4)
    if len(c) < 4 or c[1] != 0:
        raise ConnectionError(f"connect failed: {c.hex()}")
    a = c[3]
    if a == 1: s.recv(6)
    elif a == 3: s.recv(s.recv(1)[0] + 2)
    elif a == 4: s.recv(18)
    return s


def pump(src_fd, dst_fd, half_close=None):
    """src_fd -> dst_fd（都是文件描述符）。
    half_close 传 socket 对象，EOF 时对写方向做 SHUT_WR，让对端知道数据发完了。
    """
    try:
        while True:
            d = os.read(src_fd, 65536)
            if not d:
                break
            os.write(dst_fd, d)
    except OSError:
        pass
    finally:
        if half_close is not None:
            try:
                half_close.shutdown(socket.SHUT_WR)
            except OSError:
                pass


def main():
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} <host> <port>", file=sys.stderr)
        sys.exit(2)
    host, port = sys.argv[1], int(sys.argv[2])
    s = socks5_connect(
        os.environ["VPS_HOST"],
        int(os.environ.get("VPS_SOCKS_PORT", "1080")),
        os.environ.get("VPS_SOCKS_USER", ""),
        os.environ.get("VPS_SOCKS_PASS", ""),
        host, port,
    )
    s.settimeout(None)

    # remote -> stdout（fd 1）
    t = threading.Thread(target=pump, args=(s.fileno(), 1), daemon=True)
    t.start()
    # stdin（fd 0）-> remote，EOF 时半关 socket 通知对端
    pump(0, s.fileno(), half_close=s)
    t.join(timeout=5)
    s.close()


if __name__ == "__main__":
    main()
