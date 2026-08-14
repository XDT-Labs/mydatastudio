import 'package:material_ui/material_ui.dart';
import 'package:fluttertoast/fluttertoast.dart';

///
/// Useful modal popups and toast that are reused throughout the app
/// How to use
/// @see https://medium.com/@azharbinanwar/coding-made-easy-using-handy-extensions-on-buildcontext-46283b3655be
extension WidgetExtension<T> on BuildContext {
  Future<T?> showBottomSheet(
    Widget child, {
    bool isScrollControlled = true,
    Color? backgroundColor,
    Color? barrierColor,
  }) {
    return showModalBottomSheet(
      context: this,
      barrierColor: barrierColor,
      isScrollControlled: isScrollControlled,
      backgroundColor: backgroundColor,
      builder: (context) => Wrap(children: [child]),
    );
  }

  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSnackBar(
    String message,
  ) {
    return ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
        // backgroundColor: primary,
      ),
    );
  }

  void showToast(String message) {
    FToast fToast = FToast();
    fToast.init(this);

    Widget toast = Container(
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(25.0),
        color: Colors.black87,
      ),
      child: Text(message, style: const TextStyle(color: Colors.white)),
    );

    fToast.showToast(
      child: toast,
      gravity: ToastGravity.BOTTOM,
      toastDuration: const Duration(seconds: 2),
    );
  }
}

//see https://flutterqueen5.medium.com/flutter-tip-easy-padding-and-margin-988461882368
// extension on Column {
// Widget wrap({double padding=16.0, double  margin=8.0}) {
//   final reversedChildren = children.map((e) => Container(
//       padding: EdgeInsets.all(padding),
//       margin: EdgeInsets.all(margin),
//       child: e)).toList();
//   return Column(
//     children: reversedChildren,);
// }
