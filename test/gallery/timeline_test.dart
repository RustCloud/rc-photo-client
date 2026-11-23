import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/models.dart';
import 'package:rc_photo/backup/phone_media.dart';
import 'package:rc_photo/backup/store.dart';
import 'package:rc_photo/gallery/timeline.dart';

MediaItem item(int id, DateTime taken, {int size = 100}) => MediaItem(
  id: id,
  bucket: 'b1',
  name: 'IMG_$id.jpg',
  size: size,
  modified: 1700000000,
  taken: taken.millisecondsSinceEpoch,
  mime: 'image/jpeg',
  uri: 'content://media/$id',
);

MediaRow row(MediaItem m, MediaState state, {String? sha}) =>
    MediaRow.fromItem(m)
      ..state = state
      ..sha256 = sha;

void main() {
  test('newest first, with the backup marks and the cloud entry', () {
    final a = item(1, DateTime(2026, 5, 1, 10));
    final b = item(2, DateTime(2026, 5, 3, 9));
    final c = item(3, DateTime(2026, 5, 2, 8));
    final d = item(4, DateTime(2026, 4, 30));
    final e = item(5, DateTime(2026, 4, 29));
    final entry = Entry.fromJson({
      'id': 'x',
      'name': 'IMG_1.jpg',
      'etag': 'h1',
    });
    final items = buildTimeline(
      [a, b, c, d, e],
      {
        1: row(a, MediaState.done, sha: 'h1'),
        2: row(b, MediaState.uploading),
        3: row(c, MediaState.failed),
        4: row(d, MediaState.skipped, sha: 'h4'),
      },
      (sha) => sha == 'h1' ? entry : null,
    );
    expect(items.map((i) => i.media.id), [2, 3, 1, 4, 5]);
    expect(items.map((i) => i.mark), [
      CloudMark.uploading,
      CloudMark.failed,
      CloudMark.synced,
      CloudMark.synced,
      CloudMark.none,
    ]);
    expect(items[2].cloud, same(entry));
  });

  test('a row of an older version of the file gives no mark', () {
    final old = item(1, DateTime(2026, 5, 1));
    final now = item(1, DateTime(2026, 5, 1), size: 200);
    final items = buildTimeline(
      [now],
      {1: row(old, MediaState.done, sha: 'h1')},
      (_) => null,
    );
    expect(items.single.mark, CloudMark.none);
  });

  group('layout', () {
    // 2 on 3 May, 4 on 2 May, 1 in April.
    final items = buildTimeline(
      [
        item(1, DateTime(2026, 5, 3, 12)),
        item(2, DateTime(2026, 5, 3, 11)),
        for (var i = 0; i < 4; i++) item(10 + i, DateTime(2026, 5, 2, 10 - i)),
        item(20, DateTime(2026, 4, 1)),
      ],
      const {},
      (_) => null,
    );

    test('days: a header, then rows of tiles', () {
      final l = TimelineLayout.of(
        items,
        columns: 3,
        width: 300,
        headerHeight: 40,
      );
      expect(l.groupBy, GroupBy.day);
      expect(l.tile, 100);
      expect(
        l.rows.map((r) => r.isHeader ? 'H' : '${r.start}+${r.count}').toList(),
        ['H', '0+2', 'H', '2+3', '5+1', 'H', '6+1'],
      );
      expect(l.rows[3].offset, 40 + 100 + 40);
      expect(l.extent, 3 * 40 + 4 * 100);
      expect(l.rowAt(0), 0);
      expect(l.rowAt(150), 2);
      expect(l.rowAt(10000), l.rows.length - 1);
      expect(l.rowOf(0), 1);
      expect(l.rowOf(4), 3);
      expect(l.rowOf(5), 4);
      expect(l.rowOf(6), 6);
      expect(l.itemAt(0), 0);
      expect(l.itemAt(150), 2);
    });

    test('small tiles: by month', () {
      final l = TimelineLayout.of(items, columns: 5, width: 500);
      expect(l.groupBy, GroupBy.month);
      expect(
        l.rows.map((r) => r.isHeader ? 'H' : '${r.start}+${r.count}').toList(),
        ['H', '0+5', '5+1', 'H', '6+1'],
      );
    });

    test('nothing: no rows', () {
      final l = TimelineLayout.of(const [], columns: 3, width: 300);
      expect(l.rows, isEmpty);
      expect(l.extent, 0);
      expect(l.itemAt(100), 0);
    });
  });
}
