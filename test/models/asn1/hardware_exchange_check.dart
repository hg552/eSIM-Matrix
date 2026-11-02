// Decodes the trace tools/euicc_exchange.py records, so the enable/disable
// round-trip can be checked with the generated models rather than by eye.
//
//   dart run test/models/asn1/hardware_exchange_check.dart /tmp/responses.json

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

int _failures = 0;

void check(String what, bool ok, [String? detail]) {
  stdout.writeln(
    '  ${ok ? 'ok  ' : 'FAIL'}  $what${detail == null ? '' : ' — $detail'}',
  );
  if (!ok) _failures++;
}

/// iccid -> state, for one GetProfilesInfo response.
Map<String, ProfileState?> statesOf(String hex) {
  final response = ProfileInfoListResponse.decode(fromHex(hex));
  return {
    for (final p in response.profileInfoListOk ?? const <ProfileInfo>[])
      toHex(p.iccid ?? Uint8List(0)): p.profileState,
  };
}

void main(List<String> args) {
  final path = args.isNotEmpty ? args.first : '/tmp/responses.json';
  final file = io.File(path);
  if (!file.existsSync()) {
    stderr.writeln('no trace at $path');
    exit(2);
  }
  final steps = (jsonDecode(file.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();
  final byName = {for (final s in steps) s['name'] as String: s};

  stdout.writeln('enable / disable results');
  for (final name in [
    'disable-enabled',
    'enable-other',
    'disable-other',
    'restore-original',
  ]) {
    final hex = byName[name]?['response'] as String?;
    if (hex == null) continue;
    if (name.startsWith('disable')) {
      final r = DisableProfileResponse.decode(fromHex(hex));
      check(
        name,
        r.disableResult == DisableProfileResponse_disableResult.ok,
        '${r.disableResult}',
      );
    } else {
      final r = EnableProfileResponse.decode(fromHex(hex));
      check(
        name,
        r.enableResult == EnableProfileResponse_enableResult.ok,
        '${r.enableResult}',
      );
    }
  }

  stdout.writeln('\nprofile states at each step');
  final snapshots = <String, Map<String, ProfileState?>>{};
  for (final name in [
    'profiles-before',
    'profiles-both-disabled',
    'profiles-other-enabled',
    'profiles-after',
  ]) {
    final hex = byName[name]?['response'] as String?;
    if (hex == null) continue;
    final states = statesOf(hex);
    snapshots[name] = states;
    final rendered = states.entries
        .map((e) => '${e.key.substring(e.key.length - 6)}=${e.value?.name}')
        .join('  ');
    stdout.writeln('  ${name.padRight(24)} $rendered');
  }

  final before = snapshots['profiles-before'];
  final bothOff = snapshots['profiles-both-disabled'];
  final otherOn = snapshots['profiles-other-enabled'];
  final after = snapshots['profiles-after'];

  stdout.writeln('\ntransitions');
  if (before != null && bothOff != null) {
    check(
      'disabling the enabled profile left nothing enabled',
      !bothOff.values.any((s) => s == ProfileState.enabled),
    );
  }
  if (before != null && otherOn != null) {
    final wasDisabled = before.entries
        .firstWhere((e) => e.value == ProfileState.disabled)
        .key;
    check(
      'the other profile became enabled',
      otherOn[wasDisabled] == ProfileState.enabled,
      wasDisabled.substring(wasDisabled.length - 6),
    );
  }
  if (before != null && after != null) {
    check(
      'the card ended in its original state',
      '$after' == '$before',
      '$after',
    );
  }

  stdout.writeln(
    '\n${_failures == 0 ? 'all checks passed' : '$_failures FAILED'}',
  );
  exit(_failures == 0 ? 0 : 1);
}
