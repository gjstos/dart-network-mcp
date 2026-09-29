#!/usr/bin/env python3
"""Task 15 acceptance orchestrator: flutter run + native DartVmMcp driver."""
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "example"
DEVICE = "6524F3A2-8C20-47AB-9CA3-2C4C09145811"
VM_RE = re.compile(r"A Dart VM Service on .+ is available at: (http://\S+)")


def main() -> int:
    data_dir = Path(tempfile.mkdtemp(prefix="dart_vm_mcp_accept_"))
    log_path = data_dir / "flutter.log"
    print(f"DATA_DIR={data_dir}", flush=True)

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
    log_lines: list[str] = []

    def reader() -> None:
        nonlocal vm_uri
        assert flutter.stdout
        with log_path.open("w") as logf:
            for line in flutter.stdout:
                logf.write(line)
                logf.flush()
                log_lines.append(line.rstrip())
                print(f"FLUTTER|{line.rstrip()}", flush=True)
                m = VM_RE.search(line)
                if m and vm_uri is None:
                    vm_uri = m.group(1)

    t = threading.Thread(target=reader, daemon=True)
    t.start()

    deadline = time.time() + 240
    while vm_uri is None and time.time() < deadline:
        if flutter.poll() is not None:
            print("STEP2=FAIL flutter exited early", flush=True)
            return 1
        time.sleep(0.5)

    if vm_uri is None:
        print("STEP2=FAIL no vm uri", flush=True)
        flutter.kill()
        return 1
    print(f"STEP2=PASS vmUri={vm_uri}", flush=True)

    # Long-lived accept driver (communicates via stdin lines)
    driver = subprocess.Popen(
        ["dart", "run", "tool/accept_live.dart", vm_uri],
        cwd=str(ROOT),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert driver.stdin and driver.stdout

    results: dict[str, str] = {}

    def handle_driver() -> None:
        assert driver.stdout and driver.stdin and flutter.stdin
        for line in driver.stdout:
            print(f"DRIVER|{line.rstrip()}", flush=True)
            if line.startswith("STEP") and "=" in line:
                key, _, val = line.strip().partition("=")
                results[key] = val
            if "WAIT_RELOAD" in line:
                print("ORCH|sending hot reload (r)", flush=True)
                flutter.stdin.write("r\n")
                flutter.stdin.flush()
                time.sleep(2)
                driver.stdin.write("reload\n")
                driver.stdin.flush()
            elif "WAIT_RESTART" in line:
                print("ORCH|sending hot restart (R)", flush=True)
                flutter.stdin.write("R\n")
                flutter.stdin.flush()
                time.sleep(3)
                driver.stdin.write("restart\n")
                driver.stdin.flush()
            elif "WAIT_STOP" in line:
                print("ORCH|sending quit (q) + terminate Runner", flush=True)
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
                driver.stdin.write("stop\n")
                driver.stdin.flush()
            elif line.strip() == "DONE":
                break

    handle_driver()
    driver.wait(timeout=300)
    try:
        flutter.wait(timeout=30)
    except subprocess.TimeoutExpired:
        flutter.kill()

    print("RESULTS", json.dumps(results, indent=2), flush=True)
    needed = ["STEP3", "STEP4", "STEP5", "STEP6", "STEP7", "STEP8"]
    ok = all(results.get(k, "").startswith("PASS") for k in needed)
    print(f"ACCEPTANCE={'PASS' if ok else 'FAIL'}", flush=True)
    print(f"NOTE=native long-lived DartVmMcp (Docker daemon unavailable)", flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
