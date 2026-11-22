/// App login on RustCloud: OAuth 2.0 authorization code with PKCE
/// (rustcloud/docs/api/auth.md, "Вход приложений"), and the token sources the
/// API client asks for a Bearer token. Plain Dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'models.dart';

/// Where the browser returns after the user allows the device.
const redirectUri = 'com.rustcloud.photos:/callback';
const callbackScheme = 'com.rustcloud.photos';

/// The app's name on the server's consent page and in the list of sessions.
const clientId = 'rc-photo-client';

/// A PKCE pair: the app keeps [verifier], the server gets [challenge].
class Pkce {
  Pkce(this.verifier)
    : challenge = base64Url
          .encode(sha256.convert(ascii.encode(verifier)).bytes)
          .replaceAll('=', '');

  factory Pkce.generate([Random? random]) => Pkce(randomToken(48, random));

  final String verifier;
  final String challenge;
}

/// URL-safe random text of [bytes] random bytes (no padding).
String randomToken(int bytes, [Random? random]) {
  final r = random ?? Random.secure();
  return base64Url
      .encode(List<int>.generate(bytes, (_) => r.nextInt(256)))
      .replaceAll('=', '');
}

/// The page the browser opens to log in and allow this device.
Uri authorizeUri(
  Uri server, {
  required Pkce pkce,
  required String state,
  required String deviceName,
}) => server
    .resolve('/api/v1/auth/authorize')
    .replace(
      queryParameters: {
        'client_id': clientId,
        'device_name': deviceName,
        'redirect_uri': redirectUri,
        'code_challenge': pkce.challenge,
        'code_challenge_method': 'S256',
        'state': state,
      },
    );

/// The code from the browser's return to [redirectUri]; throws if the user
/// refused, or the state is not ours (another login, or a forged return).
String codeFromCallback(Uri callback, String state) {
  final q = callback.queryParameters;
  if (q['state'] != state) {
    throw const ApiException(0, 'STATE_MISMATCH', 'Login answer is not ours');
  }
  final error = q['error'];
  if (error != null) {
    throw ApiException(0, error, q['error_description'] ?? '');
  }
  final code = q['code'];
  if (code == null || code.isEmpty) {
    throw const ApiException(0, 'NO_CODE', 'Login answer has no code');
  }
  return code;
}

/// A pair from `/api/v1/auth/token`.
class OAuthTokens {
  const OAuthTokens({
    required this.access,
    required this.refresh,
    required this.accessExpiresAt,
  });

  factory OAuthTokens.fromTokenResponse(Map<String, dynamic> j, DateTime now) =>
      OAuthTokens(
        access: j['access_token'] as String,
        refresh: j['refresh_token'] as String,
        accessExpiresAt: now.add(
          Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 600),
        ),
      );

  factory OAuthTokens.fromJson(Map<String, dynamic> j) => OAuthTokens(
    access: j['access'] as String,
    refresh: j['refresh'] as String,
    accessExpiresAt: DateTime.parse(j['accessExpiresAt'] as String),
  );

  final String access;
  final String refresh;
  final DateTime accessExpiresAt;

  Map<String, dynamic> toJson() => {
    'access': access,
    'refresh': refresh,
    'accessExpiresAt': accessExpiresAt.toUtc().toIso8601String(),
  };
}

/// Where the tokens of a browser login are kept between runs (the Android
/// Keystore in the app, memory in tests).
abstract class TokenStore {
  Future<OAuthTokens?> read();
  Future<void> write(OAuthTokens tokens);
  Future<void> clear();
}

class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([this.tokens]);

  OAuthTokens? tokens;

  @override
  Future<OAuthTokens?> read() async => tokens;

  @override
  Future<void> write(OAuthTokens t) async => tokens = t;

  @override
  Future<void> clear() async => tokens = null;
}

/// What the API client asks for a Bearer token.
abstract class TokenSource {
  /// A token that should still work.
  Future<String> token();

  /// [rejected] got a 401: a new token, or [SessionEndedException] when the
  /// user must log in again.
  Future<String> renew(String rejected);
}

/// The session is over (logged out elsewhere, expired, revoked): log in again.
class SessionEndedException implements Exception {
  const SessionEndedException(this.reason);

  final String reason;

  @override
  String toString() => 'SessionEndedException($reason)';
}

/// The server could not be reached; the request may be retried later.
class NetworkException implements Exception {
  const NetworkException(this.message, {this.untrustedCertificate = false});

  /// A failed request as the app tells it: the server's certificate is not
  /// trusted (a CA the device doesn't know), or the network.
  factory NetworkException.from(DioException e) {
    final inner = e.error;
    if (inner is HandshakeException &&
        '$inner'.contains('CERTIFICATE_VERIFY_FAILED')) {
      return NetworkException(
        inner.osError?.message ?? inner.message,
        untrustedCertificate: true,
      );
    }
    return NetworkException(e.message ?? e.type.name);
  }

  final String message;

  /// TLS failed: retrying won't help until the CA is installed on the device.
  final bool untrustedCertificate;

  @override
  String toString() =>
      'NetworkException(${untrustedCertificate ? 'certificate: ' : ''}$message)';
}

/// The token endpoint, without a session.
class OAuthClient {
  OAuthClient(Uri server, {Dio? dio, DateTime Function()? clock})
    : _dio = dio ?? Dio(),
      _token = server.resolve('/api/v1/auth/token').toString(),
      _clock = clock ?? DateTime.now;

  final Dio _dio;
  final String _token;
  final DateTime Function() _clock;

  Future<OAuthTokens> exchangeCode(String code, Pkce pkce) => _post({
    'grant_type': 'authorization_code',
    'code': code,
    'code_verifier': pkce.verifier,
    'redirect_uri': redirectUri,
  });

  Future<OAuthTokens> refresh(String refreshToken) =>
      _post({'grant_type': 'refresh_token', 'refresh_token': refreshToken});

  Future<OAuthTokens> _post(Map<String, String> form) async {
    final Response<dynamic> r;
    try {
      r = await _dio.post<dynamic>(
        _token,
        data: form,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          validateStatus: (_) => true,
          responseType: ResponseType.json,
        ),
      );
    } on DioException catch (e) {
      throw NetworkException.from(e);
    }
    final body = r.data;
    if (r.statusCode == 200 && body is Map<String, dynamic>) {
      return OAuthTokens.fromTokenResponse(body, _clock());
    }
    throw ApiException.fromBody(r.statusCode ?? 0, body);
  }
}

/// Tokens of a browser login: refreshes them, one refresh at a time for the
/// whole app.
///
/// The server rotates the refresh token on every exchange and ends the session
/// if an old one comes back more than 30 s later. So the new pair is stored
/// before anyone uses it, and a refresh whose answer was lost is retried
/// right away with the same token (inside those 30 s) rather than later.
class OAuthSession implements TokenSource {
  OAuthSession(
    this._client,
    this._store,
    OAuthTokens tokens, {
    DateTime Function()? clock,
    this.retryDelay = const Duration(seconds: 2),
  }) : _tokens = tokens,
       _clock = clock ?? DateTime.now;

  final OAuthClient _client;
  final TokenStore _store;
  final DateTime Function() _clock;

  /// Pause between retries of a refresh whose answer was lost.
  final Duration retryDelay;

  /// Called once when the session turns out to be over.
  void Function()? onEnded;

  OAuthTokens _tokens;
  Future<OAuthTokens>? _refreshing;
  bool _ended = false;

  OAuthTokens get tokens => _tokens;

  static const _margin = Duration(seconds: 30);

  @override
  Future<String> token() async {
    if (_ended) throw const SessionEndedException('logged out');
    if (_clock().isBefore(_tokens.accessExpiresAt.subtract(_margin))) {
      return _tokens.access;
    }
    return (await _refresh()).access;
  }

  @override
  Future<String> renew(String rejected) async {
    if (_ended) throw const SessionEndedException('logged out');
    // Someone else already got a new pair while this request was out.
    if (_tokens.access != rejected) return _tokens.access;
    return (await _refresh()).access;
  }

  Future<OAuthTokens> _refresh() =>
      _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<OAuthTokens> _doRefresh() async {
    final old = _tokens.refresh;
    final started = _clock();
    while (true) {
      try {
        final fresh = await _client.refresh(old);
        await _store.write(fresh);
        _tokens = fresh;
        return fresh;
      } on NetworkException {
        // Retry with the same token while the server still forgives a repeat
        // (30 s). Past that, give up for now: if the server did get the lost
        // request, the next try ends the session and the user logs in again —
        // there is no way to recover a rotated token whose answer was lost.
        if (_clock().difference(started) > const Duration(seconds: 20)) {
          rethrow;
        }
        await Future<void>.delayed(retryDelay);
      } on ApiException catch (e) {
        if (e.code == 'invalid_grant') {
          await _end('refresh refused: ${e.message}');
        }
        rethrow;
      }
    }
  }

  Future<void> _end(String reason) async {
    if (_ended) return;
    _ended = true;
    await _store.clear();
    onEnded?.call();
    throw SessionEndedException(reason);
  }
}

/// A token that was handed over as is (tests, scripts): no renewal.
class StaticTokenSource implements TokenSource {
  const StaticTokenSource(this._token);

  final String _token;

  @override
  Future<String> token() async => _token;

  @override
  Future<String> renew(String rejected) async =>
      throw const SessionEndedException('static token rejected');
}
