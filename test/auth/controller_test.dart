import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/auth.dart';
import 'package:rc_photo/auth/controller.dart';
import 'package:rc_photo/auth/native.dart';
import 'package:rc_photo/auth/session_store.dart';

import '../fakes.dart';

/// Just enough of RustCloud for a login: info, token, me, plugin state.
class MiniServer {
  late HttpServer _http;
  bool plugin = true;
  String? lastBearer;
  Map<String, String>? lastTokenForm;
  bool loggedOut = false;

  Uri get uri => Uri.parse('http://127.0.0.1:${_http.port}/');

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http.listen((req) async {
      final res = req.response..headers.contentType = ContentType.json;
      Future<void> send(int status, Object body) async {
        res.statusCode = status;
        res.write(jsonEncode(body));
        await res.close();
      }

      lastBearer = req.headers.value('authorization');
      switch (req.uri.path) {
        case '/api/v1/info':
          return send(200, {
            'version': '0.1.0',
            'public_url': '',
            'thumbnails': true,
          });
        case '/api/v1/auth/token':
          lastTokenForm = Uri.splitQueryString(await utf8.decodeStream(req));
          return send(200, {
            'access_token': 'acc',
            'refresh_token': 'ref',
            'expires_in': 600,
          });
        case '/api/v1/auth/me':
          return send(200, {
            'id': 'u1',
            'username': 'alice',
            'display_name': 'Alice',
          });
        case '/api/v1/auth/logout':
          loggedOut = true;
          res.statusCode = 204;
          return res.close();
        case '/app/rc-photo/api/state':
          if (!plugin) {
            return send(404, {
              'error': {'code': 'APP_NOT_FOUND', 'message': 'no'},
            });
          }
          return send(200, {'folders': [], 'shards': []});
      }
      return send(404, {
        'error': {'code': 'NOT_FOUND', 'message': req.uri.path},
      });
    });
  }

  Future<void> stop() => _http.close(force: true);
}

void main() {
  late MiniServer server;
  setUp(() async {
    server = MiniServer();
    await server.start();
  });
  tearDown(() => server.stop());

  test('address parsing', () {
    expect(
      AuthController.parseAddress('cloud.example.com').toString(),
      'https://cloud.example.com/',
    );
    expect(
      AuthController.parseAddress(' http://10.0.0.5:8080 ').toString(),
      'http://10.0.0.5:8080/',
    );
    expect(
      AuthController.parseAddress('https://x.org/cloud').toString(),
      'https://x.org/cloud/',
    );
    expect(AuthController.parseAddress(''), isNull);
    expect(AuthController.parseAddress('ftp://x.org'), isNull);
  });

  test('browser login: PKCE round trip, tokens and login saved', () async {
    final native = FakeBridge(
      browserReturn: (authorize) => Uri.parse(
        '$redirectUri?code=c1&state=${authorize.queryParameters['state']}',
      ),
    );
    final store = MemorySessionStore();
    final auth = AuthController(native: native, store: store);
    expect(await auth.loginWithBrowser(server.uri), ServerCheck.ok);

    final q = native.lastAuthorize!.queryParameters;
    expect(q['device_name'], 'Test phone');
    expect(q['redirect_uri'], redirectUri);
    expect(server.lastTokenForm!['code'], 'c1');
    expect(
      Pkce(server.lastTokenForm!['code_verifier']!).challenge,
      q['code_challenge'],
    );

    expect(auth.session!.user.shownName, 'Alice');
    expect(store.login, isA<BrowserLogin>());
    expect((await store.tokens.read())!.refresh, 'ref');

    await auth.logout();
    expect(server.loggedOut, isTrue);
    expect(auth.session, isNull);
    expect(store.login, isNull);
    expect(await store.tokens.read(), isNull);
  });

  test('browser closed → cancelled; nothing saved', () async {
    final store = MemorySessionStore();
    final auth = AuthController(native: FakeBridge(), store: store);
    await expectLater(
      auth.loginWithBrowser(server.uri),
      throwsA(
        isA<LoginException>().having(
          (e) => e.problem,
          'problem',
          LoginProblem.cancelled,
        ),
      ),
    );
    expect(store.login, isNull);
  });

  test('no RustCloud there / nothing there', () async {
    final auth = AuthController(
      native: FakeBridge(),
      store: MemorySessionStore(),
    );
    await expectLater(
      auth.checkServer(server.uri.resolve('/nothing/')),
      throwsA(isA<LoginException>()),
    );
    await expectLater(
      auth.loginWithBrowser(Uri.parse('http://127.0.0.1:1/')),
      throwsA(
        isA<LoginException>().having(
          (e) => e.problem,
          'problem',
          LoginProblem.network,
        ),
      ),
    );
  });

  test('account login: server from the account, no plugin reported', () async {
    server.plugin = false;
    final native = FakeBridge(
      token: AccountToken(
        token: 'acct-token',
        server: server.uri.toString(),
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      ),
    );
    final store = MemorySessionStore();
    final auth = AuthController(native: native, store: store);
    expect(await auth.loginWithAccount('alice'), ServerCheck.noPlugin);
    expect(server.lastBearer, 'Bearer acct-token');
    expect(store.login, isA<AccountLogin>());

    await auth.logout();
    expect(server.loggedOut, isFalse, reason: "rc-client's session stays");
  });

  test('saved login is restored without the network', () async {
    final store = MemorySessionStore();
    await store.writeLogin(
      AccountLogin(Uri.parse('http://127.0.0.1:1/'), 'alice'),
    );
    final auth = AuthController(native: FakeBridge(), store: store);
    await auth.start();
    expect(auth.session, isNotNull);
    expect(auth.starting, isFalse);
  });

  test('browser login without tokens is not restored', () async {
    final store = MemorySessionStore();
    await store.writeLogin(BrowserLogin(server.uri));
    final auth = AuthController(native: FakeBridge(), store: store);
    await auth.start();
    expect(auth.session, isNull);
  });
}
