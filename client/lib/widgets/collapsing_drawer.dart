import 'dart:async';

import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/models/tables/app.dart' as m;
import 'package:mydatastudio/services/get_apps_service.dart';
import 'package:mydatastudio/services/get_user_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

class CollapsingDrawer extends StatefulWidget {
  const CollapsingDrawer({super.key});

  @override
  State<CollapsingDrawer> createState() => _CollapsingDrawerState();
}

class _CollapsingDrawerState extends State<CollapsingDrawer> {
  bool isLoading = true;
  GetAppsService? _getAppsService;
  StreamSubscription? _appsSub;
  StreamSubscription? _loadingSub;
  List<m.App> apps = [];
  int selectedIndex = 0;

  @override
  void initState() {
    super.initState();

    /////////////////////////////////////////////////
    // Load Apps
    _getAppsService = GetAppsService.instance;
    //flag to hide/show loading icon
    _loadingSub = _getAppsService!.isLoading.listen((value) {
      if (context.mounted) {
        setState(() {
          isLoading = value;
        });
      }
    });
    //list of all apps
    _appsSub = _getAppsService!.sink.listen((value) {
      if (context.mounted) {
        setState(() {
          apps = value;
        });
      }
    });

    _getAppsService!.invoke(GetAppsServiceCommand());
  }

  @override
  void dispose() {
    _appsSub?.cancel();
    _loadingSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    var collectionApps = apps.where((e) => e.group == 'collections').toList();
    var appApps = apps.where((e) => e.group == 'app').toList();

    if (isLoading) {
      return const SizedBox(
        width: 72,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final destinations = <NavigationRailDestination>[
      const NavigationRailDestination(
        icon: Icon(Icons.home),
        label: Text('Home'),
      ),
      if (appApps.isNotEmpty || collectionApps.isNotEmpty)
        const NavigationRailDestination(
          icon: Divider(indent: 8, endIndent: 8),
          label: Text(''),
          disabled: true,
        ),
      ...appApps.map((app) {
        return NavigationRailDestination(
          // ignore: non_const_argument_for_const_parameter
          icon: Icon(IconData(app.icon ?? 0xe08f, fontFamily: 'MaterialIcons')),
          label: Text(app.name),
        );
      }),
      if (appApps.isNotEmpty && collectionApps.isNotEmpty)
        const NavigationRailDestination(
          icon: Divider(indent: 8, endIndent: 8),
          label: Text(''),
          disabled: true,
        ),
      ...collectionApps.map((app) {
        return NavigationRailDestination(
          // ignore: non_const_argument_for_const_parameter
          icon: Icon(IconData(app.icon ?? 0xe08f, fontFamily: 'MaterialIcons')),
          label: Text(app.name),
        );
      }),
    ];

    return NavigationRail(
      selectedIndex: selectedIndex,
      onDestinationSelected: (int index) async {
        if (destinations[index].disabled) return;

        setState(() {
          selectedIndex = index;
        });

        if (index == 0) {
          GoRouter.of(context).go("/");
          return;
        }

        int currentIndex = 1; // Start after Home
        if (appApps.isNotEmpty || collectionApps.isNotEmpty) {
          currentIndex++; // Skip first divider
        }

        if (index < currentIndex + appApps.length) {
          GoRouter.of(context).go(appApps[index - currentIndex].route);
          return;
        }
        currentIndex += appApps.length;

        if (appApps.isNotEmpty && collectionApps.isNotEmpty) {
          currentIndex++; // Skip second divider
        }

        if (index < currentIndex + collectionApps.length) {
          GoRouter.of(context).go(collectionApps[index - currentIndex].route);
          return;
        }
      },
      labelType: NavigationRailLabelType.none,
      extended: false,
      backgroundColor: theme.scaffoldBackgroundColor,
      destinations: destinations,
      trailing: Expanded(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: IconButton(
              icon: const Icon(Icons.lock),
              tooltip: 'Logout',
              onPressed: () async {
                // Logout logic
                GetUserService.instance.invoke(GetUserServiceCommand(null));
                FlutterSecureStorage storage = const FlutterSecureStorage();
                await storage.write(
                  key: AppConstants.securePassword,
                  value: null,
                );
                if (context.mounted) {
                  GoRouter.of(context).go('/?action=logout');
                }
              },
            ),
          ),
        ),
      ),
    );
  }
}
