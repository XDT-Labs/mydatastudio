import 'dart:async';

import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/email/pages/email_page.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class EmailDrawer extends StatefulWidget {
  const EmailDrawer({super.key});

  @override
  State<EmailDrawer> createState() => _EmailDrawer();
}

class _EmailDrawer extends State<EmailDrawer> {
  final GetCollectionsService _collectionsService =
      GetCollectionsService.instance;
  StreamSubscription<List<Collection>>? _collectionsServiceSub;
  StreamSubscription? _selectedCollectionSub;
  List<Collection> collections = [];
  Collection? collection;

  @override
  void initState() {
    _collectionsServiceSub = _collectionsService.sink.listen((value) {
      setState(() {
        collections = value;
      });
    });

    _selectedCollectionSub = EmailPage.selectedCollection.listen((value) {
      if (mounted) {
        setState(() {
          collection = value;
        });
      }
    });

    super.initState();
  }

  @override
  void dispose() {
    _collectionsServiceSub?.cancel();
    _selectedCollectionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox.expand(
      child: Container(
        height: double.infinity,
        color: Colors.transparent,
        padding: const EdgeInsets.all(8),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: FloatingActionButton(
            tooltip: "Add Email",
            backgroundColor: Colors.transparent,
            elevation: 0,
            shape: RoundedRectangleBorder(
              side: const BorderSide(color: Colors.grey, width: 1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.add, color: Colors.grey),
            onPressed: () {
              debugPrint("fab pressed");
              GoRouter.of(context).go("/email/add");
            },
          ),
          body: Column(
            children: [
              const Align(
                alignment: Alignment.topLeft,
                child: Text(
                  "Email Accounts:",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: collections.length,
                  itemBuilder: (context, index) {
                    final isSelected = collection?.id == collections[index].id;
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
                          EmailPage.selectedCollection.add(collections[index]);
                          context.go('/email');
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
