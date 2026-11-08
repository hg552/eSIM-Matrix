import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The console is opened to adjust one position and closed again. It used to
/// reopen on the first built-in template, so the user had to re-find the spot
/// they were just looking at.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('starts with no remembered position', () {
    expect(AppSettings().lastMockLocationRule, isNull);
  });

  test('keeps the last injected position across a reload', () async {
    await AppSettings().setLastMockLocationRule('22.3193, 114.1694, 香港尖沙咀');

    // A fresh instance reads SharedPreferences again, which is what reopening
    // the page does.
    expect(AppSettings().lastMockLocationRule, '22.3193, 114.1694, 香港尖沙咀');
  });

  test('clearing the position removes it instead of storing an empty string',
      () async {
    await AppSettings().setLastMockLocationRule('1.5, 2.5, 某地');
    await AppSettings().setLastMockLocationRule('   ');

    expect(AppSettings().lastMockLocationRule, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('lastMockLocationRule'), isFalse);
  });
}
