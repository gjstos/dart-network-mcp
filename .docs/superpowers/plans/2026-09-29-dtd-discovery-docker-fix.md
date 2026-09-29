# DTD Discovery Docker Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-attach no Docker sem `DTD_URI`/`attach_vm`, lendo `…/Dart/dtd/<pid>` (`wsUri`) e reescrevendo loopback do DTD.

**Architecture:** Estender `discoverDtdUris` com dir moderno + `wsUri`; install monta esse dir em `/home/mcp/Dart/dtd`; `_tryConnect` usa `socketUriFor` sob `inDocker`.

**Tech Stack:** Dart, Docker, bash install/`run_mcp_container.sh`, `package:test`.

**Spec:** `.docs/superpowers/specs/2026-09-29-dtd-discovery-docker-fix-design.md`

## Global Constraints

- Sem `git add` / `git commit` (regra do usuário).
- Sem sidecar; sem mudança de contrato das tools MCP.
- Manter `DTD_URI` e `~/.dart-tool` como fontes.

## File map

| File | Role |
|------|------|
| `lib/src/discovery.dart` | Paths OS + `wsUri` + dir moderno |
| `test/discovery_test.dart` | Unit tests discovery |
| `bin/dart_network_mcp.dart` | Passar dir; `socketUriFor` no DTD |
| `tool/run_mcp_container.sh` | Volume + env |
| `install.sh` | Catalog volume + env + mkdir |
| `test/run_mcp_container_test.dart` | Assert volume/env |
| `docs/mcp.md` | Discovery docs |

---

### Task 1: Discovery API + unit tests

**Files:**
- Modify: `lib/src/discovery.dart`
- Modify: `test/discovery_test.dart`

- [ ] **Step 1: Expand failing tests**

Add cases:

1. `wsUri` in modern dir (filename is numeric PID, no `dtd` in name) is discovered.
2. Order: env → modern dir → dart-tool (legacy name filter still skips `notes.json`).
3. `defaultDartDtdDirectory` / override: when `DART_NETWORK_MCP_DTD_DIR` set in env map, helper returns that path.
4. Existing tests still pass; also accept `wsUri` in legacy `dtd.json`.

- [ ] **Step 2: Run tests — expect fail**

```bash
dart test test/discovery_test.dart
```

- [ ] **Step 3: Implement**

```dart
Directory? defaultDartDtdDirectory({
  Map<String, String>? environment,
  String? home,
}) { ... }

List<String> discoverDtdUris({
  String? dtdUriEnv,
  Directory? dartDtdDir,
  required Directory dartToolDir,
}) { ... }
```

- Scan `dartDtdDir` all JSON files; keys `wsUri`, `uri`, `dtdUri`.
- Scan `dartToolDir` with name filter; same keys.
- Order: env, modern, legacy.

- [x] **Step 4: Run tests — expect pass**

```bash
dart test test/discovery_test.dart
```

---

### Task 2: Wire bin + Docker DTD socket rewrite

**Files:**
- Modify: `bin/dart_network_mcp.dart`

- [ ] **Step 1: Resolve modern dir in discovery tick**

Use `Platform.environment['DART_NETWORK_MCP_DTD_DIR']` → `Directory` if non-empty and exists; else `defaultDartDtdDirectory()`. Pass as `dartDtdDir` to `discoverDtdUris`.

- [ ] **Step 2: Rewrite DTD connect URI in Docker**

In `_tryConnect`:

```dart
final canonical = Uri.parse(wsUri);
final socket = socketUriFor(canonical, inDocker: inDocker);
final client = await DartToolingDaemon.connect(socket);
_connectedUri = wsUri; // keep discovered string
```

- [ ] **Step 3: Analyze**

```bash
dart analyze bin/dart_network_mcp.dart lib/src/discovery.dart
```

---

### Task 3: Install / run container + script test

**Files:**
- Modify: `tool/run_mcp_container.sh`
- Modify: `install.sh`
- Modify: `test/run_mcp_container_test.dart`

- [ ] **Step 1: Fail script test expectations**

Expect run line contains:

- host Dart/dtd mount → `/home/mcp/Dart/dtd:ro`
- `-e DART_NETWORK_MCP_DTD_DIR=/home/mcp/Dart/dtd`

On macOS fake HOME: `$HOME/Library/Application Support/Dart/dtd`.

- [ ] **Step 2: Run test — expect fail**

```bash
dart test test/run_mcp_container_test.dart
```

- [ ] **Step 3: Update bash**

Shared path resolution:

- Darwin: `$home/Library/Application Support/Dart/dtd`
- Linux / default: `${XDG_DATA_HOME:-$home/.local/share}/Dart/dtd`
- Windows msys: `${LOCALAPPDATA}/Dart/dtd`

`mkdir -p` host dir. Mount + env as above. Catalog in `install.sh` same volume/env.

- [ ] **Step 4: Run test — expect pass**

```bash
dart test test/run_mcp_container_test.dart
```

---

### Task 4: Docs

**Files:**
- Modify: `docs/mcp.md`

- [ ] Update discovery bullet: modern `Dart/dtd` + `wsUri`; env override; Docker mount; `attach_vm` fallback.

---

### Task 5: Docker acceptance (no DTD_URI / no attach_vm)

- [x] Rebuild: `docker build -t dart-network-mcp:local .`
- [x] Ensure a Flutter debug session exists on host (DTD file under Application Support).
- [x] Run container via same mounts as `run_mcp_container.sh` **without** `DTD_URI`.
- [x] Poll `list_sessions` until live session; `list_requests` returns ≥1 call.
- [x] Report PASS/FAIL.

**Result (2026-09-29):** `DOCKER_DTD_FIX=PASS` — poll1 live `dart_network_mcp_example`, `list_requests` count=3. Extra fixes during acceptance: multi-DTD connection pool; Dockerfile `chmod 755 /home/mcp` so host `-u` can traverse mounts under home.


---

### Done when

- Unit + script tests green.
- Docs updated.
- Live Docker acceptance PASS without `DTD_URI`/`attach_vm`.
