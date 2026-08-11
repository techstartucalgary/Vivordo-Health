// this is the single entry point the rest of the app uses
// pages and buttons call this, not the generator directly
// it hides how ids are chosen and how data is created

// basically in order to the get DemoUserData object (controlled randomly generated user) 
// with all the fields you have to call DemoUserRepository().getRandomDemoUser()

import 'dart:math';
import 'demo_user_generator.dart';
import 'demo_user_data.dart';

class DemoUserRepository {
  final DemoUserGenerator _generator = DemoUserGenerator();
  final Random _rng = Random();

  // picks a demo id from a fixed demo-only range
  // caller never needs to know or care about ids
  String _randomUserId() {
    return (100 + _rng.nextInt(6)).toString(); // 100–105
  }

  // this is the function everyone uses
  // one call -> one full demo user dataset
  DemoUserData getRandomDemoUser() {
    final userId = _randomUserId();
    return _generator.generate(userId);
  }
}
