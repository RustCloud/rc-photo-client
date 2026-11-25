/// One backup run: what is new on the phone goes to the cloud.
///
/// 1. The chosen albums are listed and compared with the store: new and
///    changed files are queued, deleted ones forgotten — and moved to the
///    cloud's trash with "delete in the cloud too".
/// 2. Each queued file is hashed (SHA-256, the cloud's `etag`); if the cloud
///    has that file anywhere in the gallery or in the album's folder, it is
///    skipped. Otherwise it is uploaded: in one request up to 16 MiB, in 8 MiB
///    parts above, continued after a break.
/// 3. A lost network stops the run: the worker runs again when it is back.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../api/auth.dart';
import '../api/client.dart';
import '../api/models.dart';
import 'folders.dart';
import 'phone_media.dart';
import 'settings.dart';
import 'store.dart';

/// How a run ended, for the worker (Backup.kt) to plan the next.
enum RunResult {
  done,

  /// The network went away: again once it is back.
  network,

  /// Videos wait for Wi-Fi.
  wifi,

  /// The server asked to wait (too many uploads at once).
  later,

  /// Nothing to do: off, or not set up.
  off,
  noLogin,
  noAccess,
  quota,
}

/// The file changed while it was read: queued again, read anew next time.
class _FileChanged implements Exception {}

/// The run must stop with [result] (network, quota…).
class _Stop implements Exception {
  const _Stop(this.result);
  final RunResult result;
}

class BackupEngine {
  BackupEngine({
    required this.client,
    required this.media,
    required this.store,
    required this.settings,
    this.saveSettings,
    this.onProgress,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final RcClient client;
  final PhoneMedia media;
  final BackupStore store;
  BackupSettings settings;

  /// The settings changed (cloud folders made again).
  final Future<void> Function(BackupSettings)? saveSettings;

  /// For the notification: file [done] of [total].
  final void Function(int done, int total, String name)? onProgress;
  final DateTime Function() _now;

  /// Up to this size a file goes in one request.
  static const simpleLimit = 16 << 20;

  /// The part size above it.
  static const partSize = 8 << 20;

  /// Times a file the server refused is tried again in later runs.
  static const maxAttempts = 3;

  Set<String>? _known;
  final Map<String, Map<String, Node>> _folderFiles = {};
  int _uploaded = 0;

  Future<void> _log(LogKind kind, {String name = '', String detail = ''}) =>
      store.log(LogEntry(at: _now(), kind: kind, name: name, detail: detail));

  Future<RunResult> run() async {
    final s = settings;
    if (!s.enabled || !s.ready) return RunResult.off;
    final access = await media.access();
    if (access == MediaAccess.none) {
      await _log(LogKind.noAccess);
      return RunResult.noAccess;
    }
    final net = await media.network();
    if (net == NetworkKind.none) return RunResult.network;
    if (s.wifiOnly && net == NetworkKind.metered) return RunResult.wifi;

    try {
      final queue = await _scan(full: access == MediaAccess.full);
      var result = RunResult.done;
      if (queue.isNotEmpty) {
        await _log(LogKind.started, detail: '${queue.length}');
        result = await _upload(queue, net);
        await _log(LogKind.finished, detail: '$_uploaded');
      }
      if (result == RunResult.done || result == RunResult.wifi) {
        await _fixTimes();
      }
      return result;
    } on _Stop catch (e) {
      if (_uploaded > 0) await _log(LogKind.finished, detail: '$_uploaded');
      return e.result;
    } on SessionEndedException {
      await _log(LogKind.noLogin);
      return RunResult.noLogin;
    } on NetworkException catch (e) {
      await _log(LogKind.network, detail: e.message);
      return RunResult.network;
    } finally {
      await store.setStatus(RunStatus(lastRun: _now()));
    }
  }

  // ── Scan ────────────────────────────────────────────────────────────

  /// Brings the store in line with the phone; the files to copy, newest
  /// first. [full]: the app sees all photos, so a missing one was deleted
  /// (with partial access it may just be hidden).
  Future<List<MediaRow>> _scan({required bool full}) async {
    final buckets = {for (final a in settings.albums) a.bucketId};
    final items = await media.items(buckets.toList());
    final rows = await store.all();
    final now = _now().millisecondsSinceEpoch;
    final changed = <MediaRow>[];
    final seen = <int>{};
    for (final i in items) {
      seen.add(i.id);
      final r = rows[i.id];
      if (r == null) {
        changed.add(MediaRow.fromItem(i)..updated = now);
      } else if (r.size != i.size || r.modified != i.modified) {
        // Edited: copied again over the same cloud file (it keeps versions).
        changed.add(
          r
            ..bucket = i.bucket
            ..name = i.name
            ..size = i.size
            ..modified = i.modified
            ..added = i.added
            ..taken = i.taken
            ..mime = i.mime
            ..uri = i.uri
            ..sha256 = null
            ..uploadId = null
            ..state = MediaState.pending
            ..failKind = null
            ..error = null
            ..attempts = 0
            ..updated = now,
        );
      } else if (r.state == MediaState.uploading) {
        // A run that was stopped midway.
        changed.add(r..state = MediaState.pending);
      } else if (r.bucket != i.bucket || r.added != i.added) {
        changed.add(
          r
            ..bucket = i.bucket
            ..added = i.added,
        );
      }
    }
    await store.putAll(changed);
    await _gone(rows, seen, buckets, items, full: full);

    final all = await store.all();
    return all.values
        .where(
          (r) =>
              buckets.contains(r.bucket) &&
              (r.state == MediaState.pending ||
                  (r.state == MediaState.failed &&
                      r.failKind == FailKind.server &&
                      r.attempts < maxAttempts)),
        )
        .toList()
      ..sort((a, b) => b.ctime.compareTo(a.ctime));
  }

  /// Files no longer on the phone: forgotten; with "delete in the cloud
  /// too" their copies go to the cloud's trash. An album that vanished
  /// whole (a memory card out) is left alone.
  Future<void> _gone(
    Map<int, MediaRow> rows,
    Set<int> seen,
    Set<String> buckets,
    List<MediaItem> items, {
    required bool full,
  }) async {
    final present = {for (final i in items) i.bucket};
    final forget = <int>[];
    for (final r in rows.values) {
      if (seen.contains(r.id) || !buckets.contains(r.bucket)) continue;
      if (!present.contains(r.bucket) || !full) continue;
      final id = r.remoteId;
      if (settings.deleteInCloud && r.state == MediaState.done && id != null) {
        try {
          await client.deleteFile(id);
          await _log(LogKind.deleted, name: r.remoteName ?? r.name);
        } on ApiException catch (e) {
          // Already gone there: fine. Anything else: try next time.
          if (e.status != 404) continue;
        }
      }
      forget.add(r.id);
    }
    await store.remove(forget);
  }

  // ── Upload ──────────────────────────────────────────────────────────

  Future<RunResult> _upload(List<MediaRow> queue, NetworkKind net) async {
    var waitWifi = 0;
    for (var n = 0; n < queue.length; n++) {
      final row = queue[n];
      onProgress?.call(n, queue.length, row.name);
      await store.setStatus(
        RunStatus(
          running: true,
          name: row.name,
          size: row.size,
          done: n,
          total: queue.length,
        ),
      );
      if (row.isVideo && settings.videoWifiOnly && net == NetworkKind.metered) {
        await _set(row, MediaState.pending, kind: FailKind.wifi);
        waitWifi++;
        continue;
      }
      await _one(row, n, queue.length);
    }
    if (waitWifi > 0) {
      await _log(LogKind.waitWifi, detail: '$waitWifi');
      return RunResult.wifi;
    }
    return RunResult.done;
  }

  Future<void> _set(
    MediaRow row,
    MediaState state, {
    FailKind? kind,
    String? error,
  }) async {
    row
      ..state = state
      ..failKind = kind
      ..error = error
      ..updated = _now().millisecondsSinceEpoch;
    await store.put(row);
  }

  /// Copies one file; a failure that concerns only it is noted and the run
  /// goes on, one that concerns all (network, quota) stops it.
  Future<void> _one(MediaRow row, int n, int total) async {
    await _set(row, MediaState.uploading);
    try {
      final folder = _folderOf(row);
      final Uint8List? whole;
      if (row.size <= simpleLimit) {
        whole = await _read(row, 0, row.size);
        if (whole.length != row.size) throw _FileChanged();
        row.sha256 = sha256.convert(whole).toString();
      } else {
        whole = null;
        row.sha256 ??= await _hash(row);
      }
      await store.put(row);
      final sha = row.sha256!;
      if ((await _knownHashes()).contains(sha)) {
        await _set(row, MediaState.skipped);
        await _log(LogKind.skipped, name: row.name);
        return;
      }
      final node = await _send(row, folder, whole, n, total);
      row
        ..remoteId = node.id
        ..remoteName = node.name
        ..uploadId = null
        ..attempts = 0
        ..timesSet = _hasTimes(node, row);
      await _set(row, MediaState.done);
      _known!.add(sha);
      _uploaded++;
      await _log(LogKind.uploaded, name: node.name);
    } on NetworkException {
      await _set(row, MediaState.pending, kind: FailKind.network);
      rethrow;
    } on SessionEndedException {
      await _set(row, MediaState.pending);
      rethrow;
    } on _FileChanged {
      row
        ..sha256 = null
        ..uploadId = null;
      await _set(row, MediaState.pending);
    } on _FolderGone {
      // Made again just now: the file goes next run.
      await _set(row, MediaState.pending);
    } on _FileError catch (e) {
      await _fail(row, FailKind.file, e.message);
    } on ApiException catch (e) {
      await _apiFailure(row, e);
    }
  }

  Future<void> _apiFailure(MediaRow row, ApiException e) async {
    final detail = e.message.isEmpty ? '${e.status} ${e.code}' : e.message;
    switch (e.code) {
      case 'QUOTA_EXCEEDED' || 'STORAGE_FULL':
        await _fail(row, FailKind.quota, detail);
        await _log(LogKind.quota, detail: detail);
        throw const _Stop(RunResult.quota);
      case 'FILE_TOO_LARGE':
        await _fail(row, FailKind.tooLarge, detail);
      case 'TOO_MANY_UPLOADS':
        await _set(row, MediaState.pending);
        await _log(LogKind.later, detail: detail);
        throw const _Stop(RunResult.later);
      default:
        if (e.status >= 500 || e.status == 429) {
          row.attempts++;
        } else {
          row.attempts = maxAttempts; // the same request would fail again
        }
        await _fail(row, FailKind.server, detail);
    }
  }

  Future<void> _fail(MediaRow row, FailKind kind, String detail) async {
    await _set(row, MediaState.failed, kind: kind, error: detail);
    await _log(LogKind.failed, name: row.name, detail: detail);
  }

  String _folderOf(MediaRow row) =>
      settings.albums.firstWhere((a) => a.bucketId == row.bucket).folderId!;

  Future<Uint8List> _read(MediaRow row, int offset, int length) async {
    try {
      return await media.read(row.uri, offset, length);
    } catch (e) {
      throw _FileError('$e');
    }
  }

  Future<String> _hash(MediaRow row) async {
    final out = _DigestSink();
    final input = sha256.startChunkedConversion(out);
    var off = 0;
    while (off < row.size) {
      final len = row.size - off < partSize ? row.size - off : partSize;
      final bytes = await _read(row, off, len);
      if (bytes.length != len) throw _FileChanged();
      input.add(bytes);
      off += len;
    }
    input.close();
    return out.value.toString();
  }

  /// SHA-256 of what the cloud has: the gallery's index and the files in the
  /// backup's album folders (an upload the plugin hasn't indexed yet).
  Future<Set<String>> _knownHashes() async {
    final known = _known;
    if (known != null) return known;
    final set = <String>{};
    try {
      final state = await client.photoState();
      for (final link in state.shards) {
        for (final e in (await client.shard(link)).entries ?? const <Entry>[]) {
          set.add(e.etag);
        }
      }
    } on ApiException {
      // The plugin is off: the folders still tell.
    }
    for (final a in settings.albums) {
      for (final f in (await _files(a.folderId!)).values) {
        if (f.etag != null) set.add(f.etag!);
      }
    }
    return _known = set;
  }

  Future<Map<String, Node>> _files(String folder, {bool fresh = false}) async {
    if (!fresh && _folderFiles[folder] != null) return _folderFiles[folder]!;
    final List<Node> kids;
    try {
      kids = await client.children(folder);
    } on ApiException catch (e) {
      if (e.status != 404) rethrow;
      await _remakeFolders();
      throw _FolderGone();
    }
    return _folderFiles[folder] = {for (final k in kids) k.name: k};
  }

  /// The user deleted the backup's folders: they are made again.
  Future<void> _remakeFolders() async {
    settings = await CloudFolders(client).apply(settings);
    await saveSettings?.call(settings);
    _folderFiles.clear();
    await _log(LogKind.folders);
  }

  /// Uploads under the file's name; if the name is taken by another file,
  /// `name (2).ext` and so on. A changed file replaces its earlier copy.
  Future<Node> _send(
    MediaRow row,
    String folder,
    Uint8List? whole,
    int n,
    int total,
  ) async {
    var name = row.remoteName ?? row.name;
    final overwrite = row.remoteId != null;
    for (var attempt = 2; attempt < 100; attempt++) {
      try {
        if (whole != null) {
          return await client.upload(
            folder,
            name,
            whole,
            mtime: _time(row.modified),
            ctime: _time(row.ctime),
            overwrite: overwrite,
          );
        }
        return await _parts(row, folder, name, overwrite, n, total);
      } on ApiException catch (e) {
        if (e.status == 404 &&
            (e.code == 'FILE_NOT_FOUND' || e.code == 'NOT_FOUND')) {
          // The folder is gone.
          await _remakeFolders();
          folder = _folderOf(row);
          continue;
        }
        if (e.code != 'NAME_TAKEN' && e.code != 'ALREADY_EXISTS') rethrow;
        final there = (await _files(folder, fresh: true))[name];
        if (there != null && there.etag == row.sha256) return there;
        name = _numbered(row.name, attempt);
        row.remoteName = name;
        await store.put(row);
      } on _FolderGone {
        folder = _folderOf(row);
      }
    }
    throw const ApiException(409, 'NAME_TAKEN', 'no free name');
  }

  Future<Node> _parts(
    MediaRow row,
    String folder,
    String name,
    bool overwrite,
    int n,
    int total,
  ) async {
    UploadState? up;
    final id = row.uploadId;
    if (id != null) {
      try {
        up = await client.uploadState(id);
      } on ApiException catch (e) {
        if (e.status != 404) rethrow; // expired: start again
      }
    }
    up ??= await client.startUpload(
      folder,
      name: name,
      size: row.size,
      mtime: _time(row.modified),
      ctime: _time(row.ctime),
      overwrite: overwrite,
    );
    row.uploadId = up.id;
    await store.put(row);
    var off = up.received;
    while (off < row.size) {
      final len = row.size - off < partSize ? row.size - off : partSize;
      final bytes = await _read(row, off, len);
      if (bytes.length != len) throw _FileChanged();
      try {
        off = (await client.uploadPart(up.id, off, bytes)).received;
      } on ApiException catch (e) {
        if (e.code != 'WRONG_OFFSET') rethrow;
        off = (await client.uploadState(up.id)).received;
      }
      await store.setStatus(
        RunStatus(
          running: true,
          name: row.name,
          sent: off,
          size: row.size,
          done: n,
          total: total,
        ),
      );
    }
    try {
      return await client.finishUpload(up.id, row.sha256!);
    } on ApiException catch (e) {
      if (e.code == 'CHECKSUM_MISMATCH' || e.code == 'UPLOAD_NOT_FOUND') {
        // The file changed while it went, or the server dropped it.
        row.uploadId = null;
        throw _FileChanged();
      }
      if (e.code == 'NAME_TAKEN' || e.code == 'ALREADY_EXISTS') {
        // The upload stays on the server for 24 h; a new one under the next name.
        row.uploadId = null;
      }
      rethrow;
    }
  }

  /// A time the server takes, seconds: not before 1970, at most a day ahead.
  int? _time(int t) {
    final limit = _now().millisecondsSinceEpoch ~/ 1000 + 86400;
    return t <= 0 || t > limit ? null : t;
  }

  /// The cloud file has [row]'s times. Not after an `overwrite` (it keeps
  /// its `born_at`), nor when the name was taken by the same file, nor from
  /// a server that doesn't keep `ctime`: then [_fixTimes] sets them.
  bool _hasTimes(Node node, MediaRow row) {
    final born = node.bornAt;
    final want = _time(row.ctime);
    if (born == null) return false;
    return want == null ||
        (born.millisecondsSinceEpoch ~/ 1000 - want).abs() <= 1;
  }

  /// Gives the copies made before the server kept `ctime` (or that kept an
  /// older one) the phone's times. Once per file; a server that doesn't keep
  /// them is asked once a run.
  Future<void> _fixTimes() async {
    final buckets = {for (final a in settings.albums) a.bucketId};
    final rows = (await store.all()).values.where(
      (r) =>
          r.state == MediaState.done &&
          !r.timesSet &&
          r.remoteId != null &&
          buckets.contains(r.bucket),
    );
    for (final row in rows) {
      try {
        final node = await client.setTimes(
          row.remoteId!,
          born: _time(row.ctime),
          modified: _time(row.modified),
        );
        if (node.bornAt == null) return; // an older server
      } on ApiException catch (e) {
        // Gone from the cloud or a time it won't take: nothing to fix.
        if (e.status >= 500 || e.status == 429) return;
      } on NetworkException {
        return;
      }
      await store.put(row..timesSet = true);
    }
  }

  /// `IMG_1.jpg` → `IMG_1 (2).jpg`.
  static String _numbered(String name, int n) {
    final dot = name.lastIndexOf('.');
    return dot <= 0
        ? '$name ($n)'
        : '${name.substring(0, dot)} ($n)${name.substring(dot)}';
  }
}

class _FileError implements Exception {
  const _FileError(this.message);
  final String message;
}

class _FolderGone implements Exception {}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
