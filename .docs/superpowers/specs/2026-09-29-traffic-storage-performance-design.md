# Armazenamento do tráfego: performance com retenção integral

Data: 2026-09-29.

O MCP guarda header e body por inteiro, de qualquer tamanho, e as tools continuam respondendo rápido quando o volume é o de um checkout com centenas de produtos. O SQLite fica com as colunas curtas. O conteúdo grande fica em arquivo. O prazo apaga o ws inteiro. O padrão é 90 dias e o usuário muda esse número.

Fora desta spec: tool de grafo, índice vetorial e RAG. A descoberta da VM, a chave `vmUri` e o formato HAR 1.2 permanecem. Muda de onde o export lê o body.

## Modelo gravado

```mermaid
classDiagram
  class Session {
    +string vmUri
    +string state
    +string appName
    +string isolateIds
    +int startedAt
    +int disconnectedAt
    +string disconnectReason
    +bool httpProfileAvailable
  }
  class Request {
    +string vmUri
    +string requestId
    +int startTime
    +string isolateId
    +string method
    +string uri
    +int endTime
    +int statusCode
    +string reasonPhrase
    +int requestBodySize
    +int responseBodySize
    +bool bodyUnavailable
    +string error
    +string requestBodyPath
    +string responseBodyPath
    +string headersPath
  }
  class HeadersFile {
    +map requestHeaders
    +map responseHeaders
  }
  class BodyFile {
    +bytes conteudoIntegral
  }
  class Retention {
    +int retentionDays
  }
  Session "1" --> "*" Request : vmUri
  Request "1" --> "1" HeadersFile : headers.json
  Request "1" --> "0..1" BodyFile : request.body
  Request "1" --> "0..1" BodyFile : response.body
```

A pasta da sessão é `<dataDir>/bodies/<sha256 hex do vmUri canônico em UTF-8>/`.

O nome de cada arquivo, dentro dessa pasta, é `{startTime}_{sha256 hex do requestId em UTF-8}` com sufixo `.request.body`, `.response.body` ou `.headers.json`.

`headers.json` é um objeto com `requestHeaders` e `responseHeaders`. Os valores são string. Header vazio ainda gera o arquivo, com os dois mapas vazios.

Body entregue pela VM, inclusive com tamanho 0, gera arquivo. A linha guarda o path absoluto no processo do servidor e o tamanho. Body que a VM não entregou não gera arquivo: path nulo, `bodyUnavailable` verdadeiro.

Não há coluna de bytes, nem `raw_json`, nem corte em 1 MB. `requestBodyPath` e `responseBodyPath` ficam nulos quando o arquivo não existe. `headersPath` existe para toda request gravada.

Os paths devolvidos nas tools são os paths absolutos do processo do servidor. No container, isso é debaixo de `/data`, o volume do diretório de dados do host. O hash de 8 hex no nome do export continua sendo SHA-1 de `vmUri`, como hoje. A pasta `bodies/` usa SHA-256. São hashes diferentes de propósito.

## Gravação do poll

```mermaid
flowchart TB
  subgraph entrada [Entrada]
    e1["HttpProfile da VM"]
    e2["method, uri, status, tempos"]
    e3["headers e bodies completos"]
  end
  subgraph tratamento [Tratamento]
    t1["chave = vmUri + requestId + startTime"]
    t2["grava headers.json sempre, mesmo vazio"]
    t3["grava request.body e response.body só se a VM entregou os bytes"]
    t4["sem bytes: sem arquivo, bodyUnavailable, path vazio"]
    t5["upsert da linha com sizes e caminhos"]
    t6["mesma chave reescreve os arquivos, não duplica"]
    t7{"isolate sem request em voo?"}
    t8["clearHttpProfile"]
    t9["não limpa: request em voo seria ignorada pela VM"]
  end
  subgraph saida [Saída]
    s1["linha curta no SQLite"]
    s2["três arquivos em bodies/sha256 da vmUri"]
  end
  e1 --> e2 --> e3 --> t1 --> t2 --> t3 --> t4 --> t5 --> t6 --> t7
  t7 -->|sim| t8 --> s1
  t7 -->|não| t9 --> s1
  t5 --> s2
```

`clearHttpProfile` é por isolate, depois de persistir as requests já terminadas daquele poll. Se alguma request do perfil daquele isolate está sem `endTime`, o clear não roda.

`list_requests`, a varredura de TTL e a listagem de sessões não abrem arquivo de body nem de header.

## Retenção

Tabela `retention` com uma linha, coluna `days`, inserida com 90 na criação do banco.

`get_retention` não recebe argumento e devolve `{ "retentionDays": <days> }`.

`set_retention` recebe `days`. Inteiro menor que 1, ausente ou de outro tipo: `invalid_params`. Valor válido grava a linha e roda uma varredura na hora.

A varredura também roda na subida do processo e a cada 60 minutos. O relógio é injetável nos testes.

Sessão `live` não é apagada. Sessão `history` é apagada quando `disconnectedAt` não é nulo e a idade até o relógio é maior ou igual a `days`. A idade usa microssegundos. Junto saem as requests, a pasta `bodies/<sha256>/` e os exports cujo nome contém `_<8 hex SHA-1 de vmUri>.har` ou `.json`.

`disconnectedAt` nulo não é apagado pela varredura.

## Migração

Na abertura do banco, se existirem colunas de body, header ou `raw_json`, cada linha vira arquivos com os bytes e os mapas que já estão gravados. Em seguida a tabela `requests` é recriada no formato desta spec. Conteúdo que já tinha sido cortado em 1 MB continua cortado, porque esses bytes não estão mais no banco. A coluna de truncamento não permanece.

## Tools

`includeHistory=true` numa sessão `live` continua ignorado: a resposta fica `live` e só entra tráfego ao vivo. Sessão `history` sem a flag responde `history_requires_flag` e não inclui requests. Profiler HTTP indisponível responde `http_profile_unavailable` em `list_requests`, `get_request` e nos exports.

### attach_vm

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

### list_sessions

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

### get_session

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

### list_requests

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

`requestBodySize`, `responseBodySize` e `bodyUnavailable` entram sempre. `requestBodySize` e `responseBodySize` usam 0 quando não há bytes. `durationMs` fica de fora quando não há `endTime`. `error` fica de fora quando é nulo.

### get_request

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

O limite é o comprimento de `jsonEncode` do objeto de sucesso. Enquanto passar de 100000 caracteres, omite nesta ordem: `responseBody` e `responseBodyEncoding`, depois `requestBody` e `requestBodyEncoding`, depois `requestHeaders` e `responseHeaders`. Cada omissão coloca o path daquele arquivo e tira o valor inline. Path de um campo só aparece quando esse campo foi omitido. Os sizes permanecem. O metadado da linha permanece. `ambiguous_request` não abre arquivo. O decode de body que cabe na resposta segue a regra atual: JSON, senão UTF-8, senão base64.

### export_har e export_devtools_json

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

O arquivo de export é escrito request por request. O processo não acumula todos os bodies num único documento em memória. O nome do arquivo permanece `dart_network_mcp_<yyyyMMddTHHmmss>_<8 hex SHA-1>.har` ou `.json`.

### delete_session

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

### get_retention e set_retention

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

`get_retention` não dispara varredura. `set_retention` válido grava e varre uma vez.

## Testes

Caixa-preta, com relógio injetado na varredura.

- Body pequeno, body vazio e body maior que 1 MB vão para arquivo, inteiros. A linha não contém esses bytes e não tem `raw_json`.
- Header vazio gera `headers.json` com os dois mapas vazios. Body ausente não gera arquivo, marca `bodyUnavailable` e deixa o path nulo.
- A mesma chave reescreve os arquivos e permanece uma linha.
- `list_requests` devolve os sizes e não devolve header, body nem path. A implementação de leitura da listagem falha o teste se abrir arquivo de body ou de header.
- `get_request` devolve header e body decodificados quando o JSON cabe. Quando não cabe, omite na ordem definida e devolve path e size.
- `ambiguous_request` não abre arquivo.
- HAR e DevTools são montados das colunas e dos arquivos, com o body inteiro no export, sem juntar todos os bodies num único buffer.
- `delete_session` apaga linhas, a pasta `bodies/` daquele ws e os exports dele.
- `set_retention` com `days` menor que 1 responde `invalid_params`. Banco novo tem 90.
- Sessão `live` sobrevive ao TTL. Sessão `history` além do prazo perde linhas, pasta e exports. Dentro do prazo, fica.
- `clearHttpProfile` só ocorre sem request em voo. Com request em voo, o perfil fica e o término dela ainda é gravado.
- Migração: linha antiga com body na coluna vira arquivo e a coluna de bytes some.

## Documentação

`docs/mcp.md` passa a documentar cada tool com o diagrama de classes e o fluxo de entrada, tratamento e saída desta spec, no lugar de uma tabela única como descrição do armazenamento. O README acompanha as tools novas e o fato de `list_requests` não devolver body. O plano de implementação repete estes diagramas.
