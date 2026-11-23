import '../api/models.dart';
import '../backup/phone_media.dart';
import '../backup/store.dart';

/// Where a photo of the timeline is in the backup: its mark on the tile.
enum CloudMark {
  /// Not copied yet (waiting its turn), or not looked at by the backup yet.
  none,

  /// Being copied now.
  uploading,

  /// In the cloud: copied, or the cloud had it already.
  synced,

  /// Copying failed (the reason is in the backup's status screen).
  failed,
}

/// A photo or video of the timeline: the phone's file, and what the cloud
/// knows about it, if it has it.
class TimelineItem {
  const TimelineItem({required this.media, required this.mark, this.cloud});

  final MediaItem media;
  final CloudMark mark;

  /// The cloud's index entry (camera, lens, place…), matched by SHA-256.
  final Entry? cloud;

  DateTime get date => media.date;
}

CloudMark markOf(MediaRow? row) => switch (row?.state) {
  MediaState.done || MediaState.skipped => CloudMark.synced,
  MediaState.uploading => CloudMark.uploading,
  MediaState.failed => CloudMark.failed,
  MediaState.pending || null => CloudMark.none,
};

/// The timeline: the phone's photos of the chosen albums, newest first, each
/// with its backup mark and the cloud's metadata.
List<TimelineItem> buildTimeline(
  List<MediaItem> media,
  Map<int, MediaRow> rows,
  Entry? Function(String? sha256) cloud,
) {
  final items = [
    for (final m in media)
      () {
        final row = rows[m.id];
        // A row of an older version of the file says nothing about this one.
        final same =
            row != null && row.size == m.size && row.modified == m.modified;
        return TimelineItem(
          media: m,
          mark: same ? markOf(row) : CloudMark.none,
          cloud: same ? cloud(row.sha256) : null,
        );
      }(),
  ];
  items.sort((a, b) {
    final c = b.date.compareTo(a.date);
    return c != 0 ? c : b.media.id.compareTo(a.media.id);
  });
  return items;
}

/// What the timeline groups by: a day when tiles are large, a month when
/// small ones show years at a glance.
enum GroupBy { day, month }

/// One line of the timeline grid: a group's title, or a row of tiles.
class TimelineRow {
  const TimelineRow.header(this.date, this.start, this.offset, this.height)
    : count = 0;

  const TimelineRow.tiles(this.date, this.start, this.count, this.offset)
    : height = 0;

  /// The group's date (its day or the month's first day).
  final DateTime date;

  /// The first item of the row (of the group, for a header) and how many
  /// (0 for a header).
  final int start;
  final int count;

  /// From the top of the timeline, px.
  final double offset;

  /// Only set for headers; tile rows are [TimelineLayout.tile] high.
  final double height;

  bool get isHeader => count == 0;
}

/// Rows of the grid for a width and a number of columns, with their offsets,
/// so the list knows every row's height and the scroller can jump anywhere.
class TimelineLayout {
  TimelineLayout._(this.columns, this.groupBy, this.tile, this.rows);

  factory TimelineLayout.of(
    List<TimelineItem> items, {
    required int columns,
    required double width,
    double headerHeight = 48,
  }) {
    final groupBy = columns >= 5 ? GroupBy.month : GroupBy.day;
    final tile = width / columns;
    final rows = <TimelineRow>[];
    var offset = 0.0;
    var i = 0;
    while (i < items.length) {
      final group = groupOf(items[i].date, groupBy);
      var end = i;
      while (end < items.length && groupOf(items[end].date, groupBy) == group) {
        end++;
      }
      rows.add(TimelineRow.header(group, i, offset, headerHeight));
      offset += headerHeight;
      for (var s = i; s < end; s += columns) {
        final n = end - s < columns ? end - s : columns;
        rows.add(TimelineRow.tiles(group, s, n, offset));
        offset += tile;
      }
      i = end;
    }
    return TimelineLayout._(columns, groupBy, tile, rows);
  }

  final int columns;
  final GroupBy groupBy;

  /// A tile's side, px.
  final double tile;
  final List<TimelineRow> rows;

  double heightOf(TimelineRow r) => r.isHeader ? r.height : tile;

  double get extent =>
      rows.isEmpty ? 0 : rows.last.offset + heightOf(rows.last);

  /// The row at [offset] px from the top.
  int rowAt(double offset) {
    if (rows.isEmpty) return 0;
    var lo = 0, hi = rows.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (rows[mid].offset <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// The tile row that shows item [index].
  int rowOf(int index) {
    // The last row starting at or before it: a header and its first tile
    // row start at the same item, and the tile row comes later.
    var lo = 0, hi = rows.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (rows[mid].start <= index) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// The first item at or below [offset]: kept at the top when the number of
  /// columns changes.
  int itemAt(double offset) {
    if (rows.isEmpty) return 0;
    var r = rowAt(offset);
    while (r < rows.length && rows[r].isHeader) {
      r++;
    }
    return r < rows.length ? rows[r].start : rows.last.start;
  }
}

DateTime groupOf(DateTime d, GroupBy by) => switch (by) {
  GroupBy.day => DateTime(d.year, d.month, d.day),
  GroupBy.month => DateTime(d.year, d.month),
};
