import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/auth.dart';
import 'package:rc_photo/api/client.dart';
import 'package:rc_photo/api/models.dart';

/// A tiny server with the token rules of rustcloud (auth.md): the refresh
/// token rotates on every exchange; the previous one is forgiven within the
/// grace period (a retry after a lost answer), later it ends the session.
class FakeServer {
  late HttpServer _http;
  int _n = 0;
  String access = 'a0';
  String refresh = 'r0';
  String? previousRefresh;
  bool ended = false;
  int refreshCalls = 0;

  /// The next refresh is done but its answer is lost (connection dropped).
  bool dropNextRefreshAnswer = false;

  /// Answer to `/api/v1/auth/me` waits for this, to line up parallel requests.
  Completer<void>? holdMe;

  Uri get uri => Uri.parse('http://127.0.0.1:${_http.port}');

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http.listen(_handle);
  }

  Future<void> stop() => _http.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    Future<void> json(int status, Object body) async {
      res.statusCode = status;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(body));
      await res.close();
    }

    if (req.uri.path == '/api/v1/auth/token') {
      final form = Uri.splitQueryString(await utf8.decodeStream(req));
      refreshCalls++;
      final given = form['refresh_token'];
      if (ended || (given != refresh && given != previousRefresh)) {
        ended = true;
        return json(400, {
          'error': 'invalid_grant',
          'error_description': 'session ended',
        });
      }
      if (given == refresh) {
        previousRefresh = refresh;
        _n++;
        refresh = 'r$_n';
        access = 'a$_n';
      } else {
        // The forgiven repeat: a fresh pair for the current session.
        _n++;
        refresh = 'r$_n';
        access = 'a$_n';
      }
      if (dropNextRefreshAnswer) {
        dropNextRefreshAnswer = false;
        final socket = await res.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      return json(200, {
        'access_token': access,
        'token_type': 'Bearer',
        'expires_in': 600,
        'refresh_token': refresh,
      });
    }
    if (req.uri.path == '/api/v1/auth/me') {
      final h = holdMe;
      if (h != null) await h.future;
      if (req.headers.value('authorization') != 'Bearer $access') {
        return json(401, {
          'error': {'code': 'UNAUTHORIZED', 'message': 'expired'},
        });
      }
      return json(200, {'id': 'u1', 'username': 'alice', 'display_name': ''});
    }
    return json(404, {
      'error': {'code': 'NOT_FOUND', 'message': req.uri.path},
    });
  }
}

void main() {
  late FakeServer server;
  setUp(() async {
    server = FakeServer();
    await server.start();
  });
  tearDown(() => server.stop());

  OAuthTokens pair(String a, String r) => OAuthTokens(
    access: a,
    refresh: r,
    accessExpiresAt: DateTime.now().add(const Duration(minutes: 10)),
  );

  OAuthSession session(MemoryTokenStore store) => OAuthSession(
    OAuthClient(server.uri),
    store,
    store.tokens!,
    retryDelay: const Duration(milliseconds: 10),
  );

  test('PKCE challenge: base64url(sha256(verifier)) without padding', () {
    // Expected value computed independently:
    // python3 -c "import hashlib,base64; print(base64.urlsafe_b64encode(
    //   hashlib.sha256(b'dBjftJeZ4CVP-mJ92K1kNQ8hT1_s3J5AhMSKnmZJNMP').digest()).rstrip(b'='))"
    final p = Pkce('dBjftJeZ4CVP-mJ92K1kNQ8hT1_s3J5AhMSKnmZJNMP');
    expect(p.challenge, 'XDh_yBa04nqtxX4QY3xzYytJnWzthpD78kkOJijuT2k');
    final g = Pkce.generate();
    expect(g.verifier.length, inInclusiveRange(43, 128));
    expect(g.verifier, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    expect(g.challenge, isNot(contains('=')));
  });

  test('authorize URL and callback', () {
    final pkce = Pkce('x' * 43);
    final u = authorizeUri(
      Uri.parse('https://cloud.example.com/'),
      pkce: pkce,
      state: 's1',
      deviceName: 'Pixel 8',
    );
    expect(u.path, '/api/v1/auth/authorize');
    expect(u.queryParameters['redirect_uri'], redirectUri);
    expect(u.queryParameters['code_challenge'], pkce.challenge);
    expect(u.queryParameters['device_name'], 'Pixel 8');

    expect(
      codeFromCallback(Uri.parse('$redirectUri?code=c1&state=s1'), 's1'),
      'c1',
    );
    expect(
      () => codeFromCallback(Uri.parse('$redirectUri?code=c1&state=zz'), 's1'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'STATE_MISMATCH'),
      ),
    );
    expect(
      () => codeFromCallback(
        Uri.parse('$redirectUri?error=access_denied&state=s1'),
        's1',
      ),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'access_denied'),
      ),
    );
  });

  test('401 → refresh → retry; the new pair is stored', () async {
    server.access = 'a-new-on-server';
    final store = MemoryTokenStore(pair('a-old', 'r0'));
    final client = RcClient(server.uri, session(store));
    final me = await client.me();
    expect(me.shownName, 'alice');
    expect(server.refreshCalls, 1);
    expect(store.tokens!.refresh, server.refresh);
    expect(store.tokens!.access, server.access);
  });

  test('parallel 401s refresh once', () async {
    server.access = 'a-rotated';
    server.holdMe = Completer<void>();
    final store = MemoryTokenStore(pair('a-old', 'r0'));
    final client = RcClient(server.uri, session(store));
    final calls = [for (var i = 0; i < 5; i++) client.me()];
    await Future<void>.delayed(const Duration(milliseconds: 100));
    server.holdMe!.complete();
    await Future.wait(calls);
    expect(server.refreshCalls, 1);
  });

  test('expired access is refreshed before the request', () async {
    final store = MemoryTokenStore(
      OAuthTokens(
        access: 'a-old',
        refresh: 'r0',
        accessExpiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      ),
    );
    final client = RcClient(server.uri, session(store));
    await client.me();
    expect(server.refreshCalls, 1);
  });

  test(
    'lost refresh answer: retried with the same token, session kept',
    () async {
      server.access = 'a-rotated';
      server.dropNextRefreshAnswer = true;
      final store = MemoryTokenStore(pair('a-old', 'r0'));
      final client = RcClient(server.uri, session(store));
      await client.me();
      expect(server.refreshCalls, 2);
      expect(server.ended, isFalse);
      expect(store.tokens!.refresh, server.refresh);
    },
  );

  test('refused refresh ends the session', () async {
    server
      ..access = 'a-rotated'
      ..ended = true;
    final store = MemoryTokenStore(pair('a-old', 'r0'));
    final s = session(store);
    var ended = 0;
    s.onEnded = () => ended++;
    final client = RcClient(server.uri, s);
    await expectLater(client.me(), throwsA(isA<SessionEndedException>()));
    expect(ended, 1);
    expect(store.tokens, isNull);
    await expectLater(client.me(), throwsA(isA<SessionEndedException>()));
  });

  test('errors of the server become ApiException', () async {
    final client = RcClient(server.uri, const StaticTokenSource('a0'));
    await expectLater(
      client.photoState(),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)),
    );
  });

  test('no server: NetworkException', () async {
    final client = RcClient(
      Uri.parse('http://127.0.0.1:1'),
      const StaticTokenSource('a0'),
    );
    await expectLater(client.info(), throwsA(isA<NetworkException>()));
  });
}
