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

/// The native side (PhoneMedia.kt); an interface for tests.
abstract class PhoneMedia {
  Future<MediaAccess> access();
  Future<MediaAccess> requestAccess();
  Future<List<PhoneAlbum>> albums();
  Future<Uint8List?> thumbnail(String uri, {int size = 256});

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
  Future<String> phoneName() async =>
      (await _ch.invokeMethod<String>('phoneName')) ?? 'Android';

  @override
  Future<void> openSettings() => _ch.invokeMethod<void>('openSettings');
}
