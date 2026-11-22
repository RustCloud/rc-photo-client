import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/ui/app.dart';

void main() {
  testWidgets('home in Russian: tabs switch', (tester) async {
    await tester.pumpWidget(const RcPhotoApp(locale: Locale('ru')));
    await tester.pumpAndSettle();
    expect(find.text('Фото пока нет'), findsOneWidget);
    expect(find.text('Подключить облако'), findsOneWidget);

    await tester.tap(find.text('Коллекции'));
    await tester.pumpAndSettle();
    expect(find.textContaining('избранное'), findsOneWidget);

    await tester.tap(find.text('Поиск'));
    await tester.pumpAndSettle();
    expect(find.text('Поиск по фото'), findsOneWidget);
  });

  testWidgets('home in English', (tester) async {
    await tester.pumpWidget(const RcPhotoApp(locale: Locale('en')));
    await tester.pumpAndSettle();
    expect(find.text('No photos yet'), findsOneWidget);
  });
}
