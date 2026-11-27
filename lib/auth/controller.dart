import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/auth.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../api/trust.dart';
import 'account_source.dart';
import 'native.dart';
import 'session_store.dart';

/// What a server address turned out to be.
enum ServerCheck {
  /// RustCloud with the Photos plugin.
  ok,

  /// RustCloud, but `/app/rc-photo` is not there (not installed or off) — or
  /// it can't be told before login. The gallery won't work; backup would.
  noPlugin,
}

/// Why a login didn't happen, for the screen.
enum LoginProblem {
  /// Nothing answers there, or no RustCloud.
  notRustCloud,
  network,

  /// The server's certificate is signed by a CA the device doesn't trust.
  untrustedCertificate,

  /// The user closed the browser or refused.
  cancelled,
  failed,
}

class LoginException implements Exception {
  const LoginException(this.problem, [this.detail = '']);

  final LoginProblem problem;
  final String detail;

  @override
  String toString() => 'LoginException($problem $detail)';
}

/// The logged-in app: the client, who, and how.
class Session {
  const Session({
    required this.client,
    required this.login,
    required this.user,
  });

  final RcClient client;
  final SavedLogin login;
  final User user;
}

/// Login state for the whole app: starts from what was saved, logs in
/// through rc-client's account or the browser, logs out.
class AuthController extends ChangeNotifier {
  AuthController({
    required this.native,
    required this.store,
    RcClient Function(Uri, TokenSource?)? makeClient,
    Trust? trust,
    this.background = false,
  }) : _makeClient = makeClient ?? ((s, a) => RcClient(s, a)),
       _trust = trust ?? Trust();

  final NativeBridge native;
  final Trust _trust;

  /// In the backup's worker: no screen. An account that needs the user
  /// (rc-client logged out, consent) fails the run but doesn't log the app out.
  final bool background;

  /// Run on logout and when the session ends: the backup stops and forgets.
  final List<Future<void> Function()> onLoggedOut = [];
  final SessionStore store;
  final RcClient Function(Uri, TokenSource?) _makeClient;

  Session? _session;
  bool _starting = true;

  /// Null while logged out.
  Session? get session => _session;

  /// Reading the saved login at start.
  bool get starting => _starting;

  /// Restores the saved login without the network: the user sees the app at
  /// once, offline too. Who the user is is read when the server answers.
  Future<void> start() async {
    try {
      await trustUserCertificates();
      final saved = await store.readLogin();
      if (saved != null) {
        final source = await _sourceFor(saved);
        if (source != null) {
          _session = Session(
            client: _makeClient(saved.server, source),
            login: saved,
            user: const User(id: '', username: '', displayName: null),
          );
          unawaited(_refreshUser());
        }
      }
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  Future<void> _refreshUser() async {
    final s = _session;
    if (s == null) return;
    try {
      final user = await s.client.me();
      if (_session == s) {
        _session = Session(client: s.client, login: s.login, user: user);
        notifyListeners();
      }
    } catch (_) {
      // Offline, or the token source can't give a token now: keep the
      // session, try on the next request. A login that is really over is
      // ended by its source (onEnded).
    }
  }

  Future<TokenSource?> _sourceFor(SavedLogin saved) async {
    switch (saved) {
      case AccountLogin(:final account):
        final s = AccountTokenSource(native, account);
        if (!background) s.onEnded = _endedLater;
        return s;
      case BrowserLogin(:final server):
        final tokens = await store.tokens.read();
        if (tokens == null) return null;
        return OAuthSession(OAuthClient(server), store.tokens, tokens)
          ..onEnded = _endedLater;
    }
  }

  void _endedLater() => scheduleMicrotask(_ended);

  Future<void> _ended() async {
    if (_session == null) return;
    _session = null;
    await store.clear();
    await _runLoggedOut();
    notifyListeners();
  }

  Future<void> _runLoggedOut() async {
    for (final f in onLoggedOut) {
      try {
        await f();
      } catch (_) {
        // Best effort: the login is gone either way.
      }
    }
  }

  /// Trusts the CAs the user installed on the device. Read again before each
  /// login, so one installed while the app runs counts.
  Future<void> trustUserCertificates() async {
    try {
      _trust.add(await native.userCertificates());
    } catch (_) {
      // Not on this platform: the system's roots only.
    }
  }

  static LoginException _networkProblem(NetworkException e) => LoginException(
    e.untrustedCertificate
        ? LoginProblem.untrustedCertificate
        : LoginProblem.network,
    e.message,
  );

  /// RustCloud accounts on the phone (rc-client), to offer before the browser.
  Future<List<String>> phoneAccounts() async {
    try {
      return await native.accounts();
    } catch (_) {
      return const [];
    }
  }

  /// Normalises what the user typed: `cloud.example.com` → `https://cloud.example.com/`.
  static Uri? parseAddress(String text) {
    var t = text.trim();
    if (t.isEmpty) return null;
    if (!t.contains('://')) t = 'https://$t';
    final u = Uri.tryParse(t);
    if (u == null ||
        u.host.isEmpty ||
        !(u.scheme == 'https' || u.scheme == 'http')) {
      return null;
    }
    return u.replace(
      path: u.path.endsWith('/') ? u.path : '${u.path}/',
      query: null,
      fragment: null,
    );
  }

  /// Checks that [server] is RustCloud.
  Future<ServerInfo> checkServer(Uri server) async {
    await trustUserCertificates();
    try {
      return await _makeClient(server, null).info();
    } on NetworkException catch (e) {
      throw _networkProblem(e);
    } on ApiException catch (e) {
      throw LoginException(LoginProblem.notRustCloud, '${e.status} ${e.code}');
    } on FormatException catch (e) {
      throw LoginException(LoginProblem.notRustCloud, e.message);
    } on TypeError catch (e) {
      throw LoginException(LoginProblem.notRustCloud, '$e');
    }
  }

  /// Logs in with the browser: the server's page, then the code for tokens.
  Future<ServerCheck> loginWithBrowser(Uri server) async {
    await checkServer(server);
    final pkce = Pkce.generate();
    final state = randomToken(16);
    final device = await native.deviceName();
    final Uri? back;
    try {
      back = await native.browserLogin(
        authorizeUri(server, pkce: pkce, state: state, deviceName: device),
      );
    } catch (e) {
      throw LoginException(LoginProblem.failed, '$e');
    }
    if (back == null) throw const LoginException(LoginProblem.cancelled);
    final OAuthTokens tokens;
    try {
      final code = codeFromCallback(back, state);
      tokens = await OAuthClient(server).exchangeCode(code, pkce);
    } on ApiException catch (e) {
      if (e.code == 'access_denied') {
        throw const LoginException(LoginProblem.cancelled);
      }
      throw LoginException(
        LoginProblem.failed,
        e.message.isEmpty ? e.code : e.message,
      );
    } on NetworkException catch (e) {
      throw _networkProblem(e);
    }
    await store.tokens.write(tokens);
    final login = BrowserLogin(server);
    final source = OAuthSession(OAuthClient(server), store.tokens, tokens)
      ..onEnded = _endedLater;
    return _finish(login, source);
  }

  /// Logs in through rc-client's account (the server is the account's).
  Future<ServerCheck> loginWithAccount(String account) async {
    await trustUserCertificates();
    final probe = await native.accountToken(account);
    if (probe.token == null) {
      throw LoginException(switch (probe.error) {
        'network' => LoginProblem.network,
        'cancelled' => LoginProblem.cancelled,
        _ => LoginProblem.failed,
      }, probe.message ?? '');
    }
    final server = parseAddress(probe.server ?? '');
    if (server == null) {
      throw LoginException(
        LoginProblem.failed,
        'account has no server: ${probe.server}',
      );
    }
    final source = AccountTokenSource(native, account)..onEnded = _endedLater;
    return _finish(AccountLogin(server, account), source);
  }

  Future<ServerCheck> _finish(SavedLogin login, TokenSource source) async {
    final client = _makeClient(login.server, source);
    final User user;
    try {
      user = await client.me();
    } on NetworkException catch (e) {
      throw _networkProblem(e);
    } on SessionEndedException catch (e) {
      throw LoginException(LoginProblem.failed, e.reason);
    } on ApiException catch (e) {
      throw LoginException(LoginProblem.failed, '${e.status} ${e.code}');
    }
    var check = ServerCheck.ok;
    try {
      await client.photoState();
    } on ApiException catch (e) {
      if (e.status == 404) check = ServerCheck.noPlugin;
    } catch (_) {
      // Checked again by the gallery.
    }
    await store.writeLogin(login);
    _session = Session(client: client, login: login, user: user);
    notifyListeners();
    return check;
  }

  /// Ends the app's own session on the server (an account login belongs to
  /// rc-client and stays), then forgets everything here.
  Future<void> logout() async {
    final s = _session;
    if (s == null) return;
    if (s.login is BrowserLogin) {
      try {
        await s.client.logout().timeout(const Duration(seconds: 10));
      } catch (_) {
        // Offline: the session ends on the server after 90 days unused.
      }
    }
    _session = null;
    await store.clear();
    await _runLoggedOut();
    notifyListeners();
  }
}
