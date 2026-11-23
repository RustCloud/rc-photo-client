import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../backup/phone_media.dart';
import '../backup/settings.dart';
import '../backup/store.dart';
import 'cloud_index.dart';
import 'timeline.dart';

enum GalleryStatus {
  loading,

  /// No access to the phone's photos.
  noAccess,

  /// No albums chosen for the backup yet: the timeline shows those.
  noAlbums,
  ready,
}

/// The timeline's data: the phone's photos of the albums chosen for the
/// backup, their backup marks, and the cloud's metadata for them.
class GalleryController extends ChangeNotifier {
  GalleryController({
    required this.client,
    required this.media,
    required this.backupStore,
    required this.readSettings,
    required this.cloud,
    this.cloudEvery = const Duration(seconds: 30),
    this.marksEvery = const Duration(seconds: 3),
  });

  final RcClient client;
  final PhoneMedia media;
  final Future<BackupStore> backupStore;
  final Future<BackupSettings?> Function() readSettings;
  final CloudIndex cloud;

  /// The cloud's state is asked for at most this often (unless pulled).
  final Duration cloudEvery;

  /// How often the backup's progress is looked at while the app is open.
  final Duration marksEvery;

  GalleryStatus _status = GalleryStatus.loading;
  List<MediaItem> _media = const [];
  Map<int, MediaRow> _rows = const {};
  List<TimelineItem> _items = const [];
  Object? _cloudError;
  DateTime? _cloudAt;
  bool _cloudLoaded = false;
  Timer? _timer;
  bool _backupRunning = false;
  bool _disposed = false;

  Map<String, String> _albums = const {};

  GalleryStatus get status => _status;

  /// The chosen albums: bucket id → name.
  Map<String, String> get albums => _albums;
  List<TimelineItem> get items => _items;

  /// Why the cloud's metadata couldn't be fetched last time, if it couldn't.
  Object? get cloudError => _cloudError;

  /// The plugin's state (indexing progress, favourites…).
  PhotoState get cloudState => cloud.state;

  /// Reads the phone, then the cloud.
  Future<void> load() async {
    await refreshPhone();
    await refreshCloud();
  }

  Future<void> refreshPhone() async {
    final settings = await readSettings();
    final access = await this.media.access();
    if (access == MediaAccess.none) {
      _set(GalleryStatus.noAccess, const []);
      return;
    }
    _albums = {
      for (final a in settings?.albums ?? const <BackupAlbum>[])
        a.bucketId: a.name,
    };
    final buckets = _albums.keys.toList();
    if (buckets.isEmpty) {
      _set(GalleryStatus.noAlbums, const []);
      return;
    }
    final media = await this.media.items(buckets);
    _rows = await (await backupStore).all();
    if (!_cloudLoaded) {
      _cloudLoaded = true;
      try {
        await cloud.loadSaved();
      } on Object catch (e) {
        debugPrint('gallery: saved index unreadable: $e');
      }
    }
    _set(GalleryStatus.ready, media);
  }

  /// The plugin's state and changed shards; [force] for pull-to-refresh.
  Future<void> refreshCloud({bool force = false}) async {
    final at = _cloudAt;
    if (!force && at != null && DateTime.now().difference(at) < cloudEvery) {
      return;
    }
    _cloudAt = DateTime.now();
    try {
      await cloud.refresh(client, today: DateTime.now());
      _cloudError = null;
    } on Object catch (e) {
      _cloudError = e;
    }
    _rebuild();
  }

  /// Pull-to-refresh.
  Future<void> refresh() async {
    await refreshPhone();
    await refreshCloud(force: true);
  }

  Future<MediaAccess> requestAccess() async {
    final a = await media.requestAccess();
    await load();
    return a;
  }

  /// While the app is on screen: follows the backup's marks.
  void resume() {
    _timer?.cancel();
    _timer = Timer.periodic(marksEvery, (_) => _followBackup());
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _followBackup() async {
    if (_status != GalleryStatus.ready) return;
    final store = await backupStore;
    final running = (await store.status()).running;
    // Once more after it stopped, for the last file's mark.
    if (!running && !_backupRunning) return;
    _backupRunning = running;
    _rows = await store.all();
    _rebuild();
  }

  void _set(GalleryStatus s, List<MediaItem> media) {
    _status = s;
    _media = media;
    _rebuild();
  }

  void _rebuild() {
    if (_disposed) return;
    _items = buildTimeline(_media, _rows, cloud.byHash);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
