---
name: dart-network-mcp
description: Inspect HTTP traffic (requests, responses, headers, bodies) of a running Flutter/Dart app in debug via the dart-network-mcp server. Use when debugging API calls, failed requests, status codes, payloads, or when asked to export HAR / DevTools network logs. Also for "o que o app está enviando", "por que essa chamada falhou", "tráfego de rede do app".
---

# dart-network-mcp

Lê o tráfego HTTP (`dart:io` HTTP profile) de apps Dart/Flutter em debug. Toda tool de tráfego usa `vmUri` como chave da sessão.

## Fluxo

1. `list_sessions`. A descoberta anexa VMs sozinha (a cada 2s); só use `attach_vm(uri)` se a sessão não aparecer. Use a URI `http://…` ou `ws://…/ws` impressa pelo `flutter run`.
2. `list_requests(vmUri, …)` para o resumo: método, URI, status, `durationMs`, sizes. Não traz headers nem body. Filtre com `method`, `status`, `urlContains` antes de paginar.
3. `get_request(vmUri, requestId)` para headers e body da request escolhida.
3b. `get_curl(vmUri, requests:[{requestId}, ...])` quando o usuário quer reproduzir chamadas; passe todas numa chamada só. Completo por padrão; use `dropNoiseHeaders`, `includeBody=false` ou `multiline=false` para enxugar.
4. `export_har` ou `export_devtools_json` se o usuário quer o arquivo. O retorno é `path`; diga onde está, não leia o arquivo inteiro.

## Regras que evitam erro

- **Paginação:** `limit` máx 200. Para ler tudo, repita com `offset = nextOffset` até `nextOffset` vir `null`. Prefira filtrar a paginar tudo.
- **Sessão `history`** (app encerrado/crashou): toda tool de tráfego exige `includeHistory=true`, senão volta `history_requires_flag`. Se `list_sessions` vier vazio, olhe `historyHint.vmUris`. Em sessão `live` a flag é ignorada.
- **`ambiguous_request`:** o mesmo `requestId` existe em mais de um `startTime` (hot restart). Repita `get_request` com um dos `error.startTimes`.
- **Body grande:** `get_request` tem teto de 100000 caracteres e omite `responseBody`, depois `requestBody`, depois headers, devolvendo o `…Path` do arquivo. Leia só o trecho que precisa desse arquivo.
- **`http_profile_unavailable`:** a VM não expõe o profiler (ex.: Flutter web). Use iOS, Android ou desktop.
- **Sem requests no app:** confirme que o app roda em debug e que `HttpClient.enableTimelineLogging` está ligado antes do `runApp`.
- `bodyUnavailable: true` significa que o body não foi capturado; não é bug de leitura.

## Dados sensíveis

Headers e bodies podem ter `Authorization`, cookies e tokens, e os exports também. Não cole segredos na resposta ao usuário; mascare-os.

## Limpeza

`delete_session(vmUri)` apaga sessão, bodies e exports. `get_retention` / `set_retention(days)` controlam por quanto tempo sessões `history` ficam (padrão 90 dias). Só mexa nisso se o usuário pedir.
