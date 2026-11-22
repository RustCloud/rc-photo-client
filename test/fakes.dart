import 'dart:typed_data';

import 'package:rc_photo/api/auth.dart';
import 'package:rc_photo/api/client.dart';
import 'package:rc_photo/api/models.dart';
import 'package:rc_photo/backup/phone_media.dart';
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

/// The cloud's files in memory: folders, grants and the plugin's folders.
class FakeCloud extends RcClient {
  FakeCloud() : super(Uri.parse('http://fake/'), null) {
    nodes['root'] = _node('root', null, '', dir: true);
  }

  final Map<String, Node> nodes = {};
  final List<(String node, bool write)> grants = [];
  int _next = 0;

  /// What [photoState] answers; null → `404 APP_NOT_FOUND`.
  List<PhotoFolder>? pluginFolders = [];

  /// Called before a folder is made: lets a test make one "meanwhile".
  void Function(String parent, String name)? beforeCreate;

  static Node _node(
    String id,
    String? parent,
    String name, {
    bool dir = false,
  }) => Node(
    id: id,
    parentId: parent,
    name: name,
    isDir: dir,
    size: 0,
    mimeType: null,
    etag: null,
    modifiedAt: null,
    updatedAt: null,
  );

  Node add(String parent, String name, {bool dir = true}) {
    final n = _node('n${_next++}', parent, name, dir: dir);
    nodes[n.id] = n;
    return n;
  }

  /// `Photos/Pixel/Camera` of the folders under the root.
  Set<String> paths() {
    String path(Node n) => n.parentId == 'root' || n.parentId == null
        ? n.name
        : '${path(nodes[n.parentId]!)}/${n.name}';
    return {
      for (final n in nodes.values)
        if (n.id != 'root' && n.isDir) path(n),
    };
  }

  @override
  Future<Node> root() async => nodes['root']!;

  @override
  Future<List<Node>> children(String folderId) async =>
      nodes.values.where((n) => n.parentId == folderId).toList();

  @override
  Future<Node> createFolder(String parentId, String name) async {
    beforeCreate?.call(parentId, name);
    if (nodes.values.any((n) => n.parentId == parentId && n.name == name)) {
      throw const ApiException(409, 'NAME_TAKEN', '');
    }
    return add(parentId, name);
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
    });
  }
}

/// The phone's photos, scripted.
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
  Future<String> phoneName() async => 'Redmi 10';

  @override
  Future<void> openSettings() async => settingsOpened++;
}
