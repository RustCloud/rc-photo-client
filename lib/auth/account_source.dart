import 'dart:async';

import '../api/auth.dart';
import 'native.dart';

/// Tokens from rc-client's phone account: 10-minute access tokens, asked
/// again when they run out. The refresh token stays in rc-client (only it may
/// rotate it), so this app never refreshes by itself.
class AccountTokenSource implements TokenSource {
  AccountTokenSource(this._native, this.account, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final NativeBridge _native;
  final String account;
  final DateTime Function() _clock;

  String? _token;
  DateTime? _expiresAt;
  Future<String>? _asking;

  /// Called when the account is gone or logged out and the user didn't log
  /// in again in the client.
  void Function()? onEnded;

  static const _margin = Duration(seconds: 30);

  @override
  Future<String> token() async {
    final t = _token;
    final e = _expiresAt;
    if (t != null && (e == null || _clock().isBefore(e.subtract(_margin)))) {
      return t;
    }
    return _ask();
  }

  @override
  Future<String> renew(String rejected) async {
    if (_token != null && _token != rejected) return _token!;
    _token = null;
    return _ask();
  }

  Future<String> _ask() =>
      _asking ??= _doAsk().whenComplete(() => _asking = null);

  Future<String> _doAsk() async {
    final r = await _native.accountToken(account);
    final t = r.token;
    if (t != null) {
      _token = t;
      _expiresAt = r.expiresAt ?? _clock().add(const Duration(minutes: 10));
      return t;
    }
    if (r.error == 'network') throw NetworkException(r.message ?? 'network');
    onEnded?.call();
    throw SessionEndedException(
      'account: ${r.error} ${r.message ?? ''}'.trim(),
    );
  }
}
