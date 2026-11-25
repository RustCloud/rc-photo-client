import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/client.dart';

/// Answers every request with [answer] and keeps what was sent.
class _Recorder extends Interceptor {
  _Recorder(this.answer);

  final Object answer;
  final List<RequestOptions> sent = [];

  @override
  void onRequest(RequestOptions o, RequestInterceptorHandler handler) {
    sent.add(o);
    handler.resolve(Response(requestOptions: o, statusCode: 201, data: answer));
  }
}

void main() {
  test('an upload in parts sends mtime as a string', () async {
    final rec = _Recorder({'id': 'u1', 'size': 30000000, 'received': 0});
    final dio = Dio()..interceptors.add(rec);
    final c = RcClient(Uri.parse('http://cloud/'), null, dio: dio);
    final up = await c.startUpload(
      'f1',
      name: 'VID.mp4',
      size: 30000000,
      mtime: 1734092334,
    );
    expect(up.id, 'u1');
    final body = rec.sent.single.data as Map<String, dynamic>;
    // The server refuses a JSON number here (rustcloud files/http.rs).
    expect(body['mtime'], '1734092334');
    expect(jsonEncode(body), contains('"mtime":"1734092334"'));
  });

  test('ctime goes with both uploads', () async {
    final rec = _Recorder({'id': 'u1', 'size': 3, 'received': 0});
    final dio = Dio()..interceptors.add(rec);
    final c = RcClient(Uri.parse('http://cloud/'), null, dio: dio);
    await c.startUpload('f1', name: 'a.png', size: 3, ctime: 1650000000);
    expect((rec.sent.single.data as Map)['ctime'], '1650000000');
  });

  test('file times are set as RFC 3339; a server without born_at', () async {
    final rec = _Recorder({'id': 'n1', 'name': 'a.png'});
    final dio = Dio()..interceptors.add(rec);
    final c = RcClient(Uri.parse('http://cloud/'), null, dio: dio);
    final n = await c.setTimes('n1', born: 1650000000, modified: 1700000000);
    final sent = rec.sent.single;
    expect(sent.method, 'PATCH');
    expect(sent.path, endsWith('/api/v1/files/n1'));
    expect(sent.data, {
      'born_at': '2022-04-15T05:20:00.000Z',
      'modified_at': '2023-11-14T22:13:20.000Z',
    });
    expect(n.bornAt, isNull);
  });
}
