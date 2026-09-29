# dart_network_mcp_example

App Flutter de debug que gera HTTP previsível para o servidor `dart-network-mcp`.

`main` liga `HttpClient.enableTimelineLogging` antes do `runApp`. Sem isso, o profiler do `dart:io` não grava o request que já começou.

```bash
flutter devices
flutter run -d <id>
```

Na abertura, três GETs saem juntos para `https://jsonplaceholder.typicode.com`: `/posts/1`, `/users/1` e `/albums/1`.

A cada 5 segundos, um lote de três calls em paralelo. Os lotes alternam `POST`/`PUT`/`PATCH` em `/posts` e `DELETE /posts/1` com `GET /posts/1` e `GET /comments?postId=1`. Pausar segura o lote seguinte.

A lista na tela mostra o método, o status, o tempo, a URI e os bodies, do mais novo para o mais antigo.
