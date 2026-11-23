import '../api/models.dart';
import 'timeline.dart';

/// A person as the app shows them: the plugin's grouping with the user's
/// merges and names, and only their photos that are on this phone.
class PersonView {
  const PersonView({
    required this.id,
    required this.name,
    required this.items,
    this.face,
    this.faceItem,
  });

  final String id;

  /// The user's name for them; null if none yet.
  final String? name;

  /// Their photos on the phone, newest first.
  final List<TimelineItem> items;

  /// The face to show, cut out of [faceItem]; null: [items] first, whole.
  final FaceBox? face;
  final TimelineItem? faceItem;
}

/// People with photos on the phone, the most first. Hidden people are left
/// out; merged ones are put together, as the plugin's page does.
List<PersonView> peopleOnPhone(
  List<Person> people,
  PhotoState state,
  Map<String, TimelineItem> byCloudId,
  List<TimelineItem> timeline,
) {
  final order = {for (final (i, t) in timeline.indexed) t.media.id: i};
  final files = <String, Set<String>>{};
  final covers = <String, FaceBox>{};
  for (final p in people) {
    final id = state.personOf(p.id);
    (files[id] ??= {}).addAll(p.files);
    // The person's own face over one of someone merged into them.
    if (p.cover != null && (id == p.id || !covers.containsKey(id))) {
      covers[id] = p.cover!;
    }
  }
  final out = <PersonView>[];
  for (final MapEntry(key: id, value: ids) in files.entries) {
    if (state.hiddenPeople.contains(id)) continue;
    final items = <TimelineItem>[];
    final added = <int>{};
    for (final f in ids) {
      final t = byCloudId[f];
      if (t != null && added.add(t.media.id)) items.add(t);
    }
    items.sort((a, b) => order[a.media.id]!.compareTo(order[b.media.id]!));
    if (items.isEmpty) continue;
    var face = state.covers[id];
    if (face == null || byCloudId[face.file] == null) face = covers[id];
    final faceItem = face == null ? null : byCloudId[face.file];
    out.add(
      PersonView(
        id: id,
        name: state.names[id],
        items: items,
        face: faceItem == null ? null : face,
        faceItem: faceItem,
      ),
    );
  }
  out.sort((a, b) {
    final c = b.items.length.compareTo(a.items.length);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  return out;
}

/// A step of a story with the phone's file to show.
class StoryStep {
  const StoryStep(this.item, this.photo);

  final StoryItem item;
  final TimelineItem photo;
}

/// A story that can be played: its photos that are on the phone.
class StoryView {
  const StoryView({
    required this.story,
    required this.steps,
    required this.cover,
    required this.seen,
  });

  final Story story;
  final List<StoryStep> steps;
  final TimelineItem cover;
  final bool seen;
}

/// The day's stories that have photos on the phone, unwatched first.
List<StoryView> storiesOnPhone(
  PhotoState state,
  Map<String, TimelineItem> byCloudId, {
  Set<String> seen = const {},
  Set<String> hidden = const {},
}) {
  if (!state.storiesEnabled) return const [];
  final out = <StoryView>[];
  for (final s in state.stories) {
    if (hidden.contains(s.date)) continue;
    final steps = [
      for (final i in s.items)
        if (byCloudId[i.id] case final t?) StoryStep(i, t),
    ];
    // A story of two photos isn't one.
    if (steps.length < 2) continue;
    out.add(
      StoryView(
        story: s,
        steps: steps,
        cover: byCloudId[s.cover] ?? steps.first.photo,
        seen: state.storiesSeen.contains(s.date) || seen.contains(s.date),
      ),
    );
  }
  // Stable: newest first within each.
  final unseen = out.where((s) => !s.seen);
  final watched = out.where((s) => s.seen);
  return [...unseen, ...watched];
}
