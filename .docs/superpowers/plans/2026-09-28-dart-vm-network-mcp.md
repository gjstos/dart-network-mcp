# Dart VM Network MCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Entregar um servidor MCP em Dart que anexa em N VMs Dart, grava o HTTP profile de cada uma num SQLite separado pela URI da VM, e exporta HAR 1.2 e o JSON offline do DevTools, inclusive depois do crash.

**Architecture:** Um processo long-lived usa `package:vm_service` e `package:dtd`. A chave da sessão é a URI WebSocket canônica. `SessionStore` é o único escritor do SQLite. As tools do `package:mcp_dart` chamam `DartNetworkMcp`, que não mistura chaves. O container só reescreve host loopback para `host.docker.internal`.

**Tech Stack:** Dart 3.6, `mcp_dart`, `vm_service`, `sqlite3`, `dtd`, `path`, `test`. Imagem `dart:stable`. App exemplo Flutter com `package:http`.

## Global Constraints

- Não fazer `git add` nem `git commit`. Deixar cada tarefa na working tree.
- Diretório de dados: `$DART_NETWORK_MCP_DATA` se existir; senão `%LOCALAPPDATA%\dart-network-mcp` se `LOCALAPPDATA` existir; senão `~/.local/share/dart-network-mcp`. No container, `DART_NETWORK_MCP_DATA=/data`.
- Chave `vm_uri`: `http`→`ws`, `https`→`wss`, path termina em `/ws` sem barra final. Host da chave não muda.
- PK de request: `(vm_uri, request_id, start_time)`.
- SQLite WAL, `busy_timeout` 5000 ms. Unix: diretório `0700`, arquivo `0600`.
- Poll de `getHttpProfile` a cada 1 segundo. Descoberta a cada 2 segundos.
- Body acima de 1000000 bytes é truncado, com tamanho original e `*_truncated=1`.
- Sem `clearHttpProfile`.
- `list_sessions` default `live`. `historyHint.vmUris` tem no máximo 5 URIs, ordenadas por `disconnectedAt` decrescente, só quando o default volta vazio e existe history.
- Sessão `history` sem `includeHistory=true` responde `history_requires_flag` sem chave `requests`.
- `includeHistory=true` em sessão `live` é ignorado.
- Erros JSON: `vm_not_found`, `request_not_found`, `ambiguous_request`, `attach_failed`, `history_requires_flag`, `http_profile_unavailable`, `sqlite_busy`, `invalid_params`.
- HAR 1.2 com `creator.name=dart-network-mcp`. Snapshot DevTools com `devToolsSnapshot=true` e `activeScreenId=network`. Export: 8 hex = SHA-1 de `vmUri`; em history `isFlutterApp=false`.
- iOS, Android, desktop e qualquer outra URI de VM seguem o mesmo attach. Loopback no container vira `host.docker.internal` só no socket.
- Install exige `--claude`, `--cursor` ou os dois. Entrada do cliente se chama `dart-network-mcp` e não altera `MCP_DOCKER`. Profile `dart-network-mcp`.
- Body das tools: JSON válido sai como valor com `requestBodyEncoding` / `responseBodyEncoding` = `json`. UTF-8 que não é JSON, inclusive body truncado, sai string com `utf8`. O resto é base64. HAR e DevTools não fazem esse decode. O `dart:io` já descomprime gzip.
- `appName` vem de `package:<nome>/...` no `rootLib`. Sem isso, fica o `name` do isolate.
- `list_requests` traz método, URI, status, `durationMs` e bodies. `*BodySize` na listagem só se truncado. Headers, isolate, `reasonPhrase` e tamanhos sempre presentes ficam em `get_request`.
- Exemplo: `HttpClient.enableTimelineLogging` em `main`, antes do `runApp`. Abertura: três GETs paralelos em `https://jsonplaceholder.typicode.com` (`/posts/1`, `/users/1`, `/albums/1`). A cada 5 segundos, um lote de três calls, alternando POST/PUT/PATCH e DELETE mais dois GETs. Pausar segura o lote seguinte.
- Não usar `pause_isolates_on_start`.
- Guia de uso público: `docs/mcp.md`.

---

## File structure

- `pubspec.yaml` — pacote do servidor.
- `lib/src/vm_uri.dart` — `canonicalizeVmUri`, `socketUriFor`.
- `lib/src/data_dir.dart` — `resolveDataDirectory`.
- `lib/src/session_store.dart` — SQLite.
- `lib/src/tool_json.dart` — encode de sucesso e erro.
- `lib/src/har_export.dart` — HAR 1.2.
- `lib/src/devtools_export.dart` — snapshot offline.
- `lib/src/vm_session.dart` — attach, poll, history.
- `lib/src/discovery.dart` — URIs de DTD no disco.
- `lib/src/dart_network_mcp.dart` — métodos das tools.
- `lib/src/mcp_config_merge.dart` — merge do JSON do cliente.
- `bin/dart_network_mcp.dart` — stdio MCP.
- `test/support/fake_vm_service.dart` — VM Service WebSocket.
- `Dockerfile` — imagem Linux com `libsqlite3`.
- `install.sh` — catálogo, profile, Claude e Cursor.
- `tool/merge_mcp_config.dart` — chamado pelo install.
- `example/` — app Flutter.
- `README.md`.

### Task 1: Canonicalização da URI

**Files:**
- Create: `pubspec.yaml`
- Create: `analysis_options.yaml`
- Create: `lib/src/vm_uri.dart`
- Test: `test/vm_uri_test.dart`

**Interfaces:**
- Consumes: nada.
- Produces: `String canonicalizeVmUri(String raw)` e `Uri socketUriFor(Uri canonical, {required bool inDocker})`.

- [x] **Step 1: Criar o pacote**

`pubspec.yaml`

```yaml
name: dart_network_mcp
description: MCP server for Dart VM HTTP profiles.
version: 0.1.0
publish_to: none
environment:
  sdk: ^3.6.0
dependencies:
  crypto: ^3.0.7
  mcp_dart: ^0.6.0
  vm_service: ^15.0.0
  sqlite3: ^2.7.0
  dtd: ^4.0.0
  path: ^1.9.0
dev_dependencies:
  test: ^1.25.0
  lints: ^5.0.0
```

`analysis_options.yaml`

```yaml
include: package:lints/recommended.yaml
```

Run: `dart pub get`
Expected: resolve sem erro. Se `mcp_dart` ou `dtd` não existirem nessas versões, use a última estável que o `dart pub get` imprimir e grave essa versão no `pubspec.yaml`.

- [x] **Step 2: Escrever o teste que falha**

`test/vm_uri_test.dart`

```dart
import 'package:dart_network_mcp/src/vm_uri.dart';
import 'package:test/test.dart';

void main() {
  test('http console uri and ws uri are the same key', () {
    const httpUri = 'http://127.0.0.1:62080/06-FZCo24xM=/';
    const wsUri = 'ws://127.0.0.1:62080/06-FZCo24xM=/ws';
    expect(canonicalizeVmUri(httpUri), wsUri);
    expect(canonicalizeVmUri(wsUri), wsUri);
    expect(canonicalizeVmUri('$wsUri/'), wsUri);
  });

  test('https becomes wss', () {
    expect(
      canonicalizeVmUri('https://10.0.0.8:8181/tok/'),
      'wss://10.0.0.8:8181/tok/ws',
    );
  });

  test('docker rewrites only loopback on the socket', () {
    final canonical = Uri.parse(canonicalizeVmUri('http://127.0.0.1:1/abc/'));
    final socket = socketUriFor(canonical, inDocker: true);
    expect(socket.host, 'host.docker.internal');
    expect(socket.port, 1);
    expect(canonical.host, '127.0.0.1');

    final lan = Uri.parse(canonicalizeVmUri('http://192.168.1.20:9/abc/'));
    expect(socketUriFor(lan, inDocker: true).host, '192.168.1.20');
    expect(socketUriFor(canonical, inDocker: false).host, '127.0.0.1');
  });

  test('localhost and ipv6 loopback rewrite in docker', () {
    final local = Uri.parse(canonicalizeVmUri('http://localhost:2/abc/'));
    expect(socketUriFor(local, inDocker: true).host, 'host.docker.internal');
    final v6 = Uri.parse('ws://[::1]:3/abc/ws');
    expect(socketUriFor(v6, inDocker: true).host, 'host.docker.internal');
  });
}
```

- [x] **Step 3: Rodar e ver falhar**

Run: `dart test test/vm_uri_test.dart`
Expected: FAIL, `vm_uri.dart` não existe.

- [x] **Step 4: Implementar**

`lib/src/vm_uri.dart`

```dart
String canonicalizeVmUri(String raw) {
  final uri = Uri.parse(raw.trim());
  final scheme = switch (uri.scheme) {
    'http' => 'ws',
    'https' => 'wss',
    'ws' => 'ws',
    'wss' => 'wss',
    _ => throw FormatException('unsupported vm uri scheme: ${uri.scheme}'),
  };
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty || segments.last != 'ws') {
    segments.add('ws');
  }
  return uri.replace(scheme: scheme, pathSegments: segments).removeFragment().toString();
}

Uri socketUriFor(Uri canonical, {required bool inDocker}) {
  if (!inDocker) {
    return canonical;
  }
  final host = canonical.host;
  final loopback = host == '127.0.0.1' || host == 'localhost' || host == '::1';
  if (!loopback) {
    return canonical;
  }
  return canonical.replace(host: 'host.docker.internal');
}
```

- [x] **Step 5: Rodar e ver passar**

Run: `dart test test/vm_uri_test.dart`
Expected: PASS

### Task 2: Diretório de dados

**Files:**
- Create: `lib/src/data_dir.dart`
- Test: `test/data_dir_test.dart`

**Interfaces:**
- Consumes: nada.
- Produces: `String resolveDataDirectory(Map<String, String> env)`.

- [x] **Step 1: Teste que falha**

`test/data_dir_test.dart`

```dart
import 'package:dart_network_mcp/src/data_dir.dart';
import 'package:test/test.dart';

void main() {
  test('DART_NETWORK_MCP_DATA wins', () {
    expect(
      resolveDataDirectory({'DART_NETWORK_MCP_DATA': '/data', 'HOME': '/home/a'}),
      '/data',
    );
  });

  test('LOCALAPPDATA is the windows default', () {
    expect(
      resolveDataDirectory({'LOCALAPPDATA': r'C:\Users\a\AppData\Local'}),
      r'C:\Users\a\AppData\Local\dart-network-mcp',
    );
  });

  test('home fallback is .local/share', () {
    expect(
      resolveDataDirectory({'HOME': '/Users/a'}),
      '/Users/a/.local/share/dart-network-mcp',
    );
  });
}
```

- [x] **Step 2: Rodar e ver falhar**

Run: `dart test test/data_dir_test.dart`
Expected: FAIL, biblioteca ausente.

- [x] **Step 3: Implementar**

`lib/src/data_dir.dart`

```dart
import 'package:path/path.dart' as p;

String resolveDataDirectory(Map<String, String> env) {
  final override = env['DART_NETWORK_MCP_DATA'];
  if (override != null && override.isNotEmpty) {
    return override;
  }
  final localAppData = env['LOCALAPPDATA'];
  if (localAppData != null && localAppData.isNotEmpty) {
    return p.join(localAppData, 'dart-network-mcp');
  }
  final home = env['HOME'] ?? env['USERPROFILE'];
  if (home == null || home.isEmpty) {
    throw StateError('HOME or USERPROFILE is required');
  }
  return p.join(home, '.local', 'share', 'dart-network-mcp');
}
```

- [x] **Step 4: Rodar e ver passar**

Run: `dart test test/data_dir_test.dart`
Expected: PASS

### Task 3: SessionStore

**Files:**
- Create: `lib/src/session_store.dart`
- Test: `test/session_store_test.dart`

**Interfaces:**
- Consumes: nada do runtime da VM.
- Produces: `SessionRecord`, `RequestRecord`, `SessionStore`.

`SessionRecord` campos: `vmUri`, `state` (`live`|`history`), `appName`, `isolateIds`, `startedAt`, `disconnectedAt`, `disconnectReason`, `httpProfileAvailable`.

`RequestRecord` campos: `vmUri`, `requestId`, `isolateId`, `method`, `uri`, `startTime`, `endTime`, `statusCode`, `reasonPhrase`, `requestHeaders`, `responseHeaders`, `requestBody`, `responseBody`, `requestBodySize`, `responseBodySize`, `requestBodyTruncated`, `responseBodyTruncated`, `bodyUnavailable`, `error`, `rawJson`.

`SessionStore.open(String databasePath)` cria o arquivo, `PRAGMA journal_mode=WAL` e `PRAGMA busy_timeout=5000`. Métodos: `close`, `upsertSession`, `getSession`, `listSessions(String state)` com `state` `live`, `history` ou `all`, `markHistory(String vmUri, String reason, int disconnectedAt)`, `deleteSession`, `upsertRequest`, `listRequests`, `findByRequestId`.

`listRequests` argumentos nomeados: `vmUri`, `limit` default 50, `offset` default 0, `method`, `status`, `urlContains`. Ordena por `start_time` crescente. Limite máximo aplicado pelo caller. `urlContains` é `LIKE` com `%` escapado.

`upsertRequest` faz `INSERT ... ON CONFLICT(vm_uri, request_id, start_time) DO UPDATE`.

- [x] **Step 1: Teste que falha**

`test/session_store_test.dart` usa `Directory.systemTemp.createTempSync('dart-network-mcp')`. Cobre:

- duas `vmUri` não devolvem a request uma da outra em `listRequests`
- `upsertRequest` duas vezes com o mesmo `startTime` mantém uma linha e atualiza `statusCode`
- outro `startTime` no mesmo `requestId` insere a segunda linha e `findByRequestId` devolve as duas
- `markHistory` muda `state` e preenche `disconnectReason` sem apagar requests
- `deleteSession('ws://a')` remove só essa chave
- `listSessions('live')` omite history

Cada expect usa os valores literais acima. Abra o store, grave, feche, reabra o mesmo path e releia, para provar que o WAL persistiu.

- [x] **Step 2: Rodar e ver falhar**

Run: `dart test test/session_store_test.dart`
Expected: FAIL, `session_store.dart` ausente.

- [x] **Step 3: Implementar o schema**

Tabelas exatamente com as colunas da spec `sessions` e `requests`. FK `requests.vm_uri` `ON DELETE CASCADE`. `PRAGMA foreign_keys=ON` antes de criar as tabelas.

Bodies são `BLOB`. Headers e `raw_json` e `isolate_ids` são `TEXT`. Bool vira `INTEGER` 0 ou 1.

- [x] **Step 4: Rodar e ver passar**

Run: `dart test test/session_store_test.dart`
Expected: PASS

### Task 4: JSON das tools

**Files:**
- Create: `lib/src/tool_json.dart`
- Test: `test/tool_json_test.dart`

**Interfaces:**
- Consumes: nada.
- Produces: `String encodeJson(Map<String, Object?> value)` e `Map<String, Object?> toolError(String code, String message, {String? vmUri})`.

`toolError` devolve `{'error': {'code': code, 'message': message, if (vmUri != null) 'vmUri': vmUri}}`.

- [x] **Step 1: Teste**

`test/tool_json_test.dart`

```dart
import 'package:dart_network_mcp/src/tool_json.dart';
import 'package:test/test.dart';

void main() {
  test('error json includes code and vmUri', () {
    final encoded = encodeJson(
      toolError('vm_not_found', 'missing', vmUri: 'ws://x'),
    );
    expect(encoded, contains('"code":"vm_not_found"'));
    expect(encoded, contains('"vmUri":"ws://x"'));
  });
}
```

- [x] **Step 2: Rodar e ver falhar**

Run: `dart test test/tool_json_test.dart`
Expected: FAIL

- [x] **Step 3: Implementar com `dart:convert` `jsonEncode`.**

- [x] **Step 4: Rodar e ver passar**

Run: `dart test test/tool_json_test.dart`
Expected: PASS

### Task 5: HAR

**Files:**
- Create: `lib/src/har_export.dart`
- Test: `test/har_export_test.dart`

**Interfaces:**
- Consumes: `RequestRecord`.
- Produces: `Map<String, Object?> buildHar(List<RequestRecord> requests, {required String version})`.

- [x] **Step 1: Teste que falha**

Construa um `RequestRecord` `GET` `https://example.com/a?q=1`, `startTime` `1710000000000000`, `endTime` `1710000000500000` (500 ms), status 200, header de request `accept=application/json`, body de response UTF-8 `{"ok":true}`, `responseBodySize` igual ao tamanho, `responseBodyTruncated` false.

Expect:

- `log.version` == `1.2`
- `log.creator.name` == `dart-network-mcp`
- `log.creator.version` == a versão passada
- entry `time` == `500`
- `request.httpVersion` == `HTTP/1.1`
- `request.queryString` == `[{name: q, value: 1}]`
- `response.content.text` == `{"ok":true}` sem chave `encoding`
- timings `send` 0, `wait` 500, `receive` 0, `blocked` `-1`, `dns` `-1`, `connect` `-1`, `ssl` `-1`
- lista vazia produz `entries` vazio
- body com byte `0x00` sai em `content.text` base64 e `content.encoding` == `base64`
- `endTime` nulo produz `time` 0

- [x] **Step 2: Rodar e ver falhar**

Run: `dart test test/har_export_test.dart`
Expected: FAIL

- [x] **Step 3: Implementar**

`startedDateTime` é `DateTime.fromMicrosecondsSinceEpoch(startTime, isUtc: true).toIso8601String()`. Header HAR é `{name, value}`. `postData` só quando `requestBody` não é nulo, com a mesma regra texto ou base64. `cache` é `{}`.

- [x] **Step 4: Rodar e ver passar**

Run: `dart test test/har_export_test.dart`
Expected: PASS

### Task 6: JSON do DevTools

**Files:**
- Create: `lib/src/devtools_export.dart`
- Test: `test/devtools_export_test.dart`

**Interfaces:**
- Consumes: `RequestRecord`.
- Produces: `Map<String, Object?> buildDevToolsSnapshot(List<RequestRecord> requests, {required String version, required bool isFlutterApp})`.

- [x] **Step 1: Teste que falha**

Expect `devToolsSnapshot` true, `devToolsVersion` `dart-network-mcp/0.1.0` quando version é `0.1.0`, `activeScreenId` `network`, `connectedApp.isRunningOnDartVM` true, `connectedApp.isFlutterApp` igual ao argumento, `connectedApp.isProfileBuild` false, `connectedApp.isDartWebApp` false.

`network.socketData` e `network.webSocketData` são listas vazias. `network.selectedRequestId` é null. `network.timelineMicrosOffset` é 0.

`network.httpRequestData[0].request` é o `jsonDecode` de `rawJson`.

- [x] **Step 2: Rodar e ver falhar**

Run: `dart test test/devtools_export_test.dart`
Expected: FAIL

- [x] **Step 3: Implementar o mapa da spec, sem chaves extras no topo além de `devToolsSnapshot`, `devToolsVersion`, `activeScreenId`, `connectedApp` e `network`.**

```dart
import 'dart:convert';

import 'session_store.dart';

Map<String, Object?> buildDevToolsSnapshot(
  List<RequestRecord> requests, {
  required String version,
  required bool isFlutterApp,
}) {
  return {
    'devToolsSnapshot': true,
    'devToolsVersion': 'dart-network-mcp/$version',
    'activeScreenId': 'network',
    'connectedApp': {
      'isFlutterApp': isFlutterApp,
      'isProfileBuild': false,
      'isDartWebApp': false,
      'isRunningOnDartVM': true,
    },
    'network': {
      'httpRequestData': [
        for (final request in requests)
          {'request': jsonDecode(request.rawJson)},
      ],
      'selectedRequestId': null,
      'socketData': <Object?>[],
      'webSocketData': <Object?>[],
      'timelineMicrosOffset': 0,
    },
  };
}
```

- [x] **Step 4: Rodar e ver passar**

Run: `dart test test/devtools_export_test.dart`
Expected: PASS

### Task 7: VM falsa e sessão

**Files:**
- Create: `test/support/fake_vm_service.dart`
- Create: `lib/src/vm_session.dart`
- Test: `test/vm_session_test.dart`

**Interfaces:**
- Consumes: `canonicalizeVmUri`, `SessionStore`.
- Produces: `VmSession.attach({required SessionStore store, required String rawUri, required Uri socketUri, required bool enableTimer})`, `Future<void> pollOnce()`, `Future<void> dispose()`, `bool get isFlutterApp`.

Com `enableTimer` false os testes chamam `pollOnce`. Com true, um `Timer.periodic` de 1 segundo chama `pollOnce`.

- [x] **Step 1: Escrever a fake e o teste que falha**

A fake escuta em `127.0.0.1:0`, faz upgrade WebSocket e responde os métodos `getVM`, `getIsolate`, `ext.dart.io.isHttpProfilingAvailable`, `ext.dart.io.httpEnableTimelineLogging`, `ext.dart.io.getHttpProfile`, `ext.dart.io.getHttpProfileRequest` e `streamListen`. `consoleHttpUri` é `http://127.0.0.1:<port>/<token>/`. Requests adicionadas com `addRequest` saem no profile. `requestBody` e `responseBody` são `List<int>`. `closeClients()` fecha os sockets. `httpAvailable` default true. `extensionRpcs` default contém `ext.flutter.version`.

`test/vm_session_test.dart` abre duas fakes no mesmo `SessionStore` e afirma:

- a request da fake A não aparece na `vmUri` da fake B
- `canonicalizeVmUri(fake.consoleHttpUri)` é a chave gravada
- depois de `closeClients`, `state` é `history`, `disconnectReason` é `socket closed`, e a request continua
- o mesmo `requestId` e `startTime` atualiza `statusCode`. Outro `startTime` cria a segunda linha
- fechar só a fake A deixa B `live`
- body de 1000001 bytes grava 1000000, `responseBodyTruncated==true`, `responseBodySize==1000001`
- `httpAvailable=false` deixa `httpProfileAvailable==false` e `loggingEnabled==false`
- erro em `getHttpProfileRequest` grava `bodyUnavailable==true` e a request seguinte entra
- `isFlutterApp` é true com `ext.flutter.version` e false quando `extensionRpcs` está vazio

`getVM` devolve este `result`:

```json
{
  "type": "VM",
  "name": "vm",
  "architectureBits": 64,
  "hostCPU": "test",
  "operatingSystem": "linux",
  "targetCPU": "x64",
  "version": "3.6.0",
  "pid": 1,
  "startTime": 0,
  "isolates": [
    {
      "type": "@Isolate",
      "id": "isolates/main",
      "number": "1",
      "name": "main",
      "isSystemIsolate": false
    }
  ],
  "isolateGroups": [],
  "systemIsolates": [],
  "systemIsolateGroups": []
}
```

`getIsolate` devolve `type=Isolate`, o mesmo `id` e `name`, e `extensionRPCs` igual a `extensionRpcs`.

- [x] **Step 2: Rodar e ver falhar**

Run: `dart test test/vm_session_test.dart`
Expected: FAIL

- [x] **Step 3: Implementar `VmSession`**

`attach` abre o WebSocket em `socketUri`, chama `getVM`, grava sessão `live` com `appName` igual ao `name` do isolate raiz. Para cada isolate, lê o profiler. Se algum isolate tiver profiler, liga `httpEnableTimelineLogging` com `enabled: true` e `httpProfileAvailable=true`. `pollOnce` chama `getHttpProfile` e, para cada id, `getHttpProfileRequest`. O primeiro poll não envia `updatedSince`. Os seguintes enviam o `timestamp` anterior do profile. Body maior que 1000000 bytes usa `sublist(0, 1000000)`. Queda do socket chama `markHistory(vmUri, 'socket closed', now)`. `dispose()` fecha o socket sem marcar history. Não chame `clearHttpProfile`.

- [x] **Step 4: Rodar e ver passar**

Run: `dart test test/vm_session_test.dart`
Expected: PASS

### Task 8: Descoberta de DTD

**Files:**
- Create: `lib/src/discovery.dart`
- Test: `test/discovery_test.dart`

**Interfaces:**
- Consumes: nada.
- Produces: `List<String> discoverDtdUris({String? dtdUriEnv, required Directory dartToolDir})`.

- [x] **Step 1: Teste que falha**

```dart
import 'dart:io';

import 'package:dart_network_mcp/src/discovery.dart';
import 'package:test/test.dart';

void main() {
  test('env, dtd files, and no recursion', () {
    final dir = Directory.systemTemp.createTempSync('dtd');
    File('${dir.path}/dart-tooling-daemon.json')
        .writeAsStringSync('{"uri":"ws://127.0.0.1:2/y"}');
    File('${dir.path}/dtd.json').writeAsStringSync('{"dtdUri":"ws://127.0.0.1:3/z"}');
    File('${dir.path}/notes.json').writeAsStringSync('{"uri":"ws://127.0.0.1:4/no"}');
    Directory('${dir.path}/nested').createSync();
    File('${dir.path}/nested/dtd.json').writeAsStringSync('{"uri":"ws://127.0.0.1:5/no"}');

    expect(
      discoverDtdUris(dtdUriEnv: 'ws://127.0.0.1:1/x', dartToolDir: dir),
      [
        'ws://127.0.0.1:1/x',
        'ws://127.0.0.1:2/y',
        'ws://127.0.0.1:3/z',
      ],
    );
  });
}
```

- [x] **Step 2: Rodar e ver falhar**

Run: `dart test test/discovery_test.dart`
Expected: FAIL

- [x] **Step 3: Implementar**

Só arquivos do diretório, sem recursão. O nome contém `dtd` ou `tooling-daemon`. JSON objeto. Chaves `uri` e `dtdUri`. Só `ws` e `wss`. `dtdUriEnv` entra primeiro. Duplicata é ignorada.

- [x] **Step 4: Rodar e ver passar**

Run: `dart test test/discovery_test.dart`
Expected: PASS

### Task 9: DartNetworkMcp

**Files:**
- Create: `lib/src/dart_network_mcp.dart`
- Test: `test/dart_network_mcp_test.dart`

**Interfaces:**
- Consumes: `SessionStore`, `VmSession`, `buildHar`, `buildDevToolsSnapshot`, `canonicalizeVmUri`, `socketUriFor`, `toolError`.
- Produces: `DartNetworkMcp` com `listSessions`, `getSession`, `attachVm`, `listRequests`, `getRequest`, `exportHar`, `exportDevToolsJson`, `deleteSession`. Cada método devolve `Map<String, Object?>`.

`attachVm(String uri, {required bool inDocker})` grava a chave canônica e conecta em `socketUriFor`. Sessão `live` já existente devolve a sessão sem segundo socket. Sessão `history` cujo socket volta conecta e passa a `live` sem apagar linhas. Falha de conexão devolve `attach_failed` e não cria linha.

`limit` acima de 200 vira 200. Abaixo de 1 vira 1. Default 50. `offset` default 0.

Export grava `<dataDir>/exports/dart_network_mcp_<yyyyMMddTHHmmss>_<8 hex sha1 da vmUri>.har` ou `.json`. Resposta: `path`, `requestCount`, `bytes`, `vmUri`, `state`. Zero requests ainda grava o arquivo válido.

`getRequest` sem `startTime` e com mais de uma linha devolve `ambiguous_request` com `error.startTimes` e sem bodies.

`listSessions` default, sem live e com history, inclui `historyHint.vmUris` com no máximo 5, ordenadas por `disconnectedAt` decrescente.

`deleteSession` devolve `{ vmUri, state, deleted: true }`.

- [x] **Step 1: Teste que falha**

Use a fake da Task 7 e um store temporário. Afirme `history_requires_flag` sem chave `requests` no JSON, `historyHint` com a URI do crash, `vm_not_found` cuja string não contém a outra URI que existe no store, `request_not_found`, `ambiguous_request` com `error.startTimes`, `http_profile_unavailable`, `includeHistory: true` numa sessão live com `state` ainda `live`, `deleteSession` sem apagar um `.har` já escrito, e requests da VM A ausentes na listagem da VM B.

- [x] **Step 2: Rodar e ver falhar**

Run: `dart test test/dart_network_mcp_test.dart`
Expected: FAIL

- [x] **Step 3: Implementar**

JSON válido vira valor com `requestBodyEncoding` / `responseBodyEncoding` = `json`. UTF-8 que não é JSON vira string com `utf8`. Senão base64. HAR continua texto ou base64. `SqliteException` com `database is locked` vira `sqlite_busy`.

- [x] **Step 4: Rodar e ver passar**

Run: `dart test test/dart_network_mcp_test.dart`
Expected: PASS

### Task 10: Entrypoint stdio

**Files:**
- Create: `bin/dart_network_mcp.dart`

**Interfaces:**
- Consumes: `DartNetworkMcp`, `discoverDtdUris`, `resolveDataDirectory`, `McpServer` e `StdioServerTransport` de `package:mcp_dart`.
- Produces: as oito tools `list_sessions`, `get_session`, `attach_vm`, `list_requests`, `get_request`, `export_har`, `export_devtools_json`, `delete_session`.

- [x] **Step 1: Registrar as tools**

Stdout fica só com o protocolo. Diagnóstico vai para `stderr`. Cada callback faz `jsonEncode` do mapa. Mapa com chave `error` usa `CallToolResult.isError: true`.

`inDocker` é `Platform.environment['DART_NETWORK_MCP_IN_DOCKER'] == '1'`. Crie o diretório de dados. No Unix, modo `0700` no diretório e `0600` no sqlite.

Na subida, toda sessão `live` cujo socket falha recebe `markHistory(vmUri, 'process_restart', now)`.

A cada 2 segundos, leia as URIs de DTD e conecte com `package:dtd`. Chame `ConnectedApp.getVmServiceUris`. Se lançar, chame `Editor.getDebugSessions` e use o primeiro campo entre `vmServiceUri`, `vmServiceWsUri` e `uri` que parseie como HTTP ou WS. URI nova chama `attachVm`. Em `VmServiceUnregistered`, se o socket da sessão não estiver aberto, marque `history` com `socket closed`. Falha de DTD não mata o processo.

Schemas: `vmUri` e `uri` e `requestId` são string obrigatória onde a spec exige. `state` é enum `live`, `history`, `all`. `includeHistory` é bool. `limit`, `offset` e `status` e `startTime` são int. `method` e `urlContains` são string.

- [x] **Step 2: Analisar e testar**

Run: `dart analyze bin lib test && dart test`
Expected: analyze sem erro e todos os testes PASS.

### Task 11: Dockerfile

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`

- [x] **Step 1: Escrever**

`.dockerignore` contém `.dart_tool`, `build`, `example`, `.docs`.

```dockerfile
FROM dart:stable
RUN apt-get update \
  && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates \
  && ln -sf "$(find /usr/lib -name 'libsqlite3.so.0' | head -1)" /usr/lib/libsqlite3.so \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --create-home --home-dir /home/mcp mcp \
  && mkdir -p /data /home/mcp/.dart-tool \
  && chown -R mcp:mcp /data /home/mcp
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY bin bin
COPY lib lib
COPY tool/docker_entrypoint.sh /usr/local/bin/docker_entrypoint.sh
RUN dart compile exe bin/dart_network_mcp.dart -o /usr/local/bin/dart_network_mcp \
  && chmod 755 /usr/local/bin/docker_entrypoint.sh
ENV HOME=/home/mcp
ENV DART_NETWORK_MCP_DATA=/data
ENV DART_NETWORK_MCP_IN_DOCKER=1
ENTRYPOINT ["/usr/local/bin/docker_entrypoint.sh"]
```

O entrypoint força `HOME=/home/mcp`, `DART_NETWORK_MCP_DATA=/data` e `DART_NETWORK_MCP_IN_DOCKER=1`. O Docker MCP Toolkit passa `-e HOME` etc. como pass-through do processo do gateway; sem isso o container herda `HOME` do host e cai com `PathAccessException` em `/Users/...`.

- [x] **Step 2: Build**

Run: `docker build -t dart-network-mcp:local .`
Expected: `docker image inspect dart-network-mcp:local` sai 0.

### Task 12: Install

**Files:**
- Create: `lib/src/mcp_config_merge.dart`
- Create: `tool/merge_mcp_config.dart`
- Create: `install.sh`
- Test: `test/mcp_config_merge_test.dart`

**Interfaces:**
- Consumes: nada do store.
- Produces: `Map<String, Object?> mergeMcpServerEntry(Map<String, Object?> config, Map<String, Object?> entry)`. Substitui só `mcpServers.dart-network-mcp`. `MCP_DOCKER` permanece.

- [x] **Step 1: Teste do merge**

```dart
import 'package:dart_network_mcp/src/mcp_config_merge.dart';
import 'package:test/test.dart';

void main() {
  test('keeps MCP_DOCKER and adds dart-network-mcp', () {
    final merged = mergeMcpServerEntry(
      {
        'mcpServers': {
          'MCP_DOCKER': {
            'command': 'docker',
            'args': ['mcp', 'gateway', 'run'],
          },
        },
      },
      {
        'command': 'docker',
        'args': ['mcp', 'gateway', 'run', '--profile', 'dart-network-mcp'],
      },
    );
    final servers = merged['mcpServers'] as Map;
    expect(
      (servers['MCP_DOCKER'] as Map)['args'],
      ['mcp', 'gateway', 'run'],
    );
    expect(
      (servers['dart-network-mcp'] as Map)['args'],
      ['mcp', 'gateway', 'run', '--profile', 'dart-network-mcp'],
    );
  });
}
```

- [x] **Step 2: Implementar e ver passar**

`tool/merge_mcp_config.dart` lê o arquivo em `argv[0]`, usa `{}` se não existir, aplica o merge com o JSON objeto de `argv[1]`, e grava com indentação 2.

Run: `dart test test/mcp_config_merge_test.dart`
Expected: PASS

- [x] **Step 3: install.sh**

O script exige `--claude`, `--cursor` ou os dois. Flag desconhecida sai 2. Home é `$HOME` ou `$USERPROFILE`. Data dir segue `resolveDataDirectory`. Cria o data dir, `<home>/.dart-tool` e `<home>/.docker/mcp/catalogs`. Unix: `chmod 700` no data dir. Windows (`MINGW*`, `MSYS*`, `CYGWIN*`): `icacls` só para `$USERNAME`. Separador de allowlist: `;` no Windows e `:` nos outros.

Sem `DART_NETWORK_MCP_INSTALL_SKIP_DOCKER=1`, faz `docker build -t dart-network-mcp:local`. Escreve `<home>/.docker/mcp/catalogs/dart-network-mcp.yaml` com `longLived: true`, imagem `dart-network-mcp:local`, volumes `<home>/.dart-tool:/home/mcp/.dart-tool:ro` e `<data dir>:/data:rw`, env `HOME=/home/mcp`, `DART_NETWORK_MCP_DATA=/data`, `DART_NETWORK_MCP_IN_DOCKER=1`. Unix inclui `user: "<uid>:<gid>"`. Windows omite `user`. Se `docker run --rm alpine getent hosts host.docker.internal` falhar, inclui `extraHosts: ["host.docker.internal:host-gateway"]`. O skip não inclui `extraHosts` e não chama `docker mcp`.

Sem o skip: cria o profile `dart-network-mcp` se faltar e adiciona `file://dart-network-mcp.yaml`.

A entry do cliente é `docker` / `mcp gateway run --profile dart-network-mcp`, com `MCP_GATEWAY_DOCKER_BIND_ALLOWED_PATHS` em `<home>/.dart-tool` e `MCP_GATEWAY_DOCKER_BIND_ALLOW_WRITABLE_PATHS` no data dir. `--claude` faz merge em `<home>/.claude.json`. `--cursor` em `<home>/.cursor/mcp.json`.

- [x] **Step 4: HOME temporário**

```bash
tmp="$(mktemp -d)"
export HOME="$tmp"
export DART_NETWORK_MCP_INSTALL_SKIP_DOCKER=1
bash install.sh --claude --cursor
test -f "$tmp/.docker/mcp/catalogs/dart-network-mcp.yaml"
grep -q 'longLived: true' "$tmp/.docker/mcp/catalogs/dart-network-mcp.yaml"
python3 - <<'PY'
import json, os
home = os.environ["HOME"]
claude = json.load(open(home + "/.claude.json"))
cursor = json.load(open(home + "/.cursor/mcp.json"))
assert claude["mcpServers"]["dart-network-mcp"]["args"][-1] == "dart-network-mcp"
assert cursor["mcpServers"]["dart-network-mcp"]["args"][-1] == "dart-network-mcp"
json.dump({"mcpServers": {"MCP_DOCKER": {"command": "docker", "args": ["mcp", "gateway", "run"]}}}, open(home + "/.claude.json", "w"))
PY
bash install.sh --claude
python3 - <<'PY'
import json, os
claude = json.load(open(os.environ["HOME"] + "/.claude.json"))
assert claude["mcpServers"]["MCP_DOCKER"]["args"] == ["mcp", "gateway", "run"]
assert "dart-network-mcp" in claude["mcpServers"]
PY
```

Expected: exit 0.

### Task 13: App exemplo

**Files:**
- Create: `example/`

- [x] **Step 1: Criar**

```bash
flutter create --project-name dart_network_mcp_example --platforms=ios,android,macos,linux,windows example
```

Run em `example`: `flutter pub add http`

- [x] **Step 2: `example/lib/main.dart`**

`main` liga `HttpClient.enableTimelineLogging = true` antes do `runApp`. Abertura: três GETs paralelos a `https://jsonplaceholder.typicode.com` (`/posts/1`, `/users/1`, `/albums/1`). Timer de 5s alterna lotes de três calls: writes (`POST`/`PUT`/`PATCH` em `/posts`) e mix (`DELETE /posts/1` + dois GETs). Pausar segura o lote seguinte. UI lista method/URI/status/elapsed.

Não usar httpbin nem uuid — o contrato de aceitação é jsonplaceholder + batches.

- [x] **Step 3: Analisar**

Run: `dart analyze example/lib/main.dart`
Expected: nenhum erro. O working directory do analyze é `example` se o `pubspec.yaml` de lá for o pacote. Use `cd example && dart analyze lib/main.dart`.

### Task 14: README

**Files:**
- Create: `README.md`
- Create: `docs/mcp.md`

- [x] **Step 1: Escrever em português, nesta ordem**

1. O que é: attach em VMs Dart já em execução e o HTTP profile, uma chave por URI.
2. Alvos: iOS, Android e desktop usam o mesmo attach. A URI impressa pelo tooling é a chave. VM sem profiler `dart:io` fica `live` e as tools de tráfego devolvem `http_profile_unavailable`.
3. Dados sensíveis: SQLite e exports contêm headers e bodies, inclusive `Authorization` e cookies. O arquivo fica restrito ao usuário.
4. Install: `bash install.sh --claude`, `--cursor` ou os dois. Profile `dart-network-mcp`. Não remove outro MCP.
5. Tabela das oito tools (overview) + link para `docs/mcp.md`.
6. Live e history: default só live. History é o log de antes do crash. Sem a flag a tool recusa.
7. Exemplo: `cd example && flutter run -d <id>` com um id de `flutter devices`. As três URLs e o intervalo de 5 segundos.

`docs/mcp.md` é o guia de uso completo (fluxo, shapes JSON, erros, bodies, aceitação).

### Task 15: Aceitação ao vivo

Preferir servidor MCP long-lived (stdio `docker run -i` ou gateway estável). One-shot `docker mcp tools call` não observa bem o poll de 1s.

- [x] **Step 1:** `bash install.sh --claude --cursor`. A imagem `dart-network-mcp:local` e o profile `dart-network-mcp` existem.
- [x] **Step 2:** Subir `example/` em debug num device de `list_devices` que não seja web. Ler a URI da VM no log.
- [x] **Step 3:** `attach_vm` dessa URI no servidor do profile. `list_requests` mostra os três GETs de abertura (`/posts/1`, `/users/1`, `/albums/1`), com `responseBody` JSON.
- [x] **Step 4:** Após um ciclo de 5 segundos, o lote seguinte (POST/PUT/PATCH ou DELETE e GETs) aparece na mesma chave.
- [x] **Step 5:** `hot_reload`. A `vmUri` não muda. Após ~5s, um novo lote do timer entra na mesma chave.
- [x] **Step 6:** `hot_restart`. As linhas anteriores permanecem. As GET de abertura entram com `startTime` novo.
- [x] **Step 7:** Parar o app e aguardar o socket da VM fechar. `get_session` mostra `history`. `list_requests` sem `includeHistory` devolve `history_requires_flag`. Com a flag, as requests de antes do stop estão lá.
- [x] **Step 8:** `export_har` e `export_devtools_json` com `includeHistory=true`. Os dois `path` existem no host, em `exports/` do diretório de dados.

`dart test` verde não fecha esta tarefa.

## Self-review

Tasks 1–2 cobrem URI e diretório. Task 3 cobre isolamento, PK com `start_time`, history e delete. Tasks 5–6 cobrem os exports. Task 7 cobre a fake WebSocket, truncamento, profiler ausente e crash. Task 8 cobre a descoberta em disco. Task 9 cobre as flags das tools. Tasks 10–12 cobrem stdio, imagem e install sem apagar `MCP_DOCKER`. Tasks 13–15 cobrem o exemplo e a aceitação em iOS, Android ou desktop.

