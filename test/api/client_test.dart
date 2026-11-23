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
}
