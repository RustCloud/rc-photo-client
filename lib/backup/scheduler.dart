import 'package:flutter/services.dart';

import 'settings.dart';

/// When the backup runs (Backup.kt, WorkManager); an interface for tests.
abstract class BackupScheduler {
  /// Every 15 minutes and after new photos, under the settings' conditions;
  /// stops it when off or not set up.
  Future<void> apply(BackupSettings s);

  /// A run right away.
  Future<void> syncNow();

  /// No more runs (logout).
  Future<void> stop();
}

class AndroidBackupScheduler implements BackupScheduler {
  const AndroidBackupScheduler();

  static const _ch = MethodChannel('com.rustcloud.photos/backup');

  @override
  Future<void> apply(BackupSettings s) => _ch.invokeMethod('schedule', {
    'enabled': s.enabled && s.ready,
    'wifiOnly': s.wifiOnly,
    'charging': s.chargingOnly,
  });

  @override
  Future<void> syncNow() => _ch.invokeMethod('syncNow');

  @override
  Future<void> stop() => _ch.invokeMethod('schedule', {'enabled': false});
}
