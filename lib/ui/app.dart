import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../auth/controller.dart';
import '../backup/services.dart';
import '../l10n/app_localizations.dart';
import 'connect.dart';
import 'home.dart';

/// The app: Material 3, light and dark from the system, Russian and English.
/// Shows the connect screen while logged out, the gallery after.
class RcPhotoApp extends StatelessWidget {
  const RcPhotoApp({
    super.key,
    required this.auth,
    required this.backup,
    this.locale,
  });

  final AuthController auth;

  /// The phone's photos, the backup's runs and store.
  final BackupServices backup;

  /// Forces a language (tests); null follows the phone.
  final Locale? locale;

  static const _seed = Color(0xFF3A6EA5);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(colorSchemeSeed: _seed, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: _seed,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: ListenableBuilder(
        listenable: auth,
        builder: (context, _) {
          if (auth.starting) return const Scaffold(body: SizedBox.shrink());
          final s = auth.session;
          return s == null
              ? ConnectScreen(auth: auth)
              : HomeScreen(auth: auth, session: s, backup: backup);
        },
      ),
    );
  }
}
