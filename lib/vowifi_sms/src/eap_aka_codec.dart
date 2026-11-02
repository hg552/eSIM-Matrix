import 'dart:typed_data';

class VowifiEapAkaCodec {
  const VowifiEapAkaCodec._();

  static Uint8List buildSynchronizationFailureResponse({
    required int identifier,
    required List<int> auts,
  }) {
    if (auts.length != 14) {
      throw ArgumentError.value(auts.length, 'auts.length', 'must be 14 bytes');
    }

    const eapResponse = 2;
    const eapAka = 23;
    const synchronizationFailure = 4;
    const atAuts = 4;
    const attributeLengthWords = 4;
    const packetLength = 24;

    return Uint8List.fromList(<int>[
      eapResponse,
      identifier & 0xff,
      0,
      packetLength,
      eapAka,
      synchronizationFailure,
      0,
      0,
      atAuts,
      attributeLengthWords,
      ...auts,
    ]);
  }
}
