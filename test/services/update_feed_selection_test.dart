import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/services/update_feed.dart';

/// The feed this project publishes has to be readable by upstream's selection
/// rules, otherwise an installed app never learns that a newer release exists.
void main() {
  final feed = jsonDecode(File('update_feed.json').readAsStringSync());
  final android = Map<String, dynamic>.from(feed['android'] as Map);

  const ourSignatures = [
    'C47350C7BA682B34A3E584A0D58463EA42B1AD73',
    'D1C0F48B370E74D4EA4770ED4C3CD70A3198D31F',
    '65D0571854AFEC519A90F92D7C5D8CF8148DA373',
  ];

  test('the published feed carries the multi channel', () {
    expect(android.containsKey('multi'), isTrue);
  });

  test('offers the newest release to an install that is behind', () {
    final selected = UpdateFeed.selectAndroid(
      android,
      variant: 'multi',
      signatures: ourSignatures,
      currentBuild: 133,
    );

    expect(selected, isNotNull);
    expect(selected!['version'], '1.4.6');
    expect(selected['build'], 146);
    expect(selected['download_url'], contains('releases/download/v1.4.6'));
  });

  test('offers nothing to an install that is already current', () {
    final selected = UpdateFeed.selectAndroid(
      android,
      variant: 'multi',
      signatures: ourSignatures,
      currentBuild: 146,
    );

    expect(selected, isNull);
  });

  test('offers nothing to a build signed by somebody else', () {
    final selected = UpdateFeed.selectAndroid(
      android,
      variant: 'multi',
      signatures: const ['00112233445566778899AABBCCDDEEFF00112233'],
      currentBuild: 133,
    );

    expect(selected, isNull);
  });

  test('does not offer a multi release to another channel', () {
    final selected = UpdateFeed.selectAndroid(
      android,
      variant: 'community',
      signatures: ourSignatures,
      currentBuild: 133,
    );

    expect(selected, isNull);
  });
}
