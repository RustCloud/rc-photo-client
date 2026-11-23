import '../gallery/index_store.dart';
import 'phone_media.dart';
import 'scheduler.dart';
import 'store.dart';

/// What the backup and the timeline need from the phone, together; fakes in
/// tests.
class BackupServices {
  BackupServices({
    required this.media,
    required this.scheduler,
    required Future<BackupStore> Function() openStore,
    Future<IndexStore> Function()? openIndex,
  }) : _open = openStore,
       _openIndex = openIndex ?? (() async => MemoryIndexStore());

  /// The real ones: Android's media, WorkManager, SQLite.
  factory BackupServices.android() => BackupServices(
    media: const AndroidPhoneMedia(),
    scheduler: const AndroidBackupScheduler(),
    openStore: SqliteBackupStore.open,
    openIndex: SqliteIndexStore.open,
  );

  final PhoneMedia media;
  final BackupScheduler scheduler;
  final Future<BackupStore> Function() _open;
  final Future<IndexStore> Function() _openIndex;
  Future<BackupStore>? _store;
  Future<IndexStore>? _index;

  /// Opened once, on first use.
  Future<BackupStore> get store => _store ??= _open();

  /// The cloud's gallery index kept on the phone; opened once.
  Future<IndexStore> get index => _index ??= _openIndex();
}
