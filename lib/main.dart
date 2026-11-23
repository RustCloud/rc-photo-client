import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auth/controller.dart';
import 'auth/native.dart';
import 'auth/session_store.dart';
import 'backup/services.dart';
import 'backup/worker.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = SessionStore();
  final backup = BackupServices.android();
  final auth = AuthController(native: const AndroidBridge(), store: store);
  // Logged out: no more runs, and what the backup and the timeline kept goes
  // with the login.
  auth.onLoggedOut.add(() async {
    await backup.scheduler.stop();
    await (await backup.store).clear();
    await (await backup.index).clear();
  });
  runApp(RcPhotoApp(auth: auth, backup: backup));
  await auth.start();
  // Re-arms the runs after an update or a reboot of WorkManager's state.
  if (auth.session != null) {
    final settings = await store.readBackup();
    if (settings != null) await backup.scheduler.apply(settings);
  }
}

/// A backup run, started by BackupWorker (Backup.kt) in an engine without a
/// screen. Tells the worker how it ended.
@pragma('vm:entry-point')
Future<void> backupMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const host = MethodChannel('com.rustcloud.photos/worker');
  var result = 'failed';
  try {
    result = (await runBackup()).name;
  } catch (e) {
    debugPrint('backup run failed: $e');
  }
  await host.invokeMethod('finish', result);
}
