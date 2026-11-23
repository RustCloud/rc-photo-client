import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/models.dart';
import 'package:rc_photo/backup/phone_media.dart';
import 'package:rc_photo/gallery/people_stories.dart';
import 'package:rc_photo/gallery/timeline.dart';

TimelineItem photo(int id, String cloudId, {int day = 1}) => TimelineItem(
  media: MediaItem(
    id: id,
    bucket: 'b1',
    name: '$id.jpg',
    size: 1,
    modified: 0,
    taken: DateTime(2026, 5, day).millisecondsSinceEpoch,
    mime: 'image/jpeg',
    uri: 'content://media/$id',
  ),
  mark: CloudMark.synced,
  cloud: Entry.fromJson({'id': cloudId, 'name': '$id.jpg'}),
);

Person person(String id, List<String> files, {String? cover}) => Person(
  id: id,
  count: files.length,
  files: files,
  cover: cover == null ? null : FaceBox(cover, 0.4, 0.3, 0.1, 0.1),
);

void main() {
  // The timeline: newest first.
  final timeline = [
    photo(3, 'c', day: 3),
    photo(2, 'b', day: 2),
    photo(1, 'a'),
  ];
  final byCloudId = {for (final t in timeline) t.cloud!.id: t};

  test('people: names, merges, hidden, only photos on the phone', () {
    final state = PhotoState.fromJson({
      'names': {
        'names': {'p0': 'Аня'},
        'hidden': ['p2'],
        'merged': {'p1': 'p0'},
      },
    });
    final people = peopleOnPhone(
      [
        person('p0', ['a', 'x'], cover: 'a'),
        person('p1', ['b', 'c'], cover: 'b'),
        person('p2', ['c']),
        person('p3', ['y']), // nothing on the phone
        person('p4', ['b'], cover: 'zz'), // its face isn't on the phone
      ],
      state,
      byCloudId,
      timeline,
    );
    expect(people.map((p) => p.id), ['p0', 'p4']);
    final anya = people.first;
    expect(anya.name, 'Аня');
    expect(anya.items.map((t) => t.cloud!.id), ['c', 'b', 'a']);
    expect(anya.face!.file, 'a', reason: 'their own face over a merged one');
    expect(people[1].face, isNull);
    expect(people[1].faceItem, isNull);
  });

  test('a face chosen by the user wins', () {
    final state = PhotoState.fromJson({
      'names': {
        'covers': {
          'p0': {
            'file': 'b',
            'b': [0.1, 0.1, 0.2, 0.2],
          },
        },
      },
    });
    final p = peopleOnPhone(
      [
        person('p0', ['a', 'b'], cover: 'a'),
      ],
      state,
      byCloudId,
      timeline,
    ).single;
    expect(p.face!.file, 'b');
    expect(p.faceItem!.cloud!.id, 'b');
  });

  Map<String, dynamic> story(String date, List<String> ids, {String? cover}) =>
      {
        'date': date,
        'expires': date,
        'kind': 'on-this-day',
        'key': 'k$date',
        'params': {'years': 2},
        'cover': cover ?? ids.first,
        'items': [
          for (final id in ids) {'id': id, 'ms': 4500},
        ],
      };

  test('stories: only with photos on the phone, unwatched first', () {
    final state = PhotoState.fromJson({
      'stories': {
        'enabled': true,
        'list': [
          story('2026-11-23', ['a', 'b', 'x']),
          story('2026-11-22', ['a', 'c'], cover: 'x'),
          story('2026-11-21', ['a', 'y']), // one photo on the phone
        ],
        'seen': ['2026-11-23'],
      },
    });
    final list = storiesOnPhone(state, byCloudId);
    expect(list.map((s) => s.story.date), ['2026-11-22', '2026-11-23']);
    expect(list.first.cover.cloud!.id, 'a', reason: 'its cover is gone');
    expect(list.last.steps.map((s) => s.photo.cloud!.id), ['a', 'b']);
    expect(list.last.seen, isTrue);

    final hidden = storiesOnPhone(
      state,
      byCloudId,
      seen: {'2026-11-22'},
      hidden: {'2026-11-23'},
    );
    expect(hidden.single.seen, isTrue);
  });

  test('stories off: none', () {
    final state = PhotoState.fromJson({
      'stories': {
        'enabled': false,
        'list': [
          story('2026-11-23', ['a', 'b']),
        ],
      },
    });
    expect(storiesOnPhone(state, byCloudId), isEmpty);
  });
}
