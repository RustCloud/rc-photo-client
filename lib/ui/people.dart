import 'package:flutter/material.dart';

import '../backup/phone_media.dart';
import '../gallery/controller.dart';
import '../gallery/people_stories.dart';
import '../l10n/app_localizations.dart';
import 'faces.dart';
import 'timeline.dart';
import 'viewer.dart';

/// Collections: for now the people the plugin found on the server, with
/// their photos on the phone.
class CollectionsTab extends StatelessWidget {
  const CollectionsTab({super.key, required this.gallery, required this.media});

  final GalleryController gallery;
  final PhoneMedia media;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: gallery,
      builder: (context, _) {
        final people = gallery.people;
        final state = gallery.cloudState;
        final Widget section;
        if (people.isNotEmpty) {
          section = Wrap(
            spacing: 8,
            runSpacing: 16,
            children: [
              for (final p in people)
                _PersonTile(
                  person: p,
                  media: media,
                  onTap: () => openPerson(context, gallery, media, p.id),
                ),
            ],
          );
        } else if (!state.facesEnabled && gallery.cloudError == null) {
          section = _Note(
            text: l.facesOff,
            action: FilledButton.tonal(
              key: const Key('faces-on'),
              onPressed: () => _turnFacesOn(context),
              child: Text(l.facesTurnOn),
            ),
          );
        } else {
          section = _Note(text: l.peopleEmpty);
        }
        return RefreshIndicator(
          onRefresh: gallery.refresh,
          child: ListView(
            padding: const EdgeInsets.all(16),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              Text(l.people, style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              section,
            ],
          ),
        );
      },
    );
  }

  Future<void> _turnFacesOn(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(l.facesTurnOnTitle),
        content: Text(l.facesTurnOnBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            key: const Key('faces-on-confirm'),
            onPressed: () => Navigator.pop(d, true),
            child: Text(l.facesTurnOn),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await gallery.turnFacesOn();
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

void openPerson(
  BuildContext context,
  GalleryController gallery,
  PhoneMedia media,
  String id,
) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PersonScreen(gallery: gallery, media: media, id: id),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(text, style: Theme.of(context).textTheme.bodyMedium),
      if (action case final a?) ...[const SizedBox(height: 12), a],
    ],
  );
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({
    required this.person,
    required this.media,
    required this.onTap,
  });

  final PersonView person;
  final PhoneMedia media;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return InkWell(
      key: Key('person-${person.id}'),
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: SizedBox(
        width: 88,
        child: Column(
          children: [
            const SizedBox(height: 4),
            FaceAvatar(person: person, media: media),
            const SizedBox(height: 6),
            Text(
              personLabel(l, person.id, person.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: person.name == null
                  ? theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    )
                  : theme.textTheme.bodySmall,
            ),
            Text(
              '${person.items.length}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A person's photos on the phone; rename or hide them (kept by the plugin).
class PersonScreen extends StatelessWidget {
  const PersonScreen({
    super.key,
    required this.gallery,
    required this.media,
    required this.id,
  });

  final GalleryController gallery;
  final PhoneMedia media;
  final String id;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: gallery,
      builder: (context, _) {
        final p = gallery.person(id);
        return Scaffold(
          appBar: AppBar(
            title: Text(p == null ? '' : personLabel(l, p.id, p.name)),
            actions: [
              if (p != null)
                IconButton(
                  key: const Key('rename'),
                  tooltip: l.personRename,
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _rename(context, p),
                ),
              if (p != null)
                PopupMenuButton<String>(
                  onSelected: (_) => _hide(context, p),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'hide', child: Text(l.personHide)),
                  ],
                ),
            ],
          ),
          body: p == null
              ? const SizedBox.shrink()
              : TimelineGrid(
                  items: p.items,
                  media: media,
                  onRefresh: gallery.refresh,
                  onOpen: (i) => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ViewerScreen(
                        items: p.items,
                        initial: i,
                        media: media,
                        albums: gallery.albums,
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }

  Future<void> _rename(BuildContext context, PersonView p) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(initial: p.name ?? ''),
    );
    if (name == null) return;
    try {
      await gallery.renamePerson(p.id, name.trim());
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _hide(BuildContext context, PersonView p) async {
    final l = AppLocalizations.of(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await gallery.hidePerson(p.id);
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(l.personHidden)));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

/// Asks for a person's name; owns its text field, which lives as long as
/// the dialog's closing animation.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});

  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.personRename),
      content: TextField(
        key: const Key('person-name'),
        controller: _text,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(hintText: l.personNameHint),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          key: const Key('person-save'),
          onPressed: () => Navigator.pop(context, _text.text),
          child: Text(l.done),
        ),
      ],
    );
  }
}
