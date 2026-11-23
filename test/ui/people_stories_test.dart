import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/client.dart';
import 'package:rc_photo/api/models.dart';
import 'package:rc_photo/auth/controller.dart';
import 'package:rc_photo/auth/native.dart';
import 'package:rc_photo/auth/session_store.dart';
import 'package:rc_photo/backup/settings.dart';
import 'package:rc_photo/backup/store.dart';
import 'package:rc_photo/ui/app.dart';

import '../fakes.dart';

class _Cloud extends FakeCloud {
  @override
  Future<User> me() async =>
      const User(id: 'u', username: 'alice', displayName: 'Alice');
}

void main() {
  testWidgets('stories above the timeline, people in collections', (
    tester,
  ) async {
    final media = FakeMedia();
    final backup = MemoryBackupStore();
    for (var i = 1; i <= 3; i++) {
      final m = media.addFile(
        i,
        'IMG_$i.jpg',
        taken: DateTime(2024, 11, 20 + i).millisecondsSinceEpoch,
      );
      await backup.put(
        MediaRow.fromItem(m)
          ..state = MediaState.done
          ..sha256 = 'h$i',
      );
    }
    final cloud = _Cloud()
      ..pluginFolders = [const PhotoFolder(id: 'f1', name: 'Фото')]
      ..shardLinks = ['index/00.json']
      ..peopleLink = 'people.json';
    cloud.shardBodies['index/00.json'] = jsonEncode([
      for (var i = 1; i <= 3; i++)
        {
          'id': 'e$i',
          'name': 'IMG_$i.jpg',
          'root': 'f1',
          'etag': 'h$i',
          'width': 400,
          'height': 300,
        },
    ]);
    cloud.shardBodies['people.json'] = jsonEncode({
      'next': 2,
      'people': [
        {
          'id': 'p0',
          'count': 2,
          'files': ['e1', 'e2'],
          'cover': {
            'file': 'e1',
            'b': [0.4, 0.3, 0.1, 0.1],
          },
        },
        {
          'id': 'p1',
          'count': 1,
          'files': ['e3'],
          'cover': {
            'file': 'e3',
            'b': [0.1, 0.1, 0.1, 0.1],
          },
        },
      ],
    });
    cloud.extraState = {
      'faces': {'enabled': true},
      'names': {
        'names': {'p0': 'Аня'},
      },
      'stories': {
        'enabled': true,
        'list': [
          {
            'date': '2026-11-23',
            'expires': '2026-11-25',
            'kind': 'on-this-day',
            'key': 'on-this-day:2024',
            'params': {'years': 2, 'date': '2024-11-23'},
            'cover': 'e2',
            'items': [
              {'id': 'e1', 'ms': 4500},
              {
                'id': 'e2',
                'ms': 4500,
                'focus': [0.3, 0.4],
              },
              {'id': 'e3', 'ms': 4500},
            ],
          },
        ],
        'seen': [],
      },
    };

    final store = MemorySessionStore();
    await store.writeLogin(AccountLogin(Uri.parse('http://fake/'), 'alice'));
    await store.writeBackup(
      const BackupSettings(
        rootId: 'r',
        albums: [BackupAlbum(bucketId: 'b1', name: 'Camera', folderId: 'c')],
      ),
    );
    final auth = AuthController(
      native: FakeBridge(
        token: const AccountToken(token: 't', server: 'http://fake/'),
      ),
      store: store,
      makeClient: (_, _) => cloud,
    );
    await auth.start();
    await tester.pumpWidget(
      RcPhotoApp(
        auth: auth,
        backup: fakeServices(media: media, store: backup),
        locale: const Locale('ru'),
      ),
    );
    // The index is read in another isolate: real time for it.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('stories')), findsOneWidget);
    expect(find.text('2 года назад'), findsOneWidget);
    await tester.tap(find.byKey(const Key('story-2026-11-23')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('story-close')), findsOneWidget);
    expect(cloud.pluginCalls, contains('seen 2026-11-23'));
    // On to the second photo, then closed.
    await tester.tap(find.byKey(const Key('story-close')).hitTestable());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('story-close')), findsNothing);

    await tester.tap(find.text('Коллекции'));
    await tester.pumpAndSettle();
    expect(find.text('Люди'), findsOneWidget);
    expect(find.text('Аня'), findsOneWidget);
    expect(find.text('Человек 2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('person-p0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('person-name')), 'Анна');
    await tester.tap(find.byKey(const Key('person-save')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(cloud.pluginCalls, contains('person p0 name=Анна hidden=null'));
  });

  testWidgets('faces off: offered, with a question first', (tester) async {
    final media = FakeMedia();
    final backup = MemoryBackupStore();
    final m = media.addFile(1, 'a.jpg');
    await backup.put(MediaRow.fromItem(m)..state = MediaState.done);
    final cloud = _Cloud()
      ..pluginFolders = [const PhotoFolder(id: 'f1', name: 'Фото')]
      ..shardLinks = [];
    final store = MemorySessionStore();
    await store.writeLogin(AccountLogin(Uri.parse('http://fake/'), 'alice'));
    await store.writeBackup(
      const BackupSettings(
        rootId: 'r',
        albums: [BackupAlbum(bucketId: 'b1', name: 'Camera')],
      ),
    );
    final auth = AuthController(
      native: FakeBridge(
        token: const AccountToken(token: 't', server: 'http://fake/'),
      ),
      store: store,
      makeClient: (_, _) => cloud,
    );
    await auth.start();
    await tester.pumpWidget(
      RcPhotoApp(
        auth: auth,
        backup: fakeServices(media: media, store: backup),
        locale: const Locale('ru'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Коллекции'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('faces-on')));
    await tester.pumpAndSettle();
    expect(find.text('Искать лица?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('faces-on-confirm')));
    await tester.pumpAndSettle();
    expect(cloud.pluginCalls, ['faces true']);
    expect(find.byKey(const Key('faces-on')), findsNothing);
  });
}
