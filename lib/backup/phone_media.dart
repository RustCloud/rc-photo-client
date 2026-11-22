import 'package:flutter/services.dart';

/// What the app may read of the phone's photos.
enum MediaAccess {
  full,

  /// Android 14+: only the photos the user picked in the system dialog.
  partial,
  none,
}

/// A folder of photos or videos on the phone (a MediaStore bucket).
class PhoneAlbum {
  const PhoneAlbum({
    required this.id,
    required this.name,
    required this.path,
    required this.count,
    this.cover,
  });

  factory PhoneAlbum.fromMap(Map<Object?, Object?> m) => PhoneAlbum(
    id: m['id'] as String,
    name: m['name'] as String? ?? '',
    path: m['path'] as String? ?? '',
    count: (m['count'] as num?)?.toInt() ?? 0,
    cover: m['cover'] as String?,
  );

  /// MediaStore's bucket id: stays while the folder keeps its path.
  final String id;
  final String name;

  /// `DCIM/Camera/`; empty before Android 10.
  final String path;
  final int count;

  /// The content URI of the newest item.
  final String? cover;

  /// The camera's folder, chosen until the user chooses otherwise.
  bool get isCamera {
    final p = path.toLowerCase();
    return p == 'dcim/camera/' || (p.isEmpty && name.toLowerCase() == 'camera');
  }
}

/// A photo or video on the phone, as MediaStore has it.
class MediaItem {
  const MediaItem({
    required this.id,
    required this.bucket,
    required this.name,
    required this.size,
    required this.modified,
    required this.taken,
    required this.mime,
    required this.uri,
  });

  factory MediaItem.fromMap(Map<Object?, Object?> m) => MediaItem(
    id: (m['id'] as num).toInt(),
    bucket: m['bucket'] as String? ?? '',
    name: m['name'] as String? ?? '',
    size: (m['size'] as num?)?.toInt() ?? 0,
    modified: (m['modified'] as num?)?.toInt() ?? 0,
    taken: (m['taken'] as num?)?.toInt() ?? 0,
    mime: m['mime'] as String? ?? '',
    uri: m['uri'] as String? ?? '',
  );

  /// MediaStore's id.
  final int id;
  final String bucket;
  final String name;
  final int size;

  /// When the file changed, seconds.
  final int modified;

  /// When it was taken, ms; 0 if unknown.
  final int taken;
  final String mime;
  final String uri;
}

enum NetworkKind {
  /// Wi-Fi and the like.
  unmetered,

  /// Mobile data.
  metered,
  none,
}

/// The native side (PhoneMedia.kt); an interface for tests.
abstract class PhoneMedia {
  Future<MediaAccess> access();
  Future<MediaAccess> requestAccess();
  Future<List<PhoneAlbum>> albums();
  Future<Uint8List?> thumbnail(String uri, {int size = 256});

  /// The photos and videos in those albums (bucket ids).
  Future<List<MediaItem>> items(List<String> buckets);

  /// [length] bytes of an item from [offset]; fewer at its end.
  Future<Uint8List> read(String uri, int offset, int length);

  Future<NetworkKind> network();

  /// The name the user gave the phone, else its model: the cloud folder.
  Future<String> phoneName();
  Future<void> openSettings();
}

class AndroidPhoneMedia implements PhoneMedia {
  const AndroidPhoneMedia();

  static const _ch = MethodChannel('com.rustcloud.photos/media');

  static MediaAccess _access(String? s) => switch (s) {
    'full' => MediaAccess.full,
    'partial' => MediaAccess.partial,
    _ => MediaAccess.none,
  };

  @override
  Future<MediaAccess> access() async =>
      _access(await _ch.invokeMethod<String>('access'));

  @override
  Future<MediaAccess> requestAccess() async =>
      _access(await _ch.invokeMethod<String>('requestAccess'));

  @override
  Future<List<PhoneAlbum>> albums() async =>
      ((await _ch.invokeListMethod<Map<Object?, Object?>>('albums')) ??
              const [])
          .map(PhoneAlbum.fromMap)
          .toList();

  @override
  Future<Uint8List?> thumbnail(String uri, {int size = 256}) =>
      _ch.invokeMethod<Uint8List>('thumbnail', {'uri': uri, 'size': size});

  @override
  Future<List<MediaItem>> items(List<String> buckets) async =>
      ((await _ch.invokeListMethod<Map<Object?, Object?>>('items', {
                'buckets': buckets,
              })) ??
              const [])
          .map(MediaItem.fromMap)
          .toList();

  @override
  Future<Uint8List> read(String uri, int offset, int length) async =>
      (await _ch.invokeMethod<Uint8List>('read', {
        'uri': uri,
        'offset': offset,
        'length': length,
      }))!;

  @override
  Future<NetworkKind> network() async =>
      switch (await _ch.invokeMethod<String>('network')) {
        'unmetered' => NetworkKind.unmetered,
        'metered' => NetworkKind.metered,
        _ => NetworkKind.none,
      };

  @override
  Future<String> phoneName() async =>
      (await _ch.invokeMethod<String>('phoneName')) ?? 'Android';

  @override
  Future<void> openSettings() => _ch.invokeMethod<void>('openSettings');
}
