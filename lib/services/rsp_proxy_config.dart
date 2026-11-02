enum RspProxyMode { direct, forward, reverse }

class RspProxyConfig {
  final RspProxyMode mode;
  final String forwardProtocol;
  final String forwardHost;
  final int? forwardPort;
  final String reverseUrlPrefix;

  const RspProxyConfig({
    required this.mode,
    this.forwardProtocol = 'http',
    this.forwardHost = '',
    this.forwardPort,
    this.reverseUrlPrefix = '',
  });

  const RspProxyConfig.direct() : this(mode: RspProxyMode.direct);

  bool get usesForwardProxy =>
      mode == RspProxyMode.forward &&
      forwardHost.trim().isNotEmpty &&
      forwardPort != null;

  bool get usesReverseProxy =>
      mode == RspProxyMode.reverse && reverseUrlPrefix.trim().isNotEmpty;

  String get displayLabel {
    switch (mode) {
      case RspProxyMode.direct:
        return 'Direct';
      case RspProxyMode.forward:
        if (!usesForwardProxy) return 'Forward proxy not configured';
        return 'Forward: ${forwardProtocol.toUpperCase()} ${forwardHost.trim()}:$forwardPort';
      case RspProxyMode.reverse:
        if (!usesReverseProxy) return 'Reverse proxy not configured';
        return 'Reverse: ${reverseUrlPrefix.trim()}';
    }
  }

  String? get dartHttpProxyRule {
    if (!usesForwardProxy) return null;
    final proxyType = forwardProtocol == 'socks' ? 'SOCKS' : 'PROXY';
    return '$proxyType ${forwardHost.trim()}:$forwardPort';
  }

  Uri buildRspUri({
    required String rspAddress,
    required String endpoint,
    required bool useDefaultWebProxy,
  }) {
    final host = _normalizeRspAddress(rspAddress);
    final normalizedEndpoint = endpoint.replaceFirst(RegExp(r'^/+'), '');
    final path = 'gsma/rsp2/es9plus/$normalizedEndpoint';

    if (usesReverseProxy) {
      return _appendReversePath(reverseUrlPrefix, host, path);
    }

    if (useDefaultWebProxy) {
      return _appendReversePath('https://nlpa-data.nekoko.ee/rsp', host, path);
    }

    return Uri.parse('https://$host/$path');
  }

  static RspProxyMode modeFromString(String? value) {
    return RspProxyMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => RspProxyMode.direct,
    );
  }

  static String normalizeForwardProtocol(String? value) {
    final protocol = (value ?? 'http').trim().toLowerCase();
    if (protocol == 'socks' || protocol == 'socks5') return 'socks';
    return 'http';
  }

  static int? parsePort(String value) {
    final port = int.tryParse(value.trim());
    if (port == null || port < 1 || port > 65535) return null;
    return port;
  }

  static String _normalizeRspAddress(String address) {
    var normalized = address.trim();
    if (normalized.contains('://')) {
      final uri = Uri.tryParse(normalized);
      if (uri != null && uri.host.isNotEmpty) {
        return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
      }
    }
    return normalized.replaceFirst(RegExp(r'/+$'), '');
  }

  static Uri _appendReversePath(String prefix, String rspHost, String rspPath) {
    final cleanPrefix = prefix.trim().replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$cleanPrefix/$rspHost/$rspPath');
  }
}
