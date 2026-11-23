import 'dart:convert';
import 'dart:isolate';

import '../api/client.dart';
import '../api/models.dart';
import 'index_store.dart';
import 'link_token.dart';

/// What the cloud knows about the photos: the plugin's index (date, camera,
/// place…), its state (names, stories) and the people it found. Only
/// metadata comes from the server — the phone shows its own files — and it
/// is kept on the phone, so a shard is fetched again only when it changed
/// and the app has names and people without the network.
class CloudIndex {
  CloudIndex(this._store);

  /// Opened on first use.
  final Future<IndexStore> _store;

  /// Keys of what isn't a shard of the index.
  static const _stateKey = '#state';
  static const _peopleKey = '#people';

  PhotoState _state = const PhotoState.empty();
  Map<String, Entry> _byEtag = const {};
  Map<String, Entry> _byId = const {};
  List<Person> _people = const [];
  int _count = 0;

  PhotoState get state => _state;

  /// Photos and videos in the cloud's gallery.
  int get count => _count;

  /// Everyone the plugin found, as it last grouped them.
  List<Person> get people => _people;

  /// The cloud's entry for a file with this SHA-256.
  Entry? byHash(String? sha256) => sha256 == null ? null : _byEtag[sha256];

  /// The cloud's entry of this id.
  Entry? byId(String id) => _byId[id];

  /// What was kept from last time; nothing is fetched.
  Future<void> loadSaved() async {
    final saved = await (await _store).shards();
    final state = saved[_stateKey]?.body;
    if (state != null) {
      try {
        _state = PhotoState.fromJson(jsonDecode(state) as Map<String, dynamic>);
      } on Object {
        // fetched again
      }
    }
    _people = _readPeople(saved[_peopleKey]?.body);
    _use(await _parse(_shardBodies(saved)));
  }

  /// Asks the plugin for its state and fetches what changed.
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
    final raw = await client.photoStateJson(today: today);
    final state = PhotoState.fromJson(raw);
    final store = await _store;
    final saved = await store.shards();
    final keep = <String>{_stateKey};
    var changed = false;

    /// Fetches what [link] points at unless the phone has that version.
    Future<String?> fetch(String link, String? fixedKey) async {
      final target = LinkTarget.read(link);
      final key = fixedKey ?? target?.path ?? link;
      keep.add(key);
      final old = saved[key];
      if (old != null &&
          old.version != null &&
          old.version == target?.version) {
        return null;
      }
      // A 404 here is not "nothing there" but a closed link.
      final body = await client.fetchText(link);
      await store.put(
        CachedShard(key: key, version: target?.version, body: body),
      );
      return body;
    }

    for (final link in state.shards) {
      if (await fetch(link, null) != null) changed = true;
    }
    final peopleLink = state.people;
    if (peopleLink != null) {
      final body = await fetch(peopleLink, _peopleKey);
      if (body != null) _people = _readPeople(body);
    } else {
      _people = const [];
    }
    final gone = saved.keys.where((k) => !keep.contains(k)).toList();
    if (gone.isNotEmpty) {
      await store.remove(gone);
      if (gone.any((k) => !k.startsWith('#'))) changed = true;
    }
    await store.put(
      CachedShard(key: _stateKey, version: null, body: jsonEncode(raw)),
    );
    final roots = {for (final f in state.folders) f.id};
    _state = state;
    // Most refreshes change nothing: no need to read it all again.
    if (!changed && _roots != null && _sameSet(roots, _roots!)) return;
    _use(await _parse(_shardBodies(await store.shards())), roots: roots);
  }

  /// The folders the entries were filtered by; null until the first refresh.
  Set<String>? _roots;

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  static List<String> _shardBodies(Map<String, CachedShard> saved) => [
    for (final s in saved.values)
      if (!s.key.startsWith('#')) s.body,
  ];

  static List<Person> _readPeople(String? body) {
    if (body == null) return const [];
    try {
      return parsePeople(body);
    } on Object {
      return const [];
    }
  }

  void _use(List<Entry> entries, {Set<String>? roots}) {
    final byEtag = <String, Entry>{};
    final byId = <String, Entry>{};
    var n = 0;
    for (final e in entries) {
      // A folder taken back from the plugin: its shard lines go later.
      if (roots != null && !roots.contains(e.root)) continue;
      n++;
      byId[e.id] = e;
      if (e.etag.isNotEmpty) byEtag[e.etag] = e;
    }
    _byEtag = byEtag;
    _byId = byId;
    _count = n;
    _roots = roots;
  }

  Future<void> clear() async {
    await (await _store).clear();
    _state = const PhotoState.empty();
    _byEtag = const {};
    _byId = const {};
    _people = const [];
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
