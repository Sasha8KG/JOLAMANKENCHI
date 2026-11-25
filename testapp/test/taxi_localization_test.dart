import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sulyukta_taxi/services/taxi_localization.dart';

void main() {
  setUp(() => TaxiLanguage.current.value = 'ru');

  test('menu labels, dynamic prefixes and unknown text are handled safely', () {
    expect(TaxiLanguage.translate('Заявка водителя'), 'Айдоочунун арызы');
    expect(TaxiLanguage.translate('Подача: Центральный рынок'), 'Унаа келчү жер: Центральный рынок');
    expect(TaxiLanguage.translate('неизвестная надпись'), 'неизвестная надпись');
  });

  testWidgets('ordinary text updates immediately when language changes', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: TaxiText('Заявка водителя'))));
    expect(find.text('Заявка водителя'), findsOneWidget);
    TaxiLanguage.current.value = 'ky';
    await tester.pump();
    expect(find.text('Айдоочунун арызы'), findsOneWidget);
  });

  testWidgets('language selector fits a narrow registration header', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      appBar: AppBar(actions: [TaxiLanguageSwitcher()]),
      body: SizedBox(width: 220, child: TaxiText('Фотографии для проверки диспетчером')),
    )));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Кыргызча').last, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
