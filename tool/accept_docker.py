#!/usr/bin/env python3
"""Task 15 acceptance against dart-network-mcp Docker image (stdio MCP)."""
from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "example"
DEVICE = "6524F3A2-8C20-47AB-9CA3-2C4C09145811"
HOME = os.path.expanduser("~")
DATA = f"{HOME}/.local/share/dart-network-mcp"
VM_RE = re.compile(r"A Dart VM Service on .+ is available at: (http://\S+)")


class McpDocker:
    def __init__(self) -> None:
        Path(DATA).mkdir(parents=True, exist_ok=True)
        self.proc = subprocess.Popen(
            [
                "docker",
                "run",
                "-i",
                "--rm",
                "--add-host=host.docker.internal:host-gateway",
                "-e",
                "HOME=/home/mcp",
                "-e",
                "DART_NETWORK_MCP_DATA=/data",
                "-e",
                "DART_NETWORK_MCP_IN_DOCKER=1",
                "-v",
                f"{HOME}/.dart-tool:/home/mcp/.dart-tool:ro",
                "-v",
                f"{DATA}:/data:rw",
                "-u",
                f"{os.getuid()}:{os.getgid()}",
                "dart-network-mcp:local",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert self.proc.stdin and self.proc.stdout
        self._id = 0
        self._stderr_lines: list[str] = []
        threading.Thread(target=self._drain_stderr, daemon=True).start()
        self._initialize()

    def _drain_stderr(self) -> None:
        assert self.proc.stderr
        for line in self.proc.stderr:
            self._stderr_lines.append(line.rstrip())
            print(f"MCP_ERR|{line.rstrip()}", flush=True)

    def _next_id(self) -> int:
        self._id += 1
        return self._id

    def _send(self, msg: dict) -> None:
        assert self.proc.stdin
        line = json.dumps(msg, separators=(",", ":"))
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def _recv(self, expect_id: int | None = None, timeout: float = 60.0) -> dict:
        assert self.proc.stdout
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError(
                    "MCP stdout closed; stderr=" + "\n".join(self._stderr_lines[-20:])
                )
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                print(f"MCP_RAW|{line}", flush=True)
                continue
            if expect_id is not None and msg.get("id") != expect_id:
                # skip notifications / unrelated
                print(f"MCP_SKIP|{line[:200]}", flush=True)
                continue
            return msg
        raise TimeoutError("MCP recv timeout")

    def _initialize(self) -> None:
        req_id = self._next_id()
        self._send(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "accept-docker", "version": "0.1.0"},
                },
            }
        )
        init = self._recv(expect_id=req_id)
        print(f"MCP_INIT|{json.dumps(init)[:300]}", flush=True)
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def call_tool(self, name: str, arguments: dict) -> dict:
        req_id = self._next_id()
        self._send(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments},
            }
        )
        resp = self._recv(expect_id=req_id, timeout=120.0)
        if "error" in resp:
            return {"error": resp["error"]}
        result = resp.get("result") or {}
        content = result.get("content") or []
        text = ""
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                text += item.get("text") or ""
        if not text:
            return {"raw": result}
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return {"text": text}

    def close(self) -> None:
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


def main() -> int:
    os.environ["HOME"] = HOME
    print(f"DATA_DIR={DATA}", flush=True)

    flutter = subprocess.Popen(
        ["flutter", "run", "-d", DEVICE],
        cwd=str(EXAMPLE),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert flutter.stdin and flutter.stdout

    vm_uri: str | None = None

    def reader() -> None:
        nonlocal vm_uri
        assert flutter.stdout
        for line in flutter.stdout:
            print(f"FLUTTER|{line.rstrip()}", flush=True)
            m = VM_RE.search(line)
            if m and vm_uri is None:
                vm_uri = m.group(1)

    threading.Thread(target=reader, daemon=True).start()

    deadline = time.time() + 240
    while vm_uri is None and time.time() < deadline:
        if flutter.poll() is not None:
            print("STEP2=FAIL flutter exited", flush=True)
            return 1
        time.sleep(0.5)
    if vm_uri is None:
        print("STEP2=FAIL no vm uri", flush=True)
        flutter.kill()
        return 1
    print(f"STEP2=PASS vmUri={vm_uri}", flush=True)

    mcp = McpDocker()
    results: dict[str, str] = {"STEP2": "PASS"}

    try:
        attach = mcp.call_tool("attach_vm", {"uri": vm_uri})
        print(f"ATTACH|{json.dumps(attach)}", flush=True)
        if attach.get("error") or attach.get("state") != "live":
            print("STEP3=FAIL attach", flush=True)
            return 1

        # Step 3
        step3 = False
        for i in range(30):
            time.sleep(1)
            r = mcp.call_tool("list_requests", {"vmUri": vm_uri, "limit": 200})
            reqs = r.get("requests") or []
            uris = [x.get("uri", "") for x in reqs if isinstance(x, dict)]
            ok = (
                any("/posts/1" in u for u in uris)
                and any("/users/1" in u for u in uris)
                and any("/albums/1" in u for u in uris)
            )
            print(f"STEP3_POLL{i} total={len(reqs)} ok={ok}", flush=True)
            if ok:
                step3 = True
                break
        results["STEP3"] = "PASS" if step3 else "FAIL"
        print(f"STEP3={results['STEP3']}", flush=True)

        # Step 4
        before = len((mcp.call_tool("list_requests", {"vmUri": vm_uri, "limit": 200}).get("requests") or []))
        step4 = False
        for i in range(20):
            time.sleep(1)
            r = mcp.call_tool("list_requests", {"vmUri": vm_uri, "limit": 200})
            reqs = r.get("requests") or []
            methods = {x.get("method") for x in reqs if isinstance(x, dict)}
            has_write = bool(methods & {"POST", "PUT", "PATCH", "DELETE"})
            print(
                f"STEP4_POLL{i} total={len(reqs)} was={before} writes={has_write}",
                flush=True,
            )
            if len(reqs) > before and has_write:
                step4 = True
                break
        results["STEP4"] = "PASS" if step4 else "FAIL"
        print(f"STEP4={results['STEP4']}", flush=True)

        # Step 5 hot reload
        print("ORCH|reload", flush=True)
        flutter.stdin.write("r\n")
        flutter.stdin.flush()
        before = len((mcp.call_tool("list_requests", {"vmUri": vm_uri, "limit": 200}).get("requests") or []))
        step5 = False
        for i in range(20):
            time.sleep(1)
            total = len(
                (mcp.call_tool("list_requests", {"vmUri": vm_uri, "limit": 200}).get("requests") or [])
            )
            print(f"STEP5_POLL{i} total={total} was={before}", flush=True)
            if total > before:
                step5 = True
                break
        sess = mcp.call_tool("get_session", {"vmUri": vm_uri})
        results["STEP5"] = "PASS" if step5 and sess.get("state") == "live" else "FAIL"
        print(f"STEP5={results['STEP5']}", flush=True)

        # Step 6 hot restart
        print("ORCH|restart", flush=True)
        flutter.stdin.write("R\n")
        flutter.stdin.flush()
        before_r = mcp.call_tool("list_requests", {"vmUri": vm_uri, "limit": 200})
        before_count = len(before_r.get("requests") or [])
        before_starts = {
            x.get("startTime")
            for x in (before_r.get("requests") or [])
            if isinstance(x, dict)
            and x.get("method") == "GET"
            and "/posts/1" in (x.get("uri") or "")
        }
        step6 = False
        for i in range(30):
            time.sleep(1)
            r = mcp.call_tool("list_requests", {"vmUri": vm_uri, "limit": 200})
            reqs = r.get("requests") or []
            starts = {
                x.get("startTime")
                for x in reqs
                if isinstance(x, dict)
                and x.get("method") == "GET"
                and "/posts/1" in (x.get("uri") or "")
            }
            new_starts = starts - before_starts
            print(
                f"STEP6_POLL{i} total={len(reqs)} was={before_count} new={len(new_starts)}",
                flush=True,
            )
            if len(reqs) >= before_count and new_starts:
                step6 = True
                break
        results["STEP6"] = "PASS" if step6 else "FAIL"
        print(f"STEP6={results['STEP6']}", flush=True)

        # Step 7 stop + history
        print("ORCH|stop", flush=True)
        flutter.stdin.write("q\n")
        flutter.stdin.flush()
        time.sleep(3)
        subprocess.run(
            [
                "xcrun",
                "simctl",
                "terminate",
                DEVICE,
                "com.example.dartVmMcpExample",
            ],
            check=False,
            capture_output=True,
        )
        step7_hist = False
        for i in range(60):
            time.sleep(1)
            s = mcp.call_tool("get_session", {"vmUri": vm_uri})
            print(
                f"STEP7_SESSION_POLL{i} state={s.get('state')} reason={s.get('disconnectReason')}",
                flush=True,
            )
            if s.get("state") == "history":
                step7_hist = True
                break
        no_hist = mcp.call_tool("list_requests", {"vmUri": vm_uri})
        with_hist = mcp.call_tool(
            "list_requests", {"vmUri": vm_uri, "includeHistory": True, "limit": 200}
        )
        err = no_hist.get("error") or {}
        flag_ok = err.get("code") == "history_requires_flag"
        rows_ok = bool(with_hist.get("requests"))
        results["STEP7"] = (
            "PASS" if step7_hist and flag_ok and rows_ok else "FAIL"
        )
        print(
            f"STEP7={results['STEP7']} history={step7_hist} flag={flag_ok} rows={rows_ok}",
            flush=True,
        )

        # Step 8 exports
        har = mcp.call_tool(
            "export_har", {"vmUri": vm_uri, "includeHistory": True}
        )
        dev = mcp.call_tool(
            "export_devtools_json", {"vmUri": vm_uri, "includeHistory": True}
        )
        print(f"HAR|{json.dumps(har)}", flush=True)
        print(f"DEV|{json.dumps(dev)}", flush=True)
        har_path = har.get("path") or ""
        # container path /data/exports/... maps to host DATA/exports/...
        host_har = har_path.replace("/data", DATA) if har_path.startswith("/data") else har_path
        host_dev = (dev.get("path") or "").replace("/data", DATA)
        har_ok = Path(host_har).exists() if host_har else False
        dev_ok = Path(host_dev).exists() if host_dev else False
        results["STEP8"] = "PASS" if har_ok and dev_ok else "FAIL"
        print(f"STEP8={results['STEP8']} har={har_ok} path={host_har} dev={dev_ok}", flush=True)
    finally:
        mcp.close()
        try:
            flutter.wait(timeout=20)
        except subprocess.TimeoutExpired:
            flutter.kill()

    print("RESULTS", json.dumps(results, indent=2), flush=True)
    needed = ["STEP3", "STEP4", "STEP5", "STEP6", "STEP7", "STEP8"]
    ok = all(results.get(k) == "PASS" for k in needed)
    print(f"ACCEPTANCE={'PASS' if ok else 'FAIL'} mode=docker-stdio", flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
