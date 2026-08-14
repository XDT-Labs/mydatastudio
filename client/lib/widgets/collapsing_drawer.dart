import 'dart:async';

import 'package:mydatastudio/models/tables/app.dart' as m;
import 'package:mydatastudio/services/get_apps_service.dart';
import 'package:mydatastudio/services/get_user_service.dart';
import 'package:mydatastudio/services/vault_manager.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';

class CollapsingDrawer extends StatefulWidget {
  const CollapsingDrawer({super.key});

  @override
  State<CollapsingDrawer> createState() => _CollapsingDrawerState();
}

/// A rail entry paired with the route it navigates to — null for the
/// non-selectable dividers, which occupy an index all the same.
typedef _RailEntry = ({NavigationRailDestination destination, String? route});

/// Which rail entry [location] belongs to, or null when it belongs to none.
///
/// Derived from the route on every build rather than remembered from the last
/// tap, because the rail is not the only thing that navigates: the Photos
/// sidebar links an attachment to its email, logout returns Home, and a sub
/// route like `/files/add` never touches the rail at all. Storing the
/// selection meant the highlight stayed on whichever module the user last
/// *clicked*, pointing at a module they were no longer in.
int? selectedRailIndexFor(String location, List<String?> routes) {
  int? best;
  var bestLength = -1;

  for (var i = 0; i < routes.length; i++) {
    final route = routes[i];
    if (route == null) continue;

    // Home would otherwise prefix-match every route in the app.
    final matches = route == '/'
        ? location == '/'
        : location == route || location.startsWith('$route/');

    // Longest wins, so a hypothetical `/files/photos` picks the deeper entry
    // rather than whichever of the two was registered first.
    if (matches && route.length > bestLength) {
      best = i;
      bestLength = route.length;
    }
  }
  return best;
}

class _CollapsingDrawerState extends State<CollapsingDrawer> {
  bool isLoading = true;
  GetAppsService? _getAppsService;
  StreamSubscription? _appsSub;
  StreamSubscription? _loadingSub;
  List<m.App> apps = [];

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

    _RailEntry appEntry(m.App app) {
      return (
        destination: NavigationRailDestination(
          // ignore: non_const_argument_for_const_parameter
          icon: Icon(IconData(app.icon ?? 0xe08f, fontFamily: 'MaterialIcons')),
          label: Text(app.name),
        ),
        route: app.route,
      );
    }

    const divider = (
      destination: NavigationRailDestination(
        icon: Divider(indent: 8, endIndent: 8),
        label: Text(''),
        disabled: true,
      ),
      route: null,
    );

    // Entries carry their own route rather than the rail recomputing one from
    // an index. The arithmetic that used to do that had to re-derive where
    // each divider sat, and got it wrong whenever a group was empty.
    final entries = <_RailEntry>[
      (
        destination: const NavigationRailDestination(
          icon: Icon(Icons.home),
          label: Text('Home'),
        ),
        route: '/',
      ),
      if (appApps.isNotEmpty || collectionApps.isNotEmpty) divider,
      ...appApps.map(appEntry),
      if (appApps.isNotEmpty && collectionApps.isNotEmpty) divider,
      ...collectionApps.map(appEntry),
    ];

    return NavigationRail(
      selectedIndex: selectedRailIndexFor(
        GoRouterState.of(context).uri.path,
        entries.map((e) => e.route).toList(),
      ),
      onDestinationSelected: (int index) async {
        final route = entries[index].route;
        if (entries[index].destination.disabled || route == null) return;
        GoRouter.of(context).go(route);
      },
      labelType: NavigationRailLabelType.none,
      extended: false,
      backgroundColor: theme.scaffoldBackgroundColor,
      destinations: entries.map((e) => e.destination).toList(),
      trailing: Expanded(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: IconButton(
              icon: const Icon(Icons.lock),
              tooltip: 'Logout',
              onPressed: () async {
                // Logout: clear the session user and forget the in-memory vault
                // DEK so secrets require the password again (AUDIT M2).
                GetUserService.instance.invoke(GetUserServiceCommand(null));
                VaultManager.instance.lock();
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
