/// When the app is allowed to look for a new version, and when it is allowed
/// to say something about it.
///
/// The check reaches the network, so it must not run on every launch, and a
/// version the user dismissed must not come back every time the app starts.
/// These rules are pure so they can be tested without a device or a network.
class UpdateCheckPolicy {
  UpdateCheckPolicy._();

  /// How long to wait between two checks of the same build.
  static const Duration interval = Duration(hours: 24);

  /// Whether a network check is due now.
  ///
  /// A new build of the app always checks once — that is the moment a user
  /// upgrades and the feed may already know about something newer.
  static bool shouldCheck({
    required DateTime? lastCheckAt,
    required int lastCheckBuild,
    required int currentBuild,
    required DateTime now,
    Duration interval = interval,
  }) {
    if (lastCheckAt == null) return true;
    if (lastCheckBuild != currentBuild) return true;
    return now.difference(lastCheckAt) >= interval;
  }

  /// Whether the user should be told about [availableBuild].
  ///
  /// One message per version: a dismissal or an alert already sent for that
  /// build silences it until a newer one shows up.
  static bool shouldNotify({
    required int lastNotifiedBuild,
    required int availableBuild,
  }) => availableBuild > lastNotifiedBuild;

  /// Whether the update dialog may be shown for [availableBuild].
  static bool shouldPrompt({
    required int dismissedBuild,
    required int availableBuild,
  }) => availableBuild > dismissedBuild;
}
