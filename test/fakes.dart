import 'package:rc_photo/api/auth.dart';
import 'package:rc_photo/auth/native.dart';
import 'package:rc_photo/auth/session_store.dart';

/// The native side, scripted.
class FakeBridge implements NativeBridge {
  FakeBridge({this.phoneAccounts = const [], this.token, this.browserReturn});

  /// What `accounts` answers.
  List<String> phoneAccounts;

  @override
  Future<List<String>> accounts() async => phoneAccounts;

  /// What `accountToken` answers.
  AccountToken? token;
  int tokenCalls = 0;

  /// What the browser returns to, given the authorize URL; null = closed.
  Uri? Function(Uri authorize)? browserReturn;
  Uri? lastAuthorize;

  @override
  Future<Uri?> browserLogin(Uri url) async {
    lastAuthorize = url;
    return browserReturn?.call(url);
  }

  @override
  Future<String?> chooseAccount() async => null;

  @override
  Future<AccountToken> accountToken(String account) async {
    tokenCalls++;
    return token ?? const AccountToken(error: 'failed');
  }

  @override
  Future<String> deviceName() async => 'Test phone';
}

/// [SessionStore] in memory.
class MemorySessionStore implements SessionStore {
  SavedLogin? login;
  final MemoryTokenStore _tokens = MemoryTokenStore();

  @override
  Future<SavedLogin?> readLogin() async => login;

  @override
  Future<void> writeLogin(SavedLogin l) async => login = l;

  @override
  Future<void> clear() async {
    login = null;
    await _tokens.clear();
  }

  @override
  TokenStore get tokens => _tokens;
}
