import 'phone_media.dart';
import 'scheduler.dart';
import 'store.dart';

/// What the backup needs from the phone, together; fakes in tests.
class BackupServices {
  BackupServices({
    required this.media,
    required this.scheduler,
    required Future<BackupStore> Function() openStore,
  }) : _open = openStore;

  /// The real ones: Android's media, WorkManager, SQLite.
  factory BackupServices.android() => BackupServices(
    media: const AndroidPhoneMedia(),
    scheduler: const AndroidBackupScheduler(),
    openStore: SqliteBackupStore.open,
  );

  final PhoneMedia media;
  final BackupScheduler scheduler;
  final Future<BackupStore> Function() _open;
  Future<BackupStore>? _store;

  /// Opened once, on first use.
  Future<BackupStore> get store => _store ??= _open();
}
