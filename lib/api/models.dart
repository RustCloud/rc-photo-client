/// Data the server (`/api/v1`) and the rc-photo plugin (`/app/rc-photo/api`)
/// send. Plain Dart, no Flutter: the same code runs in `dart test` against a
/// real server.
///
/// Parsing is lenient on purpose: unknown fields are ignored and missing
/// optional ones become null, so a newer plugin or server doesn't break an
/// older app (the plugin only ever adds fields, see docs/requests.md#2).
library;

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
    required this.stories,
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
      stories = null,
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
    stories: j['stories'] as Map<String, dynamic>?,
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

  /// Stories status, raw for now.
  final Map<String, dynamic>? stories;

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

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

List<String> _strings(Object? v) =>
    v is List ? v.whereType<String>().toList() : const [];

List<T> _list<T>(Object? v, T Function(Map<String, dynamic>) f) =>
    v is List ? v.whereType<Map<String, dynamic>>().map(f).toList() : const [];
