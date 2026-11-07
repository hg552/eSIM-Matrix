import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

/// Information about a single proxy node or group reported by Clash / Mihomo / sing-box.
class ProxyNodeInfo {
  const ProxyNodeInfo({
    required this.name,
    required this.type,
    this.udp = true,
    this.delay,
  });

  final String name;
  final String type;
  final bool udp;
  final int? delay;

  factory ProxyNodeInfo.fromJson(String name, Map<String, dynamic> json) {
    int? lastDelay;
    final history = json['history'];
    if (history is List && history.isNotEmpty) {
      final last = history.last;
      if (last is Map && last['delay'] is num) {
        lastDelay = (last['delay'] as num).toInt();
      }
    }
    return ProxyNodeInfo(
      name: name,
      type: json['type'] as String? ?? 'Unknown',
      udp: json['udp'] as bool? ?? true,
      delay: lastDelay,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'udp': udp,
    if (delay != null) 'delay': delay,
  };
}

/// Information about a proxy group (Selector / URLTest / Fallback).
class ProxyGroupInfo {
  const ProxyGroupInfo({
    required this.name,
    required this.type,
    required this.now,
    required this.all,
  });

  final String name;
  final String type;
  final String now;
  final List<String> all;

  bool get isSelector => type.toLowerCase() == 'selector';

  factory ProxyGroupInfo.fromJson(String name, Map<String, dynamic> json) {
    final allList = (json['all'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList(growable: false) ??
        const <String>[];
    return ProxyGroupInfo(
      name: name,
      type: json['type'] as String? ?? 'Selector',
      now: json['now'] as String? ?? '',
      all: allList,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'now': now,
    'all': all,
  };
}

/// Snapshot of the active proxy node prior to a profile switch.
class ProxySnapshot {
  const ProxySnapshot({
    required this.group,
    required this.node,
    required this.timestamp,
  });

  final String group;
  final String node;
  final DateTime timestamp;

  Map<String, dynamic> toJson() => {
    'group': group,
    'node': node,
    'timestamp': timestamp.toIso8601String(),
  };

  factory ProxySnapshot.fromJson(Map<String, dynamic> json) => ProxySnapshot(
    group: json['group'] as String? ?? 'GLOBAL',
    node: json['node'] as String? ?? '',
    timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
        DateTime.now(),
  );
}

/// Result of a node switch or restore attempt.
class ProxySwitchResult {
  const ProxySwitchResult({
    required this.success,
    required this.group,
    this.previousNode,
    this.currentNode,
    this.error,
  });

  final bool success;
  final String group;
  final String? previousNode;
  final String? currentNode;
  final String? error;

  Map<String, dynamic> toJson() => {
    'success': success,
    'group': group,
    if (previousNode != null) 'previousNode': previousNode,
    if (currentNode != null) 'currentNode': currentNode,
    if (error != null) 'error': error,
  };
}

/// Headless client for Clash / Mihomo (FlClash) / sing-box External Controller.
class ProxyLinkageService {
  ProxyLinkageService({
    String controllerUrl = 'http://127.0.0.1:9090',
    String? secret,
    Duration timeout = const Duration(seconds: 3),
    HttpClient Function()? clientFactory,
  })  : _controllerUrl = _normalizeUrl(controllerUrl),
        _secret = secret?.trim().isEmpty == true ? null : secret?.trim(),
        _timeout = timeout,
        _clientFactory = clientFactory ?? HttpClient.new;

  static final Logger _log = Logger('ProxyLinkageService');

  String _controllerUrl;
  String? _secret;
  Duration _timeout;
  final HttpClient Function() _clientFactory;
  HttpClient? _client;

  String get controllerUrl => _controllerUrl;
  String? get secret => _secret;

  void updateConfig({String? controllerUrl, String? secret, Duration? timeout}) {
    if (controllerUrl != null && controllerUrl.isNotEmpty) {
      _controllerUrl = _normalizeUrl(controllerUrl);
    }
    if (secret != null) {
      _secret = secret.trim().isEmpty ? null : secret.trim();
    }
    if (timeout != null) {
      _timeout = timeout;
    }
    if (_client != null && timeout != null) {
      _client!.connectionTimeout = _timeout;
    }
  }

  static String _normalizeUrl(String raw) {
    var url = raw.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Uri _endpoint(String path) {
    final cleanPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$_controllerUrl$cleanPath');
  }

  Future<HttpClientRequest> _prepareRequest(
    String method,
    String path, {
    String? body,
  }) async {
    final client = _client ??= (_clientFactory()..connectionTimeout = _timeout);
    final uri = _endpoint(path);
    final request = await client.openUrl(method, uri).timeout(_timeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (_secret != null && _secret!.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_secret');
    }
    if (body != null) {
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      final encoded = utf8.encode(body);
      request.contentLength = encoded.length;
      request.add(encoded);
    }
    return request;
  }

  /// Tests connectivity with the external controller.
  Future<({bool alive, String? version, String? error})> testConnection() async {
    try {
      final req = await _prepareRequest('GET', '/version');
      final res = await req.close().timeout(_timeout);
      final bodyStr = await utf8.decodeStream(res).timeout(_timeout);
      if (res.statusCode == HttpStatus.ok) {
        try {
          final json = jsonDecode(bodyStr) as Map<String, dynamic>;
          final version = json['version']?.toString() ?? 'ok';
          return (alive: true, version: version, error: null);
        } catch (_) {
          return (alive: true, version: 'connected', error: null);
        }
      } else if (res.statusCode == HttpStatus.unauthorized) {
        return (alive: false, version: null, error: 'unauthorized_secret');
      } else {
        return (alive: false, version: null, error: 'http_${res.statusCode}');
      }
    } catch (e) {
      _log.fine('ProxyLinkage testConnection error: $e');
      return (alive: false, version: null, error: e.toString());
    }
  }

  /// Lists all proxy groups and nodes from the controller.
  Future<Map<String, dynamic>?> getProxiesRaw() async {
    try {
      final req = await _prepareRequest('GET', '/proxies');
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != HttpStatus.ok) {
        _log.warning('GET /proxies returned ${res.statusCode}');
        return null;
      }
      final bodyStr = await utf8.decodeStream(res).timeout(_timeout);
      final json = jsonDecode(bodyStr);
      if (json is Map<String, dynamic> && json['proxies'] is Map) {
        return json['proxies'] as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      _log.fine('getProxiesRaw failed: $e');
      return null;
    }
  }

  /// Returns all available selector groups (e.g. `GLOBAL`, `PROXY`, `🚀 节点选择`).
  Future<List<ProxyGroupInfo>> getSelectorGroups() async {
    final proxies = await getProxiesRaw();
    if (proxies == null) return const <ProxyGroupInfo>[];
    final groups = <ProxyGroupInfo>[];
    for (final entry in proxies.entries) {
      final val = entry.value;
      if (val is Map<String, dynamic>) {
        final type = val['type']?.toString().toLowerCase() ?? '';
        if (type == 'selector') {
          groups.add(ProxyGroupInfo.fromJson(entry.key, val));
        }
      }
    }
    return groups;
  }

  /// Retrieves a specific group info.
  Future<ProxyGroupInfo?> getGroup(String groupName) async {
    try {
      final req = await _prepareRequest('GET', '/proxies/${Uri.encodeComponent(groupName)}');
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != HttpStatus.ok) return null;
      final bodyStr = await utf8.decodeStream(res).timeout(_timeout);
      final json = jsonDecode(bodyStr);
      if (json is Map<String, dynamic>) {
        return ProxyGroupInfo.fromJson(groupName, json);
      }
      return null;
    } catch (e) {
      _log.fine('getGroup $groupName failed: $e');
      return null;
    }
  }

  /// Gets currently selected active node in [groupName].
  Future<String?> getCurrentNode(String groupName) async {
    final group = await getGroup(groupName);
    return group?.now;
  }

  /// Takes a snapshot of the current node in [groupName].
  Future<ProxySnapshot?> snapshot(String groupName) async {
    final current = await getCurrentNode(groupName);
    if (current == null || current.isEmpty) return null;
    return ProxySnapshot(
      group: groupName,
      node: current,
      timestamp: DateTime.now(),
    );
  }

  /// Switches [groupName] to [nodeName].
  Future<ProxySwitchResult> selectNode(String groupName, String nodeName) async {
    if (groupName.isEmpty || nodeName.isEmpty) {
      return ProxySwitchResult(
        success: false,
        group: groupName,
        error: 'invalid_arguments',
      );
    }
    try {
      final prevNode = await getCurrentNode(groupName);
      if (prevNode == nodeName) {
        return ProxySwitchResult(
          success: true,
          group: groupName,
          previousNode: prevNode,
          currentNode: nodeName,
        );
      }
      final payload = jsonEncode({'name': nodeName});
      final req = await _prepareRequest(
        'PUT',
        '/proxies/${Uri.encodeComponent(groupName)}',
        body: payload,
      );
      final res = await req.close().timeout(_timeout);
      // Clash external controller returns 204 No Content on success
      if (res.statusCode == HttpStatus.noContent || res.statusCode == HttpStatus.ok) {
        _log.info('Proxy group [$groupName] switched: $prevNode -> $nodeName');
        return ProxySwitchResult(
          success: true,
          group: groupName,
          previousNode: prevNode,
          currentNode: nodeName,
        );
      } else {
        final errBody = await utf8.decodeStream(res).timeout(_timeout).catchError((_) => '');
        _log.warning('Failed to select node $nodeName in $groupName: ${res.statusCode} $errBody');
        return ProxySwitchResult(
          success: false,
          group: groupName,
          previousNode: prevNode,
          error: 'http_${res.statusCode}',
        );
      }
    } catch (e) {
      _log.warning('selectNode exception: $e');
      return ProxySwitchResult(
        success: false,
        group: groupName,
        error: e.toString(),
      );
    }
  }

  /// Restores [snapshot] back to its original node.
  Future<ProxySwitchResult> restore(ProxySnapshot snapshot) async {
    _log.info('Restoring proxy snapshot for group [${snapshot.group}] to [${snapshot.node}]');
    return selectNode(snapshot.group, snapshot.node);
  }

  void close() {
    _client?.close(force: true);
    _client = null;
  }
}
