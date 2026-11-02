/// Tracks whether a foreground flow currently owns the card.
///
/// Two card sessions on one adapter share a logical channel, so whichever
/// finishes first closes it under the other and the next command comes back
/// 6881. A profile download is the long case: it keeps its authenticated
/// channel open across the user's confirmation. Background card work checks
/// here and stands down rather than opening a session alongside it.
///
/// Deliberately free of imports so every layer can consult it -- the adapters
/// must not have to depend on the services.
class ForegroundCardSession {
  ForegroundCardSession._();

  /// A count, not a flag: overlapping holders must not clear it early.
  static int _holders = 0;

  static bool get isOpen => _holders > 0;

  static void begin() => _holders++;

  /// Releases one hold. Extra releases are ignored, because holders release
  /// both on their terminal state and again from dispose().
  static void end() {
    if (_holders > 0) _holders--;
  }
}
