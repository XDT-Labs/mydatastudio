import 'dart:async';

import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class SocialDrawer extends StatefulWidget {
  const SocialDrawer({super.key});

  @override
  State<SocialDrawer> createState() => _SocialDrawerState();
}

class _SocialDrawerState extends State<SocialDrawer> {
  GetCollectionsService? _getCollectionsService;
  StreamSubscription? _collectionsSub;
  List<Collection> collections = [];

  @override
  void initState() {
    _getCollectionsService = GetCollectionsService.instance;
    _collectionsSub = _getCollectionsService!.sink.listen((value) {
      setState(() {
        collections = value;
      });
    });

    _getCollectionsService!.invoke(GetCollectionsServiceCommand("album"));
    super.initState();
  }

  @override
  void dispose() {
    _collectionsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox.expand(
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            const Align(
              alignment: Alignment.topLeft,
              child: Text(
                "Social Networks",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: collections.length,
                itemBuilder: (context, index) {
                  final isSelected = GoRouterState.of(context).uri.path.contains(collections[index].id);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2.0),
                    child: ListTile(
                      selected: isSelected,
                      selectedTileColor: theme.colorScheme.primaryContainer.withOpacity(0.3),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      title: Text(
                        collections[index].name,
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      onTap: () {
                        GoRouter.of(
                          context,
                        ).go('/social/${collections[index].id}');
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
