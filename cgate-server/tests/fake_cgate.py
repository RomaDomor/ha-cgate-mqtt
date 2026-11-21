"""Fake C-Gate command port for healthcheck tests (never used against the real bus).

State comes from a JSON file re-read on every connection:
  {"banner": true, "nets": {"254": "State=ok InterfaceState=running", ...},
   "open_delay_s": 0, "silent": false}
Every received command is appended to <state>.cmds. Reply formats are the ones C-Gate 2.11.8
logged on the house (2026-11-21): `201 Service ready: ...`, `131-network=N ...` (last `131 `),
`200 OK: //OGONEK/N` (after `120-` progress for a reopen), `204 Closing connection.`.
"""
import asyncio, json, sys

STATE = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 20023


def load():
    with open(STATE) as f:
        return json.load(f)


def save(s):
    with open(STATE, "w") as f:
        json.dump(s, f)


async def handle(reader, writer):
    s = load()
    if s.get("silent"):
        await asyncio.sleep(30)
        writer.close()
        return
    if s.get("banner", True):
        writer.write(b"201 Service ready: Clipsal C-Gate Version: v2.11.8 (build 3282) #cmd-syntax=1.0\r\n")
    while True:
        raw = await reader.readline()
        if not raw:
            break
        cmd = raw.decode().strip()
        with open(STATE + ".cmds", "a") as f:
            f.write(cmd + "\n")
        s = load()
        if cmd == "net list":
            items = sorted(s["nets"].items(), key=lambda kv: -int(kv[0]))
            for i, (n, st) in enumerate(items):
                sep = " " if i == len(items) - 1 else "-"
                writer.write(f"131{sep}network={n} {st}\r\n".encode())
        elif cmd.startswith("net open "):
            n = cmd.split()[2]
            writer.write(b"120-relinking to bridged networks\r\n")
            await writer.drain()
            await asyncio.sleep(s.get("open_delay_s", 0))
            s = load()
            s["nets"][n] = "State=sync InterfaceState=running"
            save(s)
            writer.write(f"120-open complete\r\n200 OK: //OGONEK/{n}\r\n".encode())
        elif cmd == "quit":
            writer.write(b"204 Closing connection.\r\n")
            await writer.drain()
            break
        else:
            writer.write(b"401 Bad object or device ID\r\n")
        await writer.drain()
    writer.close()


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", PORT)
    async with server:
        await server.serve_forever()


asyncio.run(main())
