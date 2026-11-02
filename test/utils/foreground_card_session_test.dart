import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/utils/foreground_card_session.dart';

/// The counter that keeps background card work off the card while a foreground
/// flow owns it.
///
/// A download keeps its authenticated channel open across the user's
/// confirmation. Background work that opened its own session at the same time
/// shared a logical channel with it, and whichever finished first closed it
/// under the other, which the card answers with 6881.
void main() {
  setUp(() {
    // The counter is static, so unwind anything a previous test left held.
    while (ForegroundCardSession.isOpen) {
      ForegroundCardSession.end();
    }
  });

  test('starts clear', () {
    expect(ForegroundCardSession.isOpen, isFalse);
  });

  test('a single holder raises and clears it', () {
    ForegroundCardSession.begin();
    expect(ForegroundCardSession.isOpen, isTrue);

    ForegroundCardSession.end();
    expect(ForegroundCardSession.isOpen, isFalse);
  });

  test('overlapping holders cannot clear it early', () {
    // Two downloads, or a retry overlapping its predecessor: the first to
    // finish must not hand the card back while the second is still using it.
    ForegroundCardSession.begin();
    ForegroundCardSession.begin();

    ForegroundCardSession.end();
    expect(
      ForegroundCardSession.isOpen,
      isTrue,
      reason: 'still held by the second holder',
    );

    ForegroundCardSession.end();
    expect(ForegroundCardSession.isOpen, isFalse);
  });

  test('an extra release cannot drive it negative', () {
    // dispose() releases unconditionally, so it can run after a terminal state
    // has already released. That must not leave the counter below zero, or the
    // next download would fail to hold the card at all.
    ForegroundCardSession.begin();
    ForegroundCardSession.end();
    ForegroundCardSession.end();
    ForegroundCardSession.end();

    expect(ForegroundCardSession.isOpen, isFalse);

    ForegroundCardSession.begin();
    expect(
      ForegroundCardSession.isOpen,
      isTrue,
      reason: 'one begin must still be enough to hold the card',
    );
    ForegroundCardSession.end();
  });

  test('releasing without ever holding is harmless', () {
    ForegroundCardSession.end();
    expect(ForegroundCardSession.isOpen, isFalse);

    ForegroundCardSession.begin();
    expect(ForegroundCardSession.isOpen, isTrue);
    ForegroundCardSession.end();
    expect(ForegroundCardSession.isOpen, isFalse);
  });
}
