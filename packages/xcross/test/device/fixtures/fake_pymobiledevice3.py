"""Scripted stand-in for pymobiledevice3 in launcher session tests.

Serves the subcommands one CoreDevice session uses over the userspace
transport: `developer dvt launch`, `developer debugserver start-server` (a
minimal GDB-remote server), `usbmux forward` (a TCP relay to FAKE_VM_PORT), and
`syslog live` (canned JSON log lines). FAKE_RECORD collects the launch argv.
"""

import json
import os
import socket
import sys
import threading
import time

PID = 4242


def packet(payload):
    checksum = sum(payload.encode()) & 0xFF
    return f"${payload}#{checksum:02x}".encode()


def debugserver(port):
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", port))
    server.listen(1)
    conn, _ = server.accept()
    buffer = b""
    while True:
        data = conn.recv(4096)
        if not data:
            return
        buffer += data
        while b"$" in buffer and b"#" in buffer[buffer.index(b"$"):]:
            start = buffer.index(b"$")
            end = buffer.index(b"#", start)
            if len(buffer) < end + 3:
                break
            payload = buffer[start + 1:end].decode()
            buffer = buffer[end + 3:]
            if payload.startswith("vAttach"):
                conn.sendall(packet("T11thread:1;"))
            elif payload == "c":
                time.sleep(float(os.environ.get("FAKE_EXIT_AFTER", "4")))
                conn.sendall(packet("W00"))
            elif payload == "k":
                return
            else:
                conn.sendall(packet("OK"))


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.close()
            except OSError:
                pass


def forward(local_port):
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", local_port))
    server.listen(8)
    target = int(os.environ["FAKE_VM_PORT"])
    while True:
        client, _ = server.accept()
        upstream = socket.create_connection(("127.0.0.1", target))
        threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
        threading.Thread(target=pump, args=(upstream, client), daemon=True).start()


def syslog():
    for pid, message in [
        (PID, "flutter: hello from dart"),
        (PID, "nw_resolver_start_query chatter"),
        (7, "flutter: another process"),
        (PID, "flutter: second line"),
    ]:
        print(json.dumps({"pid": pid, "message": message}), flush=True)
    while True:
        time.sleep(1)


def main(args):
    if args[:3] == ["developer", "dvt", "launch"]:
        with open(os.environ["FAKE_RECORD"], "w") as record:
            json.dump(args, record)
        print(f"Process launched with pid {PID}")
    elif args[:3] == ["developer", "debugserver", "start-server"]:
        debugserver(int(args[args.index("--local-port") + 1]))
    elif args[:2] == ["usbmux", "forward"]:
        forward(int(args[2]))
    elif args[:2] == ["syslog", "live"]:
        syslog()
    else:
        print(f"unexpected: {args}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
