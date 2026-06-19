import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

typedef DebugInjectHandler = void Function(Map<String, dynamic> payload);

/// Listens on a TCP port for newline-delimited JSON packets and dispatches
/// them to registered handlers by type. Debug/Linux only.
///
/// Packet format: {"type": "<type>", "payload": { ... }}\n
///
/// Example (gps):
///   {"type": "gps", "payload": {"lat": 37.7749, "lon": -122.4194,
///                               "speed": 1.5, "heading": 90.0, "hasFix": true}}
class DebugInjectService {
  static const int port = 7700;

  final Map<String, DebugInjectHandler> _handlers = {};

  ServerSocket? _server;
  final List<Socket> _clients = [];

  void registerHandler(String type, DebugInjectHandler handler) {
    _handlers[type] = handler;
  }

  Future<void> start() async {
    if (!kDebugMode || !Platform.isLinux) return;
    try {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      debugPrint('[DebugInjectService] listening on port $port');
      _server!.listen(_onClient);
    } catch (e) {
      debugPrint('[DebugInjectService] failed to bind on port $port: $e');
    }
  }

  void _onClient(Socket client) {
    debugPrint('[DebugInjectService] client connected: ${client.remoteAddress.address}');
    _clients.add(client);

    client
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _dispatch(line.trim()),
          onError: (Object e) =>
              debugPrint('[DebugInjectService] client error: $e'),
          onDone: () {
            _clients.remove(client);
            debugPrint('[DebugInjectService] client disconnected');
          },
          cancelOnError: true,
        );
  }

  void _dispatch(String line) {
    if (line.isEmpty) return;
    try {
      final map = jsonDecode(line) as Map<String, dynamic>;
      final type = map['type'] as String?;
      final payload = map['payload'] as Map<String, dynamic>?;
      if (type == null || payload == null) {
        debugPrint('[DebugInjectService] malformed packet (missing type/payload): $line');
        return;
      }
      final handler = _handlers[type];
      if (handler == null) {
        debugPrint('[DebugInjectService] no handler for type "$type"');
        return;
      }
      handler(payload);
    } catch (e) {
      debugPrint('[DebugInjectService] failed to parse packet: $e\n  line: $line');
    }
  }

  void dispose() {
    for (final c in _clients) {
      c.destroy();
    }
    _clients.clear();
    _server?.close();
    _server = null;
  }
}
