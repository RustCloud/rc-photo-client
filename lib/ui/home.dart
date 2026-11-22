import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// The main screen: three tabs at the bottom, as people know them from
/// gallery apps — the timeline, collections (favourites, people, folders,
/// stories) and search. The tabs are placeholders until the gallery phase.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final body = switch (_tab) {
      0 => const _PhotosTab(),
      1 => _Placeholder(
        icon: Icons.photo_album_outlined,
        text: l.collectionsEmpty,
      ),
      _ => const _SearchTab(),
    };
    return Scaffold(
      body: SafeArea(child: body),
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
}

class _PhotosTab extends StatelessWidget {
  const _PhotosTab();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_outlined,
              size: 72,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(l.photosEmptyTitle, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            Text(
              l.photosEmptyBody,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            // Wired to the server screen in the login phase.
            FilledButton(onPressed: null, child: Text(l.connect)),
          ],
        ),
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
