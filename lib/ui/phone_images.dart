import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../backup/phone_media.dart';

/// A thumbnail the phone makes of its own photo or video (MediaStore's,
/// cached by Android), about [size] px.
@immutable
class PhoneThumb extends ImageProvider<PhoneThumb> {
  const PhoneThumb(this.media, this.uri, {this.size = 256});

  final PhoneMedia media;
  final String uri;
  final int size;

  @override
  Future<PhoneThumb> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(PhoneThumb key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_load(decode));

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final bytes = await media.thumbnail(uri, size: size);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('no thumbnail for $uri');
    }
    final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    return ImageInfo(image: (await codec.getNextFrame()).image);
  }

  @override
  bool operator ==(Object other) =>
      other is PhoneThumb && other.uri == uri && other.size == size;

  @override
  int get hashCode => Object.hash(uri, size);
}

/// The phone's photo itself, for the viewer, decoded at most [maxSide] px
/// so a 50 MP photo doesn't take hundreds of MB.
@immutable
class PhoneFile extends ImageProvider<PhoneFile> {
  const PhoneFile(this.media, this.item, {this.maxSide = 4096});

  final PhoneMedia media;
  final MediaItem item;
  final int maxSide;

  @override
  Future<PhoneFile> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(PhoneFile key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_load(decode));

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    if (item.size <= 0) throw StateError('empty file ${item.uri}');
    final bytes = await media.read(item.uri, 0, item.size);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final codec = await decode(
      buffer,
      getTargetSize: (w, h) {
        final side = w > h ? w : h;
        if (side <= maxSide) return ui.TargetImageSize(width: w, height: h);
        return w >= h
            ? ui.TargetImageSize(width: maxSide)
            : ui.TargetImageSize(height: maxSide);
      },
    );
    return ImageInfo(image: (await codec.getNextFrame()).image);
  }

  @override
  bool operator ==(Object other) =>
      other is PhoneFile &&
      other.item.uri == item.uri &&
      other.item.modified == item.modified &&
      other.item.size == item.size;

  @override
  int get hashCode => Object.hash(item.uri, item.modified, item.size);
}
