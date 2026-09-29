# dart-vm-mcp

Servidor MCP que faz attach em VMs Dart já em execução e expõe o tráfego HTTP capturado pelo HTTP profile da VM. Cada sessão é identificada pela URI da VM — essa URI é a chave usada em todas as tools de tráfego.

## Alvos

iOS, Android e desktop usam o mesmo fluxo de attach. A URI impressa pelo tooling (`flutter run`, DevTools, etc.) é a chave da sessão.

Se a VM não expõe o profiler HTTP de `dart:io`, a sessão permanece `live`, mas as tools de tráfego respondem com o erro `http_profile_unavailable` (por exemplo em alguns alvos como Flutter web).

## Dados sensíveis

O banco SQLite local e os arquivos exportados (HAR e DevTools JSON) guardam headers e bodies completos, inclusive `Authorization`, cookies e outros segredos. Trate esses arquivos como credenciais.

O diretório de dados do servidor é criado com permissões restritas ao usuário (por exemplo `chmod 700` no Unix).

## Instalação

Na raiz do repositório:

```bash
bash install.sh --claude
bash install.sh --cursor
bash install.sh --claude --cursor
```

Pelo menos uma flag (`--claude` ou `--cursor`) é obrigatória. O script registra o profile Docker MCP `dart-vm-mcp` e mescla a entrada do servidor no JSON do cliente escolhido. **Não remove** outros servidores MCP já configurados (incluindo entradas como `MCP_DOCKER`).

Requisitos típicos: Docker, `docker mcp`, Dart SDK (para o merge de config) e imagem local `dart-vm-mcp:local` (build feito pelo script, salvo `DART_VM_MCP_INSTALL_SKIP_DOCKER`).

## Tools MCP

Documentação completa (fluxo, shapes JSON, erros, bodies): [docs/mcp.md](docs/mcp.md).

| Tool                   | Parâmetros principais                                                                            | O que faz                                                                      |
| ---------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| `list_sessions`        | `state`: `live` (padrão), `history` ou `all`                                                     | Lista sessões conhecidas.                                                      |
| `get_session`          | `vmUri`                                                                                          | Detalhes de uma sessão (app, URI, isolates, estado, profiler disponível).      |
| `attach_vm`            | `uri`                                                                                            | Attach manual à VM (HTTP ou WebSocket).                                        |
| `list_requests`        | `vmUri`, `includeHistory` (padrão `false`), `limit`, `offset`, `method`, `status`, `urlContains` | Lista o call: método, URI, status, `durationMs` e bodies. Sem headers.         |
| `get_request`          | `vmUri`, `requestId`, `startTime` (opcional), `includeHistory`                                   | O mesmo call com headers, isolate, tamanhos e body.                            |
| `export_har`           | `vmUri`, `includeHistory`                                                                        | Exporta HAR para o diretório de dados e devolve `path`, contagem e tamanho.    |
| `export_devtools_json` | `vmUri`, `includeHistory`                                                                        | Exporta snapshot offline compatível com DevTools; mesmos metadados de retorno. |
| `delete_session`       | `vmUri`                                                                                          | Desconecta se `live` e apaga a sessão e requests armazenados.                  |

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

Copie a URI da VM que o tooling imprimir, use `attach_vm` se ainda não estiver anexada, e consulte o tráfego com `list_requests` / `get_request` ou exporte com `export_har` / `export_devtools_json`.