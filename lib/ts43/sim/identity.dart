import 'imsi.dart';

/// Source SIM identity, ported from `sim/identity.go`.
class Identity {
  final String iccid;
  final String imsi;
  final String mcc;
  final String mnc;
  final String gid1;

  const Identity({
    required this.iccid,
    required this.imsi,
    required this.mcc,
    required this.mnc,
    this.gid1 = '',
  });

  String get mccMnc => '$mcc$mnc';

  Identity copyWith({
    String? iccid,
    String? imsi,
    String? mcc,
    String? mnc,
    String? gid1,
  }) {
    return Identity(
      iccid: iccid ?? this.iccid,
      imsi: imsi ?? this.imsi,
      mcc: mcc ?? this.mcc,
      mnc: mnc ?? this.mnc,
      gid1: gid1 ?? this.gid1,
    );
  }

  /// Builds an [Identity] from raw EF reads, deriving MCC from the IMSI and the
  /// MNC from the EF_AD MNC length, mirroring `sim.NewIdentity`.
  factory Identity.derive({
    required String iccid,
    required String imsi,
    String gid1 = '',
    required List<int> administrativeData,
  }) {
    if (imsi.isEmpty) {
      throw const FormatException('IMSI is required');
    }
    final mcc = Imsi(imsi).mcc;
    final mncLen = decodeMncLength(administrativeData);
    final mnc = formatMnc(imsi, mncLen);
    return Identity(iccid: iccid, imsi: imsi, mcc: mcc, mnc: mnc, gid1: gid1);
  }
}
