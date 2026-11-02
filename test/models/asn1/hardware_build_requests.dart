// Builds the ES10c request TLVs for the hardware round-trip, using the
// generated encoders, and writes them to JSON for tools/euicc_probe.py to
// transmit. Companion to hardware_capture_check.dart.
//
//   dart run test/models/asn1/hardware_build_requests.dart \
//       <enabledIccidHex> <disabledIccidHex> /tmp/requests.json
//
// The ICCIDs are the raw bytes as they appear in ProfileInfo, i.e. what
// hardware_capture_check.dart prints.

import 'dart:convert';
import 'dart:io' as io;
import 'dart:io' show exit, stderr, stdout;
import 'dart:typed_data';

import 'package:nlpa2/models/asn1/rsp_definitions.g.dart';

Uint8List fromHex(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  return Uint8List.fromList([
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ]);
}

String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

void main(List<String> args) {
  if (args.length < 3) {
    stderr.writeln('usage: <enabledIccid> <disabledIccid> <out.json>');
    exit(2);
  }
  final enabled = fromHex(args[0]);
  final disabled = fromHex(args[1]);

  // refreshFlag is false throughout: the card is in a reader, so there is no
  // modem to REFRESH, and a proactive REFRESH would only complicate the trace.
  Uint8List enableOf(Uint8List iccid) => EnableProfileRequest(
    profileIdentifier: EnableProfileRequest_profileIdentifier(iccid: iccid),
    refreshFlag: false,
  ).encode();

  Uint8List disableOf(Uint8List iccid) => DisableProfileRequest(
    profileIdentifier: DisableProfileRequest_profileIdentifier(iccid: iccid),
    refreshFlag: false,
  ).encode();

  final steps = <Map<String, String>>[
    {'name': 'profiles-before', 'request': 'BF2D00'},
    {'name': 'disable-enabled', 'request': toHex(disableOf(enabled))},
    {'name': 'profiles-both-disabled', 'request': 'BF2D00'},
    {'name': 'enable-other', 'request': toHex(enableOf(disabled))},
    {'name': 'profiles-other-enabled', 'request': 'BF2D00'},
    {'name': 'disable-other', 'request': toHex(disableOf(disabled))},
    {'name': 'restore-original', 'request': toHex(enableOf(enabled))},
    {'name': 'profiles-after', 'request': 'BF2D00'},
  ];

  io.File(
    args[2],
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(steps));
  for (final step in steps) {
    stdout.writeln('${step['name']!.padRight(24)} ${step['request']}');
  }
  stdout.writeln('\nwrote ${args[2]}');
}
