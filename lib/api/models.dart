/// Data the server (`/api/v1`) and the rc-photo plugin (`/app/rc-photo/api`)
/// send. Plain Dart, no Flutter: the same code runs in `dart test` against a
/// real server.
///
/// Parsing is lenient on purpose: unknown fields are ignored and missing
/// optional ones become null, so a newer plugin or server doesn't break an
/// older app (the plugin only ever adds fields, see docs/requests.md#2).
library;

import 'dart:convert';

/// A file or folder of the server (`Node` in rustcloud/docs/api/files.md).
class Node {
  const Node({
    required this.id,
    required this.parentId,
    required this.name,
    required this.isDir,
    required this.size,
    required this.mimeType,
    required this.etag,
    required this.modifiedAt,
    required this.updatedAt,
    this.bornAt,
  });

  factory Node.fromJson(Map<String, dynamic> j) => Node(
    id: j['id'] as String,
    parentId: j['parent_id'] as String?,
    name: j['name'] as String,
    isDir: j['is_dir'] as bool? ?? false,
    size: (j['size'] as num?)?.toInt() ?? 0,
    mimeType: j['mime_type'] as String?,
    etag: j['etag'] as String?,
    modifiedAt: _date(j['modified_at']),
    updatedAt: _date(j['updated_at']),
    bornAt: _date(j['born_at']),
  );

  final String id;

  /// Null for the root folder.
  final String? parentId;
  final String name;
  final bool isDir;
  final int size;
  final String? mimeType;

  /// sha256 of the content in hex; null for folders.
  final String? etag;

  /// The mtime the client gave on upload (or the upload time).
  final DateTime? modifiedAt;
  final DateTime? updatedAt;

  /// When the file was made on the device that sent it (`ctime`); the
  /// server's creation time if it didn't say. Null from a server before
  /// API 0.2.21, which doesn't keep it.
  final DateTime? bornAt;
}

/// One photo or video of the gallery index (`Entry` in r-image/src/index.rs).
class Entry {
  const Entry({
    required this.id,
    required this.name,
    required this.folder,
    required this.root,
    required this.etag,
    required this.size,
    required this.mime,
    required this.video,
    required this.taken,
    required this.modified,
    required this.width,
    required this.height,
    required this.container,
    required this.thumb,
    required this.preview,
    this.camera,
    this.lens,
    this.iso,
    this.aperture,
    this.exposure,
    this.focal,
    this.lat,
    this.lon,
    this.duration,
    this.codec,
  });

  factory Entry.fromJson(Map<String, dynamic> j) {
    final gps = j['gps'] as List<dynamic>?;
    final duration = (j['duration'] as num?)?.toInt();
    return Entry(
      id: j['id'] as String,
      name: j['name'] as String,
      folder: j['folder'] as String? ?? '',
      root: j['root'] as String? ?? '',
      etag: j['etag'] as String? ?? '',
      size: (j['size'] as num?)?.toInt() ?? 0,
      mime: j['mime'] as String? ?? '',
      video: j['video'] as bool? ?? false,
      taken: j['taken'] as String?,
      modified: _date(j['modified']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      width: (j['width'] as num?)?.toInt() ?? 0,
      height: (j['height'] as num?)?.toInt() ?? 0,
      container: j['container'] as String? ?? '',
      thumb: j['thumb'] as bool? ?? false,
      preview: j['preview'] as bool? ?? false,
      camera: j['camera'] as String?,
      lens: j['lens'] as String?,
      iso: (j['iso'] as num?)?.toInt(),
      aperture: (j['aperture'] as num?)?.toDouble(),
      exposure: j['exposure'] as String?,
      focal: (j['focal'] as num?)?.toDouble(),
      lat: gps != null && gps.length == 2 ? (gps[0] as num).toDouble() : null,
      lon: gps != null && gps.length == 2 ? (gps[1] as num).toDouble() : null,
      duration: duration == null ? null : Duration(milliseconds: duration),
      codec: j['codec'] as String?,
    );
  }

  final String id;
  final String name;

  /// Folders from the granted one down to the file's: `Photos/2024/Trip`.
  final String folder;

  /// Id of the granted folder it is in.
  final String root;

  /// sha256 of the file: matches [Node.etag] and the hash of a phone file.
  final String etag;
  final int size;
  final String mime;
  final bool video;

  /// When it was shot, as the plugin wrote it: RFC 3339, perhaps without an
  /// offset (camera local time). Kept as text; see [takenLocal].
  final String? taken;

  /// The file's last change on the server: the date when [taken] is missing.
  final DateTime modified;

  /// As shown (rotation applied); 0 when unknown.
  final int width;
  final int height;
  final String container;

  /// A thumbnail exists (`kind: thumb` links work).
  final bool thumb;

  /// A large JPEG exists for a format phones may not show (HEIC, RAW, TIFF).
  final bool preview;
  final String? camera;
  final String? lens;
  final int? iso;
  final double? aperture;
  final String? exposure;
  final double? focal;
  final double? lat;
  final double? lon;
  final Duration? duration;
  final String? codec;

  /// The wall-clock time the photo was taken, as the camera showed it, for
  /// grouping by day: the local date and time are kept, the offset dropped.
  /// Falls back to [modified] in the phone's time zone.
  DateTime get takenLocal {
    final t = taken;
    if (t != null) {
      final m = _wallClock.firstMatch(t);
      if (m != null) {
        return DateTime(
          int.parse(m[1]!),
          int.parse(m[2]!),
          int.parse(m[3]!),
          int.parse(m[4]!),
          int.parse(m[5]!),
          int.parse(m[6]!),
        );
      }
    }
    return modified.toLocal();
  }

  static final _wallClock = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})',
  );
}

/// A folder the plugin was given (`state.folders`).
class PhotoFolder {
  const PhotoFolder({required this.id, required this.name});

  factory PhotoFolder.fromJson(Map<String, dynamic> j) =>
      PhotoFolder(id: j['id'] as String, name: j['name'] as String? ?? '');

  final String id;
  final String name;
}

/// Jobs of one kind the plugin still has to do (`state.progress`).
class JobProgress {
  const JobProgress({required this.waiting, required this.failed});

  factory JobProgress.fromJson(Map<String, dynamic> j) => JobProgress(
    waiting: (j['waiting'] as num?)?.toInt() ?? 0,
    failed: (j['failed'] as num?)?.toInt() ?? 0,
  );

  final int waiting;
  final int failed;
}

/// `GET /app/rc-photo/api/state`: everything the gallery needs to start.
///
/// Links in it (shards, texts, people) are relative to the server, tied to the
/// session, and live 12–13 hours or until the server restarts.
class PhotoState {
  const PhotoState({
    required this.folders,
    required this.shards,
    required this.texts,
    required this.people,
    required this.names,
    required this.hiddenPeople,
    required this.progress,
    required this.favorites,
    required this.facesEnabled,
    required this.analysis,
    required this.storiesEnabled,
    required this.stories,
    required this.storiesSeen,
    required this.merged,
    required this.covers,
    required this.uploadFolder,
    required this.ffmpeg,
    required this.api,
  });

  /// Nothing yet (before the first answer).
  const PhotoState.empty()
    : folders = const [],
      shards = const [],
      texts = const [],
      people = null,
      names = const {},
      hiddenPeople = const {},
      progress = const {},
      favorites = const {},
      facesEnabled = false,
      analysis = const {},
      storiesEnabled = false,
      stories = const [],
      storiesSeen = const {},
      merged = const {},
      covers = const {},
      uploadFolder = null,
      ffmpeg = false,
      api = 0;

  factory PhotoState.fromJson(Map<String, dynamic> j) => PhotoState(
    folders: _list(j['folders'], PhotoFolder.fromJson),
    shards: _strings(j['shards']),
    texts: _strings(j['texts']),
    people: j['people'] as String?,
    names:
        ((j['names'] as Map<String, dynamic>?)?['names']
                    as Map<String, dynamic>? ??
                const {})
            .map((k, v) => MapEntry(k, v.toString())),
    hiddenPeople: _strings(
      (j['names'] as Map<String, dynamic>?)?['hidden'],
    ).toSet(),
    progress: (j['progress'] as Map<String, dynamic>? ?? const {}).map(
      (k, v) => MapEntry(k, JobProgress.fromJson(v as Map<String, dynamic>)),
    ),
    favorites: _strings(j['favorites']).toSet(),
    facesEnabled:
        (j['faces'] as Map<String, dynamic>?)?['enabled'] as bool? ?? false,
    analysis: j['analysis'] as Map<String, dynamic>? ?? const {},
    storiesEnabled:
        (j['stories'] as Map<String, dynamic>?)?['enabled'] as bool? ?? false,
    stories: _list(
      (j['stories'] as Map<String, dynamic>?)?['list'],
      Story.fromJson,
    ),
    storiesSeen: _strings(
      (j['stories'] as Map<String, dynamic>?)?['seen'],
    ).toSet(),
    merged: _stringMap((j['names'] as Map<String, dynamic>?)?['merged']),
    covers: {
      for (final e
          in ((j['names'] as Map<String, dynamic>?)?['covers']
                      as Map<String, dynamic>? ??
                  const {})
              .entries)
        if (e.value is Map<String, dynamic>)
          e.key: ?FaceBox.tryJson(e.value as Map<String, dynamic>),
    },
    uploadFolder: j['uploadFolder'] as String?,
    ffmpeg: j['ffmpeg'] as bool? ?? false,
    api: (j['api'] as num?)?.toInt() ?? 0,
  );

  final List<PhotoFolder> folders;

  /// Links to the index shards (`index/<00–3f>.json`), each a JSON list of
  /// [Entry].
  final List<String> shards;

  /// Links to the shards of text read in photos (empty when analysis is off).
  final List<String> texts;

  /// Link to the people file, if faces are on.
  final String? people;

  /// Person id → name (`state.names.names`; the rest of `state.names` —
  /// merges, faces put by hand, covers — is read in the people phase).
  final Map<String, String> names;

  /// People the user hid.
  final Set<String> hiddenPeople;

  /// Job kind (`media`, `clip`, `faces`…) → what is left.
  final Map<String, JobProgress> progress;

  /// Ids of favourite files.
  final Set<String> favorites;
  final bool facesEnabled;

  /// Photo analysis status, kept raw until the app uses it (search phase).
  final Map<String, dynamic> analysis;

  /// The administrator left stories on.
  final bool storiesEnabled;

  /// The stories showing today, newest first.
  final List<Story> stories;

  /// Dates of the stories the user watched.
  final Set<String> storiesSeen;

  /// A person merged into another (`state.names.merged`): the grouping
  /// catches up later.
  final Map<String, String> merged;

  /// The face the user chose to show for a person.
  final Map<String, FaceBox> covers;

  /// Where a merged person went.
  String personOf(String id) {
    for (var i = 0; i < 16; i++) {
      final into = merged[id];
      if (into == null) break;
      id = into;
    }
    return id;
  }

  /// The folder uploads went to last (the web page remembers it).
  final String? uploadFolder;
  final bool ffmpeg;

  /// The plugin's API version; 0 for plugins before `api` (≤ 0.8).
  final int api;

  /// Photos the plugin is still adding to the index (`media` jobs).
  int get indexing => progress['media']?.waiting ?? 0;
}

/// An answer the server couldn't fulfil: `{"error": {"code", "message"}}`, or
/// an OAuth error from `/auth/token`.
class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message);

  /// Builds it from a response body; anything unexpected keeps the status.
  factory ApiException.fromBody(int status, Object? body) {
    if (body is Map<String, dynamic>) {
      final e = body['error'];
      if (e is Map<String, dynamic>) {
        return ApiException(
          status,
          e['code'] as String? ?? 'UNKNOWN',
          e['message'] as String? ?? '',
        );
      }
      if (e is String) {
        // OAuth: {"error": "invalid_grant", "error_description": "…"}
        return ApiException(
          status,
          e,
          body['error_description'] as String? ?? '',
        );
      }
    }
    return ApiException(status, 'HTTP_$status', body?.toString() ?? '');
  }

  final int status;
  final String code;
  final String message;

  @override
  String toString() => 'ApiException($status $code: $message)';
}

/// A face in a photo: the photo's id and the box, in parts (0–1) of the
/// picture as shown: `[x, y, width, height]`.
class FaceBox {
  const FaceBox(this.file, this.x, this.y, this.w, this.h);

  static FaceBox? tryJson(Map<String, dynamic> j) {
    final file = j['file'];
    final b = j['b'];
    if (file is! String || b is! List || b.length != 4) return null;
    final n = b.whereType<num>().map((v) => v.toDouble()).toList();
    if (n.length != 4) return null;
    return FaceBox(file, n[0], n[1], n[2], n[3]);
  }

  final String file;
  final double x, y, w, h;
}

/// A person the plugin found (`people.json`).
class Person {
  const Person({
    required this.id,
    required this.count,
    required this.files,
    this.cover,
  });

  factory Person.fromJson(Map<String, dynamic> j) => Person(
    id: j['id'] as String,
    count: (j['count'] as num?)?.toInt() ?? 0,
    files: _strings(j['files']),
    cover: j['cover'] is Map<String, dynamic>
        ? FaceBox.tryJson(j['cover'] as Map<String, dynamic>)
        : null,
  );

  final String id;

  /// Faces found.
  final int count;

  /// Ids of the photos they are in.
  final List<String> files;

  /// The sharpest face.
  final FaceBox? cover;
}

/// `people.json`: everyone, as the plugin last grouped them.
List<Person> parsePeople(String body) {
  final j = jsonDecode(body);
  if (j is! Map<String, dynamic>) return const [];
  return _list(j['people'], Person.fromJson);
}

/// A story of the day (`state.stories.list`): a script to play, not a video.
class Story {
  const Story({
    required this.date,
    required this.kind,
    required this.key,
    required this.params,
    required this.cover,
    required this.items,
  });

  factory Story.fromJson(Map<String, dynamic> j) => Story(
    date: j['date'] as String? ?? '',
    kind: j['kind'] as String? ?? '',
    key: j['key'] as String? ?? '',
    params: j['params'] as Map<String, dynamic>? ?? const {},
    cover: j['cover'] as String? ?? '',
    items: _list(j['items'], StoryItem.fromJson),
  );

  /// The day it was made for (`YYYY-MM-DD`): its id in requests.
  final String date;

  /// `on-this-day`, `trip`, `event`, `person`; others may come.
  final String kind;
  final String key;

  /// For the title: `years`, `date`, `from`, `to`, `person`.
  final Map<String, dynamic> params;

  /// Id of the photo on its circle.
  final String cover;
  final List<StoryItem> items;
}

class StoryItem {
  const StoryItem({required this.id, required this.ms, this.from, this.focus});

  factory StoryItem.fromJson(Map<String, dynamic> j) {
    final f = j['focus'];
    return StoryItem(
      id: j['id'] as String,
      ms: (j['ms'] as num?)?.toInt() ?? 4500,
      from: (j['from'] as num?)?.toInt(),
      focus: f is List && f.length == 2
          ? ((f[0] as num).toDouble(), (f[1] as num).toDouble())
          : null,
    );
  }

  final String id;

  /// How long it shows.
  final int ms;

  /// A video: where its clip starts, ms.
  final int? from;

  /// Where to zoom to, in parts of the picture: a face, else the middle.
  final (double, double)? focus;
}

Map<String, String> _stringMap(Object? v) => v is Map<String, dynamic>
    ? {
        for (final e in v.entries)
          if (e.value is String) e.key: e.value as String,
      }
    : const {};

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

List<String> _strings(Object? v) =>
    v is List ? v.whereType<String>().toList() : const [];

List<T> _list<T>(Object? v, T Function(Map<String, dynamic>) f) =>
    v is List ? v.whereType<Map<String, dynamic>>().map(f).toList() : const [];
