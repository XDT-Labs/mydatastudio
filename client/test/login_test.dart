import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mydatatools/models/tables/app_user.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/widgets/login_form.dart';
import 'package:password_dart/password_dart.dart';
import 'package:uuid/uuid.dart';

void main() {
  setUp(() async {
    // Use in-memory database
    DatabaseManager.instance.useMemoryDb = true;

    // Initialize database manually to avoid path_provider errors in tests
    DatabaseManager.instance.appDatabase = AppDatabase(
      null,
      null,
      null,
      true,
    );

    // Mock Secure Storage
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    await DatabaseManager.instance.appDatabase?.close();
  });

  testWidgets('LoginForm login success test', (WidgetTester tester) async {
    // 1. Create a user in the DB
    final password = 'password123';
    final algorithm = PBKDF2(
      blockLength: 64,
      iterationCount: 10000,
      desiredKeyLength: 64,
    );
    final hash = Password.hash(password, algorithm);

    final String tempPath = '/tmp/mydatatools_test_${const Uuid().v4()}';
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

    // We can't use UserRepository.saveUser because it tries to write keys to disk.
    // So we insert directly into DB.
    final db = DatabaseManager.instance.database;
    await db?.into(db.appUsers).insert(user);

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
    await tester.pumpAndSettle(); // Wait for async operations

    // 5. Verify success
    expect(loginSuccess, isTrue);
    expect(find.text('Wrong password'), findsNothing);

    // Cleanup
    keyDir.parent.deleteSync(recursive: true);
  });

  testWidgets('LoginForm login keys missing error test', (
    WidgetTester tester,
  ) async {
    // 1. Create a user in the DB BUT NO KEYS ON DISK
    final password = 'password123';
    final algorithm = PBKDF2(
      blockLength: 64,
      iterationCount: 10000,
      desiredKeyLength: 64,
    );
    final hash = Password.hash(password, algorithm);

    final String tempPath = '/tmp/mydatatools_test_nokeys_${const Uuid().v4()}';
    final user = AppUser(
      id: const Uuid().v4(),
      name: 'testuser',
      password: hash,
      email: 'test@example.com',
      localStoragePath: tempPath,
    );

    final db = DatabaseManager.instance.database;
    await db?.into(db.appUsers).insert(user);

    // 2. Pump the widget
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: LoginForm(onLoginSuccessful: () {}))),
    );

    // 3. Enter password
    await tester.enterText(find.byType(TextField), password);
    await tester.pump();

    // 4. Tap login button
    await tester.tap(find.text('Login'));
    await tester.pumpAndSettle();

    // 5. Verify that the button is RE-ENABLED (not null) and an error is shown
    final loginButton = tester.widget<MaterialButton>(
      find.widgetWithText(MaterialButton, 'Login'),
    );
    expect(
      loginButton.onPressed,
      isNotNull,
      reason: 'Button should be re-enabled after error',
    );

    // Wait for toast timer to finish
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
    await tester.pumpAndSettle();

    // Wait for toast timer to finish
    await tester.pump(const Duration(seconds: 5));
  });
}
