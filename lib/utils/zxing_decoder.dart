import 'dart:io' as io;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:zxing_lib/zxing.dart' hide Reader;
import 'package:zxing_lib/common.dart';
import 'package:logging/logging.dart';

final _log = Logger('ZxingDecoder');

Future<String?> decodeQrWithZxing(String path) async {
  try {
    final bytes = await io.File(path).readAsBytes();
    return decodeQrBytesWithZxing(bytes);
  } catch (e) {
    _log.warning("zxing_lib file read failed: $e");
    return null;
  }
}

Future<String?> decodeQrBytesWithZxing(Uint8List bytes) async {
  try {
    final image = img.decodeImage(bytes);
    if (image == null) return null;

    final width = image.width;
    final height = image.height;

    final Int32List pixels = Int32List(width * height);
    int i = 0;
    for (final pixel in image) {
      final r = pixel.r.toInt();
      final g = pixel.g.toInt();
      final b = pixel.b.toInt();
      pixels[i++] = (r << 16) | (g << 8) | b;
    }

    final luminanceSource = RGBLuminanceSource(width, height, pixels);
    final reader = MultiFormatReader();
    for (final source in [luminanceSource, luminanceSource.invert()]) {
      for (final binarizer in [
        HybridBinarizer(source),
        GlobalHistogramBinarizer(source),
      ]) {
        try {
          final result = reader.decode(BinaryBitmap(binarizer));
          final text = result.text.trim();
          if (text.isNotEmpty) return text;
        } catch (_) {}
      }
    }
    return null;
  } catch (e) {
    _log.warning("zxing_lib decode failed: $e");
    return null;
  }
}
