import 'package:mydatastudio/widgets/setup/setup_stepper_form.dart';
import 'package:flutter/material.dart';

class SetupPage extends StatelessWidget {
  const SetupPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scaffoldKey = GlobalKey<ScaffoldState>();
    //final textTheme = Theme.of(context).textTheme;
    //final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      key: scaffoldKey,
      backgroundColor: Colors.white,
      body: Row(
        children: [
          Expanded(
            flex: 4,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 48),
              child: Column(
                children: [
                  const Text('MyData Studio', style: TextStyle(fontSize: 48)),
                  Container(height: 16),
                  const Text(
                    'Keep a local copy of your digital life. \n\n\n',
                    style: TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
          ),
          const Expanded(
            flex: 6,
            child: Dialog(child: SizedBox.expand(child: SetupStepperForm())),
          ),
        ],
      ),
    );
  }
}
