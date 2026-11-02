import 'dart:typed_data';

class VowifiIkeDatagramCodec {
  const VowifiIkeDatagramCodec._();

  static Uint8List frame(Uint8List payload, {required bool natt}) {
    if (!natt) {
      return payload;
    }
    return Uint8List.fromList(<int>[0, 0, 0, 0, ...payload]);
  }

  static Uint8List stripNattMarker(Uint8List payload) {
    if (payload.length >= 4 &&
        payload[0] == 0 &&
        payload[1] == 0 &&
        payload[2] == 0 &&
        payload[3] == 0) {
      return payload.sublist(4);
    }
    return payload;
  }
}
