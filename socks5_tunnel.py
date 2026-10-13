#!/usr/bin/env python3
"""SOCKS5 tunnel with auto-restart.
Routes local traffic through a remote SOCKS5 proxy to a target host:port.
Credentials from environment variables (see .env.example).
Usage:
    python3 socks5_tunnel.py [target_host] [target_port] [listen_port]
"""
import os, socket, struct, sys, threading, time

def socks5_connect(proxy_host, proxy_port, user, password, dst_host, dst_port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(30)
    s.connect((proxy_host, proxy_port))
    s.sendall(b"\x05\x02\x00\x02")
    resp = s.recv(2)
    if resp[1] == 2:
        s.sendall(b"\x01" + bytes([len(user)]) + user.encode()
                  + bytes([len(password)]) + password.encode())
        if s.recv(2)[1] != 0:
            raise ConnectionError("SOCKS5 auth failed")
    hb = dst_host.encode()
    s.sendall(b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb + struct.pack(">H", dst_port))
    conn = s.recv(4)
    if len(conn) < 4 or conn[1] != 0:
        raise ConnectionError(f"SOCKS5 connect failed: {conn.hex()}")
    atyp = conn[3]
    if atyp == 1: s.recv(6)
    elif atyp == 3: s.recv(s.recv(1)[0] + 2)
    elif atyp == 4: s.recv(18)
    return s

def forward(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data: break
            dst.sendall(data)
    except OSError: pass

def main():
    dst_host = sys.argv[1] if len(sys.argv) > 1 else "example.com"
    dst_port = int(sys.argv[2]) if len(sys.argv) > 2 else 443
    listen_port = int(sys.argv[3]) if len(sys.argv) > 3 else 8443
    proxy_host = os.environ["VPS_HOST"]
    proxy_port = int(os.environ.get("VPS_SOCKS_PORT", "1080"))
    user = os.environ.get("VPS_SOCKS_USER", "")
    password = os.environ.get("VPS_SOCKS_PASS", "")
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", listen_port))
    server.listen(50)
    server.settimeout(1)
    print(f"[{time.strftime('%F %T', time.gmtime())}] {listen_port} -> {dst_host}:{dst_port}")
    n = 0
    while True:
        try:
            client, _ = server.accept()
            n += 1
            try:
                remote = socks5_connect(proxy_host, proxy_port, user, password, dst_host, dst_port)
                threading.Thread(target=forward, args=(client, remote), daemon=True).start()
                threading.Thread(target=forward, args=(remote, client), daemon=True).start()
            except Exception as e:
                print(f"[!] #{n}: {e}", file=sys.stderr); client.close()
        except socket.timeout: continue
        except KeyboardInterrupt: sys.exit(0)

if __name__ == "__main__":
    main()
