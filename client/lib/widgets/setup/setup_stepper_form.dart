import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/helpers/encryption_helper.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/app_user.dart';
import 'package:mydatastudio/python_manager.dart';
import 'package:mydatastudio/repositories/user_repository.dart';
import 'package:mydatastudio/services/get_user_service.dart';
import 'package:mydatastudio/services/model_download_manager.dart';

import 'package:mydatastudio/widgets/setup/setup_step1.dart';
import 'package:mydatastudio/widgets/setup/setup_step2.dart';
import 'package:mydatastudio/widgets/setup/setup_step3.dart';
import 'package:mydatastudio/widgets/setup/setup_step4.dart';
import 'package:flutter/material.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

class SetupStepperForm extends StatefulWidget {
  const SetupStepperForm({super.key});

  @override
  State<SetupStepperForm> createState() => _SetupStepperFormState();
}

class _StepInfo {
  const _StepInfo(this.title, this.icon);
  final String title;
  final IconData icon;
}

class _SetupStepperFormState extends State<SetupStepperForm> {
  final AppLogger logger = AppLogger(null);
  final windowManager = WindowManager.instance;
  final encHelper = EncryptionHelper();
  AppUser? appUser;
  int currentStep = 0;

  static const _stepInfo = <_StepInfo>[
    _StepInfo('Account', Icons.person_outline),
    _StepInfo('Storage', Icons.folder_outlined),
    _StepInfo('Encryption', Icons.key_outlined),
    _StepInfo('Language', Icons.language),
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            for (int i = 0; i < _stepInfo.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color:
                        i <= currentStep
                            ? colorScheme.primary
                            : colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Step ${currentStep + 1} of ${_stepInfo.length} — ${_stepInfo[currentStep].title}',
          style: textTheme.labelLarge?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        getSteps(context)[currentStep],
      ],
    );
  }

  void onStepCancelHandler() {
    setState(() {
      currentStep = (currentStep - 1);
    });
  }

  void onStepContinueHandler(
    BuildContext context,
    AppUser? appUser_,
    int step,
  ) async {
    Object? sDir = MainApp.supportDirectory.value;
    String supportDir = (sDir is String) ? sDir : (sDir as Directory).path;

    //update user
    appUser = appUser_;

    bool isLastStep = (step == _stepInfo.length - 1);
    if (isLastStep) {
      //final validation before saving user, redirect back if needed
      if (appUser == null) {
        setState(() {
          currentStep = 0;
        });
        return;
      } else if (appUser!.localStoragePath.isEmpty) {
        setState(() {
          currentStep = 1;
        });
        return;
      } else if (appUser!.publicKey == null || appUser!.privateKey == null) {
        setState(() {
          currentStep = 2;
        });
        return;
      }

      //Write storage location to local lookup file.
      var config = await createConfigFile(appUser);
      var jsonConfig = jsonEncode(config);

      File(
        p.join(supportDir, AppConstants.configFileName),
      ).writeAsStringSync(jsonConfig);

      //initialize empty database in the user defined directory
      MainApp.appDataDirectory.add(appUser!.localStoragePath);

      // Initialize database
      await DatabaseManager.instance.initializeDatabase();
      MainApp.databaseManager = DatabaseManager.instance;

      // Start the embedded aiserver process (normally done on the next app
      // launch by MainAppState._initStartup, but the setup wizard completes
      // within the same running process so it must start it here too).
      try {
        final pythonMgr = await PythonManager.forAppSupport();
        await pythonMgr.startAiServerService();
        MainApp.pythonManager = pythonMgr;
        // Fire-and-forget: download default AI Chat models in the background,
        // same as MainAppState._initStartup does on normal launches.
        unawaited(ModelDownloadManager.instance.start());
      } catch (e) {
        logger.e('Failed to start aiserver after setup: $e');
      }

      //Create new instance of User
      AppUser u = AppUser(
        id: appUser!.id,
        name: appUser!.name,
        email: appUser!.email,
        password: appUser!.password,
        localStoragePath: appUser!.localStoragePath,
      );
      u.privateKey = appUser!.privateKey;
      u.publicKey = appUser!.publicKey;

      //save user to database
      final savedUser = await UserRepository(
        DatabaseManager.instance.database!,
      ).saveUser(u);
      if (savedUser == null) {
        throw Exception('Failed to save user');
      }

      //do full login to check everything is ok
      AppUser? newUser = await GetUserService.instance.invoke(
        GetUserServiceCommand(appUser!.password),
      );
      if (newUser != null) {
        if (context.mounted) {
          GoRouter.of(context).go("/");
        }
      }

      if (context.mounted) {
        context.go("/");
      }
    } else if (appUser != null) {
      setState(() {
        currentStep = step + 1;
      });
    }
  }

  Future<Map<String, dynamic>> createConfigFile(AppUser? appUser) async {
    final storagePath = appUser!.localStoragePath;
    final supportsWal = await DatabaseManager.testPathSupportsWal(storagePath);
    String databasePath = storagePath;
    if (!supportsWal) {
      final realSupportPath =
          await DatabaseManager.getRealApplicationSupportPath();
      databasePath = realSupportPath;
    }
    return <String, dynamic>{'storage': storagePath, 'database': databasePath};
  }

  List<Widget> getSteps(BuildContext context) {
    return <Widget>[
      SetupStep1(
        onCancel: () => onStepCancelHandler(),
        onSubmit: (user) => onStepContinueHandler(context, user, 0),
      ),
      SetupStep2(
        appUser: appUser,
        onCancel: () => onStepCancelHandler(),
        onSubmit: (user) => onStepContinueHandler(context, user, 1),
      ),
      SetupStep3(
        appUser: appUser,
        onCancel: () => onStepCancelHandler(),
        onSubmit: (user) => onStepContinueHandler(context, user, 2),
      ),
      SetupStep4(
        appUser: appUser,
        onCancel: () => onStepCancelHandler(),
        onSubmit: (user) => onStepContinueHandler(context, user, 3),
      ),
    ];
  }
}
