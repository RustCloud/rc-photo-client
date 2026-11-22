import 'package:flutter/material.dart';

import '../auth/controller.dart';
import '../l10n/app_localizations.dart';

/// The first screen: log in through rc-client's phone account if there is
/// one, or by the cloud's address and the browser.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.auth});

  final AuthController auth;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _address = TextEditingController();
  List<String> _accounts = const [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.auth.phoneAccounts().then((a) {
      if (mounted) setState(() => _accounts = a);
    });
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  String _problem(AppLocalizations l, LoginException e) => switch (e.problem) {
    LoginProblem.notRustCloud => l.errorNotRustCloud,
    LoginProblem.network => l.errorNetwork,
    LoginProblem.cancelled => l.errorCancelled,
    LoginProblem.failed => l.errorLoginFailed(e.detail),
  };

  Future<void> _run(Future<ServerCheck> Function() login) async {
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final check = await login();
      if (check == ServerCheck.noPlugin && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.noPluginWarning)));
      }
    } on LoginException catch (e) {
      if (mounted) setState(() => _error = _problem(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _browser() {
    final l = AppLocalizations.of(context);
    final server = AuthController.parseAddress(_address.text);
    if (server == null) {
      setState(() => _error = l.errorBadAddress);
      return;
    }
    _run(() => widget.auth.loginWithBrowser(server));
  }

  Future<void> _chooseAccount() async {
    final name = await widget.auth.native.chooseAccount();
    if (name != null) await _run(() => widget.auth.loginWithAccount(name));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.photo_library_outlined,
                    size: 72,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l.appTitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l.connectIntro,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 32),
                  for (final a in _accounts) ...[
                    FilledButton.tonalIcon(
                      onPressed: _busy
                          ? null
                          : () => _run(() => widget.auth.loginWithAccount(a)),
                      icon: const Icon(Icons.account_circle_outlined),
                      label: Text(l.continueAs(a)),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_accounts.isEmpty)
                    TextButton.icon(
                      onPressed: _busy ? null : _chooseAccount,
                      icon: const Icon(Icons.account_circle_outlined),
                      label: Text(l.useRcClientAccount),
                    ),
                  if (_accounts.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Expanded(child: Divider()),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(l.or, style: theme.textTheme.labelMedium),
                        ),
                        const Expanded(child: Divider()),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextField(
                    controller: _address,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _browser(),
                    decoration: InputDecoration(
                      labelText: l.serverAddress,
                      hintText: 'cloud.example.com',
                      prefixIcon: const Icon(Icons.cloud_outlined),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _busy ? null : _browser,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l.connect),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      key: const Key('connect-error'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
