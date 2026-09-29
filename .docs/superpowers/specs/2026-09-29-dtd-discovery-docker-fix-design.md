# DTD discovery Docker fix — design

**Date:** 2026-09-29  
**Status:** approved for implementation  
**Goal:** Usuário típico com install Docker sobe qualquer app Dart/Flutter via tooling e vê a sessão em `list_sessions` **sem** `attach_vm` e **sem** `DTD_URI` manual.

## Problem

O install monta só `~/.dart-tool` e o discovery em `lib/src/discovery.dart` lê apenas arquivos cujo nome contém `dtd` / `tooling-daemon`, com campos `uri` / `dtdUri`.

No Dart atual (macOS verificado), o Tooling Daemon grava em:

`~/Library/Application Support/Dart/dtd/<pid>`

com JSON:

```json
{"wsUri":"ws://127.0.0.1:…","pid":…,"workspaceRoot":"…"}
```

`~/.dart-tool` no host tipicamente não tem esses arquivos. Resultado: discovery ociosa no Docker; auto-attach só funciona se alguém injetar `DTD_URI` (e com `host.docker.internal`, porque `_tryConnect` não reescreve loopback).

## Glossary

| Term | Meaning |
|------|---------|
| DTD | Dart Tooling Daemon |
| `DTD_URI` | Env opcional com WebSocket do DTD |
| `wsUri` | Campo no arquivo moderno sob `…/Dart/dtd/<pid>` |
| `uri` / `dtdUri` | Campos legados em `~/.dart-tool` |
| `vmUri` | Chave canônica da sessão (WS da VM) |
| `host.docker.internal` | Host visto do container; só no socket |
| `attach_vm` | Fallback manual |

## Approach

1. Estender discovery para o diretório moderno do Dart + chave `wsUri`.
2. Montar esse diretório no container e apontar `DART_NETWORK_MCP_DTD_DIR`.
3. Em Docker, aplicar `socketUriFor` também na conexão ao DTD.
4. Manter conexões simultâneas a **todos** os DTDs descobertos (IDE + `flutter run`), sincronizando VMs de cada um — não parar no primeiro que conectar.
5. Manter `DTD_URI` e `~/.dart-tool` como fontes adicionais.

## Docker home permissions

O processa no container roda com `user: "<hostUid>:<hostGid>"`. O home da imagem `/home/mcp` precisa ser atravessável (`chmod 755`): com `700`, mounts sob `/home/mcp/...` (`.dart-tool`, `Dart/dtd`) ficam `Permission denied` para o uid do host e a discovery nunca lê os arquivos.


## Discovery contract

`discoverDtdUris` passa a aceitar:

- `dtdUriEnv` (`DTD_URI`)
- `dartDtdDir` — dir moderno (todos os arquivos JSON; campos `wsUri`, `uri`, `dtdUri`; sem filtro de nome)
- `dartToolDir` — legado `~/.dart-tool` (filtro de nome `dtd` / `tooling-daemon`; campos `uri`, `dtdUri`, `wsUri`)

Ordem de coleta (dedupe por string da URI):

1. `DTD_URI`
2. Arquivos em `dartDtdDir` (se existir)
3. Arquivos filtrados em `dartToolDir`

Path host do dir moderno (também usado pelo install):

- macOS: `$HOME/Library/Application Support/Dart/dtd`
- Linux: `${XDG_DATA_HOME:-$HOME/.local/share}/Dart/dtd`
- Windows: `%LOCALAPPDATA%\Dart\dtd`

Override no processo: env `DART_NETWORK_MCP_DTD_DIR` (path absoluto). No container: `/home/mcp/Dart/dtd`.

Helper exportado (ou equivalente testável): `defaultDartDtdDirectory({Map? env, String? home})` para OS paths.

## Docker socket

Em `_tryConnect`, com `inDocker == true`, conectar em `socketUriFor(Uri.parse(wsUri), inDocker: true)`. `_connectedUri` permanece a URI descoberta (canônica, tipicamente `127.0.0.1`).

## Install / run

`install.sh` catalog e `tool/run_mcp_container.sh`:

- Resolver path host do Dart/dtd; `mkdir -p` se ausente.
- Volume RO: `<host Dart/dtd>:/home/mcp/Dart/dtd:ro`
- Env: `DART_NETWORK_MCP_DTD_DIR=/home/mcp/Dart/dtd`
- Manter mount `~/.dart-tool` e demais envs atuais.

## Docs

Atualizar `docs/mcp.md` (fluxo de descoberta): fonte moderna + `wsUri`; `attach_vm` continua fallback.

## Acceptance

Container rebuildado, **sem** `DTD_URI` e **sem** `attach_vm`, com mounts padrão:

1. App Flutter debug no host (qualquer projeto via tooling).
2. `list_sessions` com `state=live` lista a sessão.
3. `list_requests` devolve calls.

## Out of scope

- Sidecar no host.
- Filtrar DTD da IDE vs `flutter run`.
- Mudança de shapes das tools MCP.
