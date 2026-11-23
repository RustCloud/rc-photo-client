import 'package:flutter/material.dart';

import '../api/auth.dart';
import '../api/models.dart';
import '../auth/controller.dart';
import '../auth/session_store.dart';
import '../backup/controller.dart';
import '../backup/phone_media.dart';
import '../backup/services.dart';
import '../gallery/cloud_index.dart';
import '../gallery/controller.dart';
import '../l10n/app_localizations.dart';
import 'backup.dart';
import 'people.dart';
import 'stories.dart';
import 'timeline.dart';
import 'viewer.dart';

/// The main screen: three tabs at the bottom, as people know them from
/// gallery apps — the timeline, collections (favourites, people, folders,
/// stories) and search. The account button is at the top right.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.auth,
    required this.session,
    required this.backup,
  });

  final AuthController auth;
  final Session session;
  final BackupServices backup;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;
  late final GalleryController _gallery = GalleryController(
    client: widget.session.client,
    media: widget.backup.media,
    backupStore: widget.backup.store,
    readSettings: widget.auth.store.readBackup,
    cloud: CloudIndex(widget.backup.index),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _gallery
      ..load()
      ..resume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gallery.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // New photos taken meanwhile, or access changed in the settings.
        _gallery
          ..load()
          ..resume();
      case AppLifecycleState.paused:
        _gallery.pause();
      default:
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final body = switch (_tab) {
      0 => _PhotosTab(
        gallery: _gallery,
        media: widget.backup.media,
        onChooseAlbums: () => _openBackup(context),
      ),
      1 => CollectionsTab(gallery: _gallery, media: widget.backup.media),
      _ => const _SearchTab(),
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(l.appTitle),
        actions: [
          IconButton(
            key: const Key('backup'),
            tooltip: l.backupTitle,
            icon: const Icon(Icons.cloud_upload_outlined),
            onPressed: () => _openBackup(context),
          ),
          IconButton(
            key: const Key('account'),
            tooltip: l.account,
            icon: CircleAvatar(
              radius: 15,
              child: Text(_initial(widget.session.user.shownName)),
            ),
            onPressed: () => _showAccount(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.photo_outlined),
            selectedIcon: const Icon(Icons.photo),
            label: l.tabPhotos,
          ),
          NavigationDestination(
            icon: const Icon(Icons.photo_album_outlined),
            selectedIcon: const Icon(Icons.photo_album),
            label: l.tabCollections,
          ),
          NavigationDestination(
            icon: const Icon(Icons.search),
            label: l.tabSearch,
          ),
        ],
      ),
    );
  }

  static String _initial(String name) =>
      name.isEmpty ? '·' : name.characters.first.toUpperCase();

  void _openBackup(BuildContext context) {
    final controller = BackupController(
      client: widget.session.client,
      services: widget.backup,
      store: widget.auth.store,
    );
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => BackupScreen(controller: controller),
          ),
        )
        .whenComplete(() {
          controller.dispose();
          // Other folders may be chosen now.
          _gallery.load();
        });
  }

  void _showAccount(BuildContext context) {
    final l = AppLocalizations.of(context);
    final s = widget.session;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: CircleAvatar(child: Text(_initial(s.user.shownName))),
              title: Text(s.user.shownName.isEmpty ? '…' : s.user.shownName),
              subtitle: Text(s.login.server.host),
            ),
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: Text(switch (s.login) {
                AccountLogin(:final account) => l.loggedInViaAccount(account),
                BrowserLogin() => l.loggedInViaBrowser,
              }),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: Text(l.backupTitle),
              onTap: () {
                Navigator.pop(sheet);
                _openBackup(context);
              },
            ),
            const Divider(),
            ListTile(
              key: const Key('logout'),
              leading: const Icon(Icons.logout),
              title: Text(l.logout),
              onTap: () async {
                Navigator.pop(sheet);
                await widget.auth.logout();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The timeline of the phone's photos, with backup marks; what the cloud
/// knows (progress, problems) above it.
class _PhotosTab extends StatelessWidget {
  const _PhotosTab({
    required this.gallery,
    required this.media,
    required this.onChooseAlbums,
  });

  final GalleryController gallery;
  final PhoneMedia media;
  final VoidCallback onChooseAlbums;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: gallery,
      builder: (context, _) {
        switch (gallery.status) {
          case GalleryStatus.loading:
            return const Center(child: CircularProgressIndicator());
          case GalleryStatus.noAccess:
            return _Message(
              icon: Icons.no_photography_outlined,
              title: l.galleryNoAccessTitle,
              body: l.galleryNoAccessBody,
              action: FilledButton(
                key: const Key('grant-access'),
                onPressed: gallery.requestAccess,
                child: Text(l.galleryGrantAccess),
              ),
            );
          case GalleryStatus.noAlbums:
            return _Message(
              icon: Icons.photo_library_outlined,
              title: l.galleryNoAlbumsTitle,
              body: l.galleryNoAlbumsBody,
              action: FilledButton(
                key: const Key('choose-albums'),
                onPressed: onChooseAlbums,
                child: Text(l.galleryChooseAlbums),
              ),
            );
          case GalleryStatus.ready:
            final items = gallery.items;
            if (items.isEmpty) {
              return RefreshIndicator(
                onRefresh: gallery.refresh,
                child: LayoutBuilder(
                  builder: (context, box) => SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: SizedBox(
                      height: box.maxHeight,
                      child: _Message(
                        icon: Icons.photo_outlined,
                        title: l.photosEmptyTitle,
                        body: l.galleryEmptyBody,
                      ),
                    ),
                  ),
                ),
              );
            }
            return TimelineGrid(
              items: items,
              media: media,
              onRefresh: gallery.refresh,
              header: _cloudBanner(context, l),
              top: gallery.stories.isEmpty
                  ? null
                  : StoriesRow(
                      gallery: gallery,
                      media: media,
                      stories: gallery.stories,
                    ),
              topHeight: StoriesRow.height,
              onOpen: (i) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ViewerScreen(
                    items: items,
                    initial: i,
                    media: media,
                    albums: gallery.albums,
                  ),
                ),
              ),
            );
        }
      },
    );
  }

  Widget? _cloudBanner(BuildContext context, AppLocalizations l) {
    final e = gallery.cloudError;
    final String? text;
    var problem = true;
    if (e is ApiException && e.status == 404) {
      text = l.noPluginWarning;
    } else if (e is NetworkException && e.untrustedCertificate) {
      text = l.errorUntrustedCertificate;
    } else if (e != null) {
      text = l.galleryCloudOffline;
    } else if (gallery.cloudState.indexing > 0) {
      text = l.galleryCloudIndexing(gallery.cloudState.indexing);
      problem = false;
    } else {
      text = null;
    }
    if (text == null) return null;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const Key('cloud-banner'),
      color: problem ? scheme.errorContainer : scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              problem ? Icons.cloud_off_outlined : Icons.hourglass_empty,
              size: 18,
              color: problem
                  ? scheme.onErrorContainer
                  : scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: problem
                      ? scheme.onErrorContainer
                      : scheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 72, color: theme.colorScheme.primary),
          const SizedBox(height: 24),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(body, textAlign: TextAlign.center),
          if (action case final a?) ...[const SizedBox(height: 24), a],
        ],
      ),
    );
  }
}

class _SearchTab extends StatelessWidget {
  const _SearchTab();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          SearchBar(
            hintText: l.searchHint,
            leading: const Icon(Icons.search),
            enabled: false,
          ),
        ],
      ),
    );
  }
}
