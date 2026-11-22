import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/models.dart';
import 'package:rc_photo/backup/engine.dart';
import 'package:rc_photo/backup/folders.dart';
import 'package:rc_photo/backup/phone_media.dart';
import 'package:rc_photo/backup/settings.dart';
import 'package:rc_photo/backup/store.dart';

import '../fakes.dart';

/// A cloud with `Photos/Redmi 10/Camera` made for album b1, a phone, a store.
class World {
  World._(this.cloud, this.media, this.store, this.settings);

  static Future<World> make({bool deleteInCloud = false}) async {
    final cloud = FakeCloud();
    final photos = cloud.add('root', 'Photos');
    cloud.pluginFolders = [PhotoFolder(id: photos.id, name: 'Photos')];
    final settings = await CloudFolders(cloud).apply(
      BackupSettings(
        rootId: photos.id,
        rootName: 'Photos',
        device: 'Redmi 10',
        albums: const [BackupAlbum(bucketId: 'b1', name: 'Camera')],
        deleteInCloud: deleteInCloud,
      ),
    );
    return World._(cloud, FakeMedia(), MemoryBackupStore(), settings);
  }

  final FakeCloud cloud;
  final FakeMedia media;
  final MemoryBackupStore store;
  BackupSettings settings;

  Future<RunResult> run() => BackupEngine(
    client: cloud,
    media: media,
    store: store,
    settings: settings,
    saveSettings: (s) async => settings = s,
  ).run();

  MediaRow row(int id) => store.rows[id]!;
  List<LogKind> get log => [for (final e in store.entries) e.kind];
}

const camera = 'Photos/Redmi 10/Camera';

void main() {
  test('new photos are copied once, with the time they were taken', () async {
    final w = await World.make();
    w.media
      ..addFile(1, 'IMG_1.jpg', taken: 1700000000000)
      ..addFile(2, 'IMG_2.jpg')
      ..addFile(3, 'other.jpg', bucket: 'b2'); // not chosen
    expect(await w.run(), RunResult.done);
    expect(w.cloud.files(), {'$camera/IMG_1.jpg', '$camera/IMG_2.jpg'});
    expect(
      w.cloud.find('$camera/IMG_1.jpg')!.modifiedAt,
      DateTime.utc(2023, 11, 14, 22, 13, 20),
    );
    expect(w.row(1).state, MediaState.done);
    expect(w.row(1).remoteId, w.cloud.find('$camera/IMG_1.jpg')!.id);
    expect(w.log, [
      LogKind.started,
      LogKind.uploaded,
      LogKind.uploaded,
      LogKind.finished,
    ]);

    w.store.entries.clear();
    expect(await w.run(), RunResult.done);
    expect(w.cloud.simpleUploads, 2, reason: 'nothing new');
    expect(w.log, isEmpty);
  });

  test(
    'a photo the cloud has already is skipped: in the gallery or the folder',
    () async {
      final w = await World.make();
      final a = w.media.addFile(1, 'IMG_1.jpg');
      final b = w.media.addFile(2, 'IMG_2.jpg');
      w.cloud.indexed = {_sha(w.media, a.id)};
      w.cloud.add(
        w.settings.albums.first.folderId!,
        'copy.jpg',
        dir: false,
        bytes: w.media.files[b.id]!.$2,
      );
      await w.run();
      expect(w.cloud.simpleUploads, 0);
      expect(w.row(1).state, MediaState.skipped);
      expect(w.row(2).state, MediaState.skipped);
      expect(w.log, contains(LogKind.skipped));
    },
  );

  test('a name taken by another file: "name (2)"', () async {
    final w = await World.make();
    w.cloud.add(
      w.settings.albums.first.folderId!,
      'IMG_1.jpg',
      dir: false,
      bytes: [1, 2, 3],
    );
    w.media.addFile(1, 'IMG_1.jpg');
    await w.run();
    expect(w.cloud.files(), contains('$camera/IMG_1 (2).jpg'));
    expect(w.row(1).remoteName, 'IMG_1 (2).jpg');
  });

  test(
    'a big file goes in parts; a lost network resumes where it stopped',
    () async {
      final w = await World.make();
      const size =
          BackupEngine.simpleLimit + 4 * 1024 * 1024; // 20 MiB: 3 parts
      w.media.addFile(1, 'VID_1.mp4', size: size, mime: 'video/mp4');
      w.cloud.networkFor = 2; // start, first part; then offline
      expect(await w.run(), RunResult.network);
      expect(w.row(1).state, MediaState.pending);
      expect(w.row(1).failKind, FailKind.network);
      expect(w.row(1).uploadId, isNotNull);
      expect(w.cloud.parts, 1);
      expect(w.log, contains(LogKind.network));
      expect((await w.store.problems()).single.id, 1);

      w.cloud.networkFor = null;
      expect(await w.run(), RunResult.done);
      expect(w.cloud.parts, 3, reason: 'the first part is not sent again');
      final f = w.cloud.find('$camera/VID_1.mp4')!;
      expect(f.size, size);
      expect(f.etag, _sha(w.media, 1));
      expect(w.row(1).state, MediaState.done);
      expect(w.row(1).uploadId, isNull);
      expect(await w.store.problems(), isEmpty);
    },
  );

  test(
    'the network drops before anything: the run stops, files wait',
    () async {
      final w = await World.make();
      w.media
        ..addFile(1, 'a.jpg')
        ..addFile(2, 'b.jpg');
      w.cloud.networkFor = 0;
      expect(await w.run(), RunResult.network);
      expect(
        w.store.rows.values.every((r) => r.state == MediaState.pending),
        isTrue,
      );
      w.cloud.networkFor = null;
      expect(await w.run(), RunResult.done);
      expect(w.cloud.files(), hasLength(2));
    },
  );

  test(
    'a server error: failed, tried again a few runs, then by hand',
    () async {
      final w = await World.make();
      w.media.addFile(1, 'a.jpg');
      for (var i = 0; i < BackupEngine.maxAttempts; i++) {
        w.cloud.failNext.add(const ApiException(500, 'INTERNAL', 'boom'));
        await w.run();
      }
      expect(w.row(1).state, MediaState.failed);
      expect(w.row(1).failKind, FailKind.server);
      expect(w.row(1).error, 'boom');
      expect(w.row(1).attempts, BackupEngine.maxAttempts);
      await w.run();
      expect(w.cloud.simpleUploads, 0, reason: 'no more automatic tries');

      await w.store.retry(id: 1);
      await w.run();
      expect(w.row(1).state, MediaState.done);
    },
  );

  test('no room in the cloud: the run stops', () async {
    final w = await World.make();
    w.media
      ..addFile(1, 'a.jpg', taken: 2000)
      ..addFile(2, 'b.jpg', taken: 1000);
    w.cloud.failNext.add(const ApiException(413, 'QUOTA_EXCEEDED', 'full'));
    expect(await w.run(), RunResult.quota);
    expect(w.row(1).state, MediaState.failed);
    expect(w.row(1).failKind, FailKind.quota);
    expect(w.row(2).state, MediaState.pending);
    expect(w.log, contains(LogKind.quota));
  });

  test('videos wait for Wi-Fi on mobile data, photos go', () async {
    final w = await World.make();
    w.media
      ..addFile(1, 'a.jpg')
      ..addFile(2, 'v.mp4', mime: 'video/mp4')
      ..net = NetworkKind.metered;
    expect(await w.run(), RunResult.wifi);
    expect(w.row(1).state, MediaState.done);
    expect(w.row(2).failKind, FailKind.wifi);
    w.media.net = NetworkKind.unmetered;
    expect(await w.run(), RunResult.done);
    expect(w.row(2).state, MediaState.done);
  });

  test('deleted on the phone: the cloud keeps it unless asked', () async {
    final w = await World.make();
    w.media
      ..addFile(1, 'a.jpg')
      ..addFile(2, 'b.jpg');
    await w.run();
    w.media.files.remove(1);
    await w.run();
    expect(w.cloud.files(), hasLength(2));
    expect(w.store.rows.containsKey(1), isFalse);
  });

  test(
    'deleted on the phone with "delete in the cloud too": to the trash',
    () async {
      final w = await World.make(deleteInCloud: true);
      w.media
        ..addFile(1, 'a.jpg')
        ..addFile(2, 'b.jpg');
      await w.run();
      final id = w.row(1).remoteId!;
      w.media.files.remove(1);
      await w.run();
      expect(w.cloud.deleted, [id]);
      expect(w.cloud.files(), {'$camera/b.jpg'});
      expect(w.log, contains(LogKind.deleted));
    },
  );

  test('nothing is deleted with partial access or a vanished album', () async {
    final w = await World.make(deleteInCloud: true);
    w.media
      ..addFile(1, 'a.jpg')
      ..addFile(2, 'b.jpg');
    await w.run();
    w.media
      ..files.remove(1)
      ..granted = MediaAccess.partial;
    await w.run();
    expect(w.cloud.deleted, isEmpty);
    w.media
      ..granted = MediaAccess.full
      ..files.clear(); // the whole album gone: a memory card taken out
    await w.run();
    expect(w.cloud.deleted, isEmpty);
  });

  test('an edited photo replaces its copy', () async {
    final w = await World.make();
    w.media.addFile(1, 'a.jpg', size: 100);
    await w.run();
    w.media.addFile(1, 'a.jpg', size: 200);
    final edited = w.media.files[1]!;
    w.media.files[1] = (
      MediaItem(
        id: 1,
        bucket: 'b1',
        name: 'a.jpg',
        size: 200,
        modified: edited.$1.modified + 60,
        taken: edited.$1.taken,
        mime: 'image/jpeg',
        uri: edited.$1.uri,
      ),
      edited.$2,
    );
    await w.run();
    expect(w.cloud.files(), {'$camera/a.jpg'});
    expect(w.cloud.find('$camera/a.jpg')!.size, 200);
  });

  test('the cloud folders were deleted: made again, then copied', () async {
    final w = await World.make();
    w.cloud.removeTree(w.cloud.find('Photos/Redmi 10')!.id);
    w.media.addFile(1, 'a.jpg');
    await w.run();
    await w.run();
    expect(w.cloud.files(), {'$camera/a.jpg'});
    expect(w.log, contains(LogKind.folders));
    expect(w.settings.ready, isTrue);
  });

  test('off, not set up, or no access: nothing happens', () async {
    final w = await World.make();
    w.media.addFile(1, 'a.jpg');
    w.settings = w.settings.copyWith(enabled: false);
    expect(await w.run(), RunResult.off);
    w.settings = w.settings.copyWith(enabled: true);
    w.media.granted = MediaAccess.none;
    expect(await w.run(), RunResult.noAccess);
    expect(w.cloud.simpleUploads, 0);
  });
}

String _sha(FakeMedia m, int id) =>
    FakeCloud().add('root', 'x', dir: false, bytes: m.files[id]!.$2).etag!;
