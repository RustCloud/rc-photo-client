import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/auth.dart';
import 'package:rc_photo/api/client.dart';
import 'package:rc_photo/api/trust.dart';
import 'package:rc_photo/auth/controller.dart';

import '../fakes.dart';

/// test/fixtures/tls: a CA made for these tests ("rc-photo test CA", DER) and
/// a server certificate it signed for 127.0.0.1 — a cloud signed by its own
/// CA, as on a home network. The keys protect nothing.
const _dir = 'test/fixtures/tls';

void main() {
  late HttpServer server;
  late Uri url;
  final ca = File('$_dir/ca.der').readAsBytesSync();

  setUpAll(() async {
    final ctx = SecurityContext()
      ..useCertificateChain('$_dir/server.pem')
      ..usePrivateKey('$_dir/server.key');
    server = await HttpServer.bindSecure('127.0.0.1', 0, ctx);
    server.listen((r) {
      r.response
        ..headers.contentType = ContentType.json
        ..write('{"version":"9.9.9"}');
      r.response.close();
    });
    url = Uri.parse('https://127.0.0.1:${server.port}/');
  });

  tearDownAll(() => server.close(force: true));

  Dio dioWith(SecurityContext ctx) => Dio()
    ..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient(context: ctx),
    );

  test('PEM from DER: 64-character lines', () {
    final pem = Trust.pem(ca);
    final lines = pem.trim().split('\n');
    expect(lines.first, '-----BEGIN CERTIFICATE-----');
    expect(lines.last, '-----END CERTIFICATE-----');
    expect(
      lines.skip(1).take(lines.length - 3).every((l) => l.length == 64),
      isTrue,
    );
  });

  test(
    'an unknown CA: the client says the certificate is not trusted',
    () async {
      final ctx = SecurityContext(withTrustedRoots: true);
      final client = RcClient(url, null, dio: dioWith(ctx));
      await expectLater(
        client.info(),
        throwsA(
          isA<NetworkException>().having(
            (e) => e.untrustedCertificate,
            'untrustedCertificate',
            isTrue,
          ),
        ),
      );
    },
  );

  test('the CA added: the same server is trusted, once', () async {
    final ctx = SecurityContext(withTrustedRoots: true);
    final trust = Trust(ctx);
    expect(trust.add([ca]), 1);
    expect(trust.add([ca]), 0, reason: 'added already');
    final info = await RcClient(url, null, dio: dioWith(ctx)).info();
    expect(info.version, '9.9.9');
  });

  test('a broken certificate is skipped, the rest are added', () {
    final trust = Trust(SecurityContext(withTrustedRoots: false));
    expect(
      trust.add([
        [1, 2, 3],
        ca,
      ]),
      1,
    );
  });

  test('login: untrusted until the CA is installed on the phone', () async {
    final ctx = SecurityContext(withTrustedRoots: true);
    final native = FakeBridge();
    final auth = AuthController(
      native: native,
      store: MemorySessionStore(),
      makeClient: (s, a) => RcClient(s, a, dio: dioWith(ctx)),
      trust: Trust(ctx),
    );
    await expectLater(
      auth.checkServer(url),
      throwsA(
        isA<LoginException>().having(
          (e) => e.problem,
          'problem',
          LoginProblem.untrustedCertificate,
        ),
      ),
    );
    native.certificates = [ca];
    expect((await auth.checkServer(url)).version, '9.9.9');
  });
}
