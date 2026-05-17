import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mydatatools/models/tables/app_user.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/repositories/user_repository.dart';
import 'package:mydatatools/widgets/login_form.dart';
import 'package:password_dart/password_dart.dart';
import 'package:uuid/uuid.dart';

void main() {
  late Directory tempDir;
  late DatabaseManager databaseManager;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('login_test_');

    const MethodChannel channel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    // ignore: deprecated_member_use
    channel.setMockMethodCallHandler((MethodCall methodCall) async {
      return tempDir.path;
    });

    databaseManager = DatabaseManager.instance;
    databaseManager.useMemoryDb = false;
    await databaseManager.initializeDatabase();

    // Mock Secure Storage
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    databaseManager.dispose();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  testWidgets('LoginForm login success test', (WidgetTester tester) async {
    final password = 'password123';
    final algorithm = PBKDF2(
      blockLength: 64,
      iterationCount: 10000,
      desiredKeyLength: 64,
    );
    final hash = Password.hash(password, algorithm);

    final String tempPath = '${tempDir.path}/mydatatools_test_${const Uuid().v4()}';
    final user = AppUser(
      id: const Uuid().v4(),
      name: 'testuser',
      password: hash,
      email: 'test@example.com',
      localStoragePath: tempPath,
    );

    // Create dummy keys
    final keyDir = Directory('$tempPath/keys');
    keyDir.createSync(recursive: true);
    File('${keyDir.path}/public.pem').writeAsStringSync('public-key');
    File('${keyDir.path}/private.pem').writeAsStringSync('private-key');

    // Run database insert in runAsync since it uses ports/isolates
    await tester.runAsync(() async {
      final userRepo = UserRepository(databaseManager.database!);
      await userRepo.saveUser(user);
    });

    // 2. Pump the widget
    bool loginSuccess = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginForm(
            onLoginSuccessful: () {
              loginSuccess = true;
            },
          ),
        ),
      ),
    );

    // 3. Enter password
    await tester.enterText(find.byType(TextField), password);
    await tester.pump();

    // 4. Tap login button
    await tester.tap(find.text('Login'));
    await tester.pump();

    // Run the async event loop to let the password hashing and DB select execute
    await tester.runAsync(() async {
      await Future.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();

    // 5. Verify success
    expect(loginSuccess, isTrue);
    expect(find.text('Wrong password'), findsNothing);

    // Cleanup
    keyDir.parent.deleteSync(recursive: true);
  });

  testWidgets('LoginForm login keys missing error test', (
    WidgetTester tester,
  ) async {
    final password = 'password123';
    final algorithm = PBKDF2(
      blockLength: 64,
      iterationCount: 10000,
      desiredKeyLength: 64,
    );
    final hash = Password.hash(password, algorithm);

    final String tempPath = '${tempDir.path}/mydatatools_test_nokeys_${const Uuid().v4()}';
    final user = AppUser(
      id: const Uuid().v4(),
      name: 'testuser',
      password: hash,
      email: 'test@example.com',
      localStoragePath: tempPath,
    );

    await tester.runAsync(() async {
      final userRepo = UserRepository(databaseManager.database!);
      await userRepo.saveUser(user);
    });

    // 2. Pump the widget
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: LoginForm(onLoginSuccessful: () {}))),
    );

    // 3. Enter password
    await tester.enterText(find.byType(TextField), password);
    await tester.pump();

    // 4. Tap login button
    await tester.tap(find.text('Login'));
    await tester.pump();

    await tester.runAsync(() async {
      await Future.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();

    // 5. Verify that the button is RE-ENABLED (not null)
    final loginButton = tester.widget<MaterialButton>(
      find.widgetWithText(MaterialButton, 'Login'),
    );
    expect(
      loginButton.onPressed,
      isNotNull,
      reason: 'Button should be re-enabled after error',
    );

    // Wait for FToast timers to finish
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('LoginForm login failure test', (WidgetTester tester) async {
    // 1. Pump the widget (no user in DB)
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: LoginForm(onLoginSuccessful: () {}))),
    );

    // 2. Enter wrong password
    await tester.enterText(find.byType(TextField), 'wrongpassword');
    await tester.pump();

    // 3. Tap login button
    await tester.tap(find.text('Login'));
    await tester.pump();

    await tester.runAsync(() async {
      await Future.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();

    // Wait for FToast timers to finish
    await tester.pump(const Duration(seconds: 5));
  });
}
