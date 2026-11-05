import 'utils/platform_adapter.dart';

bool get kIsPrivileged =>
    const bool.fromEnvironment('PRIVILEGED_BUILD', defaultValue: false) &&
    PlatformX.isAndroid;

bool get kIsEsim9 =>
    const bool.fromEnvironment('ESIM9_BUILD', defaultValue: false);

class AppConfig {
  /// The name shown in the window title and in the update dialog.
  ///
  /// Upstream's flavours keep their own name; a fork states its own with
  /// `--dart-define=APP_DISPLAY_NAME=...` at build time. Without it the
  /// upstream name is used, so nothing changes for the original builds.
  static const String _configuredName = String.fromEnvironment(
    'APP_DISPLAY_NAME',
  );

  static String appName = _configuredName.isEmpty
      ? 'NekokoLPA 2'
      : _configuredName;
}
