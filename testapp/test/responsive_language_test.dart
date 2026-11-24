import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jol_aman_kenchi/main.dart';

void main() {
  setUp(() => TaxiLanguage.current.value = 'ru');

  testWidgets('language switch changes localized text to Kyrgyz', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            TaxiLanguageSwitcher(),
            TaxiLocalizedText(russian: 'Заказы', kyrgyz: 'Буйрутмалар'),
          ],
        ),
      ),
    ));

    expect(find.text('Заказы'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Кыргызча').last);
    await tester.pumpAndSettle();

    expect(TaxiLanguage.isKyrgyz, isTrue);
    expect(find.text('Буйрутмалар'), findsOneWidget);
  });

  testWidgets('language selector remains usable in a narrow phone column', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 220,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(alignment: Alignment.centerRight, child: TaxiLanguageSwitcher()),
                TaxiLocalizedText(
                  russian: 'Заказы и их статусы обновляются с сервера',
                  kyrgyz: 'Буйрутмалар жана алардын абалы серверден жаңыланат',
                ),
              ],
            ),
          ),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Кыргызча').last, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
