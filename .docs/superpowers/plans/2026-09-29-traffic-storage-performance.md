# Traffic Storage Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Guardar header e body inteiros em arquivo, manter o SQLite só com colunas curtas, e apagar o ws inteiro depois de 90 dias configuráveis, sem a listagem abrir esses arquivos.

**Architecture:** `TrafficFiles` grava e apaga os arquivos em `<dataDir>/bodies/<sha256(vmUri)>/`. `SessionStore` persiste paths, sizes e o prazo. `VmSession` escreve os arquivos no poll e só chama `clearHttpProfile` sem request em voo. `DartNetworkMcp` lista sem abrir arquivo, lê um request sob o teto de 100000 caracteres, exporta um request por vez e varre o TTL.

**Tech Stack:** Dart 3.6, `sqlite3`, `crypto`, `path`, `vm_service`, `mcp_dart`, `package:test`.

**Spec:** `.docs/superpowers/specs/2026-09-29-traffic-storage-performance-design.md`. Os diagramas de classes e os fluxos de entrada, tratamento e saída da spec são o contrato de cada task. A task nomeia a seção.

## Global Constraints

- Não fazer `git add` nem `git commit`. Deixar cada tarefa na working tree.
- Body e header não entram na linha. Não existe `raw_json`. Não existe corte em 1000000 bytes. Não existem colunas `*_truncated`.
- `headers.json` é sempre gravado, com `requestHeaders` e `responseHeaders`. Mapas vazios continuam gerando arquivo.
- Body entregue, inclusive tamanho 0, gera arquivo. Body não entregue: sem arquivo, path nulo. `bodyUnavailable` continua sendo a falha do `getHttpProfileRequest`, não a ausência de um dos lados.
- Pasta: `<dataDir>/bodies/<sha256 hex UTF-8 do vmUri canônico>/`.
- Arquivo: `{startTime}_{sha256 hex UTF-8 do requestId}.request.body`, `.response.body` ou `.headers.json`.
- Export mantém `dart_network_mcp_<yyyyMMddTHHmmss>_<8 hex SHA-1 de vmUri>.har` ou `.json`.
- `list_requests` não abre arquivo. Devolve `requestBodySize`, `responseBodySize` e `bodyUnavailable` sempre. `durationMs` só com `endTime`. `error` só quando não nulo. Sem header, body ou path.
- `get_request`: o limite é o comprimento de `jsonEncode` do sucesso. Acima de 100000 caracteres, omite nesta ordem: response body e encoding, request body e encoding, os dois mapas de header. Path só entra no campo omitido.
- `includeHistory=true` em sessão `live` é ignorado. History sem a flag: `history_requires_flag`. Profiler ausente: `http_profile_unavailable`.
- `retention.days` padrão 90. `set_retention` exige inteiro `>= 1`. Varredura na subida, a cada 60 minutos e depois de um `set_retention` válido. `get_retention` não varre.
- TTL só apaga `state=history` com `disconnectedAt` não nulo e idade `>= days`. Apaga linhas, a pasta `bodies/` e os exports daquele SHA-1 de 8 hex.
- `clearHttpProfile` só no isolate cujo perfil não tem request sem `endTime` e cuja persistência deste poll não falhou.
- Migração copia bytes e headers já gravados para arquivo e recria `requests` sem blobs. Bytes já cortados permanecem cortados.
- Paths nas tools são absolutos no processo do servidor.
- Diagramas da spec são copiados para `docs/mcp.md` na task de documentação.

## File Structure

- Create: `lib/src/traffic_files.dart` — paths, escrita, leitura e apagamento de bodies e exports.
- Modify: `lib/src/session_store.dart` — `RequestRecord` sem bytes, schema novo, migração, retenção.
- Modify: `lib/src/vm_session.dart` — grava arquivos, remove o teto de 1 MB, `clearHttpProfile`.
- Modify: `lib/src/dart_network_mcp.dart` — listagem, `get_request`, export incremental, delete de arquivos, TTL.
- Modify: `lib/src/har_export.dart` e `lib/src/devtools_export.dart` — um request já carregado, sem `rawJson`.
- Modify: `bin/dart_network_mcp.dart` — tools `get_retention` e `set_retention`, varredura na subida e de hora em hora.
- Modify: `test/session_store_test.dart`, `test/dart_network_mcp_test.dart`, `test/har_export_test.dart`, `test/devtools_export_test.dart`, `test/vm_session_test.dart`.
- Create: `test/traffic_files_test.dart`, `test/retention_test.dart`.
- Modify: `docs/mcp.md`, `README.md`.

---

### Task 1: TrafficFiles

**Files:**
- Create: `lib/src/traffic_files.dart`
- Test: `test/traffic_files_test.dart`

**Interfaces:**
- Consumes: nada
- Produces: `TrafficFileStore`, `TrafficFiles`, `WrittenTraffic`, `HeaderMaps`

- [ ] **Step 1: Write the failing test**

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_network_mcp/src/traffic_files.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('traffic-files');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('writes headers and both bodies, including empty body', () {
    final files = TrafficFiles(temp.path);
    final written = files.write(
      vmUri: 'ws://vm/ws',
      requestId: 'req/1',
      startTime: 10,
      requestHeaders: {},
      responseHeaders: {'set-cookie': 'a=b'},
      requestBody: Uint8List(0),
      responseBody: Uint8List.fromList([1, 2, 3]),
    );

    expect(File(written.headersPath).readAsStringSync(),
        '{"requestHeaders":{},"responseHeaders":{"set-cookie":"a=b"}}');
    expect(written.requestBodyPath, isNotNull);
    expect(File(written.requestBodyPath!).lengthSync(), 0);
    expect(File(written.responseBodyPath!).readAsBytesSync(), [1, 2, 3]);
    expect(written.requestBodySize, 0);
    expect(written.responseBodySize, 3);
    expect(files.readHeaders(written.headersPath).responseHeaders['set-cookie'], 'a=b');
  });

  test('omits a body file when that side is null', () {
    final files = TrafficFiles(temp.path);
    final written = files.write(
      vmUri: 'ws://vm/ws',
      requestId: '1',
      startTime: 10,
      requestHeaders: {},
      responseHeaders: {},
      requestBody: null,
      responseBody: Uint8List.fromList([9]),
    );
    expect(written.requestBodyPath, isNull);
    expect(written.responseBodyPath, isNotNull);
  });

  test('rewrite keeps one file and delete removes the session directory and exports', () {
    final files = TrafficFiles(temp.path);
    files.write(
      vmUri: 'ws://vm/ws',
      requestId: '1',
      startTime: 10,
      requestHeaders: {'a': '1'},
      responseHeaders: {},
      requestBody: Uint8List.fromList([1]),
      responseBody: null,
    );
    final again = files.write(
      vmUri: 'ws://vm/ws',
      requestId: '1',
      startTime: 10,
      requestHeaders: {'a': '2'},
      responseHeaders: {},
      requestBody: Uint8List.fromList([1, 2]),
      responseBody: null,
    );
    expect(files.readHeaders(again.headersPath).requestHeaders['a'], '2');
    expect(File(again.requestBodyPath!).lengthSync(), 2);

    final exportDir = Directory('${temp.path}/exports')..createSync();
    final hash8 = files.exportHash8('ws://vm/ws');
    File('${exportDir.path}/dart_network_mcp_20260101T000000_$hash8.har')
        .writeAsStringSync('x');
    File('${exportDir.path}/dart_network_mcp_20260101T000000_other.har')
        .writeAsStringSync('keep');

    files.deleteSessionFiles('ws://vm/ws');
    files.deleteExportFiles('ws://vm/ws');

    expect(Directory(files.sessionDirectory('ws://vm/ws')).existsSync(), isFalse);
    expect(
      File('${exportDir.path}/dart_network_mcp_20260101T000000_$hash8.har').existsSync(),
      isFalse,
    );
    expect(
      File('${exportDir.path}/dart_network_mcp_20260101T000000_other.har').existsSync(),
      isTrue,
    );
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/traffic_files_test.dart`

Expected: FAIL. `traffic_files.dart` não existe.

- [ ] **Step 3: Write minimal implementation**

`lib/src/traffic_files.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

String sha256Hex(String value) => sha256.convert(utf8.encode(value)).toString();

class WrittenTraffic {
  const WrittenTraffic({
    required this.headersPath,
    required this.requestBodyPath,
    required this.responseBodyPath,
    required this.requestBodySize,
    required this.responseBodySize,
  });

  final String headersPath;
  final String? requestBodyPath;
  final String? responseBodyPath;
  final int requestBodySize;
  final int responseBodySize;
}

class HeaderMaps {
  const HeaderMaps({
    required this.requestHeaders,
    required this.responseHeaders,
  });

  final Map<String, String> requestHeaders;
  final Map<String, String> responseHeaders;
}

abstract interface class TrafficFileStore {
  WrittenTraffic write({
    required String vmUri,
    required String requestId,
    required int startTime,
    required Map<String, String> requestHeaders,
    required Map<String, String> responseHeaders,
    Uint8List? requestBody,
    Uint8List? responseBody,
  });

  Uint8List? readBytes(String path);
  HeaderMaps readHeaders(String path);
  void deleteSessionFiles(String vmUri);
  void deleteExportFiles(String vmUri);
  String sessionDirectory(String vmUri);
  String exportHash8(String vmUri);
}

class TrafficFiles implements TrafficFileStore {
  TrafficFiles(this.dataDirectory);

  final String dataDirectory;

  @override
  String sessionDirectory(String vmUri) =>
      p.join(dataDirectory, 'bodies', sha256Hex(vmUri));

  @override
  String exportHash8(String vmUri) =>
      sha1.convert(utf8.encode(vmUri)).toString().substring(0, 8);

  String _stem(String vmUri, String requestId, int startTime) => p.join(
        sessionDirectory(vmUri),
        '${startTime}_${sha256Hex(requestId)}',
      );

  @override
  WrittenTraffic write({
    required String vmUri,
    required String requestId,
    required int startTime,
    required Map<String, String> requestHeaders,
    required Map<String, String> responseHeaders,
    Uint8List? requestBody,
    Uint8List? responseBody,
  }) {
    final dir = Directory(sessionDirectory(vmUri));
    dir.createSync(recursive: true);
    final stem = _stem(vmUri, requestId, startTime);
    final headersPath = '$stem.headers.json';
    File(headersPath).writeAsStringSync(
      jsonEncode({
        'requestHeaders': requestHeaders,
        'responseHeaders': responseHeaders,
      }),
    );
    String? requestBodyPath;
    String? responseBodyPath;
    if (requestBody != null) {
      requestBodyPath = '$stem.request.body';
      File(requestBodyPath).writeAsBytesSync(requestBody);
    }
    if (responseBody != null) {
      responseBodyPath = '$stem.response.body';
      File(responseBodyPath).writeAsBytesSync(responseBody);
    }
    return WrittenTraffic(
      headersPath: headersPath,
      requestBodyPath: requestBodyPath,
      responseBodyPath: responseBodyPath,
      requestBodySize: requestBody?.length ?? 0,
      responseBodySize: responseBody?.length ?? 0,
    );
  }

  @override
  Uint8List? readBytes(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    return file.readAsBytesSync();
  }

  @override
  HeaderMaps readHeaders(String path) {
    final decoded = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    Map<String, String> mapOf(String key) {
      final raw = decoded[key] as Map<String, dynamic>? ?? {};
      return raw.map((k, v) => MapEntry(k, v as String));
    }
    return HeaderMaps(
      requestHeaders: mapOf('requestHeaders'),
      responseHeaders: mapOf('responseHeaders'),
    );
  }

  @override
  void deleteSessionFiles(String vmUri) {
    final dir = Directory(sessionDirectory(vmUri));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  @override
  void deleteExportFiles(String vmUri) {
    final dir = Directory(p.join(dataDirectory, 'exports'));
    if (!dir.existsSync()) return;
    final hash8 = exportHash8(vmUri);
    for (final entity in dir.listSync()) {
      final name = p.basename(entity.path);
      final match = name.startsWith('dart_network_mcp_') &&
          (name.endsWith('_$hash8.har') || name.endsWith('_$hash8.json'));
      if (match) entity.deleteSync();
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/traffic_files_test.dart`

Expected: PASS

- [ ] **Step 5: Do not commit**

Deixar os arquivos na working tree.

---

### Task 2: Schema, RequestRecord e migração

**Files:**
- Modify: `lib/src/session_store.dart`
- Modify: `test/session_store_test.dart`
- Modify: `test/dart_network_mcp_test.dart`
- Modify: `test/har_export_test.dart`
- Modify: `test/devtools_export_test.dart`
- Test: `test/session_store_test.dart`

**Interfaces:**
- Consumes: `TrafficFiles`, `WrittenTraffic`, `sha256Hex`
- Produces: `SessionStore.open(String databasePath, {required String dataDirectory, TrafficFileStore? files})`, `RequestRecord` com `headersPath`, `requestBodyPath`, `responseBodyPath` e sem headers, bodies, truncated ou `rawJson`. `store.files`.

Spec: seções "Modelo gravado" e "Migração".

- [ ] **Step 1: Write the failing test**

No grupo de `test/session_store_test.dart`, acrescentar:

```dart
test('stores paths and rewrites the same primary key', () {
  final store = SessionStore.open(dbPath, dataDirectory: tempDir.path);
  store.upsertSession(liveSession('ws://a/ws'));
  final files = store.files;
  final written = files.write(
    vmUri: 'ws://a/ws',
    requestId: '1',
    startTime: 10,
    requestHeaders: {'a': '1'},
    responseHeaders: {},
    requestBody: Uint8List.fromList([1, 2, 3, 4]),
    responseBody: null,
  );
  store.upsertRequest(
    request(
      vmUri: 'ws://a/ws',
      requestId: '1',
      startTime: 10,
      written: written,
      bodyUnavailable: false,
    ),
  );
  store.close();

  final reopened = SessionStore.open(dbPath, dataDirectory: tempDir.path);
  final row = reopened.listRequests(vmUri: 'ws://a/ws').single;
  expect(row.requestBodyPath, written.requestBodyPath);
  expect(row.responseBodyPath, isNull);
  expect(row.requestBodySize, 4);
  expect(row.headersPath, written.headersPath);
  reopened.close();
});

test('migrates inline blobs into files and drops raw_json', () {
  final db = sqlite3.open(dbPath);
  db.execute('CREATE TABLE sessions (vm_uri TEXT PRIMARY KEY, state TEXT, app_name TEXT, isolate_ids TEXT, started_at INTEGER, disconnected_at INTEGER, disconnect_reason TEXT, http_profile_available INTEGER)');
  db.execute('''CREATE TABLE requests (
    vm_uri TEXT, request_id TEXT, isolate_id TEXT, method TEXT, uri TEXT,
    start_time INTEGER, end_time INTEGER, status_code INTEGER, reason_phrase TEXT,
    request_headers TEXT, response_headers TEXT, request_body BLOB, response_body BLOB,
    request_body_size INTEGER, response_body_size INTEGER,
    request_body_truncated INTEGER, response_body_truncated INTEGER,
    body_unavailable INTEGER, error TEXT, raw_json TEXT,
    PRIMARY KEY (vm_uri, request_id, start_time))''');
  db.execute(
    "INSERT INTO sessions VALUES ('ws://old/ws','history','app','[]',1,2,NULL,1)",
  );
  db.execute(
    "INSERT INTO requests VALUES ('ws://old/ws','1','isolates/1','GET','https://example/',10,20,200,'OK','{\"a\":\"b\"}','{}',X'0102',NULL,2,0,1,0,0,NULL,'{\"id\":\"1\"}')",
  );
  db.dispose();

  final store = SessionStore.open(dbPath, dataDirectory: tempDir.path);
  final row = store.listRequests(vmUri: 'ws://old/ws').single;
  expect(row.requestBodyPath, isNotNull);
  expect(File(row.requestBodyPath!).readAsBytesSync(), [1, 2]);
  expect(row.responseBodyPath, isNull);
  expect(row.requestBodySize, 2);
  final headers = store.files.readHeaders(row.headersPath);
  expect(headers.requestHeaders['a'], 'b');
  final info = store.debugTableInfo('requests');
  expect(info.contains('raw_json'), isFalse);
  expect(info.contains('request_body'), isFalse);
  store.close();
});
```

O helper `request` do teste passa a receber `WrittenTraffic written` e preencher os paths. Acrescentar `import 'package:sqlite3/sqlite3.dart';` e `import 'dart:io';` se ainda não estiverem no arquivo.

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/session_store_test.dart`

Expected: FAIL. `open` não aceita `dataDirectory` e `RequestRecord` ainda exige `rawJson`.

- [ ] **Step 3: Write minimal implementation**

Trocar `RequestRecord` para:

```dart
class RequestRecord {
  RequestRecord({
    required this.vmUri,
    required this.requestId,
    required this.isolateId,
    required this.method,
    required this.uri,
    required this.startTime,
    required this.endTime,
    required this.statusCode,
    required this.reasonPhrase,
    required this.headersPath,
    required this.requestBodyPath,
    required this.responseBodyPath,
    required this.requestBodySize,
    required this.responseBodySize,
    required this.bodyUnavailable,
    required this.error,
  });

  final String vmUri;
  final String requestId;
  final String isolateId;
  final String method;
  final String uri;
  final int startTime;
  final int? endTime;
  final int? statusCode;
  final String? reasonPhrase;
  final String headersPath;
  final String? requestBodyPath;
  final String? responseBodyPath;
  final int requestBodySize;
  final int responseBodySize;
  final bool bodyUnavailable;
  final String? error;
}
```

`SessionStore.open(String databasePath, {required String dataDirectory, TrafficFileStore? files})` cria `TrafficFiles(dataDirectory)` quando `files` é nulo. Guarda em `final TrafficFileStore files`.

Schema novo de `requests`: as colunas de `RequestRecord`, PK `(vm_uri, request_id, start_time)`, FK com `ON DELETE CASCADE`. Sem headers, blobs, truncated, `raw_json`.

Se `pragma table_info(requests)` contiver `raw_json`, ler cada linha antiga, chamar `files.write` com os blobs e os mapas JSON, inserir na tabela nova e dropar a antiga. Body truncado é copiado como está. `CREATE TABLE IF NOT EXISTS retention (days INTEGER NOT NULL)` e, se vazia, `INSERT INTO retention(days) VALUES (90)`.

`upsertRequest` grava só as colunas novas. `_requestFromRow` lê os paths. `debugTableInfo` devolve os nomes das colunas para o teste.

Atualizar os helpers de `test/dart_network_mcp_test.dart`, `test/har_export_test.dart` e `test/devtools_export_test.dart` para o novo construtor. Onde o teste ainda passa header ou body para o export, a task 6 troca a API. Até lá, os testes de export que só checam metadado usam paths vazios temporários `headersPath: '/tmp/missing.headers.json'` e bodies nulos, e a task 6 corrige a leitura. Se `dart test` desses arquivos quebrar por campo removido, ajustar o expect para o campo novo. Não deixar o suite vermelho por construtor.

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/session_store_test.dart test/dart_network_mcp_test.dart test/har_export_test.dart test/devtools_export_test.dart`

Expected: PASS, ou falha só em `vm_session.dart` / exports que ainda leem campos removidos. Se `dart analyze` apontar `vm_session.dart`, a task 3 é o próximo conserto. Esta task deixa `session_store_test` verde.

- [ ] **Step 5: Do not commit**

---

### Task 3: Poll grava arquivos e limpa o perfil ocioso

**Files:**
- Modify: `lib/src/vm_session.dart`
- Test: `test/vm_session_test.dart`

**Interfaces:**
- Consumes: `store.files.write`, `RequestRecord` novo
- Produces: persistência sem teto de 1 MB. `clearHttpProfile` só sem request em voo e sem falha de persistência nesse isolate.

Spec: "Gravação do poll".

- [ ] **Step 1: Write the failing test**

Estender o fake de VM em `test/support/fake_vm_service.dart` com contagem de `clearHttpProfile` se ainda não existir. Em `test/vm_session_test.dart`:

```dart
test('stores a body larger than 1 MB in a file and does not clear while one request is in flight', () async {
  final big = Uint8List(1000001);
  // o fake devolve uma request terminada com responseBody big
  // e uma request sem endTime
  await session.pollOnce();
  final row = store.listRequests(vmUri: key).singleWhere((r) => r.endTime != null);
  expect(row.responseBodySize, 1000001);
  expect(File(row.responseBodyPath!).lengthSync(), 1000001);
  expect(fake.clearHttpProfileCalls, 0);
});

test('clears the http profile when every request in the isolate has ended', () async {
  // perfil só com requests que têm endTime, persistência ok
  await session.pollOnce();
  expect(fake.clearHttpProfileCalls, 1);
});
```

O fake precisa registrar `ext.dart.io.clearHttpProfile`. Seguir o padrão já usado para `getHttpProfileRequest`.

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/vm_session_test.dart`

Expected: FAIL. O body grande continua cortado em 1000000 e `clearHttpProfile` não é chamado.

- [ ] **Step 3: Write minimal implementation**

Apagar `_maxBodyBytes` e os cortes em `_persistRequest`. Escrever arquivos com `store.files.write` antes do `upsertRequest`. `bodyUnavailable` permanece true quando `getHttpProfileRequest` falha. Não gravar `rawJson`.

No fim do loop de um isolate, se nenhuma persistência lançou e todo `ref.endTime` é não nulo, chamar `_service.clearHttpProfile(isolateId)`. Se a lista estiver vazia, também pode limpar.

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/vm_session_test.dart`

Expected: PASS

- [ ] **Step 5: Do not commit**

---

### Task 4: list_requests não abre arquivo

**Files:**
- Modify: `lib/src/dart_network_mcp.dart` (`_requestListItem`)
- Test: `test/dart_network_mcp_test.dart`

**Interfaces:**
- Consumes: `RequestRecord` com sizes e paths
- Produces: item de lista sem header, body ou path

Spec: seção `list_requests`.

- [ ] **Step 1: Write the failing test**

```dart
test('listRequests returns sizes and does not read body files', () {
  final files = ThrowingReadFiles(tempDir.path);
  final store = SessionStore.open(dbPath, dataDirectory: tempDir.path, files: files);
  final mcp = DartNetworkMcp(store: store, dataDirectory: tempDir.path);
  store.upsertSession(liveSession(vmUri));
  final written = TrafficFiles(tempDir.path).write(
    vmUri: vmUri,
    requestId: '1',
    startTime: 10,
    requestHeaders: {'cookie': 'huge'},
    responseHeaders: {},
    requestBody: null,
    responseBody: Uint8List.fromList(List.filled(50, 1)),
  );
  store.upsertRequest(/* row apontando para written, startTime: 10, endTime: 5010 */);

  final page = mcp.listRequests(vmUri);
  final item = (page['requests'] as List).single as Map;
  expect(item['responseBodySize'], 50);
  expect(item['requestBodySize'], 0);
  expect(item['bodyUnavailable'], isFalse);
  expect(item['durationMs'], 5);
  expect(item.containsKey('responseBody'), isFalse);
  expect(item.containsKey('requestHeaders'), isFalse);
  expect(item.containsKey('responseBodyPath'), isFalse);
  expect(files.readCalls, 0);
});
```

`ThrowingReadFiles extends TrafficFiles` incrementa `readCalls` e lança `StateError` em `readBytes` e `readHeaders`. `durationMs` do exemplo: usar `endTime: startTime + 5000` e esperar `5`.

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/dart_network_mcp_test.dart --name listRequests`

Expected: FAIL. O item ainda traz body ou o teste não compila porque `_requestListItem` lê bytes.

- [ ] **Step 3: Write minimal implementation**

`_requestListItem` devolve `requestId`, `startTime`, `method`, `uri`, `statusCode`, `durationMs` se `endTime != null`, `requestBodySize`, `responseBodySize`, `bodyUnavailable`, e `error` se não nulo. Não chama `store.files`.

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/dart_network_mcp_test.dart --name listRequests`

Expected: PASS

- [ ] **Step 5: Do not commit**

---

### Task 5: get_request com teto de 100000 caracteres

**Files:**
- Modify: `lib/src/dart_network_mcp.dart`
- Test: `test/dart_network_mcp_test.dart`

**Interfaces:**
- Consumes: `store.files.readBytes`, `store.files.readHeaders`
- Produces: `const int toolResponseCharBudget = 100000` em `dart_network_mcp.dart`. `getRequest` aplica a ordem de omissão da spec.

Spec: seção `get_request`.

- [ ] **Step 1: Write the failing test**

```dart
test('getRequest inlines a small json body', () {
  // response body utf8 {"id":1}
  final detail = mcp.getRequest(vmUri, '1')['request'] as Map;
  expect(detail['responseBody'], {'id': 1});
  expect(detail['responseBodyEncoding'], 'json');
  expect(detail.containsKey('responseBodyPath'), isFalse);
  expect(detail['requestHeaders'], {'accept': 'application/json'});
});

test('getRequest replaces oversized response body with path and size', () {
  final body = Uint8List.fromList(List.filled(120000, 0x61));
  // gravar esse body no arquivo e na linha
  final detail = mcp.getRequest(vmUri, '1')['request'] as Map;
  expect(detail.containsKey('responseBody'), isFalse);
  expect(detail['responseBodyPath'], isNotEmpty);
  expect(detail['responseBodySize'], 120000);
  expect(detail.containsKey('requestHeaders'), isTrue);
});

test('ambiguous request does not read files', () {
  // duas linhas com o mesmo requestId e startTime diferente
  final files = ThrowingReadFiles(tempDir.path);
  final result = mcp.getRequest(vmUri, 'same');
  expect(result['error']['code'], 'ambiguous_request');
  expect(files.readCalls, 0);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/dart_network_mcp_test.dart --name getRequest`

Expected: FAIL. O detalhe ainda espera bytes dentro de `RequestRecord` ou não omite o body grande.

- [ ] **Step 3: Write minimal implementation**

Montar o mapa do request com metadado, sizes, `bodyUnavailable`, headers lidos do arquivo e bodies decodificados como hoje (`json`, `utf8`, `base64`). Calcular `jsonEncode` do envelope `{vmUri, state, request}`. Enquanto `length > 100000`, remover na ordem: `responseBody`+`responseBodyEncoding` e pôr `responseBodyPath` se não nulo; depois o par do request; depois os dois mapas e pôr `headersPath`. Parar quando couber ou não houver mais o que omitir.

`ambiguous_request` retorna antes de qualquer `readBytes` ou `readHeaders`.

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/dart_network_mcp_test.dart --name getRequest`

Expected: PASS

- [ ] **Step 5: Do not commit**

---

### Task 6: Export um request por vez

**Files:**
- Modify: `lib/src/har_export.dart`
- Modify: `lib/src/devtools_export.dart`
- Modify: `lib/src/dart_network_mcp.dart`
- Test: `test/har_export_test.dart`
- Test: `test/devtools_export_test.dart`

**Interfaces:**
- Consumes: `HeaderMaps`, bytes de um request
- Produces: `class ExportableRequest` em `har_export.dart` com os campos de metadado, `requestHeaders`, `responseHeaders`, `requestBody`, `responseBody`. `Map<String, Object?> harEntry(ExportableRequest request)`. `Map<String, Object?> devToolsRequest(ExportableRequest request)`.

Spec: seção `export_har` e `export_devtools_json`.

- [ ] **Step 1: Write the failing test**

```dart
test('har entry contains the full body loaded for that request only', () {
  final entry = harEntry(
    ExportableRequest(
      vmUri: 'ws://vm',
      requestId: '1',
      isolateId: 'isolates/1',
      method: 'POST',
      uri: 'https://example/order',
      startTime: 1,
      endTime: 2000,
      statusCode: 200,
      reasonPhrase: 'OK',
      requestHeaders: {},
      responseHeaders: {'content-type': 'application/json'},
      requestBody: null,
      responseBody: Uint8List.fromList('{"ok":true}'.codeUnits),
      requestBodySize: 0,
      responseBodySize: 11,
      bodyUnavailable: false,
      error: null,
    ),
  );
  final response = entry['response'] as Map;
  final content = response['content'] as Map;
  expect(content['text'], '{"ok":true}');
});
```

O teste do DevTools espera `devToolsRequest(...)` com `id`, `method`, `uri`, `startTime`, `endTime` e os bodies, sem ler `rawJson`.

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/har_export_test.dart test/devtools_export_test.dart`

Expected: FAIL. `harEntry` / `ExportableRequest` não existem.

- [ ] **Step 3: Write minimal implementation**

`harEntry` reutiliza a montagem atual de uma entry HAR, lendo headers e bodies de `ExportableRequest`. `devToolsRequest` monta o objeto `request` com id, method, uri, tempos e bodies. `buildHar` e `buildDevToolsSnapshot` passam a aceitar `List<ExportableRequest>` ou são deixados como wrappers que mapeiam a lista. Quem exporta no MCP itera as linhas do store, carrega um `ExportableRequest` por vez via `files.readHeaders` e `files.readBytes`, escreve o JSON no arquivo com vírgula entre entries e não guarda a lista de bodies. O nome do arquivo permanece o de `_writeExportFile`.

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/har_export_test.dart test/devtools_export_test.dart test/dart_network_mcp_test.dart`

Expected: PASS

- [ ] **Step 5: Do not commit**

---

### Task 7: delete_session apaga pasta e exports

**Files:**
- Modify: `lib/src/dart_network_mcp.dart`
- Test: `test/dart_network_mcp_test.dart`

**Interfaces:**
- Consumes: `store.files.deleteSessionFiles`, `store.files.deleteExportFiles`, `store.deleteSession`
- Produces: `deleteSession` remove os três

Spec: seção `delete_session`.

- [ ] **Step 1: Write the failing test**

```dart
test('deleteSession removes rows, body directory and matching exports', () async {
  final files = TrafficFiles(tempDir.path);
  final written = files.write(
    vmUri: vmUri,
    requestId: '1',
    startTime: 10,
    requestHeaders: {},
    responseHeaders: {},
    requestBody: Uint8List.fromList([1]),
    responseBody: null,
  );
  Directory('${tempDir.path}/exports').createSync();
  final hash8 = files.exportHash8(vmUri);
  File('${tempDir.path}/exports/dart_network_mcp_20260101T000000_$hash8.json')
      .writeAsStringSync('{}');
  store.upsertRequest(/* row com written.headersPath */);

  final result = await mcp.deleteSession(vmUri);
  expect(result['deleted'], isTrue);
  expect(store.getSession(vmUri), isNull);
  expect(File(written.requestBodyPath!).existsSync(), isFalse);
  expect(
    File('${tempDir.path}/exports/dart_network_mcp_20260101T000000_$hash8.json').existsSync(),
    isFalse,
  );
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/dart_network_mcp_test.dart --name deleteSession`

Expected: FAIL. A pasta ou o export continuam no disco.

- [ ] **Step 3: Write minimal implementation**

Depois de desconectar a sessão live e de `store.deleteSession`, chamar `store.files.deleteSessionFiles(vmUri)` e `store.files.deleteExportFiles(vmUri)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/dart_network_mcp_test.dart --name deleteSession`

Expected: PASS

- [ ] **Step 5: Do not commit**

---

### Task 8: Retenção

**Files:**
- Modify: `lib/src/session_store.dart`
- Modify: `lib/src/dart_network_mcp.dart`
- Test: `test/retention_test.dart`

**Interfaces:**
- Consumes: delete de linhas e `TrafficFileStore.deleteSessionFiles` / `deleteExportFiles`
- Produces: `int SessionStore.retentionDays()`, `void SessionStore.setRetentionDays(int days)`, `List<String> SessionStore.historyVmUrisPastRetention(int nowMicros)`, `Map<String, Object?> DartNetworkMcp.getRetention()`, `Map<String, Object?> DartNetworkMcp.setRetention(int days)`, `int DartNetworkMcp.sweepRetention({int? nowMicros})`

Spec: seção "Retenção" e `get_retention` / `set_retention`.

- [ ] **Step 1: Write the failing test**

```dart
test('default retention is 90 days and setRetention rejects zero', () {
  expect(mcp.getRetention()['retentionDays'], 90);
  expect(mcp.setRetention(0)['error']['code'], 'invalid_params');
});

test('sweep deletes history older than the configured days and keeps live', () {
  final day = 24 * 60 * 60 * 1000000;
  store.upsertSession(historySession(vmUri: 'ws://old/ws', disconnectedAt: 1));
  store.upsertSession(historySession(vmUri: 'ws://new/ws', disconnectedAt: 10 * day));
  store.upsertSession(liveSession('ws://live/ws'));
  mcp.setRetention(1);
  final removed = mcp.sweepRetention(nowMicros: 10 * day);
  expect(removed, greaterThanOrEqualTo(1));
  expect(store.getSession('ws://old/ws'), isNull);
  expect(store.getSession('ws://new/ws'), isNotNull);
  expect(store.getSession('ws://live/ws'), isNotNull);
});
```

`historySession` usa `state: 'history'`. Gravar também um body file e um export do ws antigo e esperar que a varredura os apague. `setRetention(1)` já varre com o relógio real. O teste de idade chama `sweepRetention(nowMicros:)` de novo. Sessão com `disconnectedAt` 1 e `now` de 10 dias está além de 1 dia.

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/retention_test.dart`

Expected: FAIL. `getRetention` não existe.

- [ ] **Step 3: Write minimal implementation**

`historyVmUrisPastRetention` seleciona `state='history'` e `disconnected_at` não nulo e `nowMicros - disconnected_at >= days * 86400000000`. `setRetention` grava `UPDATE retention SET days=?` e chama `sweepRetention()`. `getRetention` só lê. `sweepRetention` apaga cada URI com o mesmo caminho de arquivos do `delete_session`, sem desconectar live, porque live não entra na lista.

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/retention_test.dart`

Expected: PASS

- [ ] **Step 5: Do not commit**

---

### Task 9: Tools e timer no processo

**Files:**
- Modify: `bin/dart_network_mcp.dart`

**Interfaces:**
- Consumes: `mcp.getRetention`, `mcp.setRetention`, `mcp.sweepRetention`
- Produces: tools MCP `get_retention` e `set_retention`. Varredura na subida e `Timer.periodic(Duration(hours: 1))`.

Spec: seções `get_retention` e `set_retention`.

- [ ] **Step 1: Write the failing test**

Não há harness de stdio para o bin. O teste desta task é o de retenção já verde mais `dart analyze`.

- [ ] **Step 2: Run test to verify it fails**

Run: `dart analyze bin/dart_network_mcp.dart`

Expected: sem erro antes da edição. A verificação de falha desta task é a ausência das tools, confirmada pela leitura de `_registerTools`. Seguir para a implementação.

- [ ] **Step 3: Write minimal implementation**

Registrar:

```dart
server.tool(
  'get_retention',
  description: 'Return the session retention period in days',
  toolInputSchema: ToolInputSchema(properties: {}),
  callback: ({args, extra}) async => _toolResult(mcp.getRetention()),
);

server.tool(
  'set_retention',
  description: 'Set the session retention period in days and sweep expired history',
  toolInputSchema: ToolInputSchema(
    properties: {'days': {'type': 'integer'}},
    required: ['days'],
  ),
  callback: ({args, extra}) async {
    final days = args?['days'];
    if (days is! int) {
      return _toolResult(toolError('invalid_params', 'days must be an integer'));
    }
    return _toolResult(mcp.setRetention(days));
  },
);
```

Em `main`, depois de construir `mcp`:

```dart
mcp.sweepRetention();
final retentionTimer = Timer.periodic(
  const Duration(hours: 1),
  (_) => mcp.sweepRetention(),
);
```

Cancelar `retentionTimer` quando `server.connect` completar.

- [ ] **Step 4: Run test to verify it passes**

Run: `dart analyze bin/dart_network_mcp.dart lib test && dart test`

Expected: analyze sem issues e `dart test` PASS

- [ ] **Step 5: Do not commit**

---

### Task 10: Documentação

**Files:**
- Modify: `docs/mcp.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: a spec
- Produces: `docs/mcp.md` com o diagrama de classes e o fluxo de cada tool da spec. README com `get_retention`, `set_retention` e `list_requests` sem body.

- [ ] **Step 1: Write the failing test**

Não há teste de markdown. A checagem é leitura.

- [ ] **Step 2: Confirm the docs still describe the 1 MB cut**

Abrir `docs/mcp.md` e localizar "1_000_000". Esse parágrafo ainda existe antes da edição.

- [ ] **Step 3: Write the docs**

Em cada tool de `docs/mcp.md`, colar o diagrama de classes e o fluxo da seção de mesmo nome da spec. Tirar o parágrafo que corta body em 1_000_000. Documentar o teto de 100000 caracteres e a ordem de omissão. Incluir `get_retention` e `set_retention`.

No README, na tabela de tools, acrescentar as duas tools e ajustar a linha de `list_requests` para sizes sem body e sem header.

- [ ] **Step 4: Check**

Run: `rg "1_000_000|raw_json" docs/mcp.md README.md`

Expected: nenhuma ocorrência.

- [ ] **Step 5: Do not commit**

---

## Self-review

- Spec "Modelo gravado", migração, poll, `clearHttpProfile`: tasks 1–3.
- `list_requests`, `get_request`, exports, `delete_session`, retenção: tasks 4–8.
- Registro das tools e timer: task 9.
- `docs/mcp.md` e README: task 10.
- `attach_vm`, `list_sessions` e `get_session` não mudam de contrato. Nenhuma task nova.
- Sem `TBD`. `ExportableRequest`, `toolResponseCharBudget`, `sweepRetention` e `TrafficFileStore` usam os mesmos nomes nas tasks seguintes.
