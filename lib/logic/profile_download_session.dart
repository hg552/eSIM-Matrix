import 'dart:typed_data';
import '../models/asn1/rsp_definitions.g.dart';
import '../utils/hex_utils.dart';

/// Manages the state and flow of a profile download session
/// Following SGP.22 ES9+ and ES10 interaction flow
class ProfileDownloadSession {
  // ES10 data
  EUICCInfo1? _euiccInfo1;
  Uint8List? _euiccChallenge;

  // ES9+ responses
  Uint8List? _transactionId;
  String? _transactionIdHex;
  Uint8List? _serverCertificate;

  AuthenticateClientResponseEs9? _authenticateClientResponse;
  String? _authenticateClientFunctionStatus;

  // ES10 responses
  AuthenticateResponseOk? _authenticateServerResponse;

  // Activation code data
  final String? _smdpAddress;
  String? _confirmationCode;

  ProfileDownloadSession({
    required String smdpAddress,
    String? matchingId,
    String? confirmationCode,
  }) : _smdpAddress = smdpAddress,
       _confirmationCode = confirmationCode;

  AuthenticateClientResponseEs9? get authenticateClientResponse =>
      _authenticateClientResponse;
  String? get confirmationCode => _confirmationCode;

  void setConfirmationCode(String code) {
    _confirmationCode = code;
  }

  // Step 1: Process EUICCInfo1 from eUICC
  void processEuiccInfo1(Uint8List euiccInfo1Bytes) {
    _euiccInfo1 = EUICCInfo1.decode(euiccInfo1Bytes);
  }

  // Step 2: Process EuiccChallenge from eUICC
  void processEuiccChallenge(Uint8List challengeBytes) {
    _euiccChallenge = challengeBytes;
  }

  // Step 3: Build InitiateAuthenticationRequest for ES9+
  InitiateAuthenticationRequest getInitiateAuthenticationRequest() {
    if (_euiccInfo1 == null || _euiccChallenge == null) {
      throw Exception('Must process EUICCInfo1 and EuiccChallenge first');
    }

    return InitiateAuthenticationRequest(
      euiccChallenge: _euiccChallenge,
      euiccInfo1: _euiccInfo1,
      smdpAddress: _smdpAddress,
    );
  }

  // Step 4: Process InitiateAuthenticationResponse from ES9+
  ///
  /// [transactionId] is the hex text the SM-DP+ sent. It is decoded once here
  /// so everything downstream works in the octets SGP.22 defines
  /// (TransactionId ::= OCTET STRING (SIZE(1..16))); hashCc is computed over
  /// them, so hashing the hex text instead yields a code the server rejects.
  /// The original text is kept verbatim for the ES9+ JSON, which must echo the
  /// server's own spelling rather than a re-encoded one.
  void processInitiateAuthenticationResponse(
    String functionExecutionStatus,
    String transactionId,
    Uint8List serverCertificate,
  ) {
    _transactionIdHex = transactionId;
    _transactionId = HexUtils.hexToBytes(transactionId);
    _serverCertificate = serverCertificate;
  }

  // Step 5: (AuthenticateServer is called directly in download page)

  // Step 6: Process AuthenticateServerResponse from eUICC
  void processAuthenticateServerResponse(AuthenticateResponseOk response) {
    _authenticateServerResponse = response;
  }

  // Step 7: Build AuthenticateClientRequest for ES9+
  AuthenticateClientRequest getAuthenticateClientRequest() {
    if (_authenticateServerResponse == null || _transactionId == null) {
      throw Exception('Must process AuthenticateServerResponse first');
    }

    final authServerResp = AuthenticateServerResponse(
      authenticateResponseOk: _authenticateServerResponse,
    );

    return AuthenticateClientRequest(
      transactionId: _transactionId,
      authenticateServerResponse: authServerResp,
    );
  }

  // Step 8: Process AuthenticateClientResponse from ES9+
  void processAuthenticateClientResponse(
    String functionExecutionStatus,
    AuthenticateClientResponseEs9 response,
  ) {
    _authenticateClientFunctionStatus = functionExecutionStatus;
    _authenticateClientResponse = response;
  }

  // Check if authentication was successful
  bool isClientAuthenticatedSuccessfully() {
    return _authenticateClientResponse != null &&
        _authenticateClientFunctionStatus == 'Executed-Success';
  }

  // Get profile metadata if available
  StoreMetadataRequest? getProfileMetadata() {
    return _authenticateClientResponse?.authenticateClientOk?.profileMetadata;
  }

  // Get SMDP signed data for profile download
  SmdpSigned2? getSmdpSigned2() {
    return _authenticateClientResponse?.authenticateClientOk?.smdpSigned2;
  }

  // Get SMDP signature for profile download
  Uint8List? getSmdpSignature2() {
    return _authenticateClientResponse?.authenticateClientOk?.smdpSignature2;
  }

  /// The transaction id as octets, for hashCc and ASN.1 fields.
  Uint8List? getTransactionId() {
    return _transactionId;
  }

  /// The transaction id as the SM-DP+ spelled it, for ES9+ JSON bodies.
  String? getTransactionIdHex() {
    return _transactionIdHex;
  }

  Uint8List? getServerCertificate() {
    final cert2 =
        _authenticateClientResponse?.authenticateClientOk?.smdpCertificate;
    if (cert2 != null) {
      return cert2.encode();
    }
    return _serverCertificate;
  }
}
