import 'package:logging/logging.dart';

import '../settings/app_settings.dart';
import 'update_check_policy.dart';
import 'update_service.dart';

/// Looks for a newer release and keeps track of what the user has been told.
///
/// The feed check reaches the network, so [UpdateCheckPolicy] decides when it is
/// due; the outcome is remembered so a version the user dismissed does not come
/// back on every launch.
class UpdateNotifier {
  static final Logger _log = Logger('UpdateNotifier');

  /// Reads the feed when the policy allows it and returns the newer release,
  /// or null when there is nothing to report.
  ///
  /// A manual check ignores the schedule and the setting, because the user
  /// asked for it.
  static Future<UpdateInfo?> check({bool manual = false}) async {
    final settings = AppSettings();
    if (!manual && !settings.enableUpdateCheck) return null;

    final build = int.tryParse(settings.buildNumber) ?? 0;
    if (!manual &&
        !UpdateCheckPolicy.shouldCheck(
          lastCheckAt: settings.lastUpdateCheckAt,
          lastCheckBuild: settings.lastUpdateCheckBuild,
          currentBuild: build,
          now: DateTime.now(),
        )) {
      return null;
    }

    final UpdateInfo? update;
    try {
      update = await UpdateService().checkForUpdates();
    } catch (e) {
      _log.warning('Update check failed: $e');
      return null;
    }
    await settings.recordUpdateCheck(build);
    if (update == null) return null;
    _log.info('Update available: ${update.version} (build ${update.build})');
    return update;
  }

  /// Whether this version still has to be announced.
  static bool shouldNotify(UpdateInfo update) =>
      UpdateCheckPolicy.shouldNotify(
        lastNotifiedBuild: AppSettings().lastNotifiedUpdateBuild,
        availableBuild: update.build,
      );

  static Future<void> markNotified(UpdateInfo update) =>
      AppSettings().recordUpdateNotified(update.build);

  /// Whether the update dialog may still be shown for this version.
  static bool shouldPrompt(UpdateInfo update) =>
      UpdateCheckPolicy.shouldPrompt(
        dismissedBuild: AppSettings().dismissedUpdateBuild,
        availableBuild: update.build,
      );

  static Future<void> markDismissed(UpdateInfo update) =>
      AppSettings().recordUpdateDismissed(update.build);
}
