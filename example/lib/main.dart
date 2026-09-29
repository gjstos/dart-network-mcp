import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() {
  HttpClient.enableTimelineLogging = true;
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3D5AFE),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const TrafficPage(),
    ),
  );
}

class _Call {
  const _Call(this.method, this.uri, [this.body = '']);

  final String method;
  final String uri;
  final String body;
}

class _Line {
  _Line({
    required this.method,
    required this.uri,
    required this.requestBody,
    required this.responseBody,
    required this.statusCode,
    required this.elapsed,
  });

  final String method;
  final String uri;
  final String requestBody;
  final String responseBody;
  final int? statusCode;
  final Duration elapsed;
}

const _host = 'https://jsonplaceholder.typicode.com';

const _open = [
  _Call('GET', '$_host/posts/1'),
  _Call('GET', '$_host/users/1'),
  _Call('GET', '$_host/albums/1'),
];

const _writes = [
  _Call(
    'POST',
    '$_host/posts',
    '{"title":"dart-network-mcp","body":"batch","userId":1}',
  ),
  _Call(
    'PUT',
    '$_host/posts/1',
    '{"id":1,"title":"replaced","body":"batch","userId":1}',
  ),
  _Call('PATCH', '$_host/posts/1', '{"title":"patched"}'),
];

const _mix = [
  _Call('DELETE', '$_host/posts/1'),
  _Call('GET', '$_host/posts/1'),
  _Call('GET', '$_host/comments?postId=1'),
];

class TrafficPage extends StatefulWidget {
  const TrafficPage({super.key});

  @override
  State<TrafficPage> createState() => _TrafficPageState();
}

class _TrafficPageState extends State<TrafficPage> {
  Timer? _timer;
  final List<_Line> _lines = [];
  var _paused = false;
  var _inFlight = 0;
  var _batch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_run(_open));
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _tick());
  }

  void _tick() {
    if (_paused) {
      return;
    }
    final batch = _batch.isEven ? _writes : _mix;
    _batch += 1;
    unawaited(_run(batch));
  }

  Future<void> _run(List<_Call> calls) {
    if (_paused) {
      return Future<void>.value();
    }
    return Future.wait(calls.map(_send));
  }

  void _togglePause() {
    setState(() => _paused = !_paused);
  }

  Future<void> _send(_Call call) async {
    if (_paused) {
      return;
    }
    setState(() => _inFlight += 1);
    final watch = Stopwatch()..start();
    int? status;
    String responseBody;
    try {
      final response = await _dispatch(call);
      status = response.statusCode;
      responseBody = response.body;
    } catch (error) {
      responseBody = '$error';
    }
    watch.stop();
    if (!mounted) {
      return;
    }
    setState(() {
      _inFlight -= 1;
      _lines.insert(
        0,
        _Line(
          method: call.method,
          uri: call.uri,
          requestBody: call.body,
          responseBody: responseBody,
          statusCode: status,
          elapsed: watch.elapsed,
        ),
      );
    });
  }

  Future<http.Response> _dispatch(_Call call) {
    final uri = Uri.parse(call.uri);
    final headers = call.body.isEmpty
        ? null
        : const {'content-type': 'application/json; charset=utf-8'};
    return switch (call.method) {
      'POST' => http.post(uri, headers: headers, body: call.body),
      'PUT' => http.put(uri, headers: headers, body: call.body),
      'PATCH' => http.patch(uri, headers: headers, body: call.body),
      'DELETE' => http.delete(uri),
      _ => http.get(uri),
    };
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Traffic'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              _paused ? 'pausado' : '$_inFlight em voo',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          IconButton(
            onPressed: _togglePause,
            icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
            tooltip: _paused ? 'Retomar' : 'Pausar',
          ),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _lines.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final line = _lines[index];
          return DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _MethodChip(method: line.method),
                      const SizedBox(width: 8),
                      Text(
                        line.statusCode?.toString() ?? '—',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      Text(
                        '${line.elapsed.inMilliseconds} ms',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SelectableText(line.uri),
                  if (line.requestBody.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    const _Label('request'),
                    _Body(line.requestBody),
                  ],
                  const SizedBox(height: 10),
                  const _Label('response'),
                  _Body(line.responseBody),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelSmall,
    );
  }
}

class _Body extends StatelessWidget {
  const _Body(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 140),
      child: SingleChildScrollView(
        child: SelectableText(
          text.isEmpty ? '—' : text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.35),
        ),
      ),
    );
  }
}

class _MethodChip extends StatelessWidget {
  const _MethodChip({required this.method});

  final String method;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _color(method),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          method,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  static Color _color(String method) {
    return switch (method) {
      'POST' => const Color(0xFF1565C0),
      'PUT' => const Color(0xFFEF6C00),
      'PATCH' => const Color(0xFF6A1B9A),
      'DELETE' => const Color(0xFFC62828),
      _ => const Color(0xFF2E7D32),
    };
  }
}
