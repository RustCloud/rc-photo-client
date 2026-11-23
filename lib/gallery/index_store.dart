import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// A shard of the plugin's index as the phone keeps it: the JSON text, and
/// the version it was fetched at.
class CachedShard {
  const CachedShard({
    required this.key,
    required this.version,
    required this.body,
  });

  /// The shard's path in the plugin's data (`index/0a.json`), or its link
  /// when the link can't be read.
  final String key;

  /// The shard file's ETag when it was fetched; null if not known.
  final String? version;
  final String body;
}

/// The cloud's index on the phone, so the timeline has it at once and only
/// changed shards are fetched again.
abstract class IndexStore {
  Future<Map<String, CachedShard>> shards();
  Future<void> put(CachedShard shard);
  Future<void> remove(Iterable<String> keys);
  Future<void> clear();
}

class SqliteIndexStore implements IndexStore {
  SqliteIndexStore._(this._db);

  final Database _db;

  static Future<SqliteIndexStore> open({
    DatabaseFactory? factory,
    String? path,
  }) async {
    final f = factory ?? databaseFactory;
    final where = path ?? p.join(await f.getDatabasesPath(), 'gallery.db');
    final db = await f.openDatabase(
      where,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) => db.execute('''
          CREATE TABLE shard (
            key TEXT PRIMARY KEY,
            version TEXT,
            body TEXT NOT NULL
          )'''),
      ),
    );
    return SqliteIndexStore._(db);
  }

  @override
  Future<Map<String, CachedShard>> shards() async => {
    for (final r in await _db.query('shard'))
      r['key'] as String: CachedShard(
        key: r['key'] as String,
        version: r['version'] as String?,
        body: r['body'] as String,
      ),
  };

  @override
  Future<void> put(CachedShard s) => _db.insert('shard', {
    'key': s.key,
    'version': s.version,
    'body': s.body,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  @override
  Future<void> remove(Iterable<String> keys) async {
    final b = _db.batch();
    for (final k in keys) {
      b.delete('shard', where: 'key = ?', whereArgs: [k]);
    }
    await b.commit(noResult: true);
  }

  @override
  Future<void> clear() => _db.delete('shard');
}

/// [IndexStore] in memory, for tests.
class MemoryIndexStore implements IndexStore {
  final Map<String, CachedShard> saved = {};

  @override
  Future<Map<String, CachedShard>> shards() async => Map.of(saved);

  @override
  Future<void> put(CachedShard s) async => saved[s.key] = s;

  @override
  Future<void> remove(Iterable<String> keys) async =>
      keys.forEach(saved.remove);

  @override
  Future<void> clear() async => saved.clear();
}
