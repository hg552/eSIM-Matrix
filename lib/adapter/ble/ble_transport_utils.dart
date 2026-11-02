import 'dart:async';
import 'dart:math';

import 'package:ble/ble.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../euicc_adapter.dart';

int calculateBleWriteChunkSize(int mtu, {int maxChunkSize = 240}) {
  return min(maxChunkSize, max(20, mtu - 3));
}

bool preferWriteWithoutResponse({
  required bool canWrite,
  required bool canWriteWithoutResponse,
}) {
  return !canWrite && canWriteWithoutResponse;
}

/// Brings up the Bluetooth link to [device], retrying up to [attempts] times.
///
/// When [progress] is given, each attempt is published to it as the
/// [ReaderConnectStep.connectingBluetooth] step, so a retry shows as one
/// rather than as a stall.
Future<void> connectBleDevice(
  BluetoothDevice device,
  Logger log, {
  int attempts = 3,
  Duration timeout = const Duration(seconds: 10),
  int preferredMtu = 247,
  ValueNotifier<ReaderConnectProgress?>? progress,
}) async {
  Object? lastError;
  StackTrace? lastStack;

  for (var attempt = 1; attempt <= attempts; attempt++) {
    progress?.value = ReaderConnectProgress(
      ReaderConnectStep.connectingBluetooth,
      attempt: attempt,
      attempts: attempts,
    );
    try {
      if (kIsWeb) {
        await device.connect(autoConnect: false, timeout: timeout);
      } else {
        await (device as dynamic).connect(
          autoConnect: false,
          mtu: null,
          timeout: timeout,
        );
      }
      if (!kIsWeb) {
        try {
          await device.requestMtu(preferredMtu);
        } catch (error) {
          log.fine(
            'BLE MTU negotiation unavailable; using ${device.mtuNow}: $error',
          );
        }
        // A profile transfer moves tens of kilobytes as write-without-response
        // frames, and the controller sends at most one of those per connection
        // interval. These writers ask for a power-saving interval -- a link
        // left at their preference has been measured at one 20-byte frame per
        // second, which is minutes for a small profile and long enough on a
        // large one to blow the per-APDU response deadline. Asking for the
        // high-priority interval is the only lever the host has over this.
        // Android and Windows only; the call throws elsewhere and the link
        // still works, just at the writer's pace.
        try {
          await device.requestConnectionPriority(
            connectionPriorityRequest: ConnectionPriority.high,
          );
        } catch (error) {
          log.fine('BLE connection priority unavailable: $error');
        }
      }
      return;
    } catch (error, stack) {
      lastError = error;
      lastStack = stack;
      log.warning('BLE connect attempt $attempt/$attempts failed: $error');
      try {
        if (kIsWeb) {
          await device.disconnect();
        } else {
          await (device as dynamic).disconnect(queue: false);
        }
      } catch (_) {}
      if (attempt < attempts) {
        await Future.delayed(Duration(milliseconds: 350 * attempt));
      }
    }
  }

  Error.throwWithStackTrace(lastError!, lastStack!);
}

Future<void> writeBleChunks({
  required BluetoothDevice device,
  required BluetoothCharacteristic characteristic,
  required Uint8List data,
  int maxChunkSize = 240,
}) async {
  final chunkSize = kIsWeb
      ? min(20, maxChunkSize)
      : calculateBleWriteChunkSize(device.mtuNow, maxChunkSize: maxChunkSize);
  final withoutResponse = preferWriteWithoutResponse(
    canWrite: characteristic.properties.write,
    canWriteWithoutResponse: characteristic.properties.writeWithoutResponse,
  );

  for (var offset = 0; offset < data.length; offset += chunkSize) {
    final end = min(offset + chunkSize, data.length);
    await characteristic.write(
      Uint8List.sublistView(data, offset, end),
      withoutResponse: withoutResponse,
    );
    if (withoutResponse) {
      await Future.delayed(const Duration(milliseconds: 8));
    }
  }
}
