import 'package:flutter/services.dart';

import '../../utils/platform_adapter.dart';

/// Where the app reaches the modem's bus, through the process Shizuku runs.
///
/// An app may not open a socket on the bus, and may not use one another
/// process opened, so the socket stays in that process and what crosses to the
/// app is the traffic itself: a datagram to send, or a wait for one to arrive.
/// An address on the bus is a node and a port rather than anything Java can
/// name, which is why these calls end in the app's own native code.
class QrtrHost {
  static const MethodChannel _channel = MethodChannel('nlpa2/qrtr');

  /// Whether this device is likely to have a QRTR bus.
  ///
  /// A QRTR bus cannot be enumerated, and opening its socket takes Shizuku, so
  /// the sign to go on is the SoC: on a Qualcomm device the bus is there even
  /// when nothing is plugged into it.
  static Future<bool> isSupported() async {
    if (!PlatformX.isAndroid) return false;

    return await _channel.invokeMethod<bool>('isSupported') ?? false;
  }

  /// Whether Shizuku is installed, running, and new enough for user services.
  static Future<bool> isAvailable() async {
    if (!PlatformX.isAndroid) return false;

    return await _channel.invokeMethod<bool>('isAvailable') ?? false;
  }

  /// Whether the user has already let this app use Shizuku.
  static Future<bool> hasPermission() async {
    if (!PlatformX.isAndroid) return false;

    return await _channel.invokeMethod<bool>('hasPermission') ?? false;
  }

  /// Ask the user for that permission, answering whether it was granted.
  static Future<bool> requestPermission() async {
    if (!PlatformX.isAndroid) return false;

    return await _channel.invokeMethod<bool>('requestPermission') ?? false;
  }

  /// What the handset says about itself, so a scan can explain an empty list
  /// instead of leaving the reader wondering whether the ROM is at fault.
  static Future<ReaderPlatformInfo> platformInfo() async {
    if (!PlatformX.isAndroid) return const ReaderPlatformInfo();

    final result = await _channel.invokeMapMethod<String, Object?>(
      'platformInfo',
    );
    return ReaderPlatformInfo.fromMap(result);
  }

  /// Open a socket on the bus, answering the descriptor it has there.
  static Future<int> openBus() async {
    final fd = await _channel.invokeMethod<int>('openBus');
    if (fd == null || fd < 0) {
      throw StateError('Could not open a socket on the modem bus');
    }

    return fd;
  }

  /// The node that socket is bound to, which is where a lookup starts.
  static Future<int> node(int bus) async {
    return await _channel.invokeMethod<int>('busNode', {'fd': bus}) ?? 0;
  }

  /// Send one datagram to an address on the bus.
  static Future<void> send(int bus, int node, int port, Uint8List data) async {
    await _channel.invokeMethod<void>('send', {
      'fd': bus,
      'node': node,
      'port': port,
      'data': data,
    });
  }

  /// Wait for one datagram, or give up after `timeoutMs`.
  ///
  /// The address it came from is in front of the message: node then port, both
  /// 32 bit little endian. Nothing arriving in time is answered with null.
  static Future<Uint8List?> receive(int bus, int timeoutMs) async {
    return await _channel.invokeMethod<Uint8List>('receive', {
      'fd': bus,
      'timeoutMs': timeoutMs,
    });
  }

  /// Let the socket in that process go.
  static Future<void> closeBus(int bus) async {
    if (!PlatformX.isAndroid) return;

    await _channel.invokeMethod<void>('closeBus', {'fd': bus});
  }
}

/// The parts of [Build] and [PackageManager] that decide which reader
/// transports can exist on this phone at all.
class ReaderPlatformInfo {
  const ReaderPlatformInfo({
    this.hardware = '',
    this.socManufacturer = '',
    this.socModel = '',
    this.isQualcomm = false,
    this.secureElementFeature = false,
    this.omapiUiccFeature = false,
  });

  factory ReaderPlatformInfo.fromMap(Map<String, Object?>? map) {
    if (map == null) return const ReaderPlatformInfo();
    return ReaderPlatformInfo(
      hardware: (map['hardware'] as String?) ?? '',
      socManufacturer: (map['socManufacturer'] as String?) ?? '',
      socModel: (map['socModel'] as String?) ?? '',
      isQualcomm: (map['isQualcomm'] as bool?) ?? false,
      secureElementFeature: (map['secureElementFeature'] as bool?) ?? false,
      omapiUiccFeature: (map['omapiUiccFeature'] as bool?) ?? false,
    );
  }

  final String hardware;
  final String socManufacturer;
  final String socModel;
  final bool isQualcomm;

  /// Whether the ROM publishes `android.hardware.secure_element`, the HAL the
  /// SE HAL reader talks to.
  final bool secureElementFeature;

  /// Whether the ROM publishes `android.hardware.se.omapi.uicc`, without
  /// which the built-in OMAPI reader can never return a SIM slot.
  final bool omapiUiccFeature;

  /// A short label such as `qcom SM8650` or `MTK MT6769Z`, for a message that
  /// has to name the chip instead of guessing at the ROM.
  String get socLabel {
    final parts = [
      socManufacturer,
      socModel.isEmpty ? hardware : socModel,
    ].where((part) => part.trim().isNotEmpty).toList();
    if (parts.isEmpty) return 'unknown SoC';
    return parts.join(' ');
  }
}
