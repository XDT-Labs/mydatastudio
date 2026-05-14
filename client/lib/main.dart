import 'dart:io';
import 'dart:ui';

import 'package:mydatatools/app_router.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/family_dam_app.dart';
import 'package:mydatatools/pages/splash.dart';
import 'package:mydatatools/python_manager.dart';

import 'package:mydatatools/repositories/watchers/database_change_watcher.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:mydatatools/widgets/auth_dialog_manager.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:rxdart/rxdart.dart';
import 'package:window_manager/window_manager.dart';
import 'package:file_picker/file_picker.dart';
import 'package:media_kit/media_kit.dart';

/// The main() function is the starting point of the application. It first ensures that the Flutter binding is initialized.
/// Then, it checks if the platform is Windows, Linux or macOS. If it is, it gets the current screen and sets the window title, minimum size and maximum size.
/// Finally, it runs the FamilyDamApp widget wrapped in a ProviderScope using the runApp function.

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Must add this line.
  await windowManager.ensureInitialized();

  // Intercept close events to manually shutdown python service before exit
  await windowManager.setPreventClose(true);

  //set log level
  Logger.level = Level.debug;

  // Start desktop client
  runApp(const MainApp());
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  // Moved static subjects/keys here so they can be referenced as MainApp.xxx
  // Default system directory for app config
  static final BehaviorSubject<Directory?> supportDirectory =
      BehaviorSubject<Directory?>();
  // User selected directory to store files and metadata db.
  static final BehaviorSubject<String?> appDataDirectory =
      BehaviorSubject<String?>();
  // Flutter key for router
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
  // Url for local LLM service
  static final BehaviorSubject<String?> llmServiceUrl =
      BehaviorSubject<String?>();

  //Database repository
  static DatabaseManager? databaseManager;
  //Manage DB watchers
  static DatabaseChangeWatcher? collectionWatcher;
  // Manage all module scanners
  static ScannerManager? scannerManager;

  @override
  MainAppState createState() => MainAppState();
}

// In your top-level app widget (MainApp State) call stop when the app is disposed:
class MainAppState extends State<MainApp>
    with WidgetsBindingObserver, WindowListener {
  bool _needsSetup = false;
  bool _isSetupComplete = false;
  bool _dbAccessError = false;
  String? _dbErrorPath;
  PythonManager? pythonManager;
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Initialize a global dialog manager
    _initDialogManager();

    // Initialize the Database and Python Server
    _initStartup();

    windowManager.addListener(this);

    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        // This callback is invoked when the application is requested to exit.
        // You can perform cleanup or prompt the user for confirmation here.
        // Return AppExitResponse.exit to allow exit, or AppExitResponse.cancel to prevent it.
        print('Exit requested!');
        await pythonManager?.stopAiChatService();
        return AppExitResponse.exit;
      },
      onStateChange: (AppLifecycleState state) {
        // This callback is invoked for all lifecycle state changes.
        // print('AppLifecycleState changed: $state');
        switch (state) {
          case AppLifecycleState.detached:
            // Application is detached from any host view. This typically means the app is closed.
            break;
          case AppLifecycleState.inactive:
            // Application is in an inactive state (e.g., system dialog open, app losing focus).
            break;
          case AppLifecycleState.paused:
            // Application is in the background.
            break;
          case AppLifecycleState.resumed:
            // Application is in the foreground and active.
            break;
          case AppLifecycleState.hidden:
            // Application is hidden (e.g., minimized on desktop).
            break;
        }
      },
      // You can also provide specific callbacks for individual state transitions:
      // onResume: () => print('Resumed'),
      // onInactive: () => print('Inactive'),
      // onPaused: () => print('Paused'),
      // onDetached: () => print('Detached'),
      // onHide: () => print('Hidden'),
    );
  }

  Future<void> _initStartup() async {
    if (!await DatabaseManager.instance.isDatabaseConfigured()) {
      setState(() {
        _needsSetup = true;
      });
    } else {
      try {
        // 1. Initialize local Database
        var dbFuture = DatabaseManager.instance.initializeDatabase();
        await dbFuture;

        // 2. Initialize Python Manager
        final pythonFuture =
            (() async {
              final pythonMgr = await PythonManager.forAppSupport();
              await pythonMgr.startAiChatService();
              return pythonMgr;
            })();

        // Wait for both to finish (db is already done)
        await Future.wait([pythonFuture, dbFuture]);

        // set database repository
        MainApp.databaseManager = DatabaseManager.instance;
        //set python manager
        pythonManager = await pythonFuture;

        // 4. Signal ready
        if (mounted) {
          setState(() {
            _isSetupComplete = MainApp.databaseManager != null;
          });
        }
      } on FileSystemException catch (e) {
        if (mounted) {
          setState(() {
            _dbAccessError = true;
            _dbErrorPath = e.path;
          });
        }
      }
    }
  }

  // Initialize a global Dialog Manager so any screen can launch global dialogs, such as oauth expired alerts
  void _initDialogManager() =>
      AuthDialogManager(AppRouter.rootNavigatorKey).init();

  @override
  void onWindowClose() async {
    bool isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      // Hide the window immediately for a snappier UX while background python service gracefully terminates
      await windowManager.hide();
      await pythonManager?.stopAiChatService();
      await windowManager.destroy();
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    _lifecycleListener.dispose();
    super.dispose();
  }

  Widget _initSplashScreen() {
    // Show splash screen
    () async {
      await windowManager.setSize(const Size(900, 700));
      await windowManager.center();
      await windowManager.setTitle('MyData Tools - Loading...');
    }();
    return const MaterialApp(
      home: SplashPage(),
      debugShowCheckedModeBanner: false,
    );
  }

  Widget _initDbErrorScreen() {
    () async {
      await windowManager.setTitle('MyData Tools - Error');
      await windowManager.setSize(const Size(800, 600));
      await windowManager.center();
    }();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.grey.shade900,
        body: Center(
          child: Card(
            elevation: 8,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Container(
              width: 500,
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: Colors.redAccent, size: 64),
                  const SizedBox(height: 24),
                  const Text(
                    'Storage Location Not Found',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'The configured storage location could not be accessed. It may be on a disconnected network drive or the folder was moved.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          "Configured Location:\n${DatabaseManager.instance.storagePath ?? 'Unknown'}",
                          style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        SelectableText(
                          "Error Details:\n$_dbErrorPath",
                          style: const TextStyle(fontFamily: 'monospace', color: Colors.red),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry Existing'),
                        onPressed: () {
                          setState(() {
                            _dbAccessError = false;
                            _dbErrorPath = null;
                          });
                          _initStartup();
                        },
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Pick New Location'),
                        onPressed: () async {
                          String? newPath = await FilePicker.platform.getDirectoryPath();
                          if (newPath != null) {
                            await DatabaseManager.instance.updateConfigPath(newPath);
                            if (mounted) {
                              setState(() {
                                _dbAccessError = false;
                                _dbErrorPath = null;
                              });
                              _initStartup();
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _initSetupScreen() {
    // Handle case where database initialization fails but we want to show the main app anyway
    // Or perhaps navigate to a setup screen.
    // For now, just launch the main app and let the router go to setup.
    () async {
      await windowManager.setTitle('MyData Tools');
      await windowManager.setSize(const Size(1200, 800));
      await windowManager.center();
    }();
    return const FamilyDamApp();
  }

  Widget _initAppScreen() {
    // Handle case where database initialization fails but we want to show the main app anyway
    // Or perhaps navigate to a setup screen.
    // For now, just launch the main app and let the router go to setup.
    () async {
      await windowManager.setTitle('MyData Tools');
      await windowManager.setSize(const Size(1200, 800));
      await windowManager.center();
    }();
    return const FamilyDamApp();
  }

  @override
  Widget build(BuildContext context) {
    if (_dbAccessError) {
      return _initDbErrorScreen();
    }
    if (_needsSetup) {
      return _initSetupScreen();
    }
    if (_isSetupComplete) {
      return _initAppScreen();
    }
    return _initSplashScreen();
  }
}
