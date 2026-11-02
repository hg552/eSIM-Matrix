import 'package:flutter/services.dart';

import '../utils/error_codes.dart';

/// The app's door to a card-access helper a person starts over ADB.
///
/// The helper runs as the `shell` user, which the platform trusts with the
/// logical-channel and APDU operations an ordinary app is refused. This service
/// shows the command that starts it, holds the connection window open while the
/// person runs it, and then speaks the same operations [NBridgeService] speaks
/// to OTBridge — the transport differs, the card work does not.
class AdbBridgeService {
  AdbBridgeService._();

  static const MethodChannel _channel = MethodChannel('nlpa2/adb_bridge');
  static const EventChannel _events = EventChannel('nlpa2/adb_bridge/events');

  /// `true` while a `shell` helper is connected, pushed as it comes and goes.
  static Stream<bool> get connectionState =>
      _events.receiveBroadcastStream().map((event) => event == 'connected');

  /// The `adb` command a person runs on their computer to connect.
  static Future<String> connectCommand() async {
    return await _channel.invokeMethod<String>('getConnectCommand') ?? '';
  }

  static Future<bool> isConnected() async {
    return await _channel.invokeMethod<bool>('isConnected') ?? false;
  }

  /// Open a connection window; the returned duration is how long it stays open.
  static Future<Duration> beginConnect({
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final ms =
        await _channel.invokeMethod<int>('beginConnect', <String, dynamic>{
          'timeoutMs': timeout.inMilliseconds,
        }) ??
        timeout.inMilliseconds;
    return Duration(milliseconds: ms);
  }

  static Future<void> cancelConnect() async {
    await _channel.invokeMethod<void>('cancelConnect');
  }

  static Future<void> disconnect() async {
    await _channel.invokeMethod<void>('disconnect');
  }

  static Future<List<Map<String, dynamic>>> listSlots() async {
    final result = await _invokeMapMethod('listSlots');
    final slots = (result['slots'] as List<dynamic>? ?? const <dynamic>[]);
    return slots
        .whereType<Map<dynamic, dynamic>>()
        .map(
          (slot) => Map<String, dynamic>.from(
            slot.map((key, value) => MapEntry(key.toString(), value)),
          ),
        )
        .toList();
  }

  static Future<Map<String, dynamic>> connectLogicalChannel({
    required String slotId,
    required List<String> aids,
  }) {
    return _invokeMapMethod('connectLogicalChannel', <String, dynamic>{
      'slotId': slotId,
      'aids': aids,
    });
  }

  static Future<String> transmitLogical({
    required String connectionId,
    required String apdu,
  }) async {
    final result = await _invokeMapMethod('transmitLogical', <String, dynamic>{
      'connectionId': connectionId,
      'apdu': apdu,
    });
    return result['responseApdu'] as String;
  }

  static Future<String> transmitBasic({
    required String slotId,
    required String apdu,
  }) async {
    final result = await _invokeMapMethod('transmitBasic', <String, dynamic>{
      'slotId': slotId,
      'apdu': apdu,
    });
    return result['responseApdu'] as String;
  }

  static Future<void> closeLogicalChannel({
    required String connectionId,
  }) async {
    await _invokeMapMethod('closeLogicalChannel', <String, dynamic>{
      'connectionId': connectionId,
    });
  }

  static Future<Map<String, dynamic>> _invokeMapMethod(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    final raw = await _channel.invokeMethod<dynamic>(method, arguments);
    final result = Map<String, dynamic>.from(raw as Map);
    final ok = result['ok'] == true;
    if (!ok) {
      final errorCode = (result['errorCode'] as String?) ?? 'ERROR';
      final errorMessage =
          result['errorMessage'] as String? ?? 'Unknown ADB bridge error';
      if (errorCode == 'NO_BRIDGE') {
        throw AppException(
          AppErrorCode.ERROR_CHANNEL_OPEN_FAILED,
          message: 'ADB bridge $method: $errorMessage',
          originalError: result,
        );
      }
      throw PlatformException(
        code: errorCode,
        message: errorMessage,
        details: result,
      );
    }
    return result;
  }
}
