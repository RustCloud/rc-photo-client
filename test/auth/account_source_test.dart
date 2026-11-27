import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/auth.dart';
import 'package:rc_photo/auth/account_source.dart';
import 'package:rc_photo/auth/native.dart';

import '../fakes.dart';

void main() {
  (AccountTokenSource, List<int>) source(String? error, {bool there = true}) {
    final native = FakeBridge(
      phoneAccounts: there ? ['alice@cloud'] : [],
      token: AccountToken(error: error, message: 'why'),
    );
    final ended = <int>[];
    final s = AccountTokenSource(native, 'alice@cloud')
      ..onEnded = () => ended.add(1);
    return (s, ended);
  }

  test(
    'the client could not be woken: a passing failure, the login stays',
    () async {
      for (final error in ['failed', 'cancelled', 'network']) {
        final (s, ended) = source(error);
        await expectLater(s.token(), throwsA(isA<NetworkException>()));
        expect(ended, isEmpty, reason: error);
      }
    },
  );

  test(
    'the client wants its user: this request fails, the login stays',
    () async {
      final (s, ended) = source('login');
      await expectLater(s.token(), throwsA(isA<SessionEndedException>()));
      expect(ended, isEmpty);
    },
  );

  test('the account is gone from the phone: the login ends', () async {
    final (s, ended) = source('login', there: false);
    await expectLater(s.token(), throwsA(isA<SessionEndedException>()));
    expect(ended, [1]);
  });
}
