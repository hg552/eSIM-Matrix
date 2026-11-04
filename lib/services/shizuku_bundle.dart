import 'package:flutter/services.dart';

/// What the bundled Shizuku installer reports back.
class ShizukuBundleStatus {
  const ShizukuBundleStatus({
    required this.installed,
    required this.running,
    required this.canInstall,
    this.versionName,
    this.starterCommand,
  });

  final bool installed;
  final bool running;
  final bool canInstall;
  final String? versionName;

  /// The `adb shell ...` line that starts Shizuku's server from a computer.
  /// Null when Shizuku is not installed or ships no executable starter.
  final String? starterCommand;

  bool get needsInstall => !installed;
  bool get needsStart => installed && !running;
  bool get ready => installed && running;

  static const ShizukuBundleStatus unknown = ShizukuBundleStatus(
    installed: false,
    running: false,
    canInstall: false,
  );
}

/// Fetches Shizuku on request so users do not have to find it themselves.
///
/// Nothing is downloaded until the user asks, and the download is only ever
/// handed to the system installer for confirmation — this app installs nothing
/// silently and carries no copy of Shizuku in its own package.
///
/// Starting Shizuku's server on a non-root phone still needs one `adb shell`
/// command after each reboot, which [ShizukuBundleStatus.starterCommand]
/// reports verbatim for the installed build.
class ShizukuBundle {
  static const MethodChannel _channel = MethodChannel(
    'ee.nekoko.shizuku_installer',
  );

  static Future<ShizukuBundleStatus> status() async {
    final map = await _channel.invokeMapMethod<String, dynamic>('status');
    if (map == null) return ShizukuBundleStatus.unknown;
    return ShizukuBundleStatus(
      installed: map['installed'] == true,
      running: map['running'] == true,
      canInstall: map['canInstall'] == true,
      versionName: map['versionName'] as String?,
      starterCommand: map['starterCommand'] as String?,
    );
  }

  /// Downloads Shizuku from its GitHub release and opens the system installer.
  ///
  /// Answers `installer_opened`, `settings_opened` (when this app is not yet
  /// allowed to install packages, the switch is opened instead),
  /// `already_installed`, or `not_needed`.
  static Future<String> install() async {
    final result = await _channel.invokeMethod<String>('install');
    return result ?? 'unknown';
  }

  /// Opens the "install unknown apps" switch for this app.
  static Future<String> allowInstall() async {
    final result = await _channel.invokeMethod<String>('allowInstall');
    return result ?? 'unknown';
  }

  /// Brings Shizuku's own UI to the front.
  static Future<bool> launch() async {
    return await _channel.invokeMethod<bool>('launch') ?? false;
  }
}
