import 'package:flutter/services.dart';

import '../../utils/apdu_exception.dart';
import '../../utils/error_codes.dart';

const String omapiSessionCorruptedCode = 'OMAPI_SESSION_CORRUPTED';
const String omapiProcessHandoffPendingReason =
    'OMAPI same-process engine handoff is still cleaning up';
const String omapiRebootRequiredMessage =
    'SIM/eSIM channel became invalid during the profile operation. The operation may already have taken effect. Restart the device, reopen the app, and refresh profile status before retrying.';

bool isOmapiProcessHandoffPendingError(Object error) {
  if (error is! PlatformException || error.code != omapiSessionCorruptedCode) {
    return false;
  }
  final details = error.details;
  return details is Map &&
      details['reason'] == omapiProcessHandoffPendingReason;
}

bool isOmapiSessionCorruptedError(Object error) {
  if (error is PlatformException) {
    return error.code == omapiSessionCorruptedCode &&
        !isOmapiProcessHandoffPendingError(error);
  }
  if (error is AppException) {
    return error.code == AppErrorCode.ERROR_OMAPI_SESSION_CORRUPTED ||
        (error.originalError is Object &&
            isOmapiSessionCorruptedError(error.originalError as Object));
  }
  return false;
}

bool canAutomaticallyRetryProfileSwitch(
  Object error, {
  required bool commandSubmitted,
}) => !commandSubmitted && !isOmapiSessionCorruptedError(error);

/// Platform codes the OMAPI plugin emits when the APDU channel itself failed.
///
/// These arrive as raw [PlatformException]s rather than [AppException]s, so a
/// predicate that only inspected AppException let a dropped channel escape
/// every retry path and surface as an opaque `control_error`.
const Set<String> transientOmapiPlatformCodes = <String>{
  'TRANSMIT_FAILED',
  'NOT_CONNECTED',
  'CHANNEL_FAILED',
  'CONNECTION_FAILED',
  'CHANNEL_ALREADY_OPEN',
};

/// Whether repeating the profile switch can plausibly succeed.
///
/// A corrupted session is excluded because only a process restart clears it,
/// and an explicit ENABLE_FAILED/DISABLE_FAILED means the card refused the
/// command rather than dropping the transport.
bool isTransientProfileSwitchError(Object error) {
  if (isOmapiSessionCorruptedError(error)) return false;
  final errorStr = error.toString();
  if (errorStr.contains('ENABLE_FAILED:') ||
      errorStr.contains('DISABLE_FAILED:')) {
    return false;
  }
  if (error is PlatformException) {
    return transientOmapiPlatformCodes.contains(error.code);
  }
  if (error is CardBusyException ||
      error is ConditionOfUseNotSatisfiedException ||
      error is ProactiveRefreshException) {
    return true;
  }
  if (error is! AppException) return false;
  return error.code == AppErrorCode.ERROR_BLUETOOTH_TIMEOUT ||
      error.code == AppErrorCode.ERROR_BLUETOOTH_NOT_CONNECTED ||
      error.code == AppErrorCode.ERROR_BLUETOOTH_CONNECT_FAILED ||
      error.code == AppErrorCode.ERROR_BLUETOOTH_DISABLED ||
      error.code == AppErrorCode.ERROR_OMAPI_READER_NOT_AVAILABLE ||
      error.code == AppErrorCode.ERROR_OMAPI_CHANNEL_OPEN_FAILED ||
      error.code == AppErrorCode.ERROR_OMAPI_TRANSMIT_FAILED;
}

class OmapiChannelOwnershipTracker {
  int _nextToken = 0;
  final Map<int, int> _owners = {};

  int claim(int channelId) {
    if (_owners.containsKey(channelId)) {
      throw AppException(
        AppErrorCode.ERROR_OMAPI_CHANNEL_OPEN_FAILED,
        message: 'OMAPI logical channel $channelId already has a live owner',
      );
    }
    final token = ++_nextToken;
    _owners[channelId] = token;
    return token;
  }

  int? currentToken(int channelId) => _owners[channelId];

  bool owns(int channelId, int? token) =>
      token != null && _owners[channelId] == token;

  void ensureOwned(int channelId, int? token) {
    if (owns(channelId, token)) return;
    throw AppException(
      AppErrorCode.ERROR_OMAPI_CHANNEL_OPEN_FAILED,
      message: 'OMAPI channel handle $channelId is stale',
    );
  }

  bool releaseIfOwned(int channelId, int? token) {
    if (!owns(channelId, token)) return false;
    _owners.remove(channelId);
    return true;
  }

  void clear() => _owners.clear();
}

class OmapiSafetyLatch {
  PlatformException? _failure;

  bool get isPoisoned => _failure != null;

  void ensureAvailable() {
    final failure = _failure;
    if (failure != null) {
      throw AppException(
        AppErrorCode.ERROR_OMAPI_SESSION_CORRUPTED,
        message: failure.message ?? omapiRebootRequiredMessage,
        originalError: failure,
      );
    }
  }

  Future<T> invoke<T>(
    MethodChannel channel,
    String method, [
    dynamic arguments,
  ]) async {
    ensureAvailable();
    try {
      return await channel.invokeMethod<T>(method, arguments) as T;
    } on PlatformException catch (error) {
      if (isOmapiProcessHandoffPendingError(error)) {
        throw PlatformException(
          code: 'NOT_CONNECTED',
          message: 'OMAPI lifecycle handoff is still completing',
          details: error.details,
        );
      }
      if (error.code == omapiSessionCorruptedCode) {
        _failure ??= error;
      }
      rethrow;
    }
  }
}
