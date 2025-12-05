import 'package:fluttertoast/fluttertoast.dart';

class ToastMessages {
  static Future<bool?> generalMessage({required String message}) async {
    return await Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_SHORT,
    );
  }
}
