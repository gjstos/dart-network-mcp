import 'dart:io';

String canonicalizeVmUri(String raw) {
  final uri = Uri.parse(raw.trim());
  final scheme = switch (uri.scheme) {
    'http' => 'ws',
    'https' => 'wss',
    'ws' => 'ws',
    'wss' => 'wss',
    _ => throw FormatException('unsupported vm uri scheme: ${uri.scheme}'),
  };
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty || segments.last != 'ws') {
    segments.add('ws');
  }
  return uri.replace(scheme: scheme, pathSegments: segments).removeFragment().toString();
}

Uri socketUriFor(Uri canonical, {required bool inDocker}) {
  if (!inDocker) {
    return canonical;
  }
  final host = canonical.host;
  final loopback = host == '127.0.0.1' || host == 'localhost' || host == '::1';
  if (!loopback) {
    return canonical;
  }
  return canonical.replace(host: 'host.docker.internal');
}

typedef Ipv4Lookup = Future<List<InternetAddress>> Function(String host);

Future<Uri> dialUriFor(
  Uri canonical, {
  required bool inDocker,
  Ipv4Lookup? lookupIpv4,
}) async {
  final socket = socketUriFor(canonical, inDocker: inDocker);
  if (socket.host != 'host.docker.internal') {
    return socket;
  }
  final lookup = lookupIpv4 ?? _lookupIpv4;
  final addresses = await lookup(socket.host);
  if (addresses.isEmpty) {
    return socket;
  }
  return socket.replace(host: addresses.first.address);
}

Future<List<InternetAddress>> _lookupIpv4(String host) {
  return InternetAddress.lookup(host, type: InternetAddressType.IPv4);
}
