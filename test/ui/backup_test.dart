import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/models.dart';
import 'package:rc_photo/backup/controller.dart';
import 'package:rc_photo/backup/phone_media.dart';
import 'package:rc_photo/l10n/app_localizations.dart';
import 'package:rc_photo/ui/backup.dart';

import '../fakes.dart';

Widget _app(BackupController c) => MaterialApp(
  locale: const Locale('ru'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: BackupScreen(controller: c),
);

void main() {
  testWidgets('choose folders and save: they appear in the cloud', (
    tester,
  ) async {
    final cloud = FakeCloud();
    final photos = cloud.add('root', 'Фото');
    cloud.pluginFolders = [PhotoFolder(id: photos.id, name: 'Фото')];
    final c = BackupController(
      client: cloud,
      media: FakeMedia(),
      store: MemorySessionStore(),
    );
    await tester.pumpWidget(_app(c));
    await tester.pumpAndSettle();

    expect(find.text('Фото / Redmi 10'), findsOneWidget);
    expect(find.textContaining('→ Фото/Redmi 10/Camera'), findsOneWidget);
    await tester.tap(find.byKey(const Key('album-b2')));
    await tester.pumpAndSettle();
    expect(find.textContaining('→ Фото/Redmi 10/Screenshots'), findsOneWidget);

    await tester.tap(find.byKey(const Key('backup-save')));
    await tester.pumpAndSettle();
    expect(find.text('Папки в облаке готовы'), findsOneWidget);
    expect(cloud.paths(), {
      'Фото',
      'Фото/Redmi 10',
      'Фото/Redmi 10/Camera',
      'Фото/Redmi 10/Screenshots',
    });
  });

  testWidgets('asks for access; refused → the settings', (tester) async {
    final media = FakeMedia(granted: MediaAccess.none)
      ..onRequest = MediaAccess.none;
    final c = BackupController(
      client: FakeCloud(),
      media: media,
      store: MemorySessionStore(),
    );
    await tester.pumpWidget(_app(c));
    await tester.pumpAndSettle();
    expect(find.text('Разрешить'), findsOneWidget);

    await tester.tap(find.byKey(const Key('backup-access')));
    await tester.pumpAndSettle();
    // The longer text pushes the button down: scroll to it.
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('Открыть настройки'), findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-access')));
    expect(media.settingsOpened, 1);

    media.granted = MediaAccess.full;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Camera'), findsOneWidget);
  });
}
