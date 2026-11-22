import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/backup/phone_media.dart';
import 'package:rc_photo/backup/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late SqliteBackupStore store;
  setUp(() async {
    store = await SqliteBackupStore.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
  });

  MediaRow row(int id, {MediaState state = MediaState.pending}) =>
      MediaRow.fromItem(
        MediaItem(
          id: id,
          bucket: 'b1',
          name: 'IMG_$id.jpg',
          size: 10,
          modified: 1,
          taken: 0,
          mime: 'image/jpeg',
          uri: 'content://media/$id',
        ),
      )..state = state;

  test('rows: stored, counted, removed', () async {
    await store.putAll([row(1), row(2, state: MediaState.done)]);
    await store.put(
      row(3, state: MediaState.failed)
        ..failKind = FailKind.server
        ..error = 'boom'
        ..updated = 5,
    );
    final all = await store.all();
    expect(all.keys, unorderedEquals([1, 2, 3]));
    expect(all[3]!.failKind, FailKind.server);
    expect(all[3]!.error, 'boom');
    expect(await store.counts(), {
      MediaState.pending: 1,
      MediaState.done: 1,
      MediaState.failed: 1,
    });
    expect((await store.problems()).map((r) => r.id), [3]);

    await store.retry();
    expect((await store.all())[3]!.state, MediaState.pending);
    await store.remove([1, 2]);
    expect((await store.all()).keys, [3]);
  });

  test('log, newest first; status', () async {
    await store.log(
      LogEntry(at: DateTime(2026), kind: LogKind.started, detail: '2'),
    );
    await store.log(
      LogEntry(at: DateTime(2026), kind: LogKind.uploaded, name: 'a.jpg'),
    );
    final log = await store.logs();
    expect(log.map((e) => e.kind), [LogKind.uploaded, LogKind.started]);
    expect(log.first.name, 'a.jpg');

    await store.setStatus(
      RunStatus(
        running: true,
        name: 'a.jpg',
        sent: 5,
        size: 10,
        done: 1,
        total: 3,
        lastRun: DateTime(2026, 1, 2),
      ),
    );
    final s = await store.status();
    expect(s.running, isTrue);
    expect((s.name, s.sent, s.size, s.done, s.total), ('a.jpg', 5, 10, 1, 3));
    expect(s.lastRun, DateTime(2026, 1, 2));

    await store.clear();
    expect(await store.logs(), isEmpty);
    expect((await store.status()).running, isFalse);
  });
}
