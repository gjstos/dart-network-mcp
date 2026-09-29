# Dart VM Network MCP

Servidor MCP que anexa em VMs Dart já em execução e expõe o tráfego HTTP da aba Network do DevTools. Várias VMs convivem no mesmo processo, cada uma na sua chave. Quando o app cai, o log daquela URI continua consultável.

Data: 2026-09-28.

## Objetivo

O agente consulta as requests e responses que um app Flutter ou Dart em debug fez enquanto a VM estava conectada, inclusive depois do crash da run. O alvo do app não muda o caminho: iOS, Android, desktop e qualquer outro debug que publique uma URI da VM Service entram pela mesma chave. O export segue os dois formatos da aba Network: HAR 1.2 e o JSON offline que o DevTools reimporta.

## Fora de escopo

A v1 não expõe eval, heap, timeline, inspector, logging, socket profile nem WebSocket profile. Não chama `clearHttpProfile` na VM. Não redacta headers nem bodies.

## Arquitetura

Um processo Dart, imagem `dart-network-mcp:local`, sobe pelo Docker MCP Toolkit com `longLived: true`. O processo guarda N sessões. A biblioteca de protocolo é `package:vm_service`. A descoberta usa `package:dtd`. O log fica em SQLite (`package:sqlite3`), modo WAL, no host.

A URI que o tooling imprime no console é a identidade da sessão. Simulador iOS, aparelho iOS, emulador Android, aparelho Android e desktop produzem essa URI. O servidor não ramifica por sistema operacional do app nem do host.

## Sessão e armazenamento

Diretório de dados: `$DART_NETWORK_MCP_DATA` quando essa variável existe. Sem ela, `%LOCALAPPDATA%\dart-network-mcp` quando `LOCALAPPDATA` existe, e `~/.local/share/dart-network-mcp` nos outros hosts. No container, `DART_NETWORK_MCP_DATA=/data`. O SQLite é `network.sqlite` nesse diretório. O subdiretório `exports/` fica no mesmo lugar. No Unix o diretório fica `0700` e o arquivo `0600`. No Windows o install restringe o ACL do diretório ao usuário atual.

### Chave

A chave primária `vm_uri` é a URI WebSocket canônica.

Algoritmo:

1. Parse da URI recebida.
2. `http` vira `ws`. `https` vira `wss`.
3. Se o path não termina em `/ws`, acrescenta o segmento `ws`.
4. Remove barra final.
5. Host e porta permanecem como no console. `127.0.0.1` não vira `host.docker.internal` na chave.

`http://127.0.0.1:62080/06-FZCo24xM=/` e `ws://127.0.0.1:62080/06-FZCo24xM=/ws` são a mesma chave. Cada `flutter run` gera porta e token novos, portanto outra chave. Reconnect na mesma URI reabre a mesma linha e continua o log.

Dentro do container (`DART_NETWORK_MCP_IN_DOCKER=1`), host loopback na URI (`127.0.0.1`, `localhost`, `::1`) vira `host.docker.internal` só no socket, com a mesma porta, path e esquema. Qualquer outro host, inclusive IP de aparelho na rede, é discado como está na chave. Fora do container, conecta na URI canônica. O install garante que `host.docker.internal` resolva dentro do container: no Docker Desktop isso já ocorre. No Docker Engine em que o nome não resolve, a entrada do servidor leva `extraHosts: ["host.docker.internal:host-gateway"]`.

### Tabelas

`sessions`

| Coluna | Tipo | Regra |
|---|---|---|
| `vm_uri` | TEXT | PK |
| `state` | TEXT | `live` ou `history` |
| `app_name` | TEXT | nome do pacote em `package:<nome>/...` no `rootLib.uri` do isolate. Sem essa URI, cai no `name` do isolate (`main`) |
| `isolate_ids` | TEXT | JSON array |
| `started_at` | INTEGER | micros desde epoch |
| `disconnected_at` | INTEGER | nulo enquanto `live` |
| `disconnect_reason` | TEXT | nulo enquanto `live` |
| `http_profile_available` | INTEGER | 0 ou 1 |

`requests`

| Coluna | Tipo | Regra |
|---|---|---|
| `vm_uri` | TEXT | FK, `ON DELETE CASCADE` |
| `request_id` | TEXT | id do `HttpProfileRequest` |
| `isolate_id` | TEXT | |
| `method` | TEXT | |
| `uri` | TEXT | URL da request |
| `start_time` | INTEGER | micros desde epoch |
| `end_time` | INTEGER | nulo se em voo |
| `status_code` | INTEGER | nulo se ainda sem response |
| `reason_phrase` | TEXT | |
| `request_headers` | TEXT | JSON |
| `response_headers` | TEXT | JSON |
| `request_body` | BLOB | |
| `response_body` | BLOB | |
| `request_body_size` | INTEGER | tamanho original |
| `response_body_size` | INTEGER | tamanho original |
| `request_body_truncated` | INTEGER | 0 ou 1 |
| `response_body_truncated` | INTEGER | 0 ou 1 |
| `body_unavailable` | INTEGER | 0 ou 1 |
| `error` | TEXT | |
| `raw_json` | TEXT | `HttpProfileRequest` completo |

PK de `requests`: `(vm_uri, request_id, start_time)`.

Um `request_id` repetido com outro `start_time` é outra linha. Hot restart que recicle ids não apaga o log anterior. Atualização de request em voo casa as três colunas. `start_time` não muda no meio da request.

Não há consulta sem `vm_uri`. Nenhuma tool junta linhas de duas chaves.

### Ciclo de vida

O attach grava a sessão só depois de `getVM` suceder. Attach repetido numa sessão `live` devolve a sessão existente. Attach numa chave `history` cujo socket volta a aceitar conexão passa a `live` e mantém as linhas.

Queda de socket grava `disconnected_at`, `disconnect_reason` com a mensagem do socket e `state=history`. A cópia para. Na subida do processo, toda sessão `live` cujo socket não conecta passa a `history` com `disconnect_reason=process_restart`. Se a descoberta anunciar de novo a mesma URI e o socket conectar, ela volta a `live`.

`delete_session` desconecta se estiver `live` e apaga a linha. Os arquivos já exportados permanecem.

Não há expurgo automático.

## Descoberta e captura

> **Atualização (2026-09-29):** a descoberta em produção não depende mais só de `~/.dart-tool`. Ver [.docs/superpowers/specs/2026-09-29-dtd-discovery-docker-fix-design.md](2026-09-29-dtd-discovery-docker-fix-design.md) (dir moderno `…/Dart/dtd`, `wsUri`, multi-DTD, mount Docker, `socketUriFor` no DTD). O texto abaixo é o contrato original e ficou parcialmente supersedido nesse ponto.

A descoberta roda a cada 2 segundos, dentro do processo do servidor. O binário `dart` do host não é executado no container: no macOS e no Windows esse binário não roda na imagem Linux. O que o container lê é o `~/.dart-tool` do host, montado em `/home/mcp/.dart-tool`, com `HOME=/home/mcp`.

Ordem, parando na primeira URI de DTD que conectar:

1. Variável de ambiente `DTD_URI`.
2. Campo `uri` de `~/.dart-tool/dart-tooling-daemon.json` ou `~/.dart-tool/dtd.json`, se o arquivo existir.
3. Todo valor `ws://` ou `wss://` nas chaves `uri` e `dtdUri` de arquivos JSON diretamente em `~/.dart-tool` cujo nome contém `dtd` ou `tooling-daemon`.

Conectado ao DTD, chama `ConnectedApp.getVmServiceUris`. Se esse serviço não existir, chama `Editor.getDebugSessions` e, em cada sessão, usa o primeiro campo entre `vmServiceUri`, `vmServiceWsUri` e `uri` que parseie como URI HTTP ou WebSocket. Escuta o stream `ConnectedApp` pelos eventos `VmServiceRegistered` e `VmServiceUnregistered`.

URI nova recebe attach. `VmServiceUnregistered` tenta o socket. Socket morto marca `history`. DTD ausente deixa a descoberta ociosa. `attach_vm` continua válido. Falha de uma VM não altera as outras.

Em cada isolate, o servidor chama `ext.dart.io.httpEnableTimelineLogging` com `enabled=true` e passa a copiar `getHttpProfile` com `updatedSince`, a cada 1 segundo. Request que termina e cujo processo morre antes desse poll não entra no SQLite. Isolate novo entra na mesma sessão. Para cada request nova ou atualizada, chama `getHttpProfileRequest` e grava method, URL, status, tempos, headers e bodies. Body acima de 1_000_000 bytes é cortado. A linha guarda o tamanho original e `*_truncated=1`. Falha ao buscar um body marca `body_unavailable=1` e segue para as outras requests.

Se `isHttpProfilingAvailable` for falso, a sessão fica `live` com `http_profile_available=0`. As tools de tráfego dessa chave respondem `http_profile_unavailable`. Isso vale para qualquer alvo, inclusive Flutter web, em que a VM não tem o profiler de `dart:io`. A sessão continua existindo.

O servidor não chama `clearHttpProfile`.

## Tools

O SQLite usa snake_case. O JSON das tools usa camelCase.

Toda resposta de sucesso é JSON e inclui `vmUri` e `state` quando a operação é sobre uma sessão. Erro é JSON com `error.code`, `error.message` e, quando houver, `error.vmUri`. Argumentos inválidos no entrypoint stdio respondem `invalid_params`.

| Tool | Parâmetros | Comportamento |
|---|---|---|
| `list_sessions` | `state`: `live` (default), `history` ou `all` | Lista `sessions` com `vmUri`, `state`, `appName`, `httpProfileAvailable`. Com o default, se não houver `live` e houver `history`, inclui `historyHint.vmUris` com até 5 URIs ordenadas por `disconnectedAt` decrescente (o hint não inclui timestamps). |
| `get_session` | `vmUri` | `vmUri`, `appName`, `isolates`, `state`, `disconnectReason`, `httpProfileAvailable`. |
| `attach_vm` | `uri` | Attach manual (HTTP ou WebSocket). Sucesso: `vmUri`, `state`, `appName`, `httpProfileAvailable`. |
| `list_requests` | `vmUri`, `includeHistory` (default false), `limit` (default 50, máximo 200), `offset` (default 0), `method`, `status`, `urlContains` | Envelope `{ vmUri, state, requests }`. Página por `startTime` crescente. Cada item: `requestId`, `startTime`, `method`, `uri`, `statusCode`, `durationMs` quando há `endTime`, e bodies. `durationMs` é `(endTime - startTime) ~/ 1000`. `requestBody` só se não vazio. Flags `*Truncated`, `bodyUnavailable`, `error` e `*BodySize` só quando truncado ou mudam a leitura. Sem headers, isolate, `reasonPhrase`, `endTime`. Sessão `history` sem `includeHistory=true` responde `history_requires_flag` sem chave `requests`. |
| `get_request` | `vmUri`, `requestId`, `startTime` opcional, `includeHistory` | Envelope `{ vmUri, state, request }`. Em `request`: headers, `isolateId`, `reasonPhrase`, `endTime` se houver, `*BodySize` e flags booleanas sempre presentes, e body. Sem `startTime`, se houver mais de uma linha com o mesmo `requestId`, responde `ambiguous_request` com `error.startTimes` (micros) e sem bodies. Mesma regra de `includeHistory`. |
| `export_har` | `vmUri`, `includeHistory` | Escreve HAR e devolve `path`, `requestCount`, `bytes`, `vmUri`, `state`. |
| `export_devtools_json` | `vmUri`, `includeHistory` | Escreve o snapshot offline do DevTools e devolve os mesmos campos. |
| `delete_session` | `vmUri` | Desconecta se `live` e apaga a chave. Sucesso: `vmUri`, `state` (antes do delete), `deleted: true`. |

`includeHistory=true` numa sessão `live` é ignorado. A resposta continua `live`.

`list_requests` e `get_request` decodificam o body da mesma forma. JSON válido vira o valor com `requestBodyEncoding` / `responseBodyEncoding` = `json`. Texto UTF-8 que não é JSON, inclusive JSON cortado, fica string com `utf8`. Bytes que não são UTF-8 ficam base64 com `base64`. O `dart:io` já entrega o body descomprimido: não fazer gunzip.

HAR e o JSON do DevTools não aplicam esse decode. Lá o body continua texto UTF-8 ou base64 (byte nulo ou UTF-8 inválido → base64; JSON permanece texto em `text`).

`vmUri` desconhecida responde `vm_not_found` sem listar outras chaves. Request ausente responde `request_not_found`. Mais de uma linha para o mesmo `requestId` sem `startTime` responde `ambiguous_request`. Falha de conexão no attach responde `attach_failed`.

### HAR

Arquivo em `<diretório de dados>/exports/`, nome `dart_network_mcp_<yyyyMMddTHHmmss>_<8 hex SHA-1 de vmUri>.har`. Timestamp wall-clock local. O JSON usa o mesmo padrão com extensão `.json`.

Documento HAR 1.2:

```json
{
  "log": {
    "version": "1.2",
    "creator": { "name": "dart-network-mcp", "version": "<versão do pacote>" },
    "entries": []
  }
}
```

Cada entry usa a request gravada:

- `startedDateTime`: ISO-8601 de `start_time`
- `time`: duração em milissegundos, 0 se `end_time` for nulo
- `request.method`, `request.url`, `request.httpVersion` = `HTTP/1.1`
- `request.headers` no formato HAR `{ "name", "value" }`
- `request.queryString` extraído da URL
- `request.postData` presente quando há body. Texto em `text`, binário em `text` com `encoding=base64`
- `response.status`, `response.statusText`, `response.headers`, `response.content` com a mesma regra de texto ou base64
- `cache`: `{}`
- `timings.blocked`, `timings.dns`, `timings.connect` e `timings.ssl` = `-1`
- `timings.send`, `timings.wait` e `timings.receive` repartem `time`. Sem medição fina, `send=0`, `wait=time`, `receive=0`

Lista vazia gera o mesmo documento com `entries` vazio.

### JSON do DevTools

Arquivo no mesmo diretório, extensão `.json`. O documento é um snapshot que o importador do DevTools aceita (`devToolsSnapshot == true`):

```json
{
  "devToolsSnapshot": true,
  "devToolsVersion": "dart-network-mcp/<versão do pacote>",
  "activeScreenId": "network",
  "connectedApp": {
    "isFlutterApp": false,
    "isProfileBuild": false,
    "isDartWebApp": false,
    "isRunningOnDartVM": true
  },
  "network": {
    "httpRequestData": [],
    "selectedRequestId": null,
    "socketData": [],
    "webSocketData": [],
    "timelineMicrosOffset": 0
  }
}
```

`connectedApp.isFlutterApp` é true quando a VM live registra extensão com prefixo `ext.flutter`. Em sessão só `history` (sem `VmSession` live), o export usa `isFlutterApp: false`. Os arrays `socketData` e `webSocketData` ficam vazios. `selectedRequestId` é null. `timelineMicrosOffset` é 0.

Cada item de `httpRequestData` contém a chave `request` com o JSON do `HttpProfileRequest` guardado em `raw_json`, que é o campo que `DartIOHttpRequestData.fromJson` lê. Bodies truncados permanecem truncados nesse JSON.

## Erros operacionais

Códigos: `vm_not_found`, `request_not_found`, `ambiguous_request`, `attach_failed`, `history_requires_flag`, `http_profile_unavailable`, `sqlite_busy`, `invalid_params`.

SQLite usa WAL e `busy_timeout` de 5 segundos. Esgotado o timeout, a tool responde `sqlite_busy`.

Profiler indisponível não aparece como lista vazia. A tool de tráfego responde `http_profile_unavailable`.

## Docker e instalação

Entrada de catálogo: `~/.docker/mcp/catalogs/dart-network-mcp.yaml`.

Campos fixos da entrada: `name=dart-network-mcp`, `type=server`, `longLived=true`, `image=dart-network-mcp:local`. Em host Unix, `user` é `<uid>:<gid>` de quem rodou o install. Em Windows o campo `user` fica de fora. A imagem cria `/home/mcp` antes do mount. Sem `allowHosts` e sem `disableNetwork`. A porta da VM é efêmera.

O install resolve o home do usuário (`HOME` ou `USERPROFILE`) e grava paths absolutos. Volumes:

- `<home>/.dart-tool:/home/mcp/.dart-tool:ro`
- `<diretório de dados do host>:/data:rw`

Variáveis do container: `HOME=/home/mcp`, `DART_NETWORK_MCP_DATA=/data`, `DART_NETWORK_MCP_IN_DOCKER=1`. O processo lê o SQLite e os exports em `/data`. A descoberta lê `/home/mcp/.dart-tool`, que é o `~/.dart-tool` do host. O separador das allowlists de bind é o do sistema em que o install roda (`:` ou `;`).

O install cria o profile `dart-network-mcp` se ele não existir e adiciona só este servidor, por referência `file://` ao YAML do catálogo. Não remove outros profiles nem outros servidores.

`install.sh` exige ao menos uma flag. `--claude` e `--cursor` podem ir juntas. Rodar de novo só garante imagem, YAML, profile e a entrada do cliente.

A entrada do cliente se chama `dart-network-mcp` e não altera uma entrada `MCP_DOCKER` já existente.

```json
{
  "command": "docker",
  "args": [
    "run", "-i", "--rm",
    "--add-host=host.docker.internal:host-gateway",
    "-e", "HOME=/home/mcp",
    "-e", "DART_NETWORK_MCP_DATA=/data",
    "-e", "DART_NETWORK_MCP_IN_DOCKER=1",
    "-v", "<home>/.dart-tool:/home/mcp/.dart-tool:ro",
    "-v", "<diretório de dados>:/data:rw",
    "-u", "<uid>:<gid>",
    "dart-network-mcp:local"
  ]
}
```

Entrada via `docker run` stdio (não `docker mcp gateway`): o gateway do Toolkit no Docker Desktop falha ao usar `unix:///var/run/docker.sock` quando o socket real está em `~/.docker/run/docker.sock`, e também passa `-e HOME` do host para o container. A imagem usa `tool/docker_entrypoint.sh` para forçar `HOME=/home/mcp`, `DART_NETWORK_MCP_DATA=/data` e `DART_NETWORK_MCP_IN_DOCKER=1`.

`--claude` grava em `mcpServers` de `<home>/.claude.json`. `--cursor` grava em `mcpServers` de `<home>/.cursor/mcp.json`. No Windows `<home>` é `USERPROFILE`. As duas configurações coexistem. O mesmo install vale em macOS, Windows e Linux.

## README e app exemplo

`README.md` na raiz cobre o overview. O guia de uso das tools fica em `docs/mcp.md`.

`example/` é um app Flutter em debug, sem alvo fixo. `main` liga `HttpClient.enableTimelineLogging` antes do `runApp`: o profiler do `dart:io` só grava um request se o flag já estiver ativo quando ele começa. Usa `package:http` contra `https://jsonplaceholder.typicode.com`. Na abertura dispara em paralelo `GET /posts/1`, `GET /users/1` e `GET /albums/1`. Um `Timer.periodic` de 5 segundos dispara lotes de três calls em paralelo, alternando `POST`/`PUT`/`PATCH` em `/posts` e `DELETE /posts/1` com dois GETs. Pausar segura o lote seguinte. Hot reload preserva o `State` e o timer. Hot restart recria o `State`, dispara de novo a abertura e recomeça o timer.

## Testes

### Caixa-preta, sem device

Uma VM Service falsa sobre WebSocket cobre:

- duas `vm_uri` não compartilham requests
- a forma HTTP do console e a forma WebSocket gravam a mesma chave
- queda de socket preserva as linhas e muda `state` para `history`
- `list_requests` sem `includeHistory` numa sessão `history` devolve `history_requires_flag` sem chave `requests`
- `list_sessions` default, sem sessão `live` e com crash recente, devolve `historyHint.vmUris`
- reconnect na mesma URI e no mesmo `start_time` atualiza a linha. Outro `start_time` insere outra linha e preserva a anterior
- falha de conexão de uma VM não altera a outra
- body acima de 1_000_000 bytes fica truncado, com tamanho original
- profiler ausente devolve `http_profile_unavailable`
- `delete_session` remove só a chave pedida
- `export_har` valida `log.version`, `creator` e `entries` contra o mapeamento desta spec
- `export_devtools_json` valida `devToolsSnapshot`, `activeScreenId=network` e as chaves de `network` desta spec
- `appName` no attach é o nome do pacote em `package:<nome>/...`
- `list_requests` devolve JSON como valor com `responseBodyEncoding=json` (e o par `requestBodyEncoding` quando há request body), texto com `utf8` e binário com `base64`. JSON cortado fica string. O item não traz headers, isolate, `reasonPhrase` nem `endTime`. `durationMs` é a diferença dos tempos em microssegundos dividida por 1000
- `get_request` traz headers, isolate, tamanhos/flags sempre presentes e o mesmo decode de body
- body acima de 1_000_000 bytes que deixa de ser JSON válido continua string `utf8`, com `responseBodyTruncated` e o tamanho original
- `export_har` mantém o JSON do body como texto, sem companion `*BodyEncoding`

O script de install, com `HOME` temporário, cria o profile, o YAML e as duas entradas de cliente, e mantém uma `MCP_DOCKER` preexistente intacta.

### Aceitação ao vivo

Esta passagem usa o app exemplo de verdade e o servidor dentro do Docker, no profile `dart-network-mcp`. O MCP de Dart/Flutter só controla o app: `launch_app`, logs, `hot_reload`, `hot_restart` e `stop_app`.

1. Subir `example/` em debug num device disponível em `list_devices` (iOS, Android ou desktop) e ler a URI da VM no log. Os passos seguintes não mudam conforme o device.
2. Attach por essa URI no servidor dockerizado.
3. `list_requests` dessa chave mostra os três GETs de abertura, com `responseBody`.
4. Após um ciclo de 5 segundos, o lote seguinte (`POST`, `PUT` e `PATCH`, ou `DELETE` e GETs) aparece na mesma chave.
5. Hot reload mantém a mesma `vm_uri`. Após ~5s, um novo lote do timer entra na mesma chave.
6. Hot restart mantém a mesma VM. As linhas anteriores permanecem. As requests de abertura entram como linhas novas, com `start_time` novo.
7. Após o socket da VM fechar de fato (não basta o PID do `flutter run`), a sessão marca `history`. Sem `includeHistory`, a tool recusa. Com a flag, as requests de antes do encerramento continuam lá.
8. `export_har` e `export_devtools_json` devolvem caminho de arquivo dessa sessão, e os arquivos existem no host.

Falha em qualquer passo desta lista é falha da v1.

## Critério de pronto

A v1 está pronta quando os testes de caixa-preta passam e a aceitação ao vivo passa contra o container do profile `dart-network-mcp`.
