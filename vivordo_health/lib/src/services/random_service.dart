import 'package:vivordo_health/src/utils/toast.dart';

class RandomService {
  //email sign in
  static Future<void> randomFunc() async {
    print("hello world in the terminal");
    ToastMessages.generalMessage(message: "hello world in the toast message");
  }
}
