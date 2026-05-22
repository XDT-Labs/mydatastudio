import 'dart:async';

import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:mydatatools/modules/files/widgets/file_drawer/accordion_header_widget.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:meta/meta.dart';

enum SocialSection { facebook, twitter, instagram }

class SocialDrawer extends StatefulWidget {
  const SocialDrawer({super.key});

  @override
  State<SocialDrawer> createState() => _SocialDrawerState();

  @visibleForTesting
  static void resetState() {
    _SocialDrawerState._expandedSection = SocialSection.facebook;
    _SocialDrawerState._previousPath = null;
  }
}

class _SocialDrawerState extends State<SocialDrawer> {
  GetCollectionsService? _getCollectionsService;
  StreamSubscription? _collectionsSub;
  List<Collection> collections = [];

  static SocialSection? _expandedSection = SocialSection.facebook;
  static String? _previousPath;

  @override
  void initState() {
    _getCollectionsService = GetCollectionsService.instance;
    _collectionsSub = _getCollectionsService!.sink.listen((value) {
      if (mounted) {
        setState(() {
          collections = value;
        });
      }
    });

    _getCollectionsService!.invoke(GetCollectionsServiceCommand("social"));
    super.initState();
  }

  @override
  void dispose() {
    _collectionsSub?.cancel();
    super.dispose();
  }

  Widget _buildSectionHeader(String title, {double leftPadding = 16.0}) {
    return Padding(
      padding: EdgeInsets.only(left: leftPadding, right: 16.0, top: 12, bottom: 12),
      child: Align(
        alignment: Alignment.topLeft,
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 11,
            color: Colors.grey,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildSubItem({
    required String name,
    required bool isSelected,
    required VoidCallback onTap,
    required ThemeData theme,
  }) {
    final textColor = isSelected
        ? (theme.brightness == Brightness.dark ? Colors.white : theme.colorScheme.primary)
        : theme.colorScheme.onSurface.withValues(alpha: 0.6);

    final bulletColor = isSelected
        ? (theme.brightness == Brightness.dark ? Colors.white : theme.colorScheme.primary)
        : theme.colorScheme.onSurface.withValues(alpha: 0.4);

    final tileColor = isSelected
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.15)
        : Colors.transparent;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          height: 38,
          decoration: BoxDecoration(
            color: tileColor,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              // Vertical highlight line on the left
              Container(
                width: 3,
                height: 24,
                decoration: BoxDecoration(
                  color: isSelected
                      ? (theme.brightness == Brightness.dark ? Colors.white : theme.colorScheme.primary)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
              const SizedBox(width: 20),
              // Bullet point
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: bulletColor,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: textColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentPath = GoRouterState.of(context).uri.path;

    // Auto-expand section containing the selected account on route changes
    if (currentPath != _previousPath) {
      _previousPath = currentPath;
      if (currentPath.contains('/facebook/')) {
        _expandedSection = SocialSection.facebook;
      } else if (currentPath.contains('/twitter/')) {
        _expandedSection = SocialSection.twitter;
      } else if (currentPath.contains('/instagram/')) {
        _expandedSection = SocialSection.instagram;
      }
    }

    final socialCollections = collections.where((c) => c.type == 'social').toList();

    // Grouping
    final facebookCollections = socialCollections
        .where((c) => c.scanner.toLowerCase().contains('facebook') || c.oauthService == 'facebook')
        .toList();
    final twitterCollections = socialCollections
        .where((c) => c.scanner.toLowerCase().contains('twitter') || c.oauthService == 'twitter')
        .toList();
    final instagramCollections = socialCollections
        .where((c) => c.scanner.toLowerCase().contains('instagram') || c.oauthService == 'instagram')
        .toList();

    return SizedBox.expand(
      child: Container(
        color: Colors.transparent,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: FloatingActionButton.small(
            tooltip: "Add Source",
            onPressed: () => GoRouter.of(context).go("/social/add"),
            backgroundColor: theme.colorScheme.surfaceContainerHigh,
            foregroundColor: theme.colorScheme.onSurface,
            shape: const CircleBorder(),
            child: const Icon(Icons.add, size: 20),
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          body: Column(
            children: [
              StreamBuilder<bool>(
                stream: _getCollectionsService!.isLoading,
                builder: (context, snapshot) {
                  if (snapshot.data == true) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16.0),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader("SOCIAL ACCOUNTS"),
                      
                      // Facebook section
                      AccordionHeaderWidget(
                        title: "Facebook Accounts",
                        icon: Icons.people_outline,
                        isExpanded: _expandedSection == SocialSection.facebook,
                        onTap: () => setState(() {
                          _expandedSection = _expandedSection == SocialSection.facebook
                              ? null
                              : SocialSection.facebook;
                        }),
                      ),
                      if (_expandedSection == SocialSection.facebook)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: facebookCollections.isNotEmpty
                              ? facebookCollections.map((c) {
                                  final isSelected = currentPath.contains(c.id);
                                  return _buildSubItem(
                                    name: c.name,
                                    isSelected: isSelected,
                                    onTap: () => GoRouter.of(context).go('/social/facebook/${c.id}'),
                                    theme: theme,
                                  );
                                }).toList()
                              : [
                                  _buildSubItem(
                                    name: "Meta Dev Team",
                                    isSelected: currentPath.endsWith('/facebook/meta-dev-team') || currentPath.contains('/facebook/meta-dev-team'),
                                    onTap: () => GoRouter.of(context).go('/social/facebook/meta-dev-team'),
                                    theme: theme,
                                  ),
                                  _buildSubItem(
                                    name: "Studio Primary",
                                    isSelected: currentPath.endsWith('/facebook/studio-primary') || currentPath.contains('/facebook/studio-primary'),
                                    onTap: () => GoRouter.of(context).go('/social/facebook/studio-primary'),
                                    theme: theme,
                                  ),
                                ],
                        ),

                      // Twitter section
                      AccordionHeaderWidget(
                        title: "Twitter Accounts",
                        icon: Icons.flutter_dash,
                        isExpanded: _expandedSection == SocialSection.twitter,
                        onTap: () => setState(() {
                          _expandedSection = _expandedSection == SocialSection.twitter
                              ? null
                              : SocialSection.twitter;
                        }),
                      ),
                      if (_expandedSection == SocialSection.twitter)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: twitterCollections.map((c) {
                            final isSelected = currentPath.contains(c.id);
                            return _buildSubItem(
                              name: c.name,
                              isSelected: isSelected,
                              onTap: () => GoRouter.of(context).go('/social/twitter/${c.id}'),
                              theme: theme,
                            );
                          }).toList(),
                        ),

                      // Instagram section
                      AccordionHeaderWidget(
                        title: "Instagram Accounts",
                        icon: Icons.camera_alt_outlined,
                        isExpanded: _expandedSection == SocialSection.instagram,
                        onTap: () => setState(() {
                          _expandedSection = _expandedSection == SocialSection.instagram
                              ? null
                              : SocialSection.instagram;
                        }),
                      ),
                      if (_expandedSection == SocialSection.instagram)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: instagramCollections.map((c) {
                            final isSelected = currentPath.contains(c.id);
                            return _buildSubItem(
                              name: c.name,
                              isSelected: isSelected,
                              onTap: () => GoRouter.of(context).go('/social/instagram/${c.id}'),
                              theme: theme,
                            );
                          }).toList(),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
