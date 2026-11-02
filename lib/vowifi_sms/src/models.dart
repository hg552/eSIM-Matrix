import 'dart:convert';
import 'dart:typed_data';

enum VowifiTransport { udp, tcp, tls }

enum VowifiSmsDirection { inbound, outbound, system }

enum VowifiSmsConnectionState {
  disconnected,
  connecting,
  connected,
  registered,
  error,
}

class VowifiSmsConfig {
  const VowifiSmsConfig({
    this.sipServer = '',
    this.domain = '',
    this.privateIdentity = '',
    this.publicIdentity = '',
    this.username = '',
    this.password = '',
    this.smsc = '',
    this.transport = VowifiTransport.tls,
    this.registerExpires = 3600,
    this.tlsSkipVerify = false,
    this.useEpdg = false,
    this.epdgServer = '',
    this.epdgAddresses = const <String>[],
    this.epdgPort = 500,
    this.imsi = '',
    this.mcc = '',
    this.mnc = '',
    this.mncLength = 0,
    this.apn = 'ims',
    this.deviceIdentity = '',
  });

  final String sipServer;
  final String domain;
  final String privateIdentity;
  final String publicIdentity;
  final String username;
  final String password;
  final String smsc;
  final VowifiTransport transport;
  final int registerExpires;
  final bool tlsSkipVerify;
  final bool useEpdg;
  final String epdgServer;
  final List<String> epdgAddresses;
  final int epdgPort;
  final String imsi;
  final String mcc;
  final String mnc;
  final int mncLength;
  final String apn;
  final String deviceIdentity;

  String get identityUri {
    if (publicIdentity.trim().isNotEmpty) {
      return publicIdentity.trim();
    }
    final user = username.trim();
    final realm = _realm;
    if (user.isEmpty || realm.isEmpty) {
      return '';
    }
    return 'sip:$user@$realm';
  }

  String get requestRealm => _realm;

  String get _realm {
    final private = privateIdentity.trim();
    final at = private.indexOf('@');
    if (at > 0 && at + 1 < private.length) {
      return private.substring(at + 1).trim();
    }
    return domain.trim();
  }

  VowifiSmsConfig copyWith({
    String? sipServer,
    String? domain,
    String? privateIdentity,
    String? publicIdentity,
    String? username,
    String? password,
    String? smsc,
    VowifiTransport? transport,
    int? registerExpires,
    bool? tlsSkipVerify,
    bool? useEpdg,
    String? epdgServer,
    List<String>? epdgAddresses,
    int? epdgPort,
    String? imsi,
    String? mcc,
    String? mnc,
    int? mncLength,
    String? apn,
    String? deviceIdentity,
  }) {
    return VowifiSmsConfig(
      sipServer: sipServer ?? this.sipServer,
      domain: domain ?? this.domain,
      privateIdentity: privateIdentity ?? this.privateIdentity,
      publicIdentity: publicIdentity ?? this.publicIdentity,
      username: username ?? this.username,
      password: password ?? this.password,
      smsc: smsc ?? this.smsc,
      transport: transport ?? this.transport,
      registerExpires: registerExpires ?? this.registerExpires,
      tlsSkipVerify: tlsSkipVerify ?? this.tlsSkipVerify,
      useEpdg: useEpdg ?? this.useEpdg,
      epdgServer: epdgServer ?? this.epdgServer,
      epdgAddresses: epdgAddresses ?? this.epdgAddresses,
      epdgPort: epdgPort ?? this.epdgPort,
      imsi: imsi ?? this.imsi,
      mcc: mcc ?? this.mcc,
      mnc: mnc ?? this.mnc,
      mncLength: mncLength ?? this.mncLength,
      apn: apn ?? this.apn,
      deviceIdentity: deviceIdentity ?? this.deviceIdentity,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'sipServer': sipServer,
      'domain': domain,
      'privateIdentity': privateIdentity,
      'publicIdentity': publicIdentity,
      'username': username,
      'password': password,
      'smsc': smsc,
      'transport': transport.name,
      'registerExpires': registerExpires,
      'tlsSkipVerify': tlsSkipVerify,
      'useEpdg': useEpdg,
      'epdgServer': epdgServer,
      'epdgAddresses': epdgAddresses,
      'epdgPort': epdgPort,
      'imsi': imsi,
      'mcc': mcc,
      'mnc': mnc,
      'mncLength': mncLength,
      'apn': apn,
      'deviceIdentity': deviceIdentity,
    };
  }

  String toJsonString() => jsonEncode(toJson());

  static VowifiSmsConfig fromJson(Map<String, dynamic> json) {
    return VowifiSmsConfig(
      sipServer: (json['sipServer'] as String?) ?? '',
      domain: (json['domain'] as String?) ?? '',
      privateIdentity: (json['privateIdentity'] as String?) ?? '',
      publicIdentity: (json['publicIdentity'] as String?) ?? '',
      username: (json['username'] as String?) ?? '',
      password: (json['password'] as String?) ?? '',
      smsc: (json['smsc'] as String?) ?? '',
      transport: VowifiTransport.values.firstWhere(
        (value) => value.name == json['transport'],
        orElse: () => VowifiTransport.tls,
      ),
      registerExpires: (json['registerExpires'] as int?) ?? 3600,
      tlsSkipVerify: (json['tlsSkipVerify'] as bool?) ?? false,
      useEpdg: (json['useEpdg'] as bool?) ?? false,
      epdgServer: (json['epdgServer'] as String?) ?? '',
      epdgAddresses: ((json['epdgAddresses'] as List<dynamic>?) ?? const [])
          .whereType<String>()
          .toList(growable: false),
      epdgPort: (json['epdgPort'] as int?) ?? 500,
      imsi: (json['imsi'] as String?) ?? '',
      mcc: (json['mcc'] as String?) ?? '',
      mnc: (json['mnc'] as String?) ?? '',
      mncLength: (json['mncLength'] as int?) ?? 0,
      apn: (json['apn'] as String?) ?? 'ims',
      deviceIdentity: (json['deviceIdentity'] as String?) ?? '',
    );
  }
}

class VowifiDigestChallenge {
  const VowifiDigestChallenge({
    required this.method,
    required this.uri,
    required this.rawHeader,
    required this.fields,
  });

  final String method;
  final String uri;
  final String rawHeader;
  final Map<String, String> fields;
}

class VowifiSmsMessage {
  const VowifiSmsMessage({
    required this.direction,
    required this.text,
    required this.timestamp,
    this.peer = '',
    this.status = '',
    this.raw = const <int>[],
  });

  final VowifiSmsDirection direction;
  final String text;
  final DateTime timestamp;
  final String peer;
  final String status;
  final List<int> raw;
}

class VowifiAkaChallenge {
  const VowifiAkaChallenge({
    required this.rand,
    required this.autn,
    this.imsi = '',
  });

  final Uint8List rand;
  final Uint8List autn;
  final String imsi;
}

class VowifiAkaResponse {
  const VowifiAkaResponse({
    required this.res,
    required this.ck,
    required this.ik,
    this.auts = const <int>[],
  });

  final Uint8List res;
  final Uint8List ck;
  final Uint8List ik;
  final List<int> auts;
}

class VowifiSmsEvent {
  const VowifiSmsEvent._({this.state, this.message, this.info, this.error});

  final VowifiSmsConnectionState? state;
  final VowifiSmsMessage? message;
  final String? info;
  final String? error;

  factory VowifiSmsEvent.state(
    VowifiSmsConnectionState state, {
    String? info,
    String? error,
  }) {
    return VowifiSmsEvent._(state: state, info: info, error: error);
  }

  factory VowifiSmsEvent.message(VowifiSmsMessage message) {
    return VowifiSmsEvent._(message: message);
  }

  factory VowifiSmsEvent.info(String info) {
    return VowifiSmsEvent._(info: info);
  }

  factory VowifiSmsEvent.error(String error) {
    return VowifiSmsEvent._(error: error);
  }
}
