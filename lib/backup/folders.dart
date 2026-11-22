/// Makes the backup's folders in the cloud:
/// `<Photos folder>/<device>/<album>`. Plain Dart.
library;

import '../api/client.dart';
import '../api/models.dart';
import 'settings.dart';

class CloudFolders {
  CloudFolders(this.client);

  final RcClient client;

  /// A new folder for the gallery in the root ([name], or the one of that
  /// name already there), given to the Photos plugin with write access.
  Future<PhotoFolder> createRoot(String name) async {
    final root = await client.root();
    final folder = await _dir(root.id, folderName(name));
    await client.grantToPlugin(folder.id);
    return PhotoFolder(id: folder.id, name: folder.name);
  }

  /// Finds or makes the device's folder in the gallery's and an album's
  /// folder in it for every album chosen; the settings with their ids. Kept
  /// folders are found again by name, so a folder the user removed comes back.
  Future<BackupSettings> apply(BackupSettings s) async {
    final rootId = s.rootId;
    if (rootId == null) throw StateError('no gallery folder chosen');
    final device = await _dir(rootId, folderName(s.device));
    final albums = <BackupAlbum>[];
    for (final a in s.albums) {
      final f = await _dir(device.id, a.name);
      albums.add(
        BackupAlbum(bucketId: a.bucketId, name: f.name, folderId: f.id),
      );
    }
    return s.copyWith(
      device: device.name,
      deviceFolderId: device.id,
      albums: albums,
    );
  }

  /// The folder [name] in [parentId]: the one there, or a new one. A file of
  /// that name stays: then `name (2)`.
  Future<Node> _dir(String parentId, String name) async {
    var kids = await client.children(parentId);
    var n = 1;
    for (var attempt = 0; attempt < 50; attempt++) {
      final candidate = n == 1 ? name : '$name ($n)';
      final same = kids.where((k) => k.name == candidate);
      if (same.isNotEmpty) {
        if (same.first.isDir) return same.first;
        n++;
        continue;
      }
      try {
        return await client.createFolder(parentId, candidate);
      } on ApiException catch (e) {
        if (e.status != 409) rethrow;
        // Made meanwhile (another device, a second tap): look again.
        kids = await client.children(parentId);
      }
    }
    throw StateError('no free folder name for $name');
  }
}
