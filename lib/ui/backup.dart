import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../backup/controller.dart';
import '../backup/phone_media.dart';
import '../l10n/app_localizations.dart';

/// Backup settings: where in the cloud (the gallery's folder, this phone's
/// folder in it) and which folders of the phone. Saving makes the folders.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.controller});

  final BackupController controller;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen>
    with WidgetsBindingObserver {
  BackupController get c => widget.controller;

  /// Android said no to the request: only its settings can change that.
  bool _refused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system settings.
    if (state == AppLifecycleState.resumed && !c.loading) c.refreshPhone();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(l.backupTitle)),
        body: c.loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  if (c.problem != null) _problem(l),
                  _Header(l.backupWhere),
                  ..._where(l),
                  _Header(l.backupPhoneFolders, hint: l.backupPhoneFoldersHint),
                  ..._phone(l),
                ],
              ),
        bottomNavigationBar: c.loading
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton.icon(
                    key: const Key('backup-save'),
                    onPressed: c.canSave ? _save : null,
                    icon: c.saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.create_new_folder_outlined),
                    label: Text(l.backupSave),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _problem(AppLocalizations l) {
    final theme = Theme.of(context);
    final text = switch (c.problem!) {
      BackupProblem.noPlugin => l.noPluginBody,
      BackupProblem.network => l.errorNetwork,
      BackupProblem.untrustedCertificate => l.errorUntrustedCertificate,
      BackupProblem.failed => l.backupFailed(c.problemDetail),
    };
    return Card(
      key: const Key('backup-problem'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          text,
          style: TextStyle(color: theme.colorScheme.onErrorContainer),
        ),
      ),
    );
  }

  List<Widget> _where(AppLocalizations l) => [
    if (c.folders.isEmpty && c.problem != BackupProblem.noPlugin)
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(l.backupNoGalleryFolders),
      ),
    ListTile(
      key: const Key('backup-root'),
      leading: const Icon(Icons.photo_library_outlined),
      title: Text(l.backupGalleryFolder),
      subtitle: Text(c.root?.name ?? l.backupGalleryFolderNone),
      trailing: const Icon(Icons.chevron_right),
      enabled: !c.saving && c.problem != BackupProblem.noPlugin,
      onTap: _chooseRoot,
    ),
    ListTile(
      key: const Key('backup-device'),
      leading: const Icon(Icons.smartphone_outlined),
      title: Text(l.backupDeviceFolder),
      subtitle: Text('${c.root?.name ?? '…'} / ${c.device}'),
      trailing: const Icon(Icons.edit_outlined),
      enabled: !c.saving,
      onTap: _editDevice,
    ),
  ];

  List<Widget> _phone(AppLocalizations l) {
    if (c.access == MediaAccess.none) {
      return [
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.backupAccessTitle,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(_refused ? l.backupAccessDenied : l.backupAccessBody),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonal(
                    key: const Key('backup-access'),
                    onPressed: _refused ? c.media.openSettings : _askAccess,
                    child: Text(
                      _refused ? l.backupAccessSettings : l.backupAccessAllow,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    return [
      if (c.access == MediaAccess.partial)
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(l.backupPartial),
          trailing: TextButton(
            onPressed: _askAccess,
            child: Text(l.backupPartialChange),
          ),
        ),
      if (c.albums.isEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(l.backupNoAlbums),
        ),
      for (final a in c.albums)
        CheckboxListTile(
          key: Key('album-${a.id}'),
          value: c.chosen.contains(a.id),
          onChanged: c.saving ? null : (_) => c.toggle(a.id),
          secondary: _Cover(media: c.media, uri: a.cover),
          title: Text(a.name),
          subtitle: Text(
            c.chosen.contains(a.id)
                ? '${l.backupAlbumCount(a.count)} → ${c.cloudPath(a.id)}'
                : [
                    l.backupAlbumCount(a.count),
                    if (a.path.isNotEmpty) a.path,
                  ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
  }

  Future<void> _askAccess() async {
    final ok = await c.requestAccess();
    if (mounted) setState(() => _refused = !ok);
  }

  Future<void> _chooseRoot() async {
    final l = AppLocalizations.of(context);
    final defaultName = l.backupDefaultRootName;
    final picked = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in c.folders)
              ListTile(
                leading: Icon(
                  f.id == c.root?.id ? Icons.check : Icons.folder_outlined,
                ),
                title: Text(f.name),
                onTap: () => Navigator.pop(sheet, f),
              ),
            if (!c.folders.any((f) => f.name == defaultName))
              ListTile(
                key: const Key('backup-create-root'),
                leading: const Icon(Icons.create_new_folder_outlined),
                title: Text(l.backupCreateFolder(defaultName)),
                onTap: () => Navigator.pop(sheet, defaultName),
              ),
          ],
        ),
      ),
    );
    switch (picked) {
      case final String name:
        await c.createRoot(name);
      case final PhotoFolder f:
        c.setRoot(f);
    }
  }

  Future<void> _editDevice() async {
    final l = AppLocalizations.of(context);
    final field = TextEditingController(text: c.device);
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.backupDeviceFolder),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.backupDeviceFolderHint),
            const SizedBox(height: 12),
            TextField(
              key: const Key('backup-device-name'),
              controller: field,
              autofocus: true,
              onSubmitted: (v) => Navigator.pop(dialog, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, field.text),
            child: Text(l.done),
          ),
        ],
      ),
    );
    field.dispose();
    if (name != null && name.trim().isNotEmpty) c.setDevice(name);
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (await c.save()) {
      messenger.showSnackBar(SnackBar(content: Text(l.backupSaved)));
    }
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text, {this.hint});

  final String text;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// The album's newest photo, small.
class _Cover extends StatefulWidget {
  const _Cover({required this.media, required this.uri});

  final PhoneMedia media;
  final String? uri;

  @override
  State<_Cover> createState() => _CoverState();
}

class _CoverState extends State<_Cover> {
  late final Future<Uint8List?> _bytes = widget.uri == null
      ? Future.value(null)
      : widget.media.thumbnail(widget.uri!, size: 160).catchError((_) => null);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox.square(
        dimension: 52,
        child: FutureBuilder(
          future: _bytes,
          builder: (context, snap) => snap.data == null
              ? ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(Icons.photo_outlined, color: scheme.outline),
                )
              : Image.memory(snap.data!, fit: BoxFit.cover),
        ),
      ),
    );
  }
}
