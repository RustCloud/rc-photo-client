import 'package:flutter/foundation.dart';

import '../api/auth.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../auth/session_store.dart';
import 'folders.dart';
import 'phone_media.dart';
import 'services.dart';
import 'settings.dart';
import 'store.dart';

/// Why the backup's screen can't do what was asked.
enum BackupProblem {
  network,
  untrustedCertificate,

  /// The Photos plugin is not on the server.
  noPlugin,
  failed,
}

/// The backup's screen: which phone albums go to which cloud folders.
///
/// The cloud side is `<Photos folder>/<device>/<album>`: a folder the user
/// gave the Photos plugin (it indexes the folders inside), the device's
/// folder (the phone's name, can be changed), and one folder per album
/// chosen, called like the album.
class BackupController extends ChangeNotifier {
  BackupController({
    required this.client,
    required this.services,
    required this.store,
  });

  final RcClient client;
  final BackupServices services;
  final SessionStore store;

  PhoneMedia get media => services.media;

  /// Files by state, from the backup's store.
  Counts counts = const {};

  bool loading = true;
  bool saving = false;
  MediaAccess access = MediaAccess.none;
  List<PhoneAlbum> albums = const [];

  /// The Photos plugin's folders; empty if the user gave it none yet.
  List<PhotoFolder> folders = const [];
  BackupSettings saved = const BackupSettings();

  PhotoFolder? root;
  String device = '';
  final Set<String> chosen = {};

  BackupProblem? problem;
  String problemDetail = '';

  /// Something changed since the last save.
  bool get dirty {
    final names = saved.albums.map((a) => a.bucketId).toSet();
    return root?.id != saved.rootId ||
        device != saved.device ||
        !setEquals(names, chosen) ||
        !saved.ready;
  }

  bool get canSave =>
      !loading && !saving && root != null && chosen.isNotEmpty && dirty;

  Future<void> load() async {
    loading = true;
    problem = null;
    notifyListeners();
    try {
      saved = await store.readBackup() ?? const BackupSettings();
      device = saved.device.isNotEmpty
          ? saved.device
          : folderName(await media.phoneName());
      chosen
        ..clear()
        ..addAll(saved.albums.map((a) => a.bucketId));
      await _readPhone();
      if (saved.albums.isEmpty) {
        chosen.addAll(albums.where((a) => a.isCamera).map((a) => a.id));
      }
      await _readFolders();
      await readCounts();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _readPhone() async {
    access = await media.access();
    albums = access == MediaAccess.none ? const [] : await media.albums();
  }

  Future<void> _readFolders() async {
    try {
      final state = await client.photoState();
      folders = state.folders;
      root =
          folders.where((f) => f.id == saved.rootId).firstOrNull ??
          (folders.isEmpty ? null : folders.first);
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object e) {
    switch (e) {
      case ApiException(status: 404, code: 'APP_NOT_FOUND'):
        problem = BackupProblem.noPlugin;
      case NetworkException(untrustedCertificate: true):
        problem = BackupProblem.untrustedCertificate;
      case NetworkException():
        problem = BackupProblem.network;
      case ApiException(:final status, :final code, :final message):
        problem = BackupProblem.failed;
        problemDetail = message.isEmpty ? '$status $code' : message;
      default:
        problem = BackupProblem.failed;
        problemDetail = '$e';
    }
  }

  Future<void> readCounts() async {
    try {
      counts = await (await services.store).counts();
    } catch (_) {
      counts = const {};
    }
  }

  /// Changes a condition (Wi-Fi, charging, deleting, on/off): kept and
  /// applied at once, no folders to make.
  Future<void> setOptions(
    BackupSettings Function(BackupSettings) change,
  ) async {
    saved = change(saved);
    notifyListeners();
    await store.writeBackup(saved);
    await services.scheduler.apply(saved);
  }

  Future<void> syncNow() => services.scheduler.syncNow();

  /// Asks Android for the photos; false if it said no (then only the
  /// system settings can change it).
  Future<bool> requestAccess() async {
    access = await media.requestAccess();
    if (access != MediaAccess.none) {
      albums = await media.albums();
      if (chosen.isEmpty && saved.albums.isEmpty) {
        chosen.addAll(albums.where((a) => a.isCamera).map((a) => a.id));
      }
    }
    notifyListeners();
    return access != MediaAccess.none;
  }

  /// After the system settings: the access may have changed.
  Future<void> refreshPhone() async {
    await _readPhone();
    notifyListeners();
  }

  void toggle(String bucketId) {
    if (!chosen.remove(bucketId)) chosen.add(bucketId);
    notifyListeners();
  }

  void setDevice(String name) {
    device = folderName(name);
    notifyListeners();
  }

  void setRoot(PhotoFolder f) {
    root = f;
    notifyListeners();
  }

  /// Makes a new gallery folder in the cloud and gives it to the plugin.
  Future<void> createRoot(String name) async {
    saving = true;
    problem = null;
    notifyListeners();
    try {
      final f = await CloudFolders(client).createRoot(name);
      folders = [...folders.where((x) => x.id != f.id), f];
      root = f;
    } catch (e) {
      _fail(e);
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  /// Makes the cloud folders for the choice and keeps it; true on success.
  Future<bool> save() async {
    final r = root;
    if (r == null) return false;
    saving = true;
    problem = null;
    notifyListeners();
    try {
      final settings = saved.copyWith(
        rootId: r.id,
        rootName: r.name,
        device: device,
        albums: _albumNames(),
      );
      saved = await CloudFolders(client).apply(settings);
      device = saved.device;
      await store.writeBackup(saved);
      await services.scheduler.apply(saved);
      if (saved.enabled) await services.scheduler.syncNow();
      return true;
    } catch (e) {
      _fail(e);
      return false;
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  /// The chosen albums with their cloud names: kept ones keep theirs (the
  /// folder is already there), new ones get the album's, unique among all.
  List<BackupAlbum> _albumNames() {
    final kept = {for (final a in saved.albums) a.bucketId: a.name};
    final byId = {for (final a in albums) a.id: a};
    // Phone order, then the chosen albums no longer on the phone.
    final ids = [
      ...albums.map((a) => a.id).where(chosen.contains),
      ...chosen.where((id) => !byId.containsKey(id)),
    ];
    final keptIds = ids.where(kept.containsKey).toList();
    final newIds = ids.where((id) => !kept.containsKey(id)).toList();
    final names = uniqueNames([
      for (final id in keptIds) kept[id]!,
      for (final id in newIds) byId[id]?.name ?? id,
    ]);
    final nameOf = {
      for (var i = 0; i < keptIds.length; i++) keptIds[i]: names[i],
      for (var i = 0; i < newIds.length; i++)
        newIds[i]: names[keptIds.length + i],
    };
    return [for (final id in ids) BackupAlbum(bucketId: id, name: nameOf[id]!)];
  }

  /// `Photos/Redmi 10/Camera`: where an album goes.
  String cloudPath(String bucketId) {
    final a = saved.albums.where((a) => a.bucketId == bucketId).firstOrNull;
    final album =
        a?.name ??
        albums.where((x) => x.id == bucketId).firstOrNull?.name ??
        bucketId;
    return '${root?.name ?? '…'}/$device/$album';
  }
}
