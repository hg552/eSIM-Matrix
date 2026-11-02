import 'utils/platform_adapter.dart';

bool get kIsPrivileged =>
    const bool.fromEnvironment('PRIVILEGED_BUILD', defaultValue: false) &&
    PlatformX.isAndroid;

bool get kIsEsim9 =>
    const bool.fromEnvironment('ESIM9_BUILD', defaultValue: false);

class AppConfig {
  static String appName = 'NekokoLPA 2';
}
