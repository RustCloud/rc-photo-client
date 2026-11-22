import 'package:flutter/services.dart';

/// A reply of rc-client's phone account: a token, or why there is none.
class AccountToken {
  const AccountToken({
    this.token,
    this.server,
    this.expiresAt,
    this.error,
    this.message,
  });

  factory AccountToken.fromMap(Map<Object?, Object?> m) => AccountToken(
    token: m['token'] as String?,
    server: m['server'] as String?,
    expiresAt: switch (m['expiresAt']) {
      final int ms when ms > 0 => DateTime.fromMillisecondsSinceEpoch(ms),
      _ => null,
    },
    error: m['error'] as String?,
    message: m['message'] as String?,
  );

  final String? token;

  /// The account's server, `https://cloud.example.com/`.
  final String? server;
  final DateTime? expiresAt;

  /// `network`, `login` (the client is logged out), `cancelled` (the user
  /// refused or closed the client's screen), `failed`.
  final String? error;
  final String? message;
}

/// The native side (MainActivity.kt). An interface, so tests and other
/// platforms can stand in.
abstract class NativeBridge {
  /// Opens [url] in a browser tab; the URI it returned to, or null if the
  /// user came back without finishing.
  Future<Uri?> browserLogin(Uri url);

  /// RustCloud accounts on the phone this app may see.
  Future<List<String>> accounts();

  /// The system's account picker; the chosen account or null.
  Future<String?> chooseAccount();

  Future<AccountToken> accountToken(String account);

  Future<String> deviceName();

  /// CA certificates the user installed on the device (DER), to trust them
  /// as the system's own (lib/api/trust.dart).
  Future<List<Uint8List>> userCertificates();
}

class AndroidBridge implements NativeBridge {
  const AndroidBridge();

  static const _ch = MethodChannel('com.rustcloud.photos/native');

  @override
  Future<Uri?> browserLogin(Uri url) async {
    final r = await _ch.invokeMethod<String>('browserLogin', {
      'url': url.toString(),
    });
    return r == null ? null : Uri.parse(r);
  }

  @override
  Future<List<String>> accounts() async =>
      (await _ch.invokeListMethod<String>('accounts')) ?? const [];

  @override
  Future<String?> chooseAccount() => _ch.invokeMethod<String>('chooseAccount');

  @override
  Future<AccountToken> accountToken(String account) async =>
      AccountToken.fromMap(
        (await _ch.invokeMapMethod<Object?, Object?>('accountToken', {
          'name': account,
        }))!,
      );

  @override
  Future<String> deviceName() async =>
      (await _ch.invokeMethod<String>('deviceName')) ?? 'Android';

  @override
  Future<List<Uint8List>> userCertificates() async =>
      (await _ch.invokeListMethod<Uint8List>('userCertificates')) ?? const [];
}
