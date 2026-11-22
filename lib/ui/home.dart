import 'package:flutter/material.dart';

import '../api/auth.dart';
import '../api/models.dart';
import '../auth/controller.dart';
import '../auth/session_store.dart';
import '../l10n/app_localizations.dart';

/// The main screen: three tabs at the bottom, as people know them from
/// gallery apps — the timeline, collections (favourites, people, folders,
/// stories) and search. The account button is at the top right.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.auth, required this.session});

  final AuthController auth;
  final Session session;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final body = switch (_tab) {
      0 => _PhotosTab(session: widget.session),
      1 => _Placeholder(
        icon: Icons.photo_album_outlined,
        text: l.collectionsEmpty,
      ),
      _ => const _SearchTab(),
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(l.appTitle),
        actions: [
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

/// Until the timeline (phase 3): what the plugin has, so a login can be
/// checked on the phone.
class _PhotosTab extends StatefulWidget {
  const _PhotosTab({required this.session});

  final Session session;

  @override
  State<_PhotosTab> createState() => _PhotosTabState();
}

class _PhotosTabState extends State<_PhotosTab> {
  late Future<(PhotoState, int)> _load = _fetch();

  Future<(PhotoState, int)> _fetch() async {
    final c = widget.session.client;
    final state = await c.photoState(today: DateTime.now());
    var count = 0;
    for (final link in state.shards) {
      count += (await c.shard(link)).entries?.length ?? 0;
    }
    return (state, count);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: () async {
        setState(() => _load = _fetch());
        await _load.catchError((_) => (const PhotoState.empty(), 0));
      },
      child: FutureBuilder(
        future: _load,
        builder: (context, snap) {
          final Widget child;
          if (snap.connectionState != ConnectionState.done) {
            child = const CircularProgressIndicator();
          } else if (snap.hasError) {
            final e = snap.error;
            final noPlugin = e is ApiException && e.status == 404;
            final untrusted = e is NetworkException && e.untrustedCertificate;
            child = _Message(
              icon: noPlugin
                  ? Icons.extension_off_outlined
                  : Icons.cloud_off_outlined,
              title: noPlugin ? l.noPluginTitle : l.errorNetwork,
              body: noPlugin
                  ? l.noPluginBody
                  : untrusted
                  ? l.errorUntrustedCertificate
                  : '$e',
            );
          } else {
            final (state, count) = snap.data!;
            child = _Message(
              icon: Icons.cloud_done_outlined,
              title: count == 0 ? l.photosEmptyTitle : l.photosInCloud(count),
              body: [
                if (state.folders.isNotEmpty)
                  l.photoFolders(state.folders.map((f) => f.name).join(', ')),
                if (state.indexing > 0) l.indexing(state.indexing),
                l.timelineSoon,
              ].join('\n'),
            );
          }
          // Scrollable, so pull-to-refresh works on a short page too.
          return LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight),
                child: Center(
                  child: DefaultTextStyle.merge(
                    style: theme.textTheme.bodyMedium,
                    child: child,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

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

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
