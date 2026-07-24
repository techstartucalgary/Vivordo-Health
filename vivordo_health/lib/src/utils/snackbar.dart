import 'package:flutter/material.dart';

class SnackBars {
  static Future<dynamic> authMessage({
    required String message,
    required BuildContext context,
  }) async {
    return ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
