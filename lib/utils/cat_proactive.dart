import 'dart:typed_data';

/// Card Application Toolkit helpers for completing a pending proactive command.
///
/// A card that starts a proactive session keeps it open until the terminal
/// answers with a TERMINAL RESPONSE. Readers that only tunnel APDUs never
/// answer, so an eUICC that raises REFRESH after a profile state change can
/// keep rejecting every later command with 6985 until it is power cycled.
/// These helpers let an adapter close that session the way a handset does.
///
/// STATUS/FETCH/TERMINAL RESPONSE follow ETSI TS 102 221; the proactive command
/// encoding follows ETSI TS 102 223, and REFRESH qualifier 0x09 (eUICC profile
/// state change) comes from 3GPP TS 31.111.
class CatProactive {
  const CatProactive._();

  /// STATUS. A card with a waiting proactive command answers 91xx.
  static Uint8List status() =>
      Uint8List.fromList(<int>[0x80, 0xF2, 0x00, 0x00, 0x00]);

  /// FETCH. [length] is the SW2 of the 91xx that advertised the command.
  static Uint8List fetch(int length) =>
      Uint8List.fromList(<int>[0x80, 0x12, 0x00, 0x00, length & 0xFF]);

  /// TERMINAL RESPONSE carrying [details] and [generalResult].
  static Uint8List terminalResponse(
    ProactiveCommandDetails details, {
    required int generalResult,
  }) {
    final body = <int>[
      // Command details, echoed back from the fetched command.
      0x81, 0x03, details.number, details.type, details.qualifier,
      // Device identities: source terminal (0x82), destination UICC (0x81).
      0x82, 0x02, 0x82, 0x81,
      // Result.
      0x83, 0x01, generalResult & 0xFF,
    ];
    if (body.length > 0xFF) {
      throw const CatProactiveException('TERMINAL RESPONSE body is too long');
    }
    return Uint8List.fromList(<int>[
      0x80,
      0x14,
      0x00,
      0x00,
      body.length,
      ...body,
    ]);
  }

  /// Command performed successfully.
  static const int resultSuccess = 0x00;

  /// Terminal currently unable to process command.
  static const int resultUnableToProcess = 0x20;

  /// Parses the command details of a FETCH response, which still carries SW.
  ///
  /// Throws [CatProactiveException] when the response is not a well formed
  /// proactive command, so a caller never answers a command it misread.
  static ProactiveCommandDetails parseFetchResponse(Uint8List response) {
    if (response.length < 2) {
      throw const CatProactiveException(
        'FETCH response is missing a status word',
      );
    }
    final payload = response.sublist(0, response.length - 2);
    if (payload.isEmpty || payload[0] != 0xD0) {
      throw const CatProactiveException(
        'FETCH did not return a proactive command BER-TLV',
      );
    }

    final outer = _readLength(payload, 1);
    final end = outer.offset + outer.value;
    if (end > payload.length) {
      throw const CatProactiveException('Truncated proactive command BER-TLV');
    }

    for (final tlv in _parseComprehensionTlvs(
      payload.sublist(outer.offset, end),
    )) {
      // Bit 8 of a COMPREHENSION-TLV tag is the comprehension required flag.
      if (tlv.tag & 0x7F != 0x01) continue;
      if (tlv.value.length != 3) {
        throw const CatProactiveException('Invalid command details TLV');
      }
      return ProactiveCommandDetails(
        number: tlv.value[0],
        type: tlv.value[1],
        qualifier: tlv.value[2],
      );
    }
    throw const CatProactiveException(
      'Proactive command is missing command details',
    );
  }

  static List<_Tlv> _parseComprehensionTlvs(Uint8List data) {
    final result = <_Tlv>[];
    var offset = 0;
    while (offset < data.length) {
      var tag = data[offset];
      offset += 1;
      if (tag == 0x7F) {
        // Three byte tag form.
        if (offset + 2 > data.length) {
          throw const CatProactiveException('Truncated COMPREHENSION-TLV tag');
        }
        tag = (tag << 16) | (data[offset] << 8) | data[offset + 1];
        offset += 2;
      }
      final length = _readLength(data, offset);
      final end = length.offset + length.value;
      if (end > data.length) {
        throw const CatProactiveException('Truncated COMPREHENSION-TLV value');
      }
      result.add(_Tlv(tag, data.sublist(length.offset, end)));
      offset = end;
    }
    return result;
  }

  static _Length _readLength(Uint8List data, int offset) {
    if (offset >= data.length) {
      throw const CatProactiveException('Truncated BER-TLV length');
    }
    final first = data[offset];
    if (first < 0x80) return _Length(first, offset + 1);

    final count = first & 0x7F;
    if (count == 0 || count > 4 || offset + 1 + count > data.length) {
      throw const CatProactiveException('Invalid BER-TLV length');
    }
    var value = 0;
    for (var i = 0; i < count; i++) {
      value = (value << 8) | data[offset + 1 + i];
    }
    return _Length(value, offset + 1 + count);
  }
}

class CatProactiveException implements Exception {
  const CatProactiveException(this.message);

  final String message;

  @override
  String toString() => 'CatProactiveException: $message';
}

/// The command details of a fetched proactive command.
class ProactiveCommandDetails {
  const ProactiveCommandDetails({
    required this.number,
    required this.type,
    required this.qualifier,
  });

  final int number;
  final int type;
  final int qualifier;

  /// REFRESH, the only command an eUICC raises for a profile state change.
  static const int typeRefresh = 0x01;

  /// REFRESH qualifier "eUICC profile state change" (3GPP TS 31.111).
  static const int qualifierProfileStateChange = 0x09;

  /// REFRESH qualifier "UICC reset".
  static const int qualifierUiccReset = 0x04;

  /// REFRESH qualifier "NAA session reset".
  static const int qualifierNaaSessionReset = 0x06;

  bool get isRefresh => type == typeRefresh;

  /// How a reader that can only tunnel APDUs should answer this command.
  ///
  /// A profile state change is the one REFRESH a tunnelling reader may report
  /// as performed: the eUICC only needs the terminal to acknowledge that it
  /// dropped the old profile's session. Every other REFRESH asks for a real
  /// card or application reset, which has to be carried out rather than
  /// claimed. Anything that is not a REFRESH gets the standard answer from a
  /// terminal without that capability, which still closes the session.
  CatResponseDecision get decision {
    if (!isRefresh) return CatResponseDecision.declineUnableToProcess;
    if (qualifier == qualifierProfileStateChange) {
      return CatResponseDecision.acknowledgeSuccess;
    }
    if (qualifier == qualifierNaaSessionReset) {
      // A NAA session reset does not need the card to lose power: a terminal
      // performs it by dropping the application session. This is the REFRESH a
      // card raises after a profile switch, and leaving it unperformed is what
      // strands the modem on the previous profile.
      return CatResponseDecision.restartNaaSession;
    }
    return CatResponseDecision.requiresCardReset;
  }

  @override
  String toString() =>
      'ProactiveCommandDetails(number: 0x${_hex(number)}, '
      'type: 0x${_hex(type)}, qualifier: 0x${_hex(qualifier)})';

  static String _hex(int value) =>
      value.toRadixString(16).padLeft(2, '0').toUpperCase();
}

enum CatResponseDecision {
  /// Answer TERMINAL RESPONSE with "command performed successfully".
  acknowledgeSuccess,

  /// Drop every logical channel so the application session really restarts,
  /// then answer "command performed successfully".
  restartNaaSession,

  /// Answer TERMINAL RESPONSE with "terminal currently unable to process".
  declineUnableToProcess,

  /// Do not answer; the card needs a real reset before it settles.
  requiresCardReset,
}

class _Tlv {
  const _Tlv(this.tag, this.value);

  final int tag;
  final Uint8List value;
}

class _Length {
  const _Length(this.value, this.offset);

  final int value;
  final int offset;
}
