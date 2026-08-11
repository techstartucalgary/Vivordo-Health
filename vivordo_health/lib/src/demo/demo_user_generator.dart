// this file is responsible for creating realistic demo data
// values are random but bounded so they look like real humans
// no ids or ui logic here, just data generation

import 'dart:math';
import 'demo_user_data.dart';

class DemoUserGenerator {
  final Random _rng = Random();

  // helpers to keep values inside reasonable limits
  int _clampInt(int v, int min, int max) =>
      v < min ? min : (v > max ? max : v);

  double _clampDouble(double v, double min, double max) =>
      v < min ? min : (v > max ? max : v);

  // derives stress category from numeric stress level
  String _stressCategory(int level) {
    if (level <= 33) return "Low";
    if (level <= 66) return "Moderate";
    return "High";
  }

  // pick random item from a list
  String _pick(List<String> items) => items[_rng.nextInt(items.length)];

  // wording pools (more variety)
  final List<String> _lowStressMoods = [
    "Calm",
    "Content",
    "Focused",
    "Relaxed",
    "Okay",
    "Motivated",
  ];

  final List<String> _highStressMoods = [
    "Anxious",
    "Overwhelmed",
    "Tense",
    "Irritable",
    "Drained",
    "Stressed",
  ];

  final List<String> _lowStressSummaries = [
    "day felt steady and manageable overall.",
    "felt productive and mentally balanced.",
    "kept a good rhythm throughout the day.",
    "things went smoothly and focus was solid.",
    "energy was stable and mood stayed positive.",
    "worked through tasks without much pressure.",
  ];

  final List<String> _highStressSummaries = [
    "felt some pressure today but managed with short breaks.",
    "stress peaked at times and it was hard to stay focused.",
    "felt mentally overloaded and low on energy.",
    "a few moments felt overwhelming but i pushed through.",
    "felt tense most of the day and needed more downtime.",
    "pressure built up, but i tried to reset and keep going.",
  ];

  final List<String> _lowStressKeywords = [
    "routine",
    "balance",
    "focus",
    "progress",
    "calm",
    "steady",
  ];

  final List<String> _highStressKeywords = [
    "stress",
    "fatigue",
    "pressure",
    "anxiety",
    "overload",
    "tension",
  ];

  // main function that builds one demo user
  // caller only provides a userId, everything else is filled in
  DemoUserData generate(String userId) {
    final now = DateTime.now();
    final date =
        "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

    final stress = _clampInt(50 + _rng.nextInt(31) - 15, 0, 100);
    final sleepHours =
        _clampDouble(7 + (_rng.nextDouble() * 1.6) - 0.8, 4, 10);

    final stressed = stress >= 60;

    // random-ish but stress-aware writing fields
    final journalMood =
        stressed ? _pick(_highStressMoods) : _pick(_lowStressMoods);
    final journalEntrySummary =
        stressed ? _pick(_highStressSummaries) : _pick(_lowStressSummaries);
    final keyword =
        stressed ? _pick(_highStressKeywords) : _pick(_lowStressKeywords);

    return DemoUserData(
      userId: userId,
      date: date,
      age: 18 + _rng.nextInt(18),
      gender: _rng.nextBool() ? "Male" : "Female",
      timezone: "America/Edmonton",

      dailyStressLevel: stress,
      stressCategory: _stressCategory(stress),
      stressVariability: _clampInt(40 + _rng.nextInt(21) - 10, 0, 100),

      restingHeartRate: _clampInt(62 + _rng.nextInt(17) - 8, 45, 95),
      hrv: _clampInt(50 + _rng.nextInt(21) - 10, 15, 120),
      sleepDurationHours: sleepHours,
      sleepQualityScore: _clampInt(72 + _rng.nextInt(17) - 8, 0, 100),

      totalActiveMinutes: _clampInt(45 + _rng.nextInt(31) - 15, 0, 240),
      sedentaryMinutes: _clampInt(540 + _rng.nextInt(121) - 60, 0, 1000),
      stepsCount: _clampInt(8000 + _rng.nextInt(3001) - 1500, 0, 25000),
      exerciseSessions: _clampInt(1 + _rng.nextInt(3) - 1, 0, 4),
      hydrationLogged: _rng.nextInt(100) < 70,

      goalAchieved: _rng.nextInt(100) < 45,
      journalMood: journalMood,
      journalEntrySummary: journalEntrySummary,
      keyword: keyword,
      stressed: stressed,
    );
  }
}
