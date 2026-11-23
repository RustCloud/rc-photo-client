import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import '../api/models.dart';
import '../backup/phone_media.dart';
import '../gallery/timeline.dart';
import '../l10n/app_localizations.dart';
import 'phone_images.dart';
import 'timeline.dart' show MarkIcon, duration;

/// A photo or video on the whole screen; swipe for the next one, pinch or
/// double-tap to zoom, "i" for what is known about it.
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({
    super.key,
    required this.items,
    required this.initial,
    required this.media,
    this.albums = const {},
  });

  final List<TimelineItem> items;
  final int initial;
  final PhoneMedia media;

  /// Album (bucket) id → its name.
  final Map<String, String> albums;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  late final PageController _pages = PageController(
    initialPage: widget.initial,
  );
  late int _index = widget.initial;
  bool _chrome = true;
  bool _zoomed = false;

  @override
  void dispose() {
    _pages.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _toggleChrome() {
    setState(() => _chrome = !_chrome);
    SystemChrome.setEnabledSystemUIMode(
      _chrome ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final item = widget.items[_index];
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Theme(
      data: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Theme.of(context).colorScheme.primary,
        useMaterial3: true,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: _chrome
            ? AppBar(
                backgroundColor: Colors.black45,
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      DateFormat.yMMMd(locale).format(item.date),
                      style: const TextStyle(fontSize: 16),
                    ),
                    Text(
                      DateFormat.Hm(locale).format(item.date),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
                actions: [
                  if (item.mark != CloudMark.none)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Tooltip(
                        message: markText(l, item.mark),
                        child: MarkIcon(item.mark, size: 22),
                      ),
                    ),
                  IconButton(
                    key: const Key('info'),
                    tooltip: l.infoTitle,
                    icon: const Icon(Icons.info_outline),
                    onPressed: () => _showInfo(context, item),
                  ),
                ],
              )
            : null,
        body: PageView.builder(
          controller: _pages,
          physics: _zoomed
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          itemCount: widget.items.length,
          onPageChanged: (i) => setState(() {
            _index = i;
            _zoomed = false;
          }),
          itemBuilder: (context, i) {
            final it = widget.items[i];
            return it.media.video
                ? _VideoPage(
                    key: ValueKey(it.media.uri),
                    item: it.media,
                    media: widget.media,
                    current: i == _index,
                    onTap: _toggleChrome,
                  )
                : _PhotoPage(
                    key: ValueKey(it.media.uri),
                    item: it.media,
                    media: widget.media,
                    onTap: _toggleChrome,
                    onZoom: (z) {
                      if (z != _zoomed) setState(() => _zoomed = z);
                    },
                  );
          },
        ),
      ),
    );
  }

  void _showInfo(BuildContext context, TimelineItem item) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => InfoSheet(item: item, albums: widget.albums),
    );
  }
}

class _PhotoPage extends StatefulWidget {
  const _PhotoPage({
    super.key,
    required this.item,
    required this.media,
    required this.onTap,
    required this.onZoom,
  });

  final MediaItem item;
  final PhoneMedia media;
  final VoidCallback onTap;
  final ValueChanged<bool> onZoom;

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage>
    with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _zoomAnim;
  Offset _tapAt = Offset.zero;

  @override
  void initState() {
    super.initState();
    _zoomAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _transform.dispose();
    _zoomAnim.dispose();
    super.dispose();
  }

  void _zoomTo(Matrix4 to) {
    final from = Matrix4Tween(begin: _transform.value, end: to);
    final anim = _zoomAnim.drive(CurveTween(curve: Curves.easeOut));
    void step() => _transform.value = from.evaluate(anim);
    _zoomAnim
      ..removeListener(step)
      ..addListener(step)
      ..forward(from: 0);
    widget.onZoom(to.getMaxScaleOnAxis() > 1.01);
  }

  void _doubleTap() {
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      _zoomTo(Matrix4.identity());
    } else {
      const s = 2.5;
      _zoomTo(
        Matrix4.identity()
          ..translateByDouble(-_tapAt.dx * (s - 1), -_tapAt.dy * (s - 1), 0, 1)
          ..scaleByDouble(s, s, 1, 1),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.item;
    final thumb = PhoneThumb(widget.media, m.uri, size: 512);
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _tapAt = d.localPosition,
      onDoubleTap: _doubleTap,
      child: InteractiveViewer(
        transformationController: _transform,
        maxScale: 6,
        onInteractionEnd: (_) =>
            widget.onZoom(_transform.value.getMaxScaleOnAxis() > 1.01),
        child: SizedBox.expand(
          child: Image(
            image: PhoneFile(widget.media, m),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, sync) =>
                frame == null && !sync
                ? Image(
                    image: thumb,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  )
                : child,
            // A format Flutter can't decode (some HEIC, RAW): the phone's own
            // large thumbnail.
            errorBuilder: (_, _, _) => Image(
              image: PhoneThumb(widget.media, m.uri, size: 2048),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Center(
                child: Icon(Icons.broken_image_outlined, size: 64),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoPage extends StatefulWidget {
  const _VideoPage({
    super.key,
    required this.item,
    required this.media,
    required this.current,
    required this.onTap,
  });

  final MediaItem item;
  final PhoneMedia media;
  final bool current;
  final VoidCallback onTap;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  VideoPlayerController? _video;
  bool _failed = false;

  @override
  void didUpdateWidget(_VideoPage old) {
    super.didUpdateWidget(old);
    // Swiped away: stop, so two videos don't play at once.
    if (!widget.current) _video?.pause();
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    var v = _video;
    if (v == null) {
      v = VideoPlayerController.contentUri(Uri.parse(widget.item.uri));
      setState(() => _video = v);
      try {
        await v.initialize();
      } on Object {
        if (mounted) setState(() => _failed = true);
        return;
      }
      if (!mounted) return;
      setState(() {});
    }
    v.value.isPlaying ? await v.pause() : await v.play();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final v = _video;
    final ready = v != null && v.value.isInitialized;
    return GestureDetector(
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            Center(
              child: AspectRatio(
                aspectRatio: v.value.aspectRatio,
                child: VideoPlayer(v),
              ),
            )
          else
            Image(
              image: PhoneThumb(widget.media, widget.item.uri, size: 1024),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          if (_failed)
            Center(child: Text(l.videoFailed))
          else if (v == null || ready)
            Center(
              child: ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: v ?? _idle,
                builder: (context, value, _) => value.isPlaying
                    ? const SizedBox.shrink()
                    : IconButton.filledTonal(
                        key: const Key('play'),
                        iconSize: 48,
                        onPressed: _play,
                        icon: const Icon(Icons.play_arrow),
                      ),
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),
          if (ready)
            Positioned(
              left: 16,
              right: 16,
              bottom: 32,
              child: SafeArea(
                child: ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: v,
                  builder: (context, value, _) => Row(
                    children: [
                      IconButton(
                        onPressed: _play,
                        icon: Icon(
                          value.isPlaying ? Icons.pause : Icons.play_arrow,
                        ),
                      ),
                      Text(duration(value.position)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: VideoProgressIndicator(v, allowScrubbing: true),
                      ),
                      const SizedBox(width: 8),
                      Text(duration(value.duration)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static final _idle = ValueNotifier(VideoPlayerValue.uninitialized());
}

String markText(AppLocalizations l, CloudMark m) => switch (m) {
  CloudMark.synced => l.infoInCloud,
  CloudMark.uploading => l.infoUploading,
  CloudMark.failed => l.infoFailed,
  CloudMark.none => l.infoNotInCloud,
};

/// What is known about a photo: from the phone, and from the cloud's index
/// when the cloud has it (camera, exposure, place).
class InfoSheet extends StatelessWidget {
  const InfoSheet({super.key, required this.item, this.albums = const {}});

  final TimelineItem item;
  final Map<String, String> albums;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final m = item.media;
    final c = item.cloud;
    final when = DateFormat.yMMMMEEEEd(locale).add_Hm().format(item.date);
    final size = [
      if (m.width > 0 && m.height > 0) '${m.width} × ${m.height}',
      fileSize(m.size, locale),
      if (m.video && m.duration > 0)
        duration(Duration(milliseconds: m.duration)),
    ].join(' · ');
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(Icons.calendar_today_outlined),
              title: Text(when),
            ),
            ListTile(
              leading: Icon(
                m.video ? Icons.videocam_outlined : Icons.image_outlined,
              ),
              title: Text(m.name),
              subtitle: Text(size),
            ),
            if (albums[m.bucket] case final album?)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(album),
                subtitle: Text(l.infoOnPhone),
              ),
            if (c != null && cameraLine(c) != null)
              ListTile(
                leading: const Icon(Icons.camera_outlined),
                title: Text(cameraLine(c)!),
                subtitle: exposureLine(c, locale) == null
                    ? null
                    : Text(exposureLine(c, locale)!),
              ),
            if (c?.lat != null && c?.lon != null)
              ListTile(
                leading: const Icon(Icons.place_outlined),
                title: Text(
                  '${c!.lat!.toStringAsFixed(5)}, ${c.lon!.toStringAsFixed(5)}',
                ),
              ),
            ListTile(
              leading: item.mark == CloudMark.none
                  ? const Icon(Icons.cloud_queue)
                  : MarkIcon(
                      item.mark,
                      size: 24,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              title: Text(markText(l, item.mark)),
              subtitle: c == null
                  ? null
                  : Text(
                      [c.folder, c.name].where((s) => s.isNotEmpty).join('/'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Pixel 8 · 50mm F1.8 lens", or null when the cloud knows neither.
String? cameraLine(Entry c) {
  final parts = [
    c.camera,
    c.lens,
  ].whereType<String>().where((s) => s.isNotEmpty);
  return parts.isEmpty ? null : parts.join(' · ');
}

/// "ƒ/1.8 · 1/120 · ISO 100 · 26 mm".
String? exposureLine(Entry c, String locale) {
  final n = NumberFormat.decimalPattern(locale);
  final parts = [
    if (c.aperture != null) 'ƒ/${n.format(c.aperture)}',
    if (c.exposure != null && c.exposure!.isNotEmpty) c.exposure!,
    if (c.iso != null) 'ISO ${c.iso}',
    if (c.focal != null) '${n.format(c.focal)} mm',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// "3.2 MB".
String fileSize(int bytes, String locale) {
  final n = NumberFormat.decimalPatternDigits(locale: locale, decimalDigits: 1);
  if (bytes < 1024 * 1024) return '${n.format(bytes / 1024)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${n.format(bytes / 1024 / 1024)} MB';
  }
  return '${n.format(bytes / 1024 / 1024 / 1024)} GB';
}
