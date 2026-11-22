import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rc_photo/api/auth.dart';
import 'package:rc_photo/api/client.dart';
import 'package:rc_photo/auth/controller.dart';
import 'package:rc_photo/auth/native.dart';
import 'package:rc_photo/auth/session_store.dart';
import 'package:rc_photo/ui/app.dart';

import '../fakes.dart';

void main() {
  testWidgets('logged out: the connect screen in Russian', (tester) async {
    final auth = AuthController(
      native: FakeBridge(),
      store: MemorySessionStore(),
    );
    await auth.start();
    await tester.pumpWidget(RcPhotoApp(auth: auth, locale: const Locale('ru')));
    await tester.pumpAndSettle();
    expect(find.text('Адрес облака'), findsOneWidget);
    expect(find.text('Войти через приложение RustCloud'), findsOneWidget);

    await tester.tap(find.text('Подключить облако'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('connect-error')), findsOneWidget);
    expect(
      find.text('Введите адрес облака, например cloud.example.com.'),
      findsOneWidget,
    );
  });

  testWidgets('a phone account is offered first', (tester) async {
    final auth = AuthController(
      native: FakeBridge(phoneAccounts: ['alice@cloud.example.com']),
      store: MemorySessionStore(),
    );
    await auth.start();
    await tester.pumpWidget(RcPhotoApp(auth: auth, locale: const Locale('en')));
    await tester.pumpAndSettle();
    expect(find.text('Continue as alice@cloud.example.com'), findsOneWidget);
    expect(find.text('or'), findsOneWidget);
  });

  testWidgets('logged in: tabs and log out', (tester) async {
    final store = MemorySessionStore();
    await store.writeLogin(
      AccountLogin(Uri.parse('http://127.0.0.1:1/'), 'alice'),
    );
    final auth = AuthController(
      native: FakeBridge(
        token: const AccountToken(token: 't', server: 'http://127.0.0.1:1/'),
      ),
      store: store,
      makeClient: (s, a) => _OfflineClient(s, a),
    );
    await auth.start();
    await tester.pumpWidget(RcPhotoApp(auth: auth, locale: const Locale('ru')));
    await tester.pumpAndSettle();
    expect(find.text('Фото'), findsWidgets);

    await tester.tap(find.text('Коллекции'));
    await tester.pumpAndSettle();
    expect(find.textContaining('избранное'), findsOneWidget);

    await tester.tap(find.byKey(const Key('account')));
    await tester.pumpAndSettle();
    expect(find.text('Через приложение RustCloud (alice)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('logout')));
    await tester.pumpAndSettle();
    expect(find.text('Адрес облака'), findsOneWidget);
    expect(await store.readLogin(), isNull);
  });
}

/// Answers every request at once, so widget tests don't wait on a socket.
class _OfflineClient extends RcClient {
  _OfflineClient(super.server, super.auth);

  @override
  Future<User> me() async =>
      const User(id: 'u', username: 'alice', displayName: 'Alice');

  @override
  Future<Never> photoState({DateTime? today}) async =>
      throw const NetworkException('offline');
}
