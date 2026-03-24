import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/app_user.dart';
import 'package:mydatatools/modules/aichat/pages/aichat_page.dart';
import 'package:mydatatools/modules/aichat/widgets/aichat_drawer.dart';
import 'package:mydatatools/modules/email/pages/email_page.dart';
import 'package:mydatatools/modules/email/pages/new_email_page.dart';
import 'package:mydatatools/modules/email/widgets/email_drawer.dart';
import 'package:mydatatools/modules/files/pages/new_file_collection_page.dart';
import 'package:mydatatools/modules/files/pages/rx_files_page.dart';
import 'package:mydatatools/modules/files/widgets/file_drawer.dart';
import 'package:mydatatools/modules/photos/pages/photos_app.dart';
import 'package:mydatatools/modules/photos/widgets/photo_drawer.dart';
import 'package:mydatatools/modules/social/pages/facebook_page.dart';
import 'package:mydatatools/modules/social/pages/instagram_page.dart';
import 'package:mydatatools/modules/social/pages/new_social_page.dart';
import 'package:mydatatools/modules/social/pages/twitter_page.dart';
import 'package:mydatatools/modules/social/widgets/social_drawer.dart';
import 'package:mydatatools/pages/home.dart';
import 'package:mydatatools/pages/login.dart';
import 'package:mydatatools/pages/setup.dart';
import 'package:mydatatools/services/get_user_service.dart';
import 'package:mydatatools/widgets/router/navigation_wrapper.dart';
import 'package:mydatatools/widgets/router/route_page.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppRouter {
  static GlobalKey<NavigatorState> rootNavigatorKey =
      GlobalKey<NavigatorState>();

  static final GoRouter instance = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/',
    refreshListenable: DatabaseManager.isInitializedNotifier,
    debugLogDiagnostics: false,
    redirect: (BuildContext context, GoRouterState state) async {
      if (state.uri.toString() == '/setup') return null;

      //check app startup initialization
      if (!DatabaseManager.isInitializedNotifier.value) {
        return '/setup';
      }

      //check if user is logged in
      AppUser? user = GetUserService.instance.sink.valueOrNull;
      if (user == null) {
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
            path: '/',
            pageBuilder: (context, state) {
              return const RoutePage(
                body: NavigationWrapper(body: HomePage()),
              );
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
                      body: NavigationWrapper(body: NewSocialPage()),
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
