import 'dart:ui';

import 'package:flutter/services.dart';

import '../auth/controller.dart';
import '../auth/native.dart';
import '../auth/session_store.dart';
import '../l10n/app_localizations.dart';
import 'engine.dart';
import 'phone_media.dart';
import 'store.dart';

/// A backup run in the worker's engine (Backup.kt): logs in from what is
/// saved, as the app does at start, and runs [BackupEngine]. The
/// notification speaks the phone's language.
Future<RunResult> runBackup() async {
  final store = SessionStore();
  final auth = AuthController(
    native: const AndroidBridge(),
    store: store,
    background: true,
  );
  await auth.start();
  final session = auth.session;
  if (session == null) return RunResult.noLogin;
  final settings = await store.readBackup();
  if (settings == null) return RunResult.off;
  final db = await SqliteBackupStore.open();
  const host = MethodChannel('com.rustcloud.photos/worker');
  final l = _strings();
  final engine = BackupEngine(
    client: session.client,
    media: const AndroidPhoneMedia(),
    store: db,
    settings: settings,
    saveSettings: store.writeBackup,
    onProgress: (done, total, name) {
      host.invokeMethod('progress', {
        'title': l.backupNotification(done + 1, total),
        'text': name,
      });
    },
  );
  try {
    return await engine.run();
  } catch (e) {
    // A fault of the app, not of a file: kept in the log for the user to see.
    await db.log(
      LogEntry(at: DateTime.now(), kind: LogKind.error, detail: '$e'),
    );
    await db.setStatus(RunStatus(lastRun: DateTime.now()));
    rethrow;
  }
}

AppLocalizations _strings() {
  final phone = PlatformDispatcher.instance.locale;
  final known = AppLocalizations.supportedLocales.any(
    (l) => l.languageCode == phone.languageCode,
  );
  return lookupAppLocalizations(
    known ? Locale(phone.languageCode) : const Locale('en'),
  );
}
