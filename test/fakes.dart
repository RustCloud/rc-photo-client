import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:rc_photo/api/auth.dart';
import 'package:rc_photo/api/client.dart';
import 'package:rc_photo/api/models.dart';
import 'package:rc_photo/backup/phone_media.dart';
import 'package:rc_photo/backup/scheduler.dart';
import 'package:rc_photo/backup/services.dart';
import 'package:rc_photo/backup/store.dart';
import 'package:rc_photo/auth/native.dart';
import 'package:rc_photo/auth/session_store.dart';
import 'package:rc_photo/backup/settings.dart';

/// The native side, scripted.
class FakeBridge implements NativeBridge {
  FakeBridge({this.phoneAccounts = const [], this.token, this.browserReturn});

  /// What `accounts` answers.
  List<String> phoneAccounts;

  @override
  Future<List<String>> accounts() async => phoneAccounts;

  /// What `accountToken` answers.
  AccountToken? token;
  int tokenCalls = 0;

  /// What the browser returns to, given the authorize URL; null = closed.
  Uri? Function(Uri authorize)? browserReturn;
  Uri? lastAuthorize;

  @override
  Future<Uri?> browserLogin(Uri url) async {
    lastAuthorize = url;
    return browserReturn?.call(url);
  }

  @override
  Future<String?> chooseAccount() async => null;

  @override
  Future<AccountToken> accountToken(String account) async {
    tokenCalls++;
    return token ?? const AccountToken(error: 'failed');
  }

  @override
  Future<String> deviceName() async => 'Test phone';

  /// What `userCertificates` answers.
  List<Uint8List> certificates = [];

  @override
  Future<List<Uint8List>> userCertificates() async => certificates;
}

/// [SessionStore] in memory.
class MemorySessionStore implements SessionStore {
  SavedLogin? login;
  BackupSettings? backup;
  final MemoryTokenStore _tokens = MemoryTokenStore();

  @override
  Future<SavedLogin?> readLogin() async => login;

  @override
  Future<void> writeLogin(SavedLogin l) async => login = l;

  @override
  Future<BackupSettings?> readBackup() async => backup;

  @override
  Future<void> writeBackup(BackupSettings b) async => backup = b;

  @override
  Future<void> clear() async {
    login = null;
    backup = null;
    await _tokens.clear();
  }

  @override
  TokenStore get tokens => _tokens;
}

/// The cloud's files in memory: folders, files, uploads in parts, grants,
/// the plugin's folders and index.
class FakeCloud extends RcClient {
  FakeCloud() : super(Uri.parse('http://fake/'), null) {
    nodes['root'] = _node('root', null, '', dir: true);
  }

  final Map<String, Node> nodes = {};
  final Map<String, Uint8List> content = {};
  final List<(String node, bool write)> grants = [];
  final List<String> deleted = [];
  int _next = 0;

  /// What [photoState] answers; null → `404 APP_NOT_FOUND`.
  List<PhotoFolder>? pluginFolders = [];

  /// SHA-256 of the photos in the gallery's index (one shard).
  Set<String> indexed = {};

  /// Called before a folder is made: lets a test make one "meanwhile".
  void Function(String parent, String name)? beforeCreate;

  /// Requests that send bytes (uploads, parts) before the network drops;
  /// null: it never does.
  int? networkFor;

  /// Answers of the next byte-sending requests, in order: an [ApiException]
  /// is thrown instead of doing it.
  final List<ApiException> failNext = [];

  /// The uploads in parts the server has: id → (folder, name, size, bytes).
  final Map<String, (String, String, int, BytesBuilder, bool)> uploads = {};
  int simpleUploads = 0;
  int parts = 0;

  static Node _node(
    String id,
    String? parent,
    String name, {
    bool dir = false,
    int size = 0,
    String? etag,
    DateTime? modified,
  }) => Node(
    id: id,
    parentId: parent,
    name: name,
    isDir: dir,
    size: size,
    mimeType: null,
    etag: etag,
    modifiedAt: modified,
    updatedAt: null,
  );

  Node add(String parent, String name, {bool dir = true, List<int>? bytes}) {
    final n = _node(
      'n${_next++}',
      parent,
      name,
      dir: dir,
      size: bytes?.length ?? 0,
      etag: bytes == null ? null : sha256.convert(bytes).toString(),
    );
    nodes[n.id] = n;
    if (bytes != null) content[n.id] = Uint8List.fromList(bytes);
    return n;
  }

  String pathOf(Node n) => n.parentId == 'root' || n.parentId == null
      ? n.name
      : '${pathOf(nodes[n.parentId]!)}/${n.name}';

  /// `Photos/Pixel/Camera` of the folders under the root.
  Set<String> paths() => {
    for (final n in nodes.values)
      if (n.id != 'root' && n.isDir) pathOf(n),
  };

  /// `Photos/Pixel/Camera/IMG_1.jpg` of the files.
  Set<String> files() => {
    for (final n in nodes.values)
      if (!n.isDir) pathOf(n),
  };

  Node? find(String path) => nodes.values
      .where((n) => n.id != 'root' && pathOf(n) == path)
      .firstOrNull;

  void _sending() {
    if (failNext.isNotEmpty) throw failNext.removeAt(0);
    final left = networkFor;
    if (left == null) return;
    if (left <= 0) throw const NetworkException('offline');
    networkFor = left - 1;
  }

  void _needFolder(String id) {
    if (nodes[id]?.isDir != true) {
      throw const ApiException(404, 'FILE_NOT_FOUND', '');
    }
  }

  Node _store(
    String folder,
    String name,
    Uint8List bytes,
    bool overwrite,
    int? mtime,
  ) {
    final there = nodes.values
        .where((n) => n.parentId == folder && n.name == name)
        .firstOrNull;
    if (there != null && !overwrite) {
      throw const ApiException(409, 'NAME_TAKEN', '');
    }
    final n = _node(
      there?.id ?? 'n${_next++}',
      folder,
      name,
      size: bytes.length,
      etag: sha256.convert(bytes).toString(),
      modified: mtime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(mtime * 1000, isUtc: true),
    );
    nodes[n.id] = n;
    content[n.id] = bytes;
    return n;
  }

  @override
  Future<Node> root() async => nodes['root']!;

  @override
  Future<List<Node>> children(String folderId) async {
    _needFolder(folderId);
    return nodes.values.where((n) => n.parentId == folderId).toList();
  }

  @override
  Future<Node> createFolder(String parentId, String name) async {
    _needFolder(parentId);
    beforeCreate?.call(parentId, name);
    if (nodes.values.any((n) => n.parentId == parentId && n.name == name)) {
      throw const ApiException(409, 'NAME_TAKEN', '');
    }
    return add(parentId, name);
  }

  @override
  Future<void> deleteFile(String id) async {
    if (nodes.remove(id) == null) {
      throw const ApiException(404, 'FILE_NOT_FOUND', '');
    }
    deleted.add(id);
  }

  /// Deletes a folder and everything in it, as the user would.
  void removeTree(String id) {
    for (final k in nodes.values.where((n) => n.parentId == id).toList()) {
      removeTree(k.id);
    }
    nodes.remove(id);
  }

  @override
  Future<void> grantToPlugin(String folderId, {bool write = true}) async {
    grants.add((folderId, write));
    pluginFolders = [
      ...?pluginFolders,
      PhotoFolder(id: folderId, name: nodes[folderId]!.name),
    ];
  }

  @override
  Future<PhotoState> photoState({DateTime? today}) async {
    final f = pluginFolders;
    if (f == null) throw const ApiException(404, 'APP_NOT_FOUND', '');
    return PhotoState.fromJson({
      'folders': [
        for (final x in f) {'id': x.id, 'name': x.name},
      ],
      'shards': shardLinks ?? ['index/00.json'],
    });
  }

  /// Links [photoState] gives; null: one, made of [indexed].
  List<String>? shardLinks;

  /// What a link gives; links not here give [indexed] as one shard.
  final Map<String, String> shardBodies = {};

  /// Links fetched, in order.
  final List<String> fetched = [];

  /// Links that answer `404` once (rewritten after the state was made).
  final Set<String> closedOnce = {};

  @override
  Future<String> fetchText(String link) async {
    fetched.add(link);
    if (closedOnce.remove(link)) {
      throw const ApiException(404, 'NOT_FOUND', '');
    }
    return shardBodies[link] ??
        jsonEncode([
          for (final (i, e) in indexed.indexed)
            {'id': 'e$i', 'name': 'e$i.jpg', 'etag': e, 'root': 'r'},
        ]);
  }

  @override
  Future<ShardResult> shard(String link, {String? etag}) async => ShardResult(
    etag: 'x',
    entries: [
      for (final (i, e) in indexed.indexed)
        Entry.fromJson({'id': 'e$i', 'name': 'e$i.jpg', 'etag': e}),
    ],
  );

  @override
  Future<Node> upload(
    String folderId,
    String name,
    Uint8List bytes, {
    int? mtime,
    bool overwrite = false,
  }) async {
    _sending();
    _needFolder(folderId);
    simpleUploads++;
    return _store(folderId, name, bytes, overwrite, mtime);
  }

  @override
  Future<UploadState> startUpload(
    String folderId, {
    required String name,
    required int size,
    int? mtime,
    bool overwrite = false,
  }) async {
    _sending();
    _needFolder(folderId);
    if (!overwrite &&
        nodes.values.any((n) => n.parentId == folderId && n.name == name)) {
      throw const ApiException(409, 'NAME_TAKEN', '');
    }
    final id = 'u${_next++}';
    uploads[id] = (folderId, name, size, BytesBuilder(), overwrite);
    return UploadState(id: id, size: size, received: 0);
  }

  @override
  Future<UploadState> uploadState(String id) async {
    final u = uploads[id];
    if (u == null) throw const ApiException(404, 'UPLOAD_NOT_FOUND', '');
    return UploadState(id: id, size: u.$3, received: u.$4.length);
  }

  @override
  Future<UploadState> uploadPart(String id, int offset, Uint8List bytes) async {
    _sending();
    final u = uploads[id];
    if (u == null) throw const ApiException(404, 'UPLOAD_NOT_FOUND', '');
    if (offset != u.$4.length) {
      throw ApiException(409, 'WRONG_OFFSET', '${u.$4.length}');
    }
    u.$4.add(bytes);
    parts++;
    return UploadState(id: id, size: u.$3, received: u.$4.length);
  }

  @override
  Future<Node> finishUpload(String id, String sha) async {
    final u = uploads[id];
    if (u == null) throw const ApiException(404, 'UPLOAD_NOT_FOUND', '');
    final bytes = u.$4.toBytes();
    if (bytes.length != u.$3) {
      throw const ApiException(409, 'UPLOAD_INCOMPLETE', '');
    }
    if (sha256.convert(bytes).toString() != sha) {
      uploads.remove(id);
      throw const ApiException(400, 'CHECKSUM_MISMATCH', '');
    }
    final n = _store(u.$1, u.$2, bytes, u.$5, null);
    uploads.remove(id);
    return n;
  }
}

/// The phone's photos, scripted: albums, and files with their bytes.
class FakeMedia implements PhoneMedia {
  FakeMedia({this.granted = MediaAccess.full, List<PhoneAlbum>? albums})
    : phoneAlbums =
          albums ??
          const [
            PhoneAlbum(
              id: 'b1',
              name: 'Camera',
              path: 'DCIM/Camera/',
              count: 120,
            ),
            PhoneAlbum(
              id: 'b2',
              name: 'Screenshots',
              path: 'Pictures/Screenshots/',
              count: 8,
            ),
            PhoneAlbum(
              id: 'b3',
              name: 'Telegram',
              path: 'Pictures/Telegram/',
              count: 30,
            ),
          ];

  MediaAccess granted;

  /// What the system dialog ends with.
  MediaAccess onRequest = MediaAccess.full;
  List<PhoneAlbum> phoneAlbums;
  int settingsOpened = 0;
  NetworkKind net = NetworkKind.unmetered;

  /// Files: MediaStore id → (item, bytes).
  final Map<int, (MediaItem, Uint8List)> files = {};
  int reads = 0;

  /// Adds a file of [size] bytes (made of its id) to [bucket].
  MediaItem addFile(
    int id,
    String name, {
    String bucket = 'b1',
    int size = 1000,
    String mime = 'image/jpeg',
    int taken = 1700000000000,
    List<int>? bytes,
  }) {
    final data = Uint8List.fromList(
      bytes ?? List.generate(size, (i) => (i * 31 + id) & 0xff),
    );
    final item = MediaItem(
      id: id,
      bucket: bucket,
      name: name,
      size: data.length,
      modified: 1700000000,
      taken: taken,
      mime: mime,
      uri: 'content://media/$id',
    );
    files[id] = (item, data);
    return item;
  }

  @override
  Future<MediaAccess> access() async => granted;

  @override
  Future<MediaAccess> requestAccess() async => granted = onRequest;

  @override
  Future<List<PhoneAlbum>> albums() async =>
      granted == MediaAccess.none ? throw StateError('no access') : phoneAlbums;

  @override
  Future<Uint8List?> thumbnail(String uri, {int size = 256}) async => null;

  @override
  Future<List<MediaItem>> items(List<String> buckets) async => [
    for (final f in files.values)
      if (buckets.contains(f.$1.bucket)) f.$1,
  ];

  @override
  Future<Uint8List> read(String uri, int offset, int length) async {
    reads++;
    final f = files.values.where((f) => f.$1.uri == uri).firstOrNull;
    if (f == null) throw StateError('no such file: $uri');
    final end = offset + length > f.$2.length ? f.$2.length : offset + length;
    return Uint8List.sublistView(f.$2, offset, end);
  }

  @override
  Future<NetworkKind> network() async => net;

  @override
  Future<String> phoneName() async => 'Redmi 10';

  @override
  Future<void> openSettings() async => settingsOpened++;
}

class FakeScheduler implements BackupScheduler {
  BackupSettings? applied;
  int syncs = 0;
  bool stopped = false;

  @override
  Future<void> apply(BackupSettings s) async => applied = s;

  @override
  Future<void> syncNow() async => syncs++;

  @override
  Future<void> stop() async => stopped = true;
}

BackupServices fakeServices({
  PhoneMedia? media,
  BackupScheduler? scheduler,
  BackupStore? store,
}) {
  final db = store ?? MemoryBackupStore();
  return BackupServices(
    media: media ?? FakeMedia(),
    scheduler: scheduler ?? FakeScheduler(),
    openStore: () async => db,
  );
}
