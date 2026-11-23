import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/models.dart';

/// Fixtures are real answers of rustcloud 60e0e59 + rc-photo 0.8.0, saved by
/// `FIXTURES=… sh tools/api-check.sh` (see PLAN.md, section 2).
Object? fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync());

void main() {
  test('state', () {
    final s = PhotoState.fromJson(
      fixture('state.json')! as Map<String, dynamic>,
    );
    expect(s.folders.single.name, 'Pixel 8');
    expect(s.shards, hasLength(2));
    expect(s.shards.first, startsWith('/api/v1/app-links/'));
    expect(s.favorites, isEmpty);
    expect(s.names, isEmpty);
    expect(s.facesEnabled, isFalse);
    expect(s.ffmpeg, isTrue);
    expect(s.api, 0, reason: 'rc-photo 0.8 has no api field yet');
    expect(s.indexing, 0);
    expect(s.storiesEnabled, isTrue);
    expect(s.stories, isEmpty);
  });

  test('state with people and progress', () {
    final s = PhotoState.fromJson({
      'names': {
        'names': {'p1': 'Аня'},
        'hidden': ['p2'],
        'merged': {},
      },
      'progress': {
        'media': {'waiting': 12, 'failed': 1},
      },
      'favorites': ['a', 'b'],
      'api': 1,
      'some_future_field': {'x': 1},
    });
    expect(s.names, {'p1': 'Аня'});
    expect(s.hiddenPeople, {'p2'});
    expect(s.indexing, 12);
    expect(s.favorites, {'a', 'b'});
    expect(s.api, 1);
    expect(s.shards, isEmpty);
  });

  test('entry from a shard', () {
    final list = fixture('shard.json')! as List<dynamic>;
    final e = Entry.fromJson(list.first as Map<String, dynamic>);
    expect(e.etag, hasLength(64));
    expect(e.mime, 'image/jpeg');
    expect(e.video, isFalse);
    expect(e.thumb, isTrue);
    expect(e.width, 640);
    expect(e.lat, closeTo(55.7558, 1e-6));
    expect(e.camera, 'RustCloud Test Camera');
    // taken "2026-05-17T10:30:00+03:00": the camera's wall clock, offset dropped.
    expect(e.takenLocal, DateTime(2026, 5, 17, 10, 30));
  });

  test('entry without taken falls back to modified', () {
    final e = Entry.fromJson({
      'id': 'v',
      'name': 'VID.mp4',
      'etag': 'x',
      'video': true,
      'duration': 4500,
      'modified': '2024-03-01T22:30:00Z',
      'taken': 'garbage',
    });
    expect(e.video, isTrue);
    expect(e.duration, const Duration(milliseconds: 4500));
    expect(e.takenLocal, DateTime.utc(2024, 3, 1, 22, 30).toLocal());
  });

  test('nodes', () {
    final list = (fixture('children.json')! as List<dynamic>)
        .map((j) => Node.fromJson(j as Map<String, dynamic>))
        .toList();
    final img = list.firstWhere((n) => n.name == 'IMG_00000.jpg');
    expect(img.isDir, isFalse);
    expect(img.etag, hasLength(64));
    expect(img.modifiedAt, DateTime.utc(2024, 1, 10, 12));
  });

  test('errors', () {
    final e = ApiException.fromBody(409, fixture('error.json'));
    expect(e.code, 'NAME_TAKEN');
    final oauth = ApiException.fromBody(400, {
      'error': 'invalid_grant',
      'error_description': 'code used',
    });
    expect(oauth.code, 'invalid_grant');
    expect(ApiException.fromBody(502, 'Bad gateway').code, 'HTTP_502');
  });
}
