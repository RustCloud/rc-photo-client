import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import '../backup/phone_media.dart';
import '../gallery/controller.dart';
import '../gallery/people_stories.dart';
import '../l10n/app_localizations.dart';
import 'faces.dart';
import 'phone_images.dart';

/// A story's title, as the plugin's page makes it from its kind.
String storyTitle(
  AppLocalizations l,
  StoryView s,
  String locale,
  GalleryController gallery,
) {
  final p = s.story.params;
  DateTime? day(Object? v) => v is String ? DateTime.tryParse(v) : null;
  switch (s.story.kind) {
    case 'on-this-day':
      final years = (p['years'] as num?)?.toInt() ?? 1;
      return l.storyYearsAgo(years);
    case 'trip':
      final from = day(p['from']);
      return from == null
          ? l.stories
          : l.storyTrip(DateFormat.yMMMM(locale).format(from));
    case 'event':
      final d = day(p['date']);
      return d == null
          ? l.stories
          : _capital(DateFormat.yMMMMd(locale).format(d));
    case 'person':
      final raw = p['person'];
      if (raw is! String) return l.stories;
      final id = gallery.cloudState.personOf(raw);
      return l.storyPerson(personLabel(l, id, gallery.cloudState.names[id]));
    default:
      return l.stories;
  }
}

String _capital(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// The day's stories as circles above the timeline; unwatched ones ringed.
class StoriesRow extends StatelessWidget {
  const StoriesRow({
    super.key,
    required this.gallery,
    required this.media,
    required this.stories,
  });

  static const height = 132.0;

  final GalleryController gallery;
  final PhoneMedia media;
  final List<StoryView> stories;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return SizedBox(
      height: height,
      child: ListView.separated(
        key: const Key('stories'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        itemCount: stories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final s = stories[i];
          return GestureDetector(
            key: Key('story-${s.story.date}'),
            onTap: () => Navigator.of(context).push(
              PageRouteBuilder<void>(
                opaque: true,
                pageBuilder: (_, _, _) => StoryPlayer(
                  gallery: gallery,
                  media: media,
                  stories: stories,
                  initial: i,
                ),
                transitionsBuilder: (_, a, _, child) =>
                    FadeTransition(opacity: a, child: child),
              ),
            ),
            child: SizedBox(
              width: 76,
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        width: 2.5,
                        color: s.seen ? scheme.outlineVariant : scheme.primary,
                      ),
                    ),
                    child: ClipOval(
                      child: SizedBox.square(
                        dimension: 62,
                        child: Image(
                          image: PhoneThumb(
                            media,
                            s.cover.media.uri,
                            size: (62 * dpr).round(),
                          ),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) =>
                              ColoredBox(color: scheme.surfaceContainerHighest),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    storyTitle(l, s, locale, gallery),
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A story on the whole screen: photos one after another, each slowly
/// zooming to its face, video clips with their sound; tap the left side
/// for back, the right for next, hold to pause, swipe down to close. After
/// the last step the next story starts.
class StoryPlayer extends StatefulWidget {
  const StoryPlayer({
    super.key,
    required this.gallery,
    required this.media,
    required this.stories,
    required this.initial,
  });

  final GalleryController gallery;
  final PhoneMedia media;
  final List<StoryView> stories;
  final int initial;

  @override
  State<StoryPlayer> createState() => _StoryPlayerState();
}

class _StoryPlayerState extends State<StoryPlayer>
    with SingleTickerProviderStateMixin {
  late int _story = widget.initial;
  int _step = 0;
  late final AnimationController _clock;
  VideoPlayerController? _video;
  bool _held = false;
  double _drag = 0;

  StoryView get _s => widget.stories[_story];
  StoryStep get _st => _s.steps[_step];

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(vsync: this)
      ..addStatusListener((st) {
        if (st == AnimationStatus.completed) _next();
      });
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _start();
  }

  @override
  void dispose() {
    _clock.dispose();
    _video?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _start() async {
    // Not while the screen is being built (initState): a moment later.
    final story = _s.story;
    scheduleMicrotask(() => widget.gallery.storySeen(story));
    final step = _st;
    final old = _video;
    _video = null;
    unawaited(old?.dispose());
    _clock
      ..stop()
      ..duration = Duration(milliseconds: step.item.ms.clamp(1000, 15000))
      ..value = 0;
    if (!step.photo.media.video) {
      if (!_held) unawaited(_clock.forward());
      setState(() {});
      return;
    }
    final v = VideoPlayerController.contentUri(Uri.parse(step.photo.media.uri));
    setState(() => _video = v);
    try {
      await v.initialize();
      if (step.item.from case final from?) {
        await v.seekTo(Duration(milliseconds: from));
      }
    } on Object {
      // Can't be played here: shown as its thumbnail for its time.
    }
    if (!mounted || _video != v) return;
    if (!_held) {
      if (v.value.isInitialized) unawaited(v.play());
      unawaited(_clock.forward());
    }
    setState(() {});
  }

  void _next() {
    if (_step + 1 < _s.steps.length) {
      _step++;
    } else if (_story + 1 < widget.stories.length) {
      _story++;
      _step = 0;
    } else {
      Navigator.of(context).maybePop();
      return;
    }
    _start();
  }

  void _back() {
    if (_step > 0) {
      _step--;
    } else if (_story > 0) {
      _story--;
      _step = 0;
    }
    _start();
  }

  void _hold(bool on) {
    _held = on;
    if (on) {
      _clock.stop();
      _video?.pause();
    } else {
      _clock.forward();
      if (_video?.value.isInitialized ?? false) _video!.play();
    }
  }

  Future<void> _hide() async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await widget.gallery.hideStory(_s.story);
      messenger.showSnackBar(SnackBar(content: Text(l.storyHidden)));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
    await navigator.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final step = _st;
    final v = _video;
    final focus = step.item.focus ?? (0.5, 0.5);
    final align = Alignment(focus.$1 * 2 - 1, focus.$2 * 2 - 1);
    final Widget picture;
    if (v != null && v.value.isInitialized) {
      picture = FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: v.value.size.width,
          height: v.value.size.height,
          child: VideoPlayer(v),
        ),
      );
    } else {
      final thumb = PhoneThumb(widget.media, step.photo.media.uri, size: 1024);
      picture = AnimatedBuilder(
        animation: _clock,
        builder: (context, child) => Transform.scale(
          scale: 1 + 0.12 * Curves.easeOut.transform(_clock.value),
          alignment: align,
          child: child,
        ),
        child: Image(
          key: ValueKey(step.photo.media.uri),
          image: step.photo.media.video
              ? thumb
              : PhoneFile(widget.media, step.photo.media, maxSide: 2048),
          fit: BoxFit.cover,
          alignment: align,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, sync) => frame == null && !sync
              ? Image(
                  image: thumb,
                  fit: BoxFit.cover,
                  alignment: align,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
              : child,
          errorBuilder: (_, _, _) => Image(
            image: thumb,
            fit: BoxFit.cover,
            alignment: align,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      );
    }
    final date = DateFormat.yMMMMd(locale).format(step.photo.date);
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (d) {
          final w = MediaQuery.sizeOf(context).width;
          d.localPosition.dx < w / 3 ? _back() : _next();
        },
        onLongPressStart: (_) => _hold(true),
        onLongPressEnd: (_) => _hold(false),
        onVerticalDragUpdate: (d) => setState(
          () => _drag = (_drag + d.delta.dy).clamp(0, double.infinity),
        ),
        onVerticalDragEnd: (_) {
          if (_drag > 120) {
            Navigator.of(context).maybePop();
          } else {
            setState(() => _drag = 0);
          }
        },
        child: Transform.translate(
          offset: Offset(0, _drag),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRect(child: picture),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment(0, -0.4),
                    colors: [Colors.black54, Colors.transparent],
                  ),
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          for (var i = 0; i < _s.steps.length; i++)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                child: AnimatedBuilder(
                                  animation: _clock,
                                  builder: (context, _) =>
                                      LinearProgressIndicator(
                                        minHeight: 2.5,
                                        borderRadius: BorderRadius.circular(2),
                                        color: Colors.white,
                                        backgroundColor: Colors.white30,
                                        value: i < _step
                                            ? 1
                                            : i == _step
                                            ? _clock.value
                                            : 0,
                                      ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      Row(
                        children: [
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 8),
                                Text(
                                  storyTitle(l, _s, locale, widget.gallery),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  date,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuButton<String>(
                            key: const Key('story-menu'),
                            iconColor: Colors.white,
                            onOpened: () => _hold(true),
                            onCanceled: () => _hold(false),
                            onSelected: (_) => _hide(),
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'hide',
                                child: Text(l.storyHide),
                              ),
                            ],
                          ),
                          IconButton(
                            key: const Key('story-close'),
                            color: Colors.white,
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).closeButtonTooltip,
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
