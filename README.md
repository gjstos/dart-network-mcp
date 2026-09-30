# dart-network-mcp

Servidor MCP que faz attach em VMs Dart já em execução e expõe o tráfego HTTP capturado pelo HTTP profile da VM. Cada sessão é identificada pela URI da VM — essa URI é a chave usada em todas as tools de tráfego.

## Alvos

iOS, Android e desktop usam o mesmo fluxo de attach. A URI da VM (`vmUri`) é a chave da sessão.

A descoberta acha os Dart Tooling Daemons (DTD) do IDE e do `flutter run` pelos servidores DevTools (`/api/getDtdUri`, portas 9100+), pelos arquivos em `Dart/dtd` e por `DTD_URI`, e anexa sessões sozinha — em geral **não** é preciso `attach_vm`. Esse tool continua como fallback se a descoberta não pegar a VM.

Se a VM não expõe o profiler HTTP de `dart:io`, a sessão permanece `live`, mas as tools de tráfego respondem com o erro `http_profile_unavailable` (por exemplo em alguns alvos como Flutter web).

## Dados sensíveis

Headers e bodies das requisições são gravados como arquivos individuais na pasta `bodies/` dentro do diretório de dados. O banco SQLite armazena apenas o índice (metadados, caminhos, tamanhos) — não os headers nem os bodies em si. Os arquivos exportados (HAR e DevTools JSON) compilam esses dados e podem conter `Authorization`, cookies e outros segredos. Trate o diretório de dados e os exports como credenciais.

O diretório de dados do servidor é criado com permissões restritas ao usuário (por exemplo `chmod 700` no Unix).

## Instalação

Na raiz do repositório:

```bash
bash install.sh --claude
bash install.sh --cursor
bash install.sh --claude --cursor
bash install.sh --fresh --claude --cursor
```

Pelo menos uma flag (`--claude` ou `--cursor`) é obrigatória. O script compila o servidor nativo (`dart compile exe`) para `~/.local/bin/dart_network_mcp` e mescla a entrada no JSON do cliente escolhido. Também instala a skill `dart-network-mcp` (fluxo de uso das tools e armadilhas) em `~/.claude/skills/` e/ou `~/.cursor/skills/`, valendo globalmente. **Não remove** outros servidores MCP já configurados.

`--fresh` limpa antes de instalar: tira `dart-network-mcp` e `dart-vm-mcp` do Claude e do Cursor, remove a skill dos dois e apaga o diretório de dados. Se o Docker estiver disponível, também remove resquícios de instalações antigas (catálogos, profile, imagens e containers `dart-network-mcp:local` / `dart-vm-mcp:local`). Em seguida instala de novo só nos clientes pedidos.

Requisitos: Dart SDK e `python3`. O SQLite vem do sistema (macOS já traz; em Linux instale `libsqlite3`). Não precisa de Docker. Variáveis: `DART_NETWORK_MCP_BIN_DIR` (destino do binário) e `DART_NETWORK_MCP_INSTALL_SKIP_BUILD=1` (só registra o cliente).

## Tools MCP

Documentação completa (fluxo, shapes JSON, erros, bodies): [docs/mcp.md](docs/mcp.md).

| Tool                   | Parâmetros principais                                                                            | O que faz                                                                      |
| ---------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| `list_sessions`        | `state`: `live` (padrão), `history` ou `all`                                                     | Lista sessões conhecidas.                                                      |
| `get_session`          | `vmUri`                                                                                          | Detalhes de uma sessão (app, URI, isolates, estado, profiler disponível).      |
| `attach_vm`            | `uri`                                                                                            | Attach manual à VM (HTTP ou WebSocket).                                        |
| `list_requests`        | `vmUri`, `includeHistory` (padrão `false`), `limit`, `offset`, `method`, `status`, `urlContains` | Lista o call: método, URI, status, `durationMs` e sizes. Sem body e sem headers. |
| `get_request`          | `vmUri`, `requestId`, `startTime` (opcional), `includeHistory`                                   | O mesmo call com headers, isolate, tamanhos e body (teto de 100000 caracteres). |
| `get_curl`             | `vmUri`, `requests: [{requestId, startTime?}]` (máx. 50), `includeHistory`, `includeBody`, `includeHeaders`, `dropNoiseHeaders`, `multiline` | Um curl por request no estilo "Copy as cURL (bash)" do Chrome (completo por padrão), mais `errors` por item. |
| `export_har`           | `vmUri`, `includeHistory`                                                                        | Exporta HAR para o diretório de dados e devolve `path`, contagem e tamanho.     |
| `export_devtools_json` | `vmUri`, `includeHistory`                                                                        | Exporta snapshot offline compatível com DevTools; mesmos metadados de retorno.  |
| `delete_session`       | `vmUri`                                                                                          | Desconecta se `live` e apaga sessão, requests, pasta `bodies/` e exports.       |
| `get_retention`        | (nenhum)                                                                                         | Devolve `{ "retentionDays": <days> }`. Padrão 90.                               |
| `set_retention`        | `days` (inteiro ≥ 1)                                                                             | Grava o prazo e varre sessões `history` expiradas, inclusive exports.           |

## Sessões `live` e `history`

Por padrão, as tools de tráfego consideram apenas sessões `live` (`includeHistory` default `false`).

Quando o app encerra ou a VM cai, a sessão passa a `history`: o tráfego gravado antes do crash continua no SQLite, mas **não** é devolvido sem `includeHistory=true`. Nesse caso, a tool responde `history_requires_flag` e **não** inclui requests no JSON.

Com `includeHistory=true` numa sessão ainda `live`, a flag é **ignorada** — a resposta permanece `live` e só tráfego ao vivo entra na operação.

## Exemplo

App Flutter de demonstração que gera HTTP de forma previsível:

```bash
cd example
flutter devices          # escolha um <id>
flutter run -d <id>
```

Na subida, três GETs saem juntos para `https://jsonplaceholder.typicode.com`: `/posts/1`, `/users/1` e `/albums/1`.

A cada **5 segundos**, um lote de três calls em paralelo. Os lotes alternam `POST`/`PUT`/`PATCH` em `/posts` e `DELETE` mais dois GETs. **Pausar** segura o lote seguinte.

`main` liga `HttpClient.enableTimelineLogging` antes do `runApp`. O profiler do `dart:io` só grava um request se o flag já estiver ativo quando ele começa. O servidor também chama `httpEnableTimelineLogging`, mas esse RPC chega depois do primeiro GET de um hot restart.

Com o MCP instalado, a descoberta anexa a VM sozinha via DTD (`list_sessions` sem `attach_vm`). Detalhes e fallback: [docs/mcp.md](docs/mcp.md). Depois use `list_requests` / `get_request` ou exporte com `export_har` / `export_devtools_json`.