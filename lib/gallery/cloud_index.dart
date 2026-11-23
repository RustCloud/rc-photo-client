import 'dart:convert';
import 'dart:isolate';

import '../api/client.dart';
import '../api/models.dart';
import 'index_store.dart';
import 'link_token.dart';

/// What the cloud knows about the photos: the plugin's index (date, camera,
/// place…) and state. Only metadata comes from the server — the timeline
/// shows the phone's own files — and it is kept on the phone, so a shard is
/// fetched again only when it changed.
class CloudIndex {
  CloudIndex(this._store);

  /// Opened on first use.
  final Future<IndexStore> _store;

  PhotoState _state = const PhotoState.empty();
  Map<String, Entry> _byEtag = const {};
  int _count = 0;

  PhotoState get state => _state;

  /// Photos and videos in the cloud's gallery.
  int get count => _count;

  /// The cloud's entry for a file with this SHA-256.
  Entry? byHash(String? sha256) => sha256 == null ? null : _byEtag[sha256];

  /// What was kept from last time; nothing is fetched.
  Future<void> loadSaved() async {
    final saved = await (await _store).shards();
    _use(await _parse(saved.values.map((s) => s.body).toList()));
  }

  /// Asks the plugin for its state and fetches the shards that changed.
  /// Throws what the client throws (`404` when the plugin is missing).
  Future<void> refresh(RcClient client, {DateTime? today}) async {
    // A job may rewrite a shard between the state and the fetch, which
    // closes its link (404): then everything once more.
    for (var attempt = 1; ; attempt++) {
      try {
        return await _refreshOnce(client, today);
      } on ApiException catch (e) {
        if (e.status != 404 || attempt == 3) rethrow;
      }
    }
  }

  Future<void> _refreshOnce(RcClient client, DateTime? today) async {
    final state = await client.photoState(today: today);
    final saved = await (await _store).shards();
    final keep = <String>{};
    var changed = false;
    for (final link in state.shards) {
      final target = LinkTarget.read(link);
      final key = target?.path ?? link;
      keep.add(key);
      final old = saved[key];
      if (old != null &&
          old.version != null &&
          old.version == target?.version) {
        continue;
      }
      // A 404 here is not "no such shard" but a closed link.
      final body = await client.fetchText(link);
      await (await _store).put(
        CachedShard(key: key, version: target?.version, body: body),
      );
      changed = true;
    }
    final gone = saved.keys.where((k) => !keep.contains(k)).toList();
    if (gone.isNotEmpty) {
      await (await _store).remove(gone);
      changed = true;
    }
    final roots = {for (final f in state.folders) f.id};
    _state = state;
    // Most refreshes change nothing: no need to read it all again.
    if (!changed && _roots != null && _sameSet(roots, _roots!)) return;
    final bodies = (await (await _store).shards()).values
        .map((s) => s.body)
        .toList();
    _use(await _parse(bodies), roots: roots);
  }

  /// The folders the entries were filtered by; null until the first refresh.
  Set<String>? _roots;

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  void _use(List<Entry> entries, {Set<String>? roots}) {
    final byEtag = <String, Entry>{};
    var n = 0;
    for (final e in entries) {
      // A folder taken back from the plugin: its shard lines go later.
      if (roots != null && !roots.contains(e.root)) continue;
      n++;
      if (e.etag.isNotEmpty) byEtag[e.etag] = e;
    }
    _byEtag = byEtag;
    _count = n;
    _roots = roots;
  }

  Future<void> clear() async {
    await (await _store).clear();
    _state = const PhotoState.empty();
    _byEtag = const {};
    _count = 0;
    _roots = null;
  }

  /// JSON of 10 000 photos is a few MB: read off the screen's isolate.
  static Future<List<Entry>> _parse(List<String> bodies) {
    if (bodies.isEmpty) return Future.value(const []);
    return Isolate.run(() => parseShards(bodies));
  }
}

/// The entries of shards; a shard that can't be read is skipped.
List<Entry> parseShards(List<String> bodies) {
  final out = <Entry>[];
  for (final b in bodies) {
    try {
      final list = jsonDecode(b);
      if (list is! List) continue;
      for (final j in list.whereType<Map<String, dynamic>>()) {
        try {
          out.add(Entry.fromJson(j));
        } on Object {
          // one bad line
        }
      }
    } on FormatException {
      // a broken shard: fetched again when its version changes
    }
  }
  return out;
}
