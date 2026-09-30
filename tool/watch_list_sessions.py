#!/usr/bin/env python3
"""Poll list_sessions on a throwaway server process (own data dir, never the installed DB)."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "bin" / "dart_network_mcp.dart"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Watch list_sessions through a native server started from this checkout",
    )
    parser.add_argument(
        "-i",
        "--interval",
        type=float,
        default=3.0,
        help="Seconds between list_sessions polls (default: 3)",
    )
    parser.add_argument(
        "--state",
        default="live",
        choices=("live", "history", "all"),
        help="list_sessions state filter (default: live)",
    )
    args = parser.parse_args()

    if not SERVER.is_file():
        print(f"missing {SERVER}", file=sys.stderr)
        return 2

    env = os.environ.copy()
    env.pop("DTD_URI", None)
    env["DART_NETWORK_MCP_DATA"] = tempfile.mkdtemp(prefix="dart_network_mcp_watch_")

    print(
        f"[watch] starting {SERVER} (no DTD_URI, data={env['DART_NETWORK_MCP_DATA']}); poll every {args.interval}s state={args.state}",
        flush=True,
    )
    proc = subprocess.Popen(
        ["dart", "run", str(SERVER)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env=env,
        cwd=str(ROOT),
    )

    def drain_stderr() -> None:
        assert proc.stderr is not None
        for line in proc.stderr:
            print(f"[mcp-err] {line.rstrip()}", flush=True)

    threading.Thread(target=drain_stderr, daemon=True).start()

    stopping = False

    def stop(*_args: object) -> None:
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    nid = 0

    def send(msg: dict) -> None:
        assert proc.stdin is not None
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    def recv(expect: int, timeout: float = 30.0) -> dict:
        assert proc.stdout is not None
        deadline = time.time() + timeout
        while time.time() < deadline:
            if proc.poll() is not None:
                raise RuntimeError(f"mcp exited early code={proc.returncode}")
            line = proc.stdout.readline()
            if not line:
                raise RuntimeError("mcp stdout closed")
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            if msg.get("id") == expect:
                return msg
        raise TimeoutError(f"timeout waiting for id={expect}")

    try:
        nid += 1
        send(
            {
                "jsonrpc": "2.0",
                "id": nid,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "watch-list-sessions", "version": "0"},
                },
            }
        )
        init = recv(nid)
        server = (init.get("result") or {}).get("serverInfo") or {}
        print(f"[watch] initialized {server}", flush=True)
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})

        while not stopping:
            nid += 1
            send(
                {
                    "jsonrpc": "2.0",
                    "id": nid,
                    "method": "tools/call",
                    "params": {
                        "name": "list_sessions",
                        "arguments": {"state": args.state},
                    },
                }
            )
            resp = recv(nid)
            content = (resp.get("result") or {}).get("content") or []
            text = "".join(
                c.get("text", "") for c in content if c.get("type") == "text"
            )
            stamp = time.strftime("%H:%M:%S")
            try:
                body = json.loads(text) if text else {}
            except json.JSONDecodeError:
                print(f"[{stamp}] raw={text}", flush=True)
            else:
                sessions = body.get("sessions") or []
                if not sessions:
                    print(f"[{stamp}] sessions=[]", flush=True)
                else:
                    print(f"[{stamp}] sessions={len(sessions)}", flush=True)
                    for s in sessions:
                        print(
                            f"  vmUri={s.get('vmUri')} state={s.get('state')} "
                            f"appName={s.get('appName')} "
                            f"httpProfileAvailable={s.get('httpProfileAvailable')}",
                            flush=True,
                        )
            time.sleep(args.interval)
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
        print("[watch] stopped", flush=True)

    return 0


if __name__ == "__main__":
    sys.exit(main())
