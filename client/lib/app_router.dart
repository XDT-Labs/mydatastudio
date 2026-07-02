import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/app_user.dart';
import 'package:mydatastudio/modules/aichat/pages/aichat_page.dart';
import 'package:mydatastudio/modules/aichat/widgets/aichat_drawer.dart';
import 'package:mydatastudio/modules/email/pages/email_page.dart';
import 'package:mydatastudio/modules/email/pages/new_email_page.dart';
import 'package:mydatastudio/modules/email/widgets/email_drawer.dart';
import 'package:mydatastudio/modules/files/pages/new_file_collection_page.dart';
import 'package:mydatastudio/modules/files/pages/rx_files_page.dart';
import 'package:mydatastudio/modules/files/widgets/file_drawer.dart';
import 'package:mydatastudio/modules/photos/pages/photos_app.dart';
import 'package:mydatastudio/modules/photos/widgets/photo_drawer.dart';
import 'package:mydatastudio/modules/social/pages/facebook_page.dart';
import 'package:mydatastudio/modules/social/pages/instagram_page.dart';
import 'package:mydatastudio/modules/social/pages/new_social_page.dart';
import 'package:mydatastudio/modules/social/pages/twitter_page.dart';
import 'package:mydatastudio/modules/social/widgets/social_drawer.dart';
import 'package:mydatastudio/pages/home.dart';
import 'package:mydatastudio/pages/login.dart';
import 'package:mydatastudio/modules/aichat/pages/aichat_models_settings_page.dart';
import 'package:mydatastudio/modules/aichat/pages/aichat_skills_settings_page.dart';
import 'package:mydatastudio/pages/settings.dart';
import 'package:mydatastudio/pages/settings_drawer.dart';
import 'package:mydatastudio/pages/setup.dart';
import 'package:mydatastudio/services/get_user_service.dart';
import 'package:mydatastudio/repositories/user_repository.dart';
import 'package:mydatastudio/widgets/router/navigation_wrapper.dart';
import 'package:mydatastudio/widgets/router/route_page.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppRouter {
  static GlobalKey<NavigatorState> rootNavigatorKey =
      GlobalKey<NavigatorState>();

  /// Shared observer — subscribe via RouteAware to get didPopNext() callbacks.
  static final RouteObserver<PageRoute<dynamic>> routeObserver =
      RouteObserver<PageRoute<dynamic>>();

  static final GoRouter instance = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/',
    refreshListenable: DatabaseManager.isInitializedNotifier,
    debugLogDiagnostics: false,
    observers: [routeObserver],
    redirect: (BuildContext context, GoRouterState state) async {
      if (state.uri.toString() == '/setup') return null;

      //check app startup initialization
      if (!DatabaseManager.isInitializedNotifier.value) {
        return '/setup';
      }

      //check if user is logged in
      AppUser? user = GetUserService.instance.sink.valueOrNull;
      if (user == null) {
        // Check if there are any users in the database at all
        UserRepository repo = UserRepository(DatabaseManager.instance.database);
        AppUser? existingUser = await repo.userExists();
        if (existingUser == null) {
          return '/setup';
        }
        return '/login';
      }

      if (state.uri.toString() == '/login') {
        return '/';
      } else {
        return state.uri.toString();
      }
    },
    routes: <ShellRoute>[
      ShellRoute(
        //navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) {
          return child;
        },
        routes: [
          GoRoute(
            path: '/login',
            pageBuilder: (BuildContext context, GoRouterState state) {
              return RoutePage(
                key: UniqueKey(),
                isStandalone: true,
                body: const LoginPage(),
              );
            },
          ),

          GoRoute(
            path: '/setup',
            pageBuilder: (BuildContext context, GoRouterState state) {
              return RoutePage(
                key: UniqueKey(),
                isStandalone: true,
                body: const SetupPage(),
              );
            },
          ),

          GoRoute(
            path: '/settings',
            pageBuilder: (BuildContext context, GoRouterState state) {
              return const RoutePage(
                body: NavigationWrapper(
                  body: SettingsPage(),
                  drawer: SettingsDrawer(),
                ),
              );
            },
            routes: [
              GoRoute(
                path: 'aichat-models',
                pageBuilder: (context, state) => const RoutePage(
                  body: NavigationWrapper(
                    body: AichatModelsSettingsPage(),
                    drawer: SettingsDrawer(),
                  ),
                ),
              ),
              GoRoute(
                path: 'aichat-skills',
                pageBuilder: (context, state) => const RoutePage(
                  body: NavigationWrapper(
                    body: AichatSkillsSettingsPage(),
                    drawer: SettingsDrawer(),
                  ),
                ),
              ),
            ],
          ),

          GoRoute(
            path: '/',
            pageBuilder: (context, state) {
              return const RoutePage(body: NavigationWrapper(body: HomePage()));
            },
          ),

          /// File Module Routes
          GoRoute(
            path: '/files',
            pageBuilder: (context, state) {
              //build method will load "new collection form" if needed
              return const RoutePage(
                body: NavigationWrapper(
                  body: RxFilesPage(),
                  drawer: FileDrawer(),
                ),
              );
            },
            routes: [
              GoRoute(
                path: 'add',
                pageBuilder:
                    (context, state) => const RoutePage(
                      body: NavigationWrapper(
                        body: NewFileCollectionPage(),
                        drawer: FileDrawer(),
                      ),
                    ),
              ),
            ],
          ),

          /// AI Chat Module Routes
          GoRoute(
            path: '/aichat',
            pageBuilder:
                (context, state) => const RoutePage(
                  body: NavigationWrapper(
                    body: AichatPage(),
                    drawer: AiChatDrawer(),
                  ),
                ),
          ),

          /// Photos Module Routes
          GoRoute(
            path: '/photos',
            pageBuilder:
                (context, state) => const RoutePage(
                  body: NavigationWrapper(
                    body: PhotosApp(),
                    drawer: PhotoDrawer(),
                  ),
                ),
          ),

          //Email Networks
          GoRoute(
            path: '/email',
            pageBuilder: (context, state) {
              return const RoutePage(
                body: NavigationWrapper(
                  body: EmailPage(),
                  drawer: EmailDrawer(),
                ),
              );
            },
            routes: [
              GoRoute(
                path: 'add',
                pageBuilder:
                    (context, state) => const RoutePage(
                      body: NavigationWrapper(
                        body: NewEmailPage(),
                        drawer: EmailDrawer(),
                      ),
                    ),
              ),
            ],
          ),

          /// Social Archive Module Routes
          GoRoute(
            path: '/social',
            pageBuilder: (context, state) {
              return const RoutePage(
                body: NavigationWrapper(
                  body: NewSocialPage(),
                  drawer: SocialDrawer(),
                ),
              );
            },
            routes: [
              GoRoute(
                path: 'add',
                pageBuilder:
                    (context, state) => const RoutePage(
                      body: NavigationWrapper(
                        body: NewSocialPage(),
                        drawer: SocialDrawer(),
                      ),
                    ),
              ),
              GoRoute(
                path: 'facebook/:id',
                pageBuilder: (context, state) {
                  return RoutePage(
                    body: NavigationWrapper(
                      body: FacebookPage(id: state.pathParameters['id']!),
                      drawer: const SocialDrawer(),
                    ),
                  );
                },
              ),
              GoRoute(
                path: 'twitter/:id',
                pageBuilder: (context, state) {
                  return RoutePage(
                    body: NavigationWrapper(
                      body: TwitterPage(id: state.pathParameters['id']!),
                      drawer: const SocialDrawer(),
                    ),
                  );
                },
              ),
              GoRoute(
                path: 'instagram/:id',
                pageBuilder: (context, state) {
                  return RoutePage(
                    body: NavigationWrapper(
                      body: InstagramPage(id: state.pathParameters["id"]!),
                      drawer: const SocialDrawer(),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
