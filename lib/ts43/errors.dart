import 'response.dart';
import 'enums.dart';

/// Carrier rejected a TS.43 operation. Ported from `ts43-go/ts43/errors.go`.
class CarrierDeniedError implements Exception {
  final Operation operation;
  final OdsaResponse? result;
  CarrierDeniedError({required this.operation, this.result});

  @override
  String toString() {
    if (result != null && result!.generalErrorText.isNotEmpty) {
      return '${operation.value} denied: ${result!.generalErrorText}';
    }
    return '${operation.value} denied';
  }
}

/// HTTP error carrying the status code, used for 511 retry handling.
/// Ported from `ts43-go/http/client.go` HTTPError.
class Ts43HttpError implements Exception {
  final int statusCode;
  final Map<String, String> headers;
  final List<int> body;
  Ts43HttpError({
    required this.statusCode,
    this.headers = const {},
    this.body = const [],
  });

  @override
  String toString() => 'TS.43 HTTP status $statusCode';
}

/// Entitlement discovery errors.
class EntitlementException implements Exception {
  final String message;
  const EntitlementException(this.message);
  @override
  String toString() => message;
}

const entitlementNotFound = 'entitlement config not found';
const entitlementAmbiguous = 'entitlement config is ambiguous';
const entitlementUnsupported = 'entitlement transfer is unsupported';

/// Websheet flow control errors.
class WebsheetException implements Exception {
  final String message;
  const WebsheetException(this.message);
  @override
  String toString() => message;
}

const websheetDismissed = 'websheet dismissed';
const websheetDefaultSmdpUnsupported =
    'websheet default SM-DP+ callback is unsupported';

bool isHttpStatus(Object? err, int status) =>
    err is Ts43HttpError && err.statusCode == status;
