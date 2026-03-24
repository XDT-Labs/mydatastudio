import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:googleapis/adsense/v2.dart';
import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/helpers/encryption_helper.dart';
import 'package:mydatatools/main.dart';
import 'package:mydatatools/models/tables/app_user.dart';
import 'package:mydatatools/services/get_user_service.dart';

import 'package:mydatatools/widgets/setup/setup_step1.dart';
import 'package:mydatatools/widgets/setup/setup_step2.dart';
import 'package:mydatatools/widgets/setup/setup_step3.dart';
import 'package:flutter/material.dart'
    as material; //create alias because Padding is in multiple widgets
import 'package:flutter/material.dart';
import 'package:mydatatools/app_logger.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

class SetupStepperForm extends StatefulWidget {
  const SetupStepperForm({super.key});

  @override
  State<SetupStepperForm> createState() => _SetupStepperFormState();
}

class _SetupStepperFormState extends State<SetupStepperForm> {
  final AppLogger logger = AppLogger(null);
  final windowManager = WindowManager.instance;
  final encHelper = EncryptionHelper();
  SendPort? dbWriterPort;
  AppUser? appUser;
  int currentStep = 0;

  @override
  Widget build(BuildContext context) {
    return Stepper(
      type: StepperType.horizontal,
      currentStep: currentStep,
      controlsBuilder: (context, details) => Container(),
      steps: getSteps(context),
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

    bool isLastStep = (step == getSteps(context).length - 1);
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
      } else if (appUser!.publicKey == null || appUser!.privateKey == null) {
        setState(() {
          currentStep = 2;
        });
      }

      //Write storage location to local lookup file.
      var config = createConfigFile(appUser);
      var jsonConfig = jsonEncode(config);

      File(
        p.join(supportDir, AppConstants.configFileName),
      ).writeAsStringSync(jsonConfig);

      //initialize empty database in the user defined directory
      MainApp.appDataDirectory.add(appUser!.localStoragePath);

      // Initialize database
      await DatabaseManager.instance.initializeDatabase();

      //final theme = Theme.of(context);
      dbWriterPort = await DatabaseManager.instance.writerPort;
      if (dbWriterPort == null) {
        throw Exception('Failed to get db writer port');
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
      final receivePort = ReceivePort();
      dbWriterPort?.send({
        'type': 'user',
        'user': u,
        'replyTo': receivePort.sendPort,
      });

      final response = await receivePort.first;
      if (response == null) {
        throw Exception('Failed to save user');
      } else {
        //do full login to check everything is ok
        AppUser? newUser = await GetUserService.instance!.invoke(
          GetUserServiceCommand(appUser!.password),
        );
        if (newUser != null) {
          if (context.mounted) {
            GoRouter.of(context).go("/");
          }
        } else {
          // TODO: do something on save
        }
      }
      receivePort.close();

      if (response is Map && response.containsKey('error')) {
        logger.e("Error saving user: ${response['error']}");
        return;
      }

      if (context.mounted) {
        context.go("/");
      }
    } else if (appUser != null) {
      //CurrentStep.gotoStep(step + 1);
      setState(() {
        currentStep = step + 1;
      });
    }
  }

  Map<String, dynamic> createConfigFile(AppUser? appUser) => <String, dynamic>{
    'path': appUser!.localStoragePath,
  };

  List<Step> getSteps(BuildContext context) {
    return <Step>[
      Step(
        state: currentStep > 0 ? StepState.complete : StepState.indexed,
        isActive: currentStep >= 0,
        title: const Text("Personal Info"),
        content: material.Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 48),
          child: SetupStep1(
            onCancel: () => onStepCancelHandler(),
            onSubmit: (user) => onStepContinueHandler(context, user, 0),
          ),
        ),
      ),
      Step(
        state: currentStep > 1 ? StepState.complete : StepState.indexed,
        isActive: currentStep >= 1,
        title: const Text("Storage"),
        content: material.Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 48),
          child: SetupStep2(
            appUser: appUser,
            onCancel: () => onStepCancelHandler(),
            onSubmit: (user) => onStepContinueHandler(context, user, 1),
          ),
        ),
      ),
      Step(
        state: currentStep > 2 ? StepState.complete : StepState.indexed,
        isActive: currentStep >= 2,
        title: const Text("Encryption Keys"),
        content: material.Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 48),
          child: SetupStep3(
            appUser: appUser,
            onCancel: () => onStepCancelHandler(),
            onSubmit: (user) => onStepContinueHandler(context, user, 2),
          ),
        ),
      ),
    ];
  }
}
