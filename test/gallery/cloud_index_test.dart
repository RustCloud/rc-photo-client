import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/models.dart';
import 'package:rc_photo/gallery/cloud_index.dart';
import 'package:rc_photo/gallery/index_store.dart';
import 'package:rc_photo/gallery/link_token.dart';

import '../fakes.dart';

/// A link as the server makes it: `/api/v1/app-links/<payload>.<signature>`.
String link(String path, String etag, {String session = 's1'}) {
  final claims = {
    's': session,
    'a': 'rc-photo',
    't': {'k': 'a', 'v': path},
    'e': etag,
    'x': 1700000000,
  };
  final payload = base64Url
      .encode(utf8.encode(jsonEncode(claims)))
      .replaceAll('=', '');
  return '/api/v1/app-links/$payload.c2lnbmF0dXJl';
}

String shard(List<(String id, String sha)> entries, {String root = 'f1'}) =>
    jsonEncode([
      for (final (id, sha) in entries)
        {
          'id': id,
          'name': '$id.jpg',
          'root': root,
          'etag': sha,
          'camera': 'Pixel 8',
        },
    ]);

void main() {
  group('LinkTarget', () {
    test('reads the path and the ETag of a link', () {
      final t = LinkTarget.read(link('index/0a.json', 'abc'))!;
      expect(t.path, 'index/0a.json');
      expect(t.version, 'abc');
      expect(
        LinkTarget.read('http://cloud${link('index/01.json', 'x')}')!.path,
        'index/01.json',
      );
    });

    test('anything else: null', () {
      expect(LinkTarget.read('index/00.json'), isNull);
      expect(LinkTarget.read('/api/v1/app-links/notbase64!.sig'), isNull);
      expect(LinkTarget.read('/api/v1/app-links/e30.sig'), isNull); // {}
    });
  });

  group('CloudIndex', () {
    late FakeCloud cloud;
    late MemoryIndexStore store;
    late CloudIndex index;

    setUp(() {
      cloud = FakeCloud()
        ..pluginFolders = [const PhotoFolder(id: 'f1', name: 'Photos')];
      store = MemoryIndexStore();
      index = CloudIndex(Future.value(store));
    });

    test('fetches the shards and finds photos by hash', () async {
      final a = link('index/00.json', 'v1');
      final b = link('index/01.json', 'v1');
      cloud
        ..shardLinks = [a, b]
        ..shardBodies[a] = shard([('p1', 'h1')])
        ..shardBodies[b] = shard([('p2', 'h2')]);
      await index.refresh(cloud);
      expect(index.count, 2);
      expect(index.byHash('h2')!.camera, 'Pixel 8');
      expect(index.byHash('nope'), isNull);
      expect(store.saved.keys, {'index/00.json', 'index/01.json', '#state'});
    });

    test('new links to unchanged shards: nothing fetched again', () async {
      cloud
        ..shardLinks = [link('index/00.json', 'v1')]
        ..shardBodies[cloud.shardLinks!.first] = shard([('p1', 'h1')]);
      await index.refresh(cloud);
      expect(cloud.fetched, hasLength(1));

      // The server restarted: other links, same files.
      final again = link('index/00.json', 'v1', session: 's2');
      cloud.shardLinks = [again];
      final later = CloudIndex(Future.value(store));
      await later.loadSaved();
      expect(later.byHash('h1'), isNotNull);
      await later.refresh(cloud);
      expect(cloud.fetched, hasLength(1));
      expect(later.byHash('h1'), isNotNull);

      // The shard changed: fetched.
      final changed = link('index/00.json', 'v2', session: 's2');
      cloud
        ..shardLinks = [changed]
        ..shardBodies[changed] = shard([('p1', 'h1'), ('p3', 'h3')]);
      await later.refresh(cloud);
      expect(cloud.fetched.last, changed);
      expect(later.byHash('h3'), isNotNull);
    });

    test('a shard gone from the state is forgotten', () async {
      final a = link('index/00.json', 'v1');
      final b = link('index/01.json', 'v1');
      cloud
        ..shardLinks = [a, b]
        ..shardBodies[a] = shard([('p1', 'h1')])
        ..shardBodies[b] = shard([('p2', 'h2')]);
      await index.refresh(cloud);
      cloud.shardLinks = [a];
      await index.refresh(cloud);
      expect(index.byHash('h2'), isNull);
      expect(store.saved.keys, {'index/00.json', '#state'});
    });

    test('photos of folders taken back from the plugin are left out', () async {
      final a = link('index/00.json', 'v1');
      cloud
        ..shardLinks = [a]
        ..shardBodies[a] = jsonEncode([
          {'id': 'p1', 'name': 'a.jpg', 'root': 'f1', 'etag': 'h1'},
          {'id': 'p2', 'name': 'b.jpg', 'root': 'old', 'etag': 'h2'},
        ]);
      await index.refresh(cloud);
      expect(index.count, 1);
      expect(index.byHash('h2'), isNull);
    });

    test('a link closed meanwhile: everything once more', () async {
      final a = link('index/00.json', 'v1');
      cloud
        ..shardLinks = [a]
        ..shardBodies[a] = shard([('p1', 'h1')])
        ..closedOnce.add(a);
      await index.refresh(cloud);
      expect(index.byHash('h1'), isNotNull);
    });

    test('no plugin: the 404 of the state is thrown', () async {
      cloud.pluginFolders = null;
      await expectLater(index.refresh(cloud), throwsA(isA<ApiException>()));
    });

    test('links that can\'t be read: fetched each time', () async {
      cloud
        ..shardLinks = ['index/00.json']
        ..shardBodies['index/00.json'] = shard([('p1', 'h1')]);
      await index.refresh(cloud);
      await index.refresh(cloud);
      expect(cloud.fetched, hasLength(2));
      expect(index.byHash('h1'), isNotNull);
    });
  });

  test('parseShards skips what it can\'t read', () {
    final entries = parseShards([
      'not json',
      '{"a": 1}',
      jsonEncode([
        {'id': 'p1', 'name': 'a.jpg'},
        {'name': 'no id'},
      ]),
    ]);
    expect(entries.map((e) => e.id), ['p1']);
  });
}
