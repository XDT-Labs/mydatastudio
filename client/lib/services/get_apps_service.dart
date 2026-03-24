import 'package:mydatatools/models/tables/app.dart';
import 'package:mydatatools/repositories/app_repository.dart';
import 'package:mydatatools/services/rx_service.dart';

class GetAppsService extends RxService<GetAppsServiceCommand, List<App>> {
  static final GetAppsService _singleton = GetAppsService();
  static GetAppsService get instance => _singleton;

  // Cache the app list — apps are static at runtime (populated once at DB
  // creation and never changed), so there is no need to re-query on every
  // CollapsingDrawer rebuild triggered by navigation.
  List<App>? _cachedApps;

  @override
  Future<List<App>> invoke(GetAppsServiceCommand command) async {
    // Return cached result immediately — no DB query, no loading flash.
    if (_cachedApps != null && _cachedApps!.isNotEmpty) {
      sink.add(_cachedApps!);
      return _cachedApps!;
    }

    isLoading.add(true);
    AppRepository repo = AppRepository();
    List<App> apps = await repo.apps();
    _cachedApps = apps;
    sink.add(apps);
    isLoading.add(false);
    return apps;
  }

  /// Force a fresh fetch on the next [invoke] call (e.g. after adding an app).
  void invalidateCache() => _cachedApps = null;
}

class GetAppsServiceCommand implements RxCommand {}
