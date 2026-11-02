import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nlpa2/widgets/lazy_tab_body.dart';

void main() {
  testWidgets('unvisited tabs are not built; visiting retains editor state', (
    tester,
  ) async {
    var secondBuilds = 0;
    Widget app(int selected) => MaterialApp(
      home: Scaffold(
        body: IndexedStack(
          index: selected,
          children: [
            LazyTabBody(
              key: const ValueKey('manage'),
              active: selected == 0,
              builder: (_) => const Text('Manage'),
            ),
            LazyTabBody(
              key: const ValueKey('browser'),
              active: selected == 1,
              builder: (_) {
                secondBuilds++;
                return const TextField(key: ValueKey('editor'));
              },
            ),
          ],
        ),
      ),
    );
    await tester.pumpWidget(app(0));
    expect(secondBuilds, 0);
    await tester.pumpWidget(app(1));
    expect(secondBuilds, greaterThan(0));
    await tester.enterText(find.byKey(const ValueKey('editor')), 'kept state');
    await tester.pumpWidget(app(0));
    await tester.pumpWidget(app(1));
    expect(find.text('kept state'), findsOneWidget);
  });

  testWidgets('visited inactive tabs disable animation tickers', (
    tester,
  ) async {
    bool? tickerEnabled;
    Widget app(bool active) => Directionality(
      textDirection: TextDirection.ltr,
      child: LazyTabBody(
        active: active,
        builder: (context) {
          tickerEnabled = TickerMode.of(context);
          return const SizedBox();
        },
      ),
    );
    await tester.pumpWidget(app(true));
    expect(tickerEnabled, isTrue);
    await tester.pumpWidget(app(false));
    expect(tickerEnabled, isFalse);
    await tester.pumpWidget(app(true));
    expect(tickerEnabled, isTrue);
  });
}
