/// What the backup copies and where: phone albums into
/// `<Photos folder>/<device>/<album>` in the cloud. Plain Dart.
library;

/// A phone album chosen for backup and its folder in the cloud.
class BackupAlbum {
  const BackupAlbum({
    required this.bucketId,
    required this.name,
    this.folderId,
  });

  factory BackupAlbum.fromJson(Map<String, dynamic> j) => BackupAlbum(
    bucketId: j['bucket'] as String,
    name: j['name'] as String,
    folderId: j['folder'] as String?,
  );

  /// MediaStore's bucket id of the phone folder.
  final String bucketId;

  /// The cloud folder's name (the album's, made unique among the chosen).
  final String name;

  /// Null until the folder is made.
  final String? folderId;

  Map<String, dynamic> toJson() => {
    'bucket': bucketId,
    'name': name,
    'folder': ?folderId,
  };
}

class BackupSettings {
  const BackupSettings({
    this.rootId,
    this.rootName = '',
    this.device = '',
    this.deviceFolderId,
    this.albums = const [],
  });

  factory BackupSettings.fromJson(Map<String, dynamic> j) => BackupSettings(
    rootId: j['root'] as String?,
    rootName: j['rootName'] as String? ?? '',
    device: j['device'] as String? ?? '',
    deviceFolderId: j['deviceFolder'] as String?,
    albums: [
      for (final a in (j['albums'] as List<dynamic>? ?? const []))
        if (a is Map<String, dynamic>) BackupAlbum.fromJson(a),
    ],
  );

  /// A folder of the Photos plugin (`state.folders`); null until chosen.
  final String? rootId;
  final String rootName;

  /// The device's folder name inside it, `Redmi 10`.
  final String device;
  final String? deviceFolderId;
  final List<BackupAlbum> albums;

  /// The cloud folders exist for everything chosen.
  bool get ready =>
      rootId != null &&
      deviceFolderId != null &&
      albums.isNotEmpty &&
      albums.every((a) => a.folderId != null);

  BackupSettings copyWith({
    String? rootId,
    String? rootName,
    String? device,
    String? deviceFolderId,
    bool clearDeviceFolder = false,
    List<BackupAlbum>? albums,
  }) => BackupSettings(
    rootId: rootId ?? this.rootId,
    rootName: rootName ?? this.rootName,
    device: device ?? this.device,
    deviceFolderId: clearDeviceFolder
        ? null
        : deviceFolderId ?? this.deviceFolderId,
    albums: albums ?? this.albums,
  );

  Map<String, dynamic> toJson() => {
    'root': ?rootId,
    'rootName': rootName,
    'device': device,
    'deviceFolder': ?deviceFolderId,
    'albums': [for (final a in albums) a.toJson()],
  };
}

/// A name the server takes for a folder: no slashes, not `.`/`..`, trimmed.
String folderName(String s) {
  final t = s.replaceAll(RegExp(r'[/\\\x00-\x1f]'), ' ').trim();
  final one = t.replaceAll(RegExp(r'\s+'), ' ');
  if (one.isEmpty || one == '.' || one == '..') return '_';
  return one;
}

/// Cloud folder names for the albums chosen, in order: their own names,
/// `Camera (2)` when two albums are called the same.
List<String> uniqueNames(Iterable<String> names) {
  final used = <String>{};
  return [
    for (final n in names)
      () {
        final base = folderName(n);
        var name = base;
        for (var i = 2; used.contains(name.toLowerCase()); i++) {
          name = '$base ($i)';
        }
        used.add(name.toLowerCase());
        return name;
      }(),
  ];
}
