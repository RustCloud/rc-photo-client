import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../backup/phone_media.dart';
import '../gallery/people_stories.dart';
import '../l10n/app_localizations.dart';
import 'phone_images.dart';

/// A person's name, or "Person 4" by the plugin's number (`p3`; `m0` for
/// people made by hand).
String personLabel(AppLocalizations l, String id, String? name) {
  if (name != null && name.isNotEmpty) return name;
  final n = int.tryParse(id.substring(1));
  if (n == null) return id;
  return id.startsWith('m') ? l.personN('M${n + 1}') : l.personN('${n + 1}');
}

/// A round face: the box the plugin found, cut out of the phone's thumbnail
/// of the photo. Without a box, the photo's middle.
class FaceAvatar extends StatelessWidget {
  const FaceAvatar({
    super.key,
    required this.person,
    required this.media,
    this.size = 72,
  });

  final PersonView person;
  final PhoneMedia media;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = person.faceItem ?? person.items.first;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(Icons.person, size: size * 0.6, color: scheme.outline),
    );
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: _cut(item.media, item.cloud, person.face, dpr, placeholder),
      ),
    );
  }

  Widget _cut(
    MediaItem m,
    Entry? cloud,
    FaceBox? face,
    double dpr,
    Widget placeholder,
  ) {
    var w = m.width.toDouble(), h = m.height.toDouble();
    if ((w <= 0 || h <= 0) && cloud != null) {
      w = cloud.width.toDouble();
      h = cloud.height.toDouble();
    }
    if (face == null || w <= 0 || h <= 0) {
      return Image(
        image: PhoneThumb(media, m.uri, size: (size * dpr).round()),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      );
    }
    // A square around the face, a little larger than it.
    final side = math.max(face.w * w, face.h * h) * 1.5;
    final k = size / side;
    final cx = (face.x + face.w / 2) * w;
    final cy = (face.y + face.h / 2) * h;
    // The thumbnail must be sharp at the face's size.
    final px = math.min(
      1024,
      math.max(256, (math.max(w, h) * k * dpr).round()),
    );
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned.fill(child: placeholder),
        Positioned(
          left: -(cx - side / 2) * k,
          top: -(cy - side / 2) * k,
          width: w * k,
          height: h * k,
          child: Image(
            image: PhoneThumb(media, m.uri, size: px),
            fit: BoxFit.fill,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}
