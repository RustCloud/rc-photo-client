import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../backup/scheduler.dart';
import '../backup/store.dart';
import '../l10n/app_localizations.dart';

/// What the backup is doing: the file being copied, counts, the log, and the
/// files that failed (with why, and "retry"). Read from the backup's store
/// every second: the worker writes it from its own engine.
class BackupStatusScreen extends StatefulWidget {
  const BackupStatusScreen({
    super.key,
    required this.store,
    required this.scheduler,
    this.refresh = const Duration(seconds: 1),
  });

  final BackupStore store;
  final BackupScheduler scheduler;
  final Duration refresh;

  @override
  State<BackupStatusScreen> createState() => _BackupStatusScreenState();
}

class _BackupStatusScreenState extends State<BackupStatusScreen> {
  Timer? _timer;
  RunStatus _status = const RunStatus();
  Counts _counts = const {};
  List<MediaRow> _problems = const [];
  List<LogEntry> _log = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _read();
    _timer = Timer.periodic(widget.refresh, (_) => _read());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    final s = widget.store;
    final status = await s.status();
    final counts = await s.counts();
    final problems = await s.problems();
    final log = await s.logs();
    if (!mounted) return;
    setState(() {
      _status = status;
      _counts = counts;
      _problems = problems;
      _log = log;
      _loaded = true;
    });
  }

  Future<void> _syncNow() async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await widget.scheduler.syncNow();
    messenger.showSnackBar(SnackBar(content: Text(l.backupSyncStarted)));
  }

  Future<void> _retry({int? id}) async {
    await widget.store.retry(id: id);
    await widget.scheduler.syncNow();
    await _read();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.statusTitle),
          actions: [
            IconButton(
              key: const Key('sync-now'),
              tooltip: l.backupSyncNow,
              icon: const Icon(Icons.sync),
              onPressed: _syncNow,
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: l.statusLog),
              Tab(
                key: const Key('tab-problems'),
                text: _problems.isEmpty
                    ? l.statusProblems
                    : '${l.statusProblems} (${_problems.length})',
              ),
            ],
          ),
        ),
        body: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  _Summary(status: _status, counts: _counts),
                  const Divider(height: 1),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _LogList(entries: _log),
                        _Problems(rows: _problems, onRetry: _retry),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.status, required this.counts});

  final RunStatus status;
  final Counts counts;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final s = status;
    final last = s.lastRun;
    final when = last == null
        ? l.statusNever
        : l.statusLastRun(
            DateFormat.MMMd(
              Localizations.localeOf(context).toLanguageTag(),
            ).add_Hm().format(last),
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (s.running) ...[
            Text(
              l.statusRunning(s.name),
              style: theme.textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(l.statusProgress(s.done + 1, s.total)),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: s.size > 0 && s.sent > 0 ? s.sent / s.size : null,
            ),
          ] else ...[
            Text(l.statusIdle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(when, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Count(l.statusCopied, counts[MediaState.done] ?? 0),
              _Count(
                l.statusWaiting,
                (counts[MediaState.pending] ?? 0) +
                    (counts[MediaState.uploading] ?? 0),
              ),
              _Count(l.statusInCloud, counts[MediaState.skipped] ?? 0),
              _Count(
                l.statusFailed,
                counts[MediaState.failed] ?? 0,
                error: (counts[MediaState.failed] ?? 0) > 0,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.label, this.n, {this.error = false});

  final String label;
  final int n;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Chip(
      label: Text('$label: $n'),
      backgroundColor: error ? scheme.errorContainer : null,
      labelStyle: error ? TextStyle(color: scheme.onErrorContainer) : null,
      visualDensity: VisualDensity.compact,
    );
  }
}

/// A log line in the user's language.
String logText(AppLocalizations l, LogEntry e) => switch (e.kind) {
  LogKind.started => l.logStarted(e.detail),
  LogKind.finished => l.logFinished(e.detail),
  LogKind.uploaded => l.logUploaded,
  LogKind.skipped => l.logSkipped,
  LogKind.failed => l.logFailed(e.detail),
  LogKind.network => l.logNetwork,
  LogKind.waitWifi => l.logWaitWifi(e.detail),
  LogKind.deleted => l.logDeleted,
  LogKind.quota => l.logQuota(e.detail),
  LogKind.noAccess => l.logNoAccess,
  LogKind.noLogin => l.logNoLogin,
  LogKind.folders => l.logFolders,
  LogKind.later => l.logLater,
  LogKind.error => l.logError(e.detail),
};

/// Why a file failed or waits, in the user's language.
String failText(AppLocalizations l, MediaRow r) => switch (r.failKind) {
  FailKind.network => l.failNetwork,
  FailKind.wifi => l.failWifi,
  FailKind.quota => l.failQuota,
  FailKind.tooLarge => l.failTooLarge,
  FailKind.file => l.failFile(r.error ?? ''),
  FailKind.server || null => l.failServer(r.error ?? ''),
};

class _LogList extends StatelessWidget {
  const _LogList({required this.entries});

  final List<LogEntry> entries;

  static IconData _icon(LogKind k) => switch (k) {
    LogKind.uploaded => Icons.cloud_done_outlined,
    LogKind.skipped => Icons.cloud_outlined,
    LogKind.deleted => Icons.delete_outline,
    LogKind.started || LogKind.finished => Icons.sync,
    LogKind.network || LogKind.waitWifi || LogKind.later => Icons.wifi_off,
    _ => Icons.error_outline,
  };

  static bool _bad(LogKind k) => switch (k) {
    LogKind.failed ||
    LogKind.quota ||
    LogKind.noAccess ||
    LogKind.noLogin ||
    LogKind.error => true,
    _ => false,
  };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    if (entries.isEmpty) return Center(child: Text(l.statusEmptyLog));
    final time = DateFormat.MMMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).add_Hms();
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        final text = logText(l, e);
        return ListTile(
          dense: true,
          leading: Icon(
            _icon(e.kind),
            color: _bad(e.kind) ? scheme.error : scheme.outline,
          ),
          title: Text(e.name.isEmpty ? text : e.name),
          subtitle: Text(
            e.name.isEmpty ? time.format(e.at) : '$text · ${time.format(e.at)}',
          ),
        );
      },
    );
  }
}

class _Problems extends StatelessWidget {
  const _Problems({required this.rows, required this.onRetry});

  final List<MediaRow> rows;
  final Future<void> Function({int? id}) onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (rows.isEmpty) return Center(child: Text(l.statusNoProblems));
    final failed = rows.any((r) => r.state == MediaState.failed);
    return Column(
      children: [
        if (failed)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextButton.icon(
                key: const Key('retry-all'),
                onPressed: () => onRetry(),
                icon: const Icon(Icons.refresh),
                label: Text(l.statusRetryAll),
              ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final r = rows[i];
              return ListTile(
                leading: Icon(
                  r.state == MediaState.failed
                      ? Icons.error_outline
                      : Icons.schedule,
                  color: r.state == MediaState.failed
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
                title: Text(r.name),
                subtitle: Text(failText(l, r)),
                trailing: r.state == MediaState.failed
                    ? IconButton(
                        tooltip: l.statusRetry,
                        icon: const Icon(Icons.refresh),
                        onPressed: () => onRetry(id: r.id),
                      )
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }
}
