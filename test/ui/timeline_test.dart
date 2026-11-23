import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/auth.dart';
import 'package:rc_photo/api/client.dart';
import 'package:rc_photo/auth/controller.dart';
import 'package:rc_photo/auth/native.dart';
import 'package:rc_photo/auth/session_store.dart';
import 'package:rc_photo/backup/phone_media.dart';
import 'package:rc_photo/backup/settings.dart';
import 'package:rc_photo/backup/store.dart';
import 'package:rc_photo/l10n/app_localizations.dart';
import 'package:rc_photo/ui/app.dart';
import 'package:rc_photo/ui/timeline.dart';

import '../fakes.dart';

Future<AuthController> _login(MemorySessionStore store) async {
  await store.writeLogin(
    AccountLogin(Uri.parse('http://127.0.0.1:1/'), 'alice'),
  );
  final auth = AuthController(
    native: FakeBridge(
      token: const AccountToken(token: 't', server: 'http://127.0.0.1:1/'),
    ),
    store: store,
    makeClient: (s, a) => _Client(s, a),
  );
  await auth.start();
  return auth;
}

void main() {
  testWidgets('no folders chosen: the timeline asks for them', (tester) async {
    final auth = await _login(MemorySessionStore());
    await tester.pumpWidget(
      RcPhotoApp(
        auth: auth,
        backup: fakeServices(),
        locale: const Locale('ru'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Выберите папки'), findsOneWidget);
    expect(find.byKey(const Key('choose-albums')), findsOneWidget);
  });

  testWidgets('no access: asks for it', (tester) async {
    final media = FakeMedia(granted: MediaAccess.none)
      ..onRequest = MediaAccess.full;
    final auth = await _login(MemorySessionStore());
    await tester.pumpWidget(
      RcPhotoApp(
        auth: auth,
        backup: fakeServices(media: media),
        locale: const Locale('ru'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('grant-access')));
    await tester.pumpAndSettle();
    expect(media.granted, MediaAccess.full);
    expect(find.text('Выберите папки'), findsOneWidget);
  });

  testWidgets('the phone\'s photos by day, with their marks; open one', (
    tester,
  ) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 10);
    final media = FakeMedia();
    final a = media.addFile(1, 'a.jpg', taken: today.millisecondsSinceEpoch);
    final b = media.addFile(
      2,
      'b.jpg',
      taken: today.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
    );
    final c = media.addFile(
      3,
      'c.jpg',
      taken: today
          .subtract(const Duration(days: 1, hours: 1))
          .millisecondsSinceEpoch,
    );
    media.addFile(
      4,
      'd.jpg',
      taken: DateTime(2020, 3, 5).millisecondsSinceEpoch,
    );
    // Not a chosen album: not in the timeline.
    media.addFile(5, 'e.jpg', bucket: 'b3');
    final backup = MemoryBackupStore();
    await backup.putAll([
      MediaRow.fromItem(a)..state = MediaState.done,
      MediaRow.fromItem(b)..state = MediaState.uploading,
      MediaRow.fromItem(c)
        ..state = MediaState.failed
        ..failKind = FailKind.server,
    ]);
    final store = MemorySessionStore();
    await store.writeBackup(
      const BackupSettings(
        rootId: 'r',
        albums: [BackupAlbum(bucketId: 'b1', name: 'Camera', folderId: 'c')],
      ),
    );
    final auth = await _login(store);
    await tester.pumpWidget(
      RcPhotoApp(
        auth: auth,
        backup: fakeServices(media: media, store: backup),
        locale: const Locale('ru'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Сегодня'), findsOneWidget);
    expect(find.text('Вчера'), findsOneWidget);
    expect(find.textContaining('2020', skipOffstage: false), findsOneWidget);
    expect(find.byKey(const Key('mark-synced')), findsOneWidget);
    expect(find.byKey(const Key('mark-uploading')), findsOneWidget);
    expect(find.byKey(const Key('mark-failed')), findsOneWidget);
    // Offline: said above the timeline, the timeline still there.
    expect(find.byKey(const Key('cloud-banner')), findsOneWidget);

    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('info')), findsOneWidget);
    await tester.tap(find.byKey(const Key('info')));
    await tester.pumpAndSettle();
    expect(find.text('a.jpg'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('В облаке'), findsWidgets);
  });

  test('day titles', () async {
    final l = await AppLocalizations.delegate.load(const Locale('ru'));
    final now = DateTime(2026, 11, 23, 12);
    expect(dayTitle(l, DateTime(2026, 11, 23, 1), 'ru', now), 'Сегодня');
    expect(dayTitle(l, DateTime(2026, 11, 22, 23), 'ru', now), 'Вчера');
    expect(dayTitle(l, DateTime(2026, 5, 17), 'ru', now), contains('17'));
    expect(dayTitle(l, DateTime(2025, 5, 17), 'ru', now), contains('2025'));
    expect(duration(const Duration(seconds: 65)), '1:05');
    expect(duration(const Duration(hours: 1, seconds: 3)), '1:00:03');
  });
}

class _Client extends RcClient {
  _Client(super.server, super.auth);

  @override
  Future<User> me() async =>
      const User(id: 'u', username: 'alice', displayName: 'Alice');

  @override
  Future<Never> photoState({DateTime? today}) async =>
      throw const NetworkException('offline');
}
