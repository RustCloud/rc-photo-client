import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/auth.dart';
import '../backup/settings.dart';

/// How the app is logged in, kept between runs.
sealed class SavedLogin {
  const SavedLogin(this.server);

  final Uri server;

  Map<String, dynamic> toJson();

  static SavedLogin? fromJson(Map<String, dynamic> j) {
    final server = Uri.tryParse(j['server'] as String? ?? '');
    if (server == null) return null;
    return switch (j['kind']) {
      'account' => AccountLogin(server, j['account'] as String),
      'browser' => BrowserLogin(server),
      _ => null,
    };
  }
}

/// Through rc-client's phone account: nothing secret is kept here.
class AccountLogin extends SavedLogin {
  const AccountLogin(super.server, this.account);

  final String account;

  @override
  Map<String, dynamic> toJson() => {
    'kind': 'account',
    'server': '$server',
    'account': account,
  };
}

/// The app's own login; its tokens are in [SecureTokenStore].
class BrowserLogin extends SavedLogin {
  const BrowserLogin(super.server);

  @override
  Map<String, dynamic> toJson() => {'kind': 'browser', 'server': '$server'};
}

/// Login and tokens in the Android Keystore-backed storage.
class SessionStore {
  SessionStore([FlutterSecureStorage? storage])
    : _s = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _s;

  static const _login = 'login';
  static const _tokens = 'tokens';
  static const _backup = 'backup';

  /// The backup's choices; they belong to the login and go with it.
  Future<BackupSettings?> readBackup() async {
    final v = await _s.read(key: _backup);
    if (v == null) return null;
    try {
      return BackupSettings.fromJson(jsonDecode(v) as Map<String, dynamic>);
    } on FormatException {
      return null;
    }
  }

  Future<void> writeBackup(BackupSettings b) =>
      _s.write(key: _backup, value: jsonEncode(b.toJson()));

  Future<SavedLogin?> readLogin() async {
    final v = await _s.read(key: _login);
    if (v == null) return null;
    try {
      return SavedLogin.fromJson(jsonDecode(v) as Map<String, dynamic>);
    } on FormatException {
      return null;
    }
  }

  Future<void> writeLogin(SavedLogin login) =>
      _s.write(key: _login, value: jsonEncode(login.toJson()));

  Future<void> clear() async {
    await _s.delete(key: _login);
    await _s.delete(key: _tokens);
    await _s.delete(key: _backup);
  }

  TokenStore get tokens => SecureTokenStore(_s);
}

class SecureTokenStore implements TokenStore {
  SecureTokenStore(this._s);

  final FlutterSecureStorage _s;

  @override
  Future<OAuthTokens?> read() async {
    final v = await _s.read(key: SessionStore._tokens);
    if (v == null) return null;
    try {
      return OAuthTokens.fromJson(jsonDecode(v) as Map<String, dynamic>);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(OAuthTokens t) =>
      _s.write(key: SessionStore._tokens, value: jsonEncode(t.toJson()));

  @override
  Future<void> clear() => _s.delete(key: SessionStore._tokens);
}
