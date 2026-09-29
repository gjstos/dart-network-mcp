# Guia de uso: dart-network-mcp

Servidor MCP que anexa em VMs Dart já em execução e expõe o tráfego HTTP do HTTP profile (`dart:io`). Cada sessão é uma chave: a URI WebSocket canônica da VM Service.

Use este servidor quando um agente precisa inspecionar requests/responses de um app Flutter ou Dart em debug — inclusive depois do crash, enquanto o log daquela URI ainda estiver no SQLite.

## Instalação

Na raiz do repositório:

```bash
bash install.sh --claude          # mescla em ~/.claude.json
bash install.sh --cursor          # mescla em ~/.cursor/mcp.json
bash install.sh --claude --cursor # os dois
```

Pelo menos uma flag é obrigatória. O script:

1. constrói a imagem `dart-network-mcp:local` (salvo `DART_NETWORK_MCP_INSTALL_SKIP_DOCKER=1`);
2. grava o catálogo e o profile Docker MCP `dart-network-mcp`;
3. mescla a entrada `dart-network-mcp` no cliente — **não** altera `MCP_DOCKER` nem outros servidores.

Entrada do cliente: o install aponta para `tool/run_mcp_container.sh`. O script remove os containers da imagem (incluindo os de nome aleatório e os da tag antiga `dart-vm-mcp:local`) e sobe um só, com `--name dart-network-mcp` e `--rm`.

```json
{
  "command": "<repo>/tool/run_mcp_container.sh",
  "args": []
}
```

O servidor é **long-lived**. O script faz `docker run -i` (não `docker mcp gateway`): no Docker Desktop o gateway costuma falhar ao usar `unix:///var/run/docker.sock`. Chamadas one-shot mal observam o poll de 1s do HTTP profile.

## Dados e privacidade

Diretório de dados:

| Prioridade | Caminho |
|---|---|
| 1 | `$DART_NETWORK_MCP_DATA` |
| 2 | `%LOCALAPPDATA%\dart-network-mcp` (se `LOCALAPPDATA` existir) |
| 3 | `~/.local/share/dart-network-mcp` |

No container: `DART_NETWORK_MCP_DATA=/data`. SQLite em `network.sqlite`; bodies e headers em `bodies/`; exports em `exports/`.

O SQLite guarda só metadados curtos. Headers e bodies completos (`Authorization`, cookies, etc.) ficam em arquivo. Trate o diretório de dados como credenciais. No Unix o diretório fica `0700` e o arquivo `0600`.

`delete_session` e a varredura de TTL apagam as linhas daquela sessão, a pasta `bodies/` correspondente e os exports cujo nome contém o hash de 8 hex SHA-1 da `vmUri`.

## Fluxo típico

```text
app em debug (imprime URI da VM)
        │
        ▼
list_sessions  ← ou attach_vm(uri) se a descoberta DTD não pegou
        │
        ▼
list_requests(vmUri)   → resumo + sizes (sem body, sem headers)
        │
        ▼
get_request(...)       → headers, isolate, sizes, body se couber no teto
        │
        ▼
export_har / export_devtools_json
```

1. Suba o app em debug (não-web se for usar o profiler `dart:io`).
2. A descoberta interna lê DTD / `~/.dart-tool` a cada 2s e anexa URIs novas. Se precisar, chame `attach_vm` com a URI do console (`http://…` ou `ws://…/ws`).
3. Consulte com `list_requests` / `get_request`.
4. Exporte HAR 1.2 ou o snapshot offline do DevTools.

Hot reload mantém a mesma `vmUri`. Hot restart na mesma VM mantém a chave e as linhas antigas; requests de abertura entram de novo com `startTime` novo.

Quando o app para, a sessão só vira `history` **depois que o socket da VM fecha** (Runner/DDS podem ficar ouvindo um tempo após o `stop` do `flutter run`).

## Sessões `live` e `history`

| Estado | Significado |
|---|---|
| `live` | Socket conectado; poll a cada 1s |
| `history` | Socket caiu; log permanece no SQLite |

- Tools de tráfego exigem `includeHistory=true` em sessão `history`. Sem a flag: `history_requires_flag` **sem** chave `requests`.
- `includeHistory=true` em sessão `live` é ignorado.
- `list_sessions` com default `live`, sem live e com history, inclui `historyHint.vmUris` (até 5, mais recentes primeiro).

## Tools

Todas as respostas de sucesso são JSON. Operações de sessão incluem `vmUri` e `state` quando aplicável. Erros: `{ "error": { "code", "message", "vmUri?" } }`.

O banco usa snake_case; o JSON das tools usa camelCase.

`includeHistory=true` numa sessão `live` continua ignorado: a resposta fica `live` e só entra tráfego ao vivo. Sessão `history` sem a flag responde `history_requires_flag` e não inclui requests. Profiler HTTP indisponível responde `http_profile_unavailable` em `list_requests`, `get_request` e nos exports.

### `list_sessions`

**Parâmetros:** `state` — `live` (default), `history` ou `all`.

```json
{
  "sessions": [
    {
      "vmUri": "ws://127.0.0.1:55530/tok=/ws",
      "state": "live",
      "appName": "dart_network_mcp_example",
      "httpProfileAvailable": true
    }
  ],
  "historyHint": { "vmUris": ["ws://…"] }
}
```

`historyHint` só aparece no default `live` quando a lista live está vazia e existe history.

```mermaid
classDiagram
  class ListSessionsInput {
    +string state
  }
  class SessionSummary {
    +string vmUri
    +string state
    +string appName
    +bool httpProfileAvailable
  }
  class ListSessionsOutput {
    +SessionSummary sessions
    +string historyHint.vmUris
  }
  ListSessionsInput --> SessionSummary : filtra sessions
  SessionSummary --> ListSessionsOutput
```

```mermaid
flowchart TB
  subgraph entrada [Entrada]
    e1["state: live por padrão, history ou all"]
  end
  subgraph tratamento [Tratamento]
    t1["lê só a tabela sessions"]
    t2{"state live e a lista está vazia e existe history?"}
    t3["historyHint com até 5 vmUri por disconnectedAt"]
  end
  subgraph saida [Saída]
    s1["sessions: vmUri, state, appName, httpProfileAvailable"]
    s2["historyHint só nesse caso"]
  end
  e1 --> t1 --> t2
  t2 -->|sim| t3 --> s2
  t1 --> s1
```

### `get_session`

**Parâmetros:** `vmUri`.

```json
{
  "vmUri": "ws://…",
  "appName": "dart_network_mcp_example",
  "isolates": ["isolates/…"],
  "state": "history",
  "disconnectReason": "socket closed",
  "httpProfileAvailable": true
}
```

```mermaid
classDiagram
  class GetSessionInput {
    +string vmUri
  }
  class SessionDetail {
    +string vmUri
    +string appName
    +string isolates
    +string state
    +string disconnectReason
    +bool httpProfileAvailable
  }
  GetSessionInput --> SessionDetail : uma linha
```

```mermaid
flowchart TB
  subgraph entrada [Entrada]
    e1["vmUri"]
  end
  subgraph tratamento [Tratamento]
    t1["canonicaliza a chave"]
    t2{"linha existe?"}
    t3["vm_not_found"]
    t4["monta o detalhe"]
  end
  subgraph saida [Saída]
    s1["vmUri, appName, isolates, state, disconnectReason, httpProfileAvailable"]
  end
  e1 --> t1 --> t2
  t2 -->|não| t3
  t2 -->|sim| t4 --> s1
```

### `attach_vm`

**Parâmetros:** `uri` (HTTP ou WebSocket do console).

Sucesso:

```json
{
  "vmUri": "ws://127.0.0.1:55530/tok=/ws",
  "state": "live",
  "appName": "main",
  "httpProfileAvailable": true
}
```

- Sessão `live` já existente: devolve a sessão sem segundo socket.
- Sessão `history` cujo socket volta: passa a `live` e mantém as linhas.
- Falha de conexão: `attach_failed` (não cria linha).

Dentro do container, host loopback na URI vira `host.docker.internal` **só no socket**; a chave canônica continua com `127.0.0.1` / `localhost`.

```mermaid
classDiagram
  class AttachInput {
    +string uri
  }
  class Session {
    +string vmUri
    +string state
    +string appName
    +bool httpProfileAvailable
  }
  class AttachOutput {
    +string vmUri
    +string state
    +string appName
    +bool httpProfileAvailable
  }
  AttachInput --> Session : cria ou reabre
  Session --> AttachOutput
```

```mermaid
flowchart TB
  subgraph entrada [Entrada]
    e1["uri do console, HTTP ou WebSocket"]
  end
  subgraph tratamento [Tratamento]
    t1["canonicaliza a chave vmUri"]
    t2["loopback no container só muda o socket"]
    t3{"já existe sessão live?"}
    t4["devolve a sessão, sem segundo socket"]
    t5["conecta, getVM, nome do pacote em package:"]
    t6["grava sessions como live"]
    t7["falha de socket: attach_failed, sem linha nova"]
  end
  subgraph saida [Saída]
    s1["vmUri, state, appName, httpProfileAvailable"]
  end
  e1 --> t1 --> t2 --> t3
  t3 -->|sim| t4 --> s1
  t3 -->|não| t5 --> t6 --> s1
  t5 -.-> t7
```

### `list_requests`

**Parâmetros:** `vmUri`, `includeHistory` (default `false`), `limit` (default 50, máx 200), `offset` (default 0), `method`, `status`, `urlContains`.

```json
{
  "vmUri": "ws://…",
  "state": "live",
  "requests": [
    {
      "requestId": "1",
      "startTime": 1790648106314927,
      "method": "GET",
      "uri": "https://jsonplaceholder.typicode.com/posts/1",
      "statusCode": 200,
      "durationMs": 120,
      "requestBodySize": 0,
      "responseBodySize": 292,
      "bodyUnavailable": false
    }
  ]
}
```

Não inclui headers, body nem path. A listagem não abre `headers.json` nem os arquivos de body. `requestBodySize`, `responseBodySize` e `bodyUnavailable` entram sempre; os sizes usam 0 quando não há bytes. `durationMs` fica de fora quando não há `endTime`. `error` fica de fora quando é nulo.

```mermaid
classDiagram
  class ListRequestsInput {
    +string vmUri
    +bool includeHistory
    +int limit
    +int offset
    +string method
    +int status
    +string urlContains
  }
  class Request {
    +string method
    +string uri
    +int statusCode
    +int startTime
    +int endTime
    +int requestBodySize
    +int responseBodySize
    +bool bodyUnavailable
    +string error
  }
  class RequestListItem {
    +string requestId
    +int startTime
    +string method
    +string uri
    +int statusCode
    +int durationMs
    +int requestBodySize
    +int responseBodySize
    +bool bodyUnavailable
    +string error
  }
  class ListRequestsOutput {
    +string vmUri
    +string state
    +RequestListItem requests
  }
  ListRequestsInput --> Request : lê colunas
  Request --> RequestListItem : não abre arquivo
  RequestListItem --> ListRequestsOutput
```

```mermaid
flowchart TB
  subgraph entrada [Entrada]
    e1["vmUri"]
    e2["includeHistory padrão false"]
    e3["limit padrão 50, máximo 200, offset"]
    e4["method, status, urlContains opcionais"]
  end
  subgraph tratamento [Tratamento]
    t1["canonicaliza vmUri"]
    t2{"sessão history sem includeHistory?"}
    t3["history_requires_flag, sem requests"]
    t4{"profiler HTTP indisponível?"}
    t5["http_profile_unavailable"]
    t6["SELECT das colunas, ordena por startTime"]
    t7["não abre headers.json nem os bodies"]
    t8["durationMs só quando endTime existe"]
  end
  subgraph saida [Saída]
    s1["vmUri, state, requests"]
    s2["cada item: id, startTime, method, uri, status, durationMs, sizes, bodyUnavailable, error"]
    s3["sem header, sem body, sem path"]
  end
  e1 --> e2 --> e3 --> e4 --> t1 --> t2
  t2 -->|sim| t3
  t2 -->|não| t4
  t4 -->|sim| t5
  t4 -->|não| t6 --> t7 --> t8 --> s1 --> s2 --> s3
```

### `get_request`

**Parâmetros:** `vmUri`, `requestId`, `startTime` (opcional), `includeHistory`.

```json
{
  "vmUri": "ws://…",
  "state": "live",
  "request": {
    "requestId": "1",
    "isolateId": "isolates/…",
    "method": "GET",
    "uri": "https://…",
    "startTime": 1790648106314927,
    "endTime": 1790648106434927,
    "statusCode": 200,
    "reasonPhrase": "OK",
    "requestHeaders": {},
    "responseHeaders": {},
    "requestBodySize": 0,
    "responseBodySize": 292,
    "bodyUnavailable": false,
    "responseBody": { "id": 1 },
    "responseBodyEncoding": "json"
  }
}
```

Sem `startTime` e com mais de uma linha para o mesmo `requestId`: `ambiguous_request` com `error.startTimes`, sem abrir arquivo e sem bodies.

O teto da resposta de sucesso é **100000 caracteres** do `jsonEncode` do objeto. Enquanto passar desse comprimento, omite nesta ordem:

1. `responseBody` e `responseBodyEncoding`
2. `requestBody` e `requestBodyEncoding`
3. `requestHeaders` e `responseHeaders`

Cada omissão coloca o path daquele arquivo e tira o valor inline. Path de um campo só aparece quando esse campo foi omitido. Os sizes e o metadado da linha permanecem.

```mermaid
classDiagram
  class GetRequestInput {
    +string vmUri
    +string requestId
    +int startTime
    +bool includeHistory
  }
  class Request {
    +string isolateId
    +string reasonPhrase
    +int endTime
    +string headersPath
    +string requestBodyPath
    +string responseBodyPath
  }
  class HeadersFile {
    +map requestHeaders
    +map responseHeaders
  }
  class BodyFile {
    +bytes conteudoIntegral
  }
  class RequestDetail {
    +string requestId
    +string isolateId
    +string method
    +string uri
    +int startTime
    +int endTime
    +int statusCode
    +string reasonPhrase
    +map requestHeaders
    +map responseHeaders
    +any requestBody
    +string requestBodyEncoding
    +any responseBody
    +string responseBodyEncoding
    +int requestBodySize
    +int responseBodySize
    +bool bodyUnavailable
    +string error
    +string headersPath
    +string requestBodyPath
    +string responseBodyPath
  }
  GetRequestInput --> Request
  Request --> HeadersFile : lê
  Request --> BodyFile : lê
  HeadersFile --> RequestDetail
  BodyFile --> RequestDetail
```

```mermaid
flowchart TB
  subgraph entrada [Entrada]
    e1["vmUri e requestId"]
    e2["startTime opcional"]
    e3["includeHistory"]
  end
  subgraph tratamento [Tratamento]
    t1["mesma guarda de history e de profiler"]
    t2{"mais de uma linha e startTime ausente?"}
    t3["ambiguous_request com startTimes, sem arquivo"]
    t4["abre headers.json"]
    t5["abre request.body e response.body se o path existe"]
    t6["decode: json, senão utf8, senão base64"]
    t7{"jsonEncode passa de 100000 caracteres?"}
    t8["tira o campo grande e deixa path e size"]
  end
  subgraph saida [Saída]
    s1["vmUri, state, request"]
    s2["metadado da linha sempre"]
    s3["headers e bodies quando cabem"]
    s4["path e size quando não cabem"]
  end
  e1 --> e2 --> e3 --> t1 --> t2
  t2 -->|sim| t3
  t2 -->|não| t4 --> t5 --> t6 --> t7
  t7 -->|sim| t8 --> s4
  t7 -->|não| s3
  t6 --> s1 --> s2
```

### `export_har` / `export_devtools_json`

**Parâmetros:** `vmUri`, `includeHistory`.

```json
{
  "path": "/data/exports/dart_network_mcp_20260929T021600_8ff87291.har",
  "requestCount": 217,
  "bytes": 48012,
  "vmUri": "ws://…",
  "state": "history"
}
```

Arquivo no host: `<dataDir>/exports/dart_network_mcp_<yyyyMMddTHHmmss>_<8 hex SHA-1 de vmUri>.har` ou `.json`. Timestamp local. Zero requests ainda gera arquivo válido. O arquivo é escrito request por request; o processo não acumula todos os bodies num único documento em memória.

No snapshot DevTools, `connectedApp.isFlutterApp` só é true com sessão **live** que registrue `ext.flutter.*`. Em history pura fica `false`.

```mermaid
classDiagram
  class ExportInput {
    +string vmUri
    +bool includeHistory
  }
  class Request
  class HeadersFile
  class BodyFile
  class ExportFile {
    +string path
    +int bytes
  }
  class ExportOutput {
    +string path
    +int requestCount
    +int bytes
    +string vmUri
    +string state
  }
  ExportInput --> Request : todas as linhas do ws
  Request --> HeadersFile
  Request --> BodyFile
  HeadersFile --> ExportFile : monta na hora
  BodyFile --> ExportFile
  ExportFile --> ExportOutput
```

```mermaid
flowchart TB
  subgraph entrada [Entrada]
    e1["vmUri e includeHistory"]
  end
  subgraph tratamento [Tratamento]
    t1["mesma guarda de history e de profiler"]
    t2["lê cada linha e os três arquivos"]
    t3["HAR 1.2: body em texto ou base64 dentro do arquivo"]
    t4["DevTools: objeto request montado das colunas e dos arquivos"]
    t5["grava exports um request por vez"]
  end
  subgraph saida [Saída]
    s1["path, requestCount, bytes, vmUri, state"]
    s2["zero requests ainda gera arquivo válido"]
  end
  e1 --> t1 --> t2 --> t3 --> t5 --> s1
  t2 --> t4 --> t5
  t5 --> s2
```

### `delete_session`

**Parâmetros:** `vmUri`.

```json
{
  "vmUri": "ws://…",
  "state": "history",
  "deleted": true
}
```

Desconecta se `live`, apaga a linha e o tráfego no SQLite, a pasta `bodies/` daquela `vmUri` e os exports dessa sessão (`_<8 hex SHA-1 de vmUri>.har` ou `.json`). A varredura de TTL faz o mesmo recorte para sessões `history` cujo `disconnectedAt` passou do prazo.

```mermaid
classDiagram
  class DeleteInput {
    +string vmUri
  }
  class Session
  class Request
  class HeadersFile
  class BodyFile
  class ExportFile
  class DeleteOutput {
    +string vmUri
    +string state
    +bool deleted
  }
  DeleteInput --> Session : apaga
  Session --> Request : cascade
  Request --> HeadersFile : apaga a pasta
  Request --> BodyFile : apaga a pasta
  DeleteInput --> ExportFile : apaga os desta vmUri
  Session --> DeleteOutput
```

```mermaid
flowchart TB
  subgraph entrada [Entrada]
    e1["vmUri"]
  end
  subgraph tratamento [Tratamento]
    t1["canonicaliza"]
    t2{"não existe?"}
    t3["vm_not_found"]
    t4{"state live?"}
    t5["desconecta o socket"]
    t6["apaga a linha e as requests"]
    t7["apaga bodies/sha256 dessa vmUri"]
    t8["apaga exports cujo hash de 8 hex é dessa vmUri"]
  end
  subgraph saida [Saída]
    s1["vmUri, state de antes, deleted true"]
  end
  e1 --> t1 --> t2
  t2 -->|sim| t3
  t2 -->|não| t4
  t4 -->|sim| t5 --> t6
  t4 -->|não| t6
  t6 --> t7 --> t8 --> s1
```

### `get_retention` / `set_retention`

**Parâmetros:** `get_retention` não recebe argumento. `set_retention` recebe `days` (inteiro ≥ 1).

```json
{ "retentionDays": 90 }
```

Banco novo usa 90 dias. `days` menor que 1, ausente ou de outro tipo: `invalid_params`. `get_retention` não dispara varredura. `set_retention` válido grava e varre uma vez. A varredura também roda na subida do processo e a cada 60 minutos.

Sessão `live` não é apagada. Sessão `history` é apagada quando `disconnectedAt` não é nulo e a idade até o relógio é maior ou igual a `days`. Junto saem as requests, a pasta `bodies/` e os exports daquela sessão.

```mermaid
classDiagram
  class SetRetentionInput {
    +int days
  }
  class Retention {
    +int retentionDays
  }
  class RetentionOutput {
    +int retentionDays
  }
  class Session {
    +string state
    +int disconnectedAt
  }
  SetRetentionInput --> Retention : grava se days maior ou igual a 1
  Retention --> RetentionOutput
  Retention --> Session : varre history
```

```mermaid
flowchart TB
  subgraph entrada [Entrada]
    e1["get_retention sem argumento"]
    e2["set_retention com days"]
  end
  subgraph tratamento [Tratamento]
    t1{"days inteiro e maior ou igual a 1?"}
    t2["invalid_params"]
    t3["grava retentionDays, padrão 90"]
    t4["varre agora, na subida e a cada hora"]
    t5{"history e disconnectedAt passou do prazo?"}
    t6["apaga linhas, pasta bodies e exports"]
    t7["sessão live não entra no prazo"]
  end
  subgraph saida [Saída]
    s1["retentionDays"]
  end
  e1 --> s1
  e2 --> t1
  t1 -->|não| t2
  t1 -->|sim| t3 --> t4
  t4 --> t5
  t5 -->|sim| t6
  t5 -->|não| t7
  t3 --> s1
```

## Decode de body

Companions: `requestBodyEncoding` e `responseBodyEncoding`.

| Encoding | Quando |
|---|---|
| `json` | UTF-8 que `jsonDecode` aceita → valor JSON (objeto, array, número, bool, null) |
| `utf8` | Texto UTF-8 que não é JSON (inclui JSON truncado no meio) |
| `base64` | Bytes que não são UTF-8 válido |

Não há corte de body na gravação: o arquivo guarda os bytes inteiros. O teto de **100000 caracteres** aplica-se só ao JSON de `get_request`, com a ordem de omissão acima. HAR / DevTools JSON **não** usam esses companions: body fica texto ou base64 no formato do arquivo. O `dart:io` já entrega body descomprimido — não há gunzip extra.

## Erros

| `error.code` | Situação |
|---|---|
| `vm_not_found` | `vmUri` desconhecida |
| `request_not_found` | request ausente |
| `ambiguous_request` | vários `startTime` sem parâmetro |
| `attach_failed` | socket não conectou |
| `history_requires_flag` | sessão `history` sem `includeHistory` |
| `http_profile_unavailable` | VM sem profiler `dart:io` (ex.: alguns alvos web) |
| `sqlite_busy` | lock SQLite após `busy_timeout` 5s |
| `invalid_params` | argumento inválido/ausente no entrypoint stdio |

## App exemplo

```bash
cd example
flutter devices
flutter run -d <id>   # iOS, Android ou desktop — não web para o profiler
```

- `main` liga `HttpClient.enableTimelineLogging` **antes** do `runApp`.
- Abertura: `GET /posts/1`, `/users/1`, `/albums/1` em paralelo contra `https://jsonplaceholder.typicode.com`.
- A cada 5s: lote `POST`/`PUT`/`PATCH` ou `DELETE` + dois GETs.
- Pausar na UI segura o lote seguinte.

Copie a URI impressa, use `attach_vm` se necessário, e confira com `list_requests`.

## Referências

- Overview: [README.md](../README.md)
- Design / contrato: [.docs/superpowers/specs/2026-09-28-dart-vm-network-mcp-design.md](../.docs/superpowers/specs/2026-09-28-dart-vm-network-mcp-design.md)
- Armazenamento e tools: [.docs/superpowers/specs/2026-09-29-traffic-storage-performance-design.md](../.docs/superpowers/specs/2026-09-29-traffic-storage-performance-design.md)
