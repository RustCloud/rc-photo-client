import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/models.dart';
import 'package:rc_photo/backup/controller.dart';
import 'package:rc_photo/backup/folders.dart';
import 'package:rc_photo/backup/phone_media.dart';
import 'package:rc_photo/backup/settings.dart';

import '../fakes.dart';

void main() {
  group('names', () {
    test('folder names: no slashes, trimmed, never empty', () {
      expect(folderName('  Redmi 10 '), 'Redmi 10');
      expect(folderName('a/b\\c'), 'a b c');
      expect(folderName('..'), '_');
      expect(folderName('   '), '_');
    });

    test('albums of the same name get (2), (3)', () {
      expect(uniqueNames(['Camera', 'camera', 'Camera', 'DCIM']), [
        'Camera',
        'camera (2)',
        'Camera (3)',
        'DCIM',
      ]);
    });

    test('settings survive JSON', () {
      const s = BackupSettings(
        rootId: 'r',
        rootName: 'Photos',
        device: 'Redmi 10',
        deviceFolderId: 'd',
        albums: [BackupAlbum(bucketId: 'b1', name: 'Camera', folderId: 'f')],
      );
      final back = BackupSettings.fromJson(s.toJson());
      expect(back.toJson(), s.toJson());
      expect(back.ready, isTrue);
      expect(const BackupSettings().ready, isFalse);
    });
  });

  group('cloud folders', () {
    test(
      'device and album folders are made inside the gallery folder',
      () async {
        final cloud = FakeCloud();
        final photos = cloud.add('root', 'Photos');
        final s = await CloudFolders(cloud).apply(
          BackupSettings(
            rootId: photos.id,
            device: 'Redmi 10',
            albums: const [
              BackupAlbum(bucketId: 'b1', name: 'Camera'),
              BackupAlbum(bucketId: 'b2', name: 'Screenshots'),
            ],
          ),
        );
        expect(cloud.paths(), {
          'Photos',
          'Photos/Redmi 10',
          'Photos/Redmi 10/Camera',
          'Photos/Redmi 10/Screenshots',
        });
        expect(s.ready, isTrue);
        expect(cloud.nodes[s.albums.first.folderId]!.name, 'Camera');
      },
    );

    test(
      'folders already there are used, a file of the name is passed by',
      () async {
        final cloud = FakeCloud();
        final photos = cloud.add('root', 'Photos');
        final device = cloud.add(photos.id, 'Redmi 10');
        final camera = cloud.add(device.id, 'Camera');
        cloud.add(device.id, 'Screenshots', dir: false);
        final s = await CloudFolders(cloud).apply(
          BackupSettings(
            rootId: photos.id,
            device: 'Redmi 10',
            albums: const [
              BackupAlbum(bucketId: 'b1', name: 'Camera'),
              BackupAlbum(bucketId: 'b2', name: 'Screenshots'),
            ],
          ),
        );
        expect(s.deviceFolderId, device.id);
        expect(s.albums[0].folderId, camera.id);
        expect(s.albums[1].name, 'Screenshots (2)');
      },
    );

    test('a folder made meanwhile by someone else is taken', () async {
      final cloud = FakeCloud();
      final photos = cloud.add('root', 'Photos');
      Node? other;
      cloud.beforeCreate = (parent, name) {
        if (name == 'Redmi 10' && other == null) {
          other = cloud.add(parent, name);
        }
      };
      final s = await CloudFolders(
        cloud,
      ).apply(BackupSettings(rootId: photos.id, device: 'Redmi 10'));
      expect(s.deviceFolderId, other!.id);
    });

    test('a new gallery folder is given to the plugin with write', () async {
      final cloud = FakeCloud();
      final f = await CloudFolders(cloud).createRoot('Фото');
      expect(f.name, 'Фото');
      expect(cloud.grants, [(f.id, true)]);
    });
  });

  group('controller', () {
    BackupController make(FakeCloud cloud, FakeMedia media) => BackupController(
      client: cloud,
      services: fakeServices(media: media),
      store: MemorySessionStore(),
    );

    test('first time: the camera is chosen, the phone named, saved', () async {
      final cloud = FakeCloud();
      final photos = cloud.add('root', 'Photos');
      cloud.pluginFolders = [PhotoFolder(id: photos.id, name: 'Photos')];
      final c = make(cloud, FakeMedia());
      await c.load();
      expect(c.chosen, {'b1'});
      expect(c.device, 'Redmi 10');
      expect(c.root?.name, 'Photos');
      expect(c.cloudPath('b1'), 'Photos/Redmi 10/Camera');

      c.toggle('b3');
      expect(await c.save(), isTrue);
      expect(cloud.paths(), {
        'Photos',
        'Photos/Redmi 10',
        'Photos/Redmi 10/Camera',
        'Photos/Redmi 10/Telegram',
      });
      expect(c.dirty, isFalse);
      expect((await c.store.readBackup())!.ready, isTrue);
    });

    test('the choice comes back; a renamed phone gets a new folder', () async {
      final cloud = FakeCloud();
      final photos = cloud.add('root', 'Photos');
      cloud.pluginFolders = [PhotoFolder(id: photos.id, name: 'Photos')];
      final store = MemorySessionStore();
      final media = FakeMedia();
      var c = BackupController(
        client: cloud,
        services: fakeServices(media: media),
        store: store,
      );
      await c.load();
      await c.save();

      c = BackupController(
        client: cloud,
        services: fakeServices(media: media),
        store: store,
      );
      await c.load();
      expect(c.chosen, {'b1'});
      expect(c.dirty, isFalse);
      c.setDevice('Old phone');
      expect(c.canSave, isTrue);
      await c.save();
      expect(cloud.paths(), contains('Photos/Old phone/Camera'));
    });

    test(
      'no gallery folder yet: one is made and given to the plugin',
      () async {
        final cloud = FakeCloud();
        final c = make(cloud, FakeMedia());
        await c.load();
        expect(c.root, isNull);
        expect(c.canSave, isFalse);
        await c.createRoot('Фото');
        expect(c.root?.name, 'Фото');
        await c.save();
        expect(cloud.paths(), contains('Фото/Redmi 10/Camera'));
      },
    );

    test('no access to photos until asked', () async {
      final media = FakeMedia(granted: MediaAccess.none);
      final c = make(FakeCloud(), media);
      await c.load();
      expect(c.albums, isEmpty);
      expect(await c.requestAccess(), isTrue);
      expect(c.albums, hasLength(3));
      expect(c.chosen, {'b1'});
    });

    test('no plugin on the server', () async {
      final cloud = FakeCloud()..pluginFolders = null;
      final c = make(cloud, FakeMedia());
      await c.load();
      expect(c.problem, BackupProblem.noPlugin);
    });
  });
}
