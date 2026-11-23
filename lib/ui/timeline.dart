import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../backup/phone_media.dart';
import '../gallery/timeline.dart';
import '../l10n/app_localizations.dart';
import 'phone_images.dart';

/// The timeline grid: tiles in groups by day (by month when small), pinch to
/// change the number of columns, a handle on the right to jump through the
/// years, and on each tile its backup mark.
class TimelineGrid extends StatefulWidget {
  const TimelineGrid({
    super.key,
    required this.items,
    required this.media,
    required this.onOpen,
    required this.onRefresh,
    this.header,
    this.top,
    this.topHeight = 0,
  });

  final List<TimelineItem> items;
  final PhoneMedia media;
  final void Function(int index) onOpen;
  final Future<void> Function() onRefresh;

  /// Shown above the grid (the cloud's progress or problem).
  final Widget? header;

  /// Scrolls with the grid, above its first group (the stories), and is
  /// [topHeight] high.
  final Widget? top;
  final double topHeight;

  /// The numbers of columns a pinch goes through.
  static const columnSteps = [3, 5, 7];

  @override
  State<TimelineGrid> createState() => _TimelineGridState();
}

class _TimelineGridState extends State<TimelineGrid> {
  final _scroll = ScrollController();
  int _columns = 3;
  TimelineLayout? _layout;
  List<TimelineItem>? _laidOut;
  double _laidWidth = 0;
  int _laidColumns = 0;

  // Pinch: two fingers apart → bigger tiles, together → smaller.
  final Map<int, Offset> _fingers = {};
  double? _pinchFrom;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  double get _top => widget.top == null ? 0 : widget.topHeight;

  TimelineLayout _layoutFor(double width) {
    if (_layout == null ||
        !identical(_laidOut, widget.items) ||
        _laidWidth != width ||
        _laidColumns != _columns) {
      _layout = TimelineLayout.of(
        widget.items,
        columns: _columns,
        width: width,
      );
      _laidOut = widget.items;
      _laidWidth = width;
      _laidColumns = _columns;
    }
    return _layout!;
  }

  void _setColumns(int columns) {
    final layout = _layout;
    if (columns == _columns || layout == null) return;
    // The photo at the top stays at the top.
    final first = _scroll.hasClients ? layout.itemAt(_scroll.offset - _top) : 0;
    setState(() => _columns = columns);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final now = _layout;
      if (now == null || !_scroll.hasClients || now.rows.isEmpty) return;
      final row = now.rows[now.rowOf(first)];
      _scroll.jumpTo(
        (row.offset + _top)
            .clamp(0.0, _scroll.position.maxScrollExtent)
            .toDouble(),
      );
    });
  }

  void _step(int by) {
    const steps = TimelineGrid.columnSteps;
    final i = steps.indexOf(_columns);
    final next = (i < 0 ? 0 : i + by).clamp(0, steps.length - 1);
    _setColumns(steps[next]);
  }

  double _spread() {
    final p = _fingers.values.toList();
    return (p[0] - p[1]).distance;
  }

  void _down(PointerDownEvent e) {
    _fingers[e.pointer] = e.position;
    if (_fingers.length == 2) _pinchFrom = _spread();
  }

  void _move(PointerMoveEvent e) {
    if (!_fingers.containsKey(e.pointer)) return;
    _fingers[e.pointer] = e.position;
    final from = _pinchFrom;
    if (_fingers.length != 2 || from == null || from < 1) return;
    final ratio = _spread() / from;
    if (ratio > 1.3) {
      _step(-1);
      _pinchFrom = _spread();
    } else if (ratio < 0.77) {
      _step(1);
      _pinchFrom = _spread();
    }
  }

  void _up(PointerEvent e) {
    _fingers.remove(e.pointer);
    if (_fingers.length < 2) _pinchFrom = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final layout = _layoutFor(box.maxWidth);
        final dpr = MediaQuery.devicePixelRatioOf(context);
        // The phone makes thumbnails in a few fixed sizes; ask for one near
        // the tile.
        final thumbPx = math.max(96, (layout.tile * dpr).round());
        final header = widget.header;
        final top = widget.top;
        final grid = Listener(
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: RefreshIndicator(
            onRefresh: widget.onRefresh,
            child: ListView.builder(
              key: const Key('timeline'),
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: layout.rows.length + (top == null ? 0 : 1),
              itemExtentBuilder: (i, _) {
                if (top != null) {
                  if (i == 0) return _top;
                  i--;
                }
                return i < layout.rows.length
                    ? layout.heightOf(layout.rows[i])
                    : 0;
              },
              itemBuilder: (context, i) {
                if (top != null) {
                  if (i == 0) return top;
                  i--;
                }
                final row = layout.rows[i];
                if (row.isHeader) {
                  return _GroupHeader(date: row.date, by: layout.groupBy);
                }
                return Row(
                  children: [
                    for (var k = 0; k < layout.columns; k++)
                      SizedBox(
                        width: layout.tile,
                        height: layout.tile,
                        child: k < row.count
                            ? _Tile(
                                item: widget.items[row.start + k],
                                media: widget.media,
                                thumbPx: thumbPx,
                                small: layout.columns >= 5,
                                onTap: () => widget.onOpen(row.start + k),
                              )
                            : null,
                      ),
                  ],
                );
              },
            ),
          ),
        );
        return Column(
          children: [
            ?header,
            Expanded(
              child: _Scroller(
                controller: _scroll,
                layout: layout,
                top: _top,
                child: grid,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.date, required this.by});

  final DateTime date;
  final GroupBy by;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Text(
          by == GroupBy.month
              ? monthTitle(date, locale)
              : dayTitle(l, date, locale, DateTime.now()),
          style: theme.textTheme.titleSmall,
        ),
      ),
    );
  }
}

/// "Today", "Yesterday", "Sat, 17 May", "Sat, 17 May 2025".
String dayTitle(AppLocalizations l, DateTime d, String locale, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final ago = today.difference(day).inDays;
  if (ago == 0) return l.today;
  if (ago == 1) return l.yesterday;
  final f = d.year == now.year
      ? DateFormat.MMMEd(locale)
      : DateFormat.yMMMEd(locale);
  return _capital(f.format(d));
}

/// "May 2026".
String monthTitle(DateTime d, String locale) =>
    _capital(DateFormat.yMMMM(locale).format(d));

String _capital(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

class _Tile extends StatelessWidget {
  const _Tile({
    required this.item,
    required this.media,
    required this.thumbPx,
    required this.small,
    required this.onTap,
  });

  final TimelineItem item;
  final PhoneMedia media;
  final int thumbPx;
  final bool small;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = item.media;
    return Padding(
      padding: const EdgeInsets.all(1),
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: scheme.surfaceContainerHighest),
            Image(
              image: PhoneThumb(media, m.uri, size: thumbPx),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => Icon(
                m.video ? Icons.videocam_outlined : Icons.broken_image_outlined,
                color: scheme.outline,
              ),
            ),
            if (m.video)
              Positioned(
                right: 4,
                bottom: 2,
                child: small
                    ? const Icon(
                        Icons.play_arrow,
                        size: 14,
                        color: Colors.white,
                        shadows: _shadow,
                      )
                    : Text(
                        duration(Duration(milliseconds: m.duration)),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          shadows: _shadow,
                        ),
                      ),
              ),
            if (item.mark != CloudMark.none)
              Positioned(
                right: 3,
                top: 3,
                child: MarkIcon(item.mark, size: small ? 12 : 16),
              ),
          ],
        ),
      ),
    );
  }
}

const _shadow = [Shadow(blurRadius: 3, color: Colors.black54)];

/// The backup mark: a cloud — in the cloud; arrows in a circle — being
/// copied; a crossed-out cloud — copying failed.
class MarkIcon extends StatelessWidget {
  const MarkIcon(this.mark, {super.key, this.size = 16, this.color});

  final CloudMark mark;
  final double size;
  final Color? color;

  static IconData? iconOf(CloudMark m) => switch (m) {
    CloudMark.synced => Icons.cloud_done,
    CloudMark.uploading => Icons.sync,
    CloudMark.failed => Icons.cloud_off,
    CloudMark.none => null,
  };

  @override
  Widget build(BuildContext context) {
    final icon = iconOf(mark);
    if (icon == null) return const SizedBox.shrink();
    return Icon(
      icon,
      key: Key('mark-${mark.name}'),
      size: size,
      color:
          color ??
          (mark == CloudMark.failed ? const Color(0xFFFF8A80) : Colors.white),
      shadows: _shadow,
    );
  }
}

/// `1:05`, `1:02:03`.
String duration(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// A handle on the right that appears while scrolling: drag it to go through
/// months and years fast, with the month shown beside it.
class _Scroller extends StatefulWidget {
  const _Scroller({
    required this.controller,
    required this.layout,
    required this.child,
    this.top = 0,
  });

  final ScrollController controller;
  final TimelineLayout layout;

  /// Height above the layout's first row.
  final double top;
  final Widget child;

  @override
  State<_Scroller> createState() => _ScrollerState();
}

class _ScrollerState extends State<_Scroller> {
  static const _handle = 48.0;

  bool _shown = false;
  bool _dragging = false;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification || n is ScrollStartNotification) {
      if (!_shown) setState(() => _shown = true);
      _hide?.cancel();
      _hide = Timer(const Duration(milliseconds: 1500), () {
        if (mounted && !_dragging) setState(() => _shown = false);
      });
    }
    return false;
  }

  /// The handle's top while dragged.
  double _dragTop = 0;

  void _drag(double top, double height) {
    final c = widget.controller;
    if (!c.hasClients || height <= _handle) return;
    final f = (top / (height - _handle)).clamp(0.0, 1.0);
    c.jumpTo(f * c.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    return LayoutBuilder(
      builder: (context, box) {
        final height = box.maxHeight;
        // Worth it only past a few screens.
        final useful = widget.layout.extent > height * 4;
        return NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: Stack(
            children: [
              widget.child,
              if (useful && (_shown || _dragging))
                AnimatedBuilder(
                  animation: widget.controller,
                  builder: (context, _) {
                    final c = widget.controller;
                    if (!c.hasClients || c.position.maxScrollExtent <= 0) {
                      return const SizedBox.shrink();
                    }
                    final f = (c.offset / c.position.maxScrollExtent).clamp(
                      0.0,
                      1.0,
                    );
                    final top = f * (height - _handle);
                    final rows = widget.layout.rows;
                    final row = rows.isEmpty
                        ? null
                        : rows[widget.layout.rowAt(c.offset - widget.top)];
                    return Positioned(
                      right: 0,
                      top: top,
                      child: Row(
                        children: [
                          if (_dragging && row != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                monthTitle(row.date, locale),
                                style: TextStyle(
                                  color: scheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                          GestureDetector(
                            key: const Key('scroller'),
                            onVerticalDragStart: (d) {
                              _hide?.cancel();
                              _dragTop = top;
                              setState(() => _dragging = true);
                            },
                            onVerticalDragUpdate: (d) {
                              _dragTop += d.delta.dy;
                              _drag(_dragTop, height);
                            },
                            onVerticalDragEnd: (_) {
                              setState(() => _dragging = false);
                              _onScroll(
                                ScrollUpdateNotification(
                                  metrics: widget.controller.position,
                                  context: context,
                                ),
                              );
                            },
                            child: Container(
                              width: 36,
                              height: _handle,
                              margin: const EdgeInsets.only(left: 8),
                              decoration: BoxDecoration(
                                color: scheme.secondaryContainer,
                                borderRadius: const BorderRadius.horizontal(
                                  left: Radius.circular(24),
                                ),
                              ),
                              child: Icon(
                                Icons.unfold_more,
                                color: scheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}
