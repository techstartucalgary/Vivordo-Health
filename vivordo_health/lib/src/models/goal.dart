import 'package:flutter/material.dart';

class Goal {
  String id;
  String title;
  String subtext;
  Color color;
  Set<int> days;

  Goal({
    required this.id,
    required this.title,
    required this.subtext,
    required this.color,
    required this.days,
  });

  int get currentStreak {
    if (days.isEmpty) return 0;
    int maxStreak = 0;
    int currentRun = 0;

    for (int i = 0; i < 7; i++) {
      if (days.contains(i)) {
        currentRun++;
        if (currentRun > maxStreak) maxStreak = currentRun;
      } else {
        currentRun = 0;
      }
    }
    return maxStreak;
  }
}
