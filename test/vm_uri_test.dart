import 'dart:io';

import 'package:dart_network_mcp/src/vm_uri.dart';
import 'package:test/test.dart';

void main() {
  test('http console uri and ws uri are the same key', () {
    const httpUri = 'http://127.0.0.1:62080/06-FZCo24xM=/';
    const wsUri = 'ws://127.0.0.1:62080/06-FZCo24xM=/ws';
    expect(canonicalizeVmUri(httpUri), wsUri);
    expect(canonicalizeVmUri(wsUri), wsUri);
    expect(canonicalizeVmUri('$wsUri/'), wsUri);
  });

  test('https becomes wss', () {
    expect(
      canonicalizeVmUri('https://10.0.0.8:8181/tok/'),
      'wss://10.0.0.8:8181/tok/ws',
    );
  });

  test('docker rewrites only loopback on the socket', () {
    final canonical = Uri.parse(canonicalizeVmUri('http://127.0.0.1:1/abc/'));
    final socket = socketUriFor(canonical, inDocker: true);
    expect(socket.host, 'host.docker.internal');
    expect(socket.port, 1);
    expect(canonical.host, '127.0.0.1');

    final lan = Uri.parse(canonicalizeVmUri('http://192.168.1.20:9/abc/'));
    expect(socketUriFor(lan, inDocker: true).host, '192.168.1.20');
    expect(socketUriFor(canonical, inDocker: false).host, '127.0.0.1');
  });

  test('localhost and ipv6 loopback rewrite in docker', () {
    final local = Uri.parse(canonicalizeVmUri('http://localhost:2/abc/'));
    expect(socketUriFor(local, inDocker: true).host, 'host.docker.internal');
    final v6 = Uri.parse('ws://[::1]:3/abc/ws');
    expect(socketUriFor(v6, inDocker: true).host, 'host.docker.internal');
  });

  test('docker dial uses ipv4 and ignores ipv6 of host.docker.internal', () async {
    final canonical = Uri.parse('ws://127.0.0.1:53865/v1TNHY5hIHc=');
    final dial = await dialUriFor(
      canonical,
      inDocker: true,
      lookupIpv4: (host) async {
        expect(host, 'host.docker.internal');
        return [InternetAddress('192.168.65.254')];
      },
    );
    expect(dial.host, '192.168.65.254');
    expect(dial.port, 53865);
    expect(dial.path, '/v1TNHY5hIHc=');
    expect(canonical.host, '127.0.0.1');
  });

  test('dial outside docker and lan uris do not lookup', () async {
    var calls = 0;
    Future<List<InternetAddress>> lookup(String host) async {
      calls++;
      return [InternetAddress('192.168.65.254')];
    }

    final local = Uri.parse('ws://127.0.0.1:9/abc');
    final outside = await dialUriFor(
      local,
      inDocker: false,
      lookupIpv4: lookup,
    );
    expect(outside.host, '127.0.0.1');

    final lan = Uri.parse('ws://192.168.1.20:9/abc');
    final lanDial = await dialUriFor(lan, inDocker: true, lookupIpv4: lookup);
    expect(lanDial.host, '192.168.1.20');
    expect(calls, 0);
  });
}
