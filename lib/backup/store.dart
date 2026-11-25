import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'phone_media.dart';

/// Where a phone file is in the backup.
enum MediaState {
  /// To be copied (new, changed, or waiting for the network or Wi-Fi).
  pending,
  uploading,
  done,

  /// The cloud has the same file already (same SHA-256): not copied again.
  skipped,
  failed,
}

/// Why a file failed or waits.
enum FailKind {
  /// The network went away: copied once it is back.
  network,

  /// No room in the cloud.
  quota,

  /// Larger than the server takes.
  tooLarge,

  /// The phone couldn't read the file.
  file,

  /// The server refused (in [MediaRow.error]); tried again a few times.
  server,

  /// A video on mobile data: waits for Wi-Fi.
  wifi,
}

/// A phone file and its backup state.
class MediaRow {
  MediaRow({
    required this.id,
    required this.bucket,
    required this.name,
    required this.size,
    required this.modified,
    this.added = 0,
    required this.taken,
    required this.mime,
    required this.uri,
    this.sha256,
    this.timesSet = false,
    this.state = MediaState.pending,
    this.remoteId,
    this.remoteName,
    this.uploadId,
    this.failKind,
    this.error,
    this.attempts = 0,
    this.updated = 0,
  });

  factory MediaRow.fromItem(MediaItem i) => MediaRow(
    id: i.id,
    bucket: i.bucket,
    name: i.name,
    size: i.size,
    modified: i.modified,
    added: i.added,
    taken: i.taken,
    mime: i.mime,
    uri: i.uri,
  );

  factory MediaRow.fromDb(Map<String, Object?> m) => MediaRow(
    id: m['id']! as int,
    bucket: m['bucket']! as String,
    name: m['name']! as String,
    size: m['size']! as int,
    modified: m['modified']! as int,
    added: m['added'] as int? ?? 0,
    taken: m['taken']! as int,
    mime: m['mime']! as String,
    uri: m['uri']! as String,
    sha256: m['sha256'] as String?,
    timesSet: m['times_set'] == 1,
    state: MediaState.values.byName(m['state']! as String),
    remoteId: m['remote_id'] as String?,
    remoteName: m['remote_name'] as String?,
    uploadId: m['upload_id'] as String?,
    failKind: switch (m['fail_kind']) {
      final String k => FailKind.values.byName(k),
      _ => null,
    },
    error: m['error'] as String?,
    attempts: m['attempts']! as int,
    updated: m['updated']! as int,
  );

  final int id;
  String bucket;
  String name;
  int size;

  /// Seconds, as in [MediaItem].
  int modified;
  int added;
  int taken;
  String mime;
  String uri;
  String? sha256;
  MediaState state;

  /// The cloud file has this file's times: [ctime] as its `born_at`,
  /// [modified] as its `modified_at`. Files copied before the server took
  /// `ctime` get them afterwards.
  bool timesSet;

  /// The cloud file copied from it; kept to replace it when the file changes and to delete it
  /// with "delete in the cloud too".
  String? remoteId;

  /// Its name in the cloud (`IMG_1.jpg (2)` when the name was taken).
  String? remoteName;

  /// An unfinished upload in parts, continued next time.
  String? uploadId;
  FailKind? failKind;
  String? error;
  int attempts;

  /// When the state last changed, ms.
  int updated;

  bool get isVideo => mime.startsWith('video/');

  /// When the file was made, seconds: taken, else when it came to the phone,
  /// else when it changed. Sent as `ctime`; the backup goes newest first by it.
  int get ctime => taken > 0
      ? taken ~/ 1000
      : added > 0
      ? added
      : modified;

  Map<String, Object?> toDb() => {
    'id': id,
    'bucket': bucket,
    'name': name,
    'size': size,
    'modified': modified,
    'added': added,
    'taken': taken,
    'mime': mime,
    'uri': uri,
    'sha256': sha256,
    'times_set': timesSet ? 1 : 0,
    'state': state.name,
    'remote_id': remoteId,
    'remote_name': remoteName,
    'upload_id': uploadId,
    'fail_kind': failKind?.name,
    'error': error,
    'attempts': attempts,
    'updated': updated,
  };
}

/// What happened, for the log screen. [kind] is shown in the user's
/// language there; [name] is a file, [detail] the server's words or a count.
class LogEntry {
  const LogEntry({
    required this.at,
    required this.kind,
    this.name = '',
    this.detail = '',
  });

  factory LogEntry.fromDb(Map<String, Object?> m) => LogEntry(
    at: DateTime.fromMillisecondsSinceEpoch(m['at']! as int),
    kind: LogKind.values.asNameMap()[m['kind']] ?? LogKind.error,
    name: m['name'] as String? ?? '',
    detail: m['detail'] as String? ?? '',
  );

  final DateTime at;
  final LogKind kind;
  final String name;
  final String detail;
}

enum LogKind {
  /// A run began; detail: how many files wait.
  started,

  /// A run ended; detail: how many were copied.
  finished,
  uploaded,

  /// Already in the cloud.
  skipped,
  failed,

  /// Network lost: goes on when it is back.
  network,

  /// Videos wait for Wi-Fi; detail: how many.
  waitWifi,

  /// Deleted on the phone, so moved to the cloud's trash.
  deleted,

  /// No room in the cloud: stopped.
  quota,

  /// No access to the phone's photos.
  noAccess,

  /// The rc-client account or the login needs the user.
  noLogin,

  /// The cloud folders were gone and are made again.
  folders,

  /// The server asked to wait.
  later,
  error,
}

/// The current run, for the screen: what is being copied and how far.
class RunStatus {
  const RunStatus({
    this.running = false,
    this.name = '',
    this.sent = 0,
    this.size = 0,
    this.done = 0,
    this.total = 0,
    this.lastRun,
  });

  final bool running;
  final String name;
  final int sent;
  final int size;

  /// Files handled in this run, of [total].
  final int done;
  final int total;
  final DateTime? lastRun;
}

/// Counts of files by state, for the summary.
typedef Counts = Map<MediaState, int>;

/// The backup's memory: a row per phone file, the log, the current run.
abstract class BackupStore {
  Future<Map<int, MediaRow>> all();
  Future<void> put(MediaRow row);
  Future<void> putAll(Iterable<MediaRow> rows);
  Future<void> remove(Iterable<int> ids);
  Future<Counts> counts();

  /// Failed files and the ones waiting for the network or Wi-Fi, newest
  /// first.
  Future<List<MediaRow>> problems();

  /// Puts failed files (one, or all) back in the queue.
  Future<void> retry({int? id});

  Future<void> log(LogEntry e);
  Future<List<LogEntry>> logs({int limit = 300});

  Future<RunStatus> status();
  Future<void> setStatus(RunStatus s);

  /// Forgets everything (logout).
  Future<void> clear();
}

/// [BackupStore] in SQLite (`backup.db`). The worker's engine and the app's
/// open it each on their own; SQLite keeps them apart.
class SqliteBackupStore implements BackupStore {
  SqliteBackupStore._(this._db);

  final Database _db;

  static const _logKeep = 2000;

  static Future<SqliteBackupStore> open({
    DatabaseFactory? factory,
    String? path,
  }) async {
    final f = factory ?? databaseFactory;
    final where = path ?? p.join(await f.getDatabasesPath(), 'backup.db');
    final db = await f.openDatabase(
      where,
      options: OpenDatabaseOptions(
        version: 2,
        onConfigure: (db) async {
          // Two engines at once: wait for the other's write instead of failing.
          await db.rawQuery('PRAGMA busy_timeout = 5000');
          await db.rawQuery('PRAGMA journal_mode = WAL');
        },
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE media (
              id INTEGER PRIMARY KEY,
              bucket TEXT NOT NULL,
              name TEXT NOT NULL,
              size INTEGER NOT NULL,
              modified INTEGER NOT NULL,
              added INTEGER NOT NULL DEFAULT 0,
              taken INTEGER NOT NULL,
              mime TEXT NOT NULL,
              uri TEXT NOT NULL,
              sha256 TEXT,
              times_set INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL,
              remote_id TEXT,
              remote_name TEXT,
              upload_id TEXT,
              fail_kind TEXT,
              error TEXT,
              attempts INTEGER NOT NULL DEFAULT 0,
              updated INTEGER NOT NULL DEFAULT 0
            )''');
          await db.execute('CREATE INDEX media_state ON media (state)');
          await db.execute('''
            CREATE TABLE log (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              at INTEGER NOT NULL,
              kind TEXT NOT NULL,
              name TEXT NOT NULL DEFAULT '',
              detail TEXT NOT NULL DEFAULT ''
            )''');
          await db.execute(
            'CREATE TABLE status (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
        },
        onUpgrade: (db, from, _) async {
          if (from < 2) {
            // Filled by the next scan; the cloud's dates are set after that.
            await db.execute(
              'ALTER TABLE media ADD COLUMN added INTEGER NOT NULL DEFAULT 0',
            );
            await db.execute(
              'ALTER TABLE media ADD COLUMN times_set INTEGER NOT NULL DEFAULT 0',
            );
          }
        },
      ),
    );
    return SqliteBackupStore._(db);
  }

  @override
  Future<Map<int, MediaRow>> all() async => {
    for (final m in await _db.query('media'))
      m['id']! as int: MediaRow.fromDb(m),
  };

  @override
  Future<void> put(MediaRow row) => _db.insert(
    'media',
    row.toDb(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  @override
  Future<void> putAll(Iterable<MediaRow> rows) async {
    final b = _db.batch();
    for (final r in rows) {
      b.insert('media', r.toDb(), conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await b.commit(noResult: true);
  }

  @override
  Future<void> remove(Iterable<int> ids) async {
    final list = ids.toList();
    for (var i = 0; i < list.length; i += 500) {
      final part = list.sublist(
        i,
        i + 500 > list.length ? list.length : i + 500,
      );
      await _db.delete(
        'media',
        where: 'id IN (${List.filled(part.length, '?').join(',')})',
        whereArgs: part,
      );
    }
  }

  @override
  Future<Counts> counts() async => {
    for (final m in await _db.rawQuery(
      'SELECT state, COUNT(*) AS n FROM media GROUP BY state',
    ))
      MediaState.values.byName(m['state']! as String): m['n']! as int,
  };

  @override
  Future<List<MediaRow>> problems() async => [
    for (final m in await _db.query(
      'media',
      where:
          "state = 'failed' OR (state = 'pending' AND fail_kind IS NOT NULL)",
      orderBy: 'updated DESC',
    ))
      MediaRow.fromDb(m),
  ];

  @override
  Future<void> retry({int? id}) => _db.update(
    'media',
    {'state': 'pending', 'fail_kind': null, 'error': null, 'attempts': 0},
    where: id == null ? "state = 'failed'" : "id = ? AND state = 'failed'",
    whereArgs: id == null ? null : [id],
  );

  @override
  Future<void> log(LogEntry e) async {
    final id = await _db.insert('log', {
      'at': e.at.millisecondsSinceEpoch,
      'kind': e.kind.name,
      'name': e.name,
      'detail': e.detail,
    });
    if (id % 100 == 0) {
      await _db.delete('log', where: 'id <= ?', whereArgs: [id - _logKeep]);
    }
  }

  @override
  Future<List<LogEntry>> logs({int limit = 300}) async => [
    for (final m in await _db.query('log', orderBy: 'id DESC', limit: limit))
      LogEntry.fromDb(m),
  ];

  @override
  Future<RunStatus> status() async {
    final m = {
      for (final r in await _db.query('status'))
        r['key']! as String: r['value']! as String,
    };
    int n(String k) => int.tryParse(m[k] ?? '') ?? 0;
    final last = n('lastRun');
    return RunStatus(
      running: m['running'] == '1',
      name: m['name'] ?? '',
      sent: n('sent'),
      size: n('size'),
      done: n('done'),
      total: n('total'),
      lastRun: last == 0 ? null : DateTime.fromMillisecondsSinceEpoch(last),
    );
  }

  @override
  Future<void> setStatus(RunStatus s) async {
    final b = _db.batch();
    final values = {
      'running': s.running ? '1' : '0',
      'name': s.name,
      'sent': '${s.sent}',
      'size': '${s.size}',
      'done': '${s.done}',
      'total': '${s.total}',
      'lastRun': '${s.lastRun?.millisecondsSinceEpoch ?? 0}',
    };
    for (final e in values.entries) {
      b.insert('status', {
        'key': e.key,
        'value': e.value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await b.commit(noResult: true);
  }

  @override
  Future<void> clear() async {
    await _db.delete('media');
    await _db.delete('log');
    await _db.delete('status');
  }
}

/// [BackupStore] in memory, for tests.
class MemoryBackupStore implements BackupStore {
  final Map<int, MediaRow> rows = {};
  final List<LogEntry> entries = [];
  RunStatus current = const RunStatus();

  MediaRow _copy(MediaRow r) => MediaRow.fromDb(r.toDb());

  @override
  Future<Map<int, MediaRow>> all() async => {
    for (final r in rows.values) r.id: _copy(r),
  };

  @override
  Future<void> put(MediaRow row) async => rows[row.id] = _copy(row);

  @override
  Future<void> putAll(Iterable<MediaRow> rs) async {
    for (final r in rs) {
      rows[r.id] = _copy(r);
    }
  }

  @override
  Future<void> remove(Iterable<int> ids) async => ids.forEach(rows.remove);

  @override
  Future<Counts> counts() async {
    final c = <MediaState, int>{};
    for (final r in rows.values) {
      c[r.state] = (c[r.state] ?? 0) + 1;
    }
    return c;
  }

  @override
  Future<List<MediaRow>> problems() async =>
      rows.values
          .where(
            (r) =>
                r.state == MediaState.failed ||
                (r.state == MediaState.pending && r.failKind != null),
          )
          .map(_copy)
          .toList()
        ..sort((a, b) => b.updated.compareTo(a.updated));

  @override
  Future<void> retry({int? id}) async {
    for (final r in rows.values) {
      if (r.state == MediaState.failed && (id == null || r.id == id)) {
        r
          ..state = MediaState.pending
          ..failKind = null
          ..error = null
          ..attempts = 0;
      }
    }
  }

  @override
  Future<void> log(LogEntry e) async => entries.add(e);

  @override
  Future<List<LogEntry>> logs({int limit = 300}) async =>
      entries.reversed.take(limit).toList();

  @override
  Future<RunStatus> status() async => current;

  @override
  Future<void> setStatus(RunStatus s) async => current = s;

  @override
  Future<void> clear() async {
    rows.clear();
    entries.clear();
    current = const RunStatus();
  }
}
