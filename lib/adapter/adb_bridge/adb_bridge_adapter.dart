import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../euicc_adapter.dart';
import '../../services/adb_bridge_service.dart';
import '../../settings/app_settings.dart';
import '../../utils/apdu_exception.dart';
import '../../utils/error_codes.dart';
import '../../utils/hex_utils.dart';

/// A reader backed by a `shell` helper the person started over ADB.
///
/// This is [NBridgeAdapter] with a different transport: the card operations are
/// the same, but they go to the ADB helper over its binder rather than to the
/// OTBridge provider. A reader's id is the SIM slot index the helper reported.
class AdbBridgeAdapter extends BaseAdapter {
  static final Logger _log = Logger('AdbBridgeAdapter');

  AdbBridgeAdapter() : super(_log);

  String? _slotId;
  int _nextChannelId = 1;
  final Map<int, _AdbBridgeConnection> _connections = {};
  final StreamController<EuiccPortState> _stateController =
      StreamController<EuiccPortState>.broadcast();

  @override
  Stream<EuiccPortState> get stateStream => _stateController.stream;

  @override
  bool get requiresRefresh => true;

  @override
  String? get lastAtr => null;

  @override
  bool get supportsRawApdu => true;

  Future<bool> isAvailable() => AdbBridgeService.isConnected();

  @override
  Future<List<Reader>> listReaders({bool force = false}) async {
    if (!await isAvailable()) {
      return const <Reader>[];
    }

    final slots = await AdbBridgeService.listSlots();
    return slots.map((slot) {
      final slotId = slot['id'] as String? ?? '';
      final displayName = slot['displayName'] as String? ?? 'SIM slot $slotId';
      return Reader(id: slotId, name: displayName, source: this, context: slot);
    }).toList();
  }

  @override
  Future<void> connect(Reader reader) async {
    return runExclusive(() async {
      await disconnect();
      _slotId = reader.id;
      updateConnectedReader(reader);
      _stateController.add(EuiccPortState.open);
    });
  }

  @override
  Future<void> disconnect() async {
    return runExclusive(() async {
      await _closeAllChannels();
      _slotId = null;
      updateConnectedReader(null);
      _stateController.add(EuiccPortState.closed);
    });
  }

  @override
  Future<void> reconnect() async {
    return runExclusive(() async {
      final reader = connectedReader;
      await disconnect();
      if (reader != null) {
        await connect(reader);
      }
    });
  }

  @override
  Future<void> cleanupChannels() => _closeAllChannels();

  @override
  Future<Uint8List> sendRawApdu(Uint8List apdu) async {
    final slotId = _slotId;
    if (slotId == null) {
      throw AppException(AppErrorCode.ERROR_UNKNOWN, message: 'Not connected');
    }

    final responseHex = await AdbBridgeService.transmitBasic(
      slotId: slotId,
      apdu: HexUtils.bytesToHex(apdu),
    );
    return HexUtils.hexToBytes(responseHex);
  }

  @override
  Future<Channel> openChannel({List<String>? aids}) async {
    return runExclusive(() async {
      final slotId = _slotId;
      if (slotId == null) {
        throw AppException(
          AppErrorCode.ERROR_UNKNOWN,
          message: 'Not connected',
        );
      }

      final targetAids = (aids == null || aids.isEmpty)
          ? AppSettings().aids
          : aids;
      if (targetAids.isEmpty) {
        throw AppException(
          AppErrorCode.ERROR_CHANNEL_OPEN_FAILED,
          message: 'No AIDs configured for the ADB bridge channel open',
        );
      }

      if (AppSettings().ensureSingleChannel) {
        await _closeAllChannels();
      }

      final result = await AdbBridgeService.connectLogicalChannel(
        slotId: slotId,
        aids: targetAids,
      );

      final localChannelId = _allocateLocalChannelId();
      final connectionId = result['connectionId'] as String?;
      final selectedAid = result['selectedAid'] as String?;
      final providerChannelNumber = result['channelNumber'] as int?;
      if (connectionId == null || selectedAid == null) {
        throw AppException(
          AppErrorCode.ERROR_CHANNEL_OPEN_FAILED,
          message: 'The ADB bridge returned an incomplete channel response',
        );
      }

      final exposedChannelNumber =
          providerChannelNumber != null && providerChannelNumber > 0
          ? providerChannelNumber
          : localChannelId;

      if (_connections.containsKey(exposedChannelNumber)) {
        throw CardBusyException(
          'ADB bridge channel number collision for $exposedChannelNumber',
        );
      }

      _connections[exposedChannelNumber] = _AdbBridgeConnection(
        connectionId: connectionId,
        slotId: slotId,
        aid: selectedAid,
      );
      return _AdbBridgeChannel(this, exposedChannelNumber, selectedAid);
    });
  }

  Future<Uint8List> transmitLogical(int channelNumber, Uint8List apdu) async {
    final connection = _connections[channelNumber];
    if (connection == null) {
      throw AppException(
        AppErrorCode.ERROR_CHANNEL_OPEN_FAILED,
        message: 'Unknown ADB bridge logical channel',
      );
    }

    final responseHex = await AdbBridgeService.transmitLogical(
      connectionId: connection.connectionId,
      apdu: HexUtils.bytesToHex(apdu),
    );
    return HexUtils.hexToBytes(responseHex);
  }

  Future<void> closeLogicalChannel(int channelNumber) async {
    final connection = _connections.remove(channelNumber);
    if (connection == null) {
      return;
    }
    await AdbBridgeService.closeLogicalChannel(
      connectionId: connection.connectionId,
    );
  }

  Future<void> _closeAllChannels() async {
    final channelIds = _connections.keys.toList();
    for (final channelId in channelIds) {
      try {
        await closeLogicalChannel(channelId);
      } catch (e) {
        _log.warning('Failed to close ADB bridge channel $channelId: $e');
      }
    }
  }

  int _allocateLocalChannelId() {
    for (var attempts = 0; attempts < 19; attempts++) {
      final candidate = _nextChannelId;
      _nextChannelId = (_nextChannelId % 19) + 1;
      if (!_connections.containsKey(candidate)) {
        return candidate;
      }
    }
    throw CardBusyException('All local ADB bridge channel slots are in use');
  }
}

class _AdbBridgeConnection {
  final String connectionId;
  final String slotId;
  final String aid;

  const _AdbBridgeConnection({
    required this.connectionId,
    required this.slotId,
    required this.aid,
  });
}

class _AdbBridgeChannel extends BaseChannel {
  final AdbBridgeAdapter _adapter;
  final String _aid;

  _AdbBridgeChannel(this._adapter, int localChannelNumber, this._aid)
    : super(_adapter, localChannelNumber);

  @override
  String? get aid => _aid;

  @override
  Future<void> close() async {
    await _adapter.closeLogicalChannel(channelNumber);
  }

  @override
  Future<Uint8List> sendRawApdu(Uint8List apdu) async {
    return _adapter.transmitLogical(channelNumber, apdu);
  }
}
