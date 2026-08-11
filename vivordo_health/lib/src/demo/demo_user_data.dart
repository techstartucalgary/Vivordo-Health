//this file defines what a demo user "looks like"
// it's just a container for example data no logic here
// the goal is to hold all fields needed for testing, gemini, or UI demos

class DemoUserData {
  final String userId;
  final String date;
  final int age;
  final String gender;
  final String timezone;

  final int dailyStressLevel;
  final String stressCategory;
  final int stressVariability;

  final int restingHeartRate;
  final int hrv;
  final double sleepDurationHours;
  final int sleepQualityScore;

  final int totalActiveMinutes;
  final int sedentaryMinutes;
  final int stepsCount;
  final int exerciseSessions;
  final bool hydrationLogged;

  final bool goalAchieved;
  final String journalMood;
  final String journalEntrySummary;
  final String keyword;
  final bool stressed;

  // constructor just wires everything together
  DemoUserData({
    required this.userId,
    required this.date,
    required this.age,
    required this.gender,
    required this.timezone,
    required this.dailyStressLevel,
    required this.stressCategory,
    required this.stressVariability,
    required this.restingHeartRate,
    required this.hrv,
    required this.sleepDurationHours,
    required this.sleepQualityScore,
    required this.totalActiveMinutes,
    required this.sedentaryMinutes,
    required this.stepsCount,
    required this.exerciseSessions,
    required this.hydrationLogged,
    required this.goalAchieved,
    required this.journalMood,
    required this.journalEntrySummary,
    required this.keyword,
    required this.stressed,
  });

  // converts the demo user into a map
  // useful for logging, sending to apis, or feeding gemini
  Map<String, dynamic> toMap() {
    return {
      "userId": userId,
      "date": date,
      "age": age,
      "gender": gender,
      "timezone": timezone,

      "dailyStressLevel": dailyStressLevel,
      "stressCategory": stressCategory,
      "stressVariability": stressVariability,

      "restingHeartRate": restingHeartRate,
      "hrv": hrv,
      "sleepDurationHours": sleepDurationHours,
      "sleepQualityScore": sleepQualityScore,

      "totalActiveMinutes": totalActiveMinutes,
      "sedentaryMinutes": sedentaryMinutes,
      "stepsCount": stepsCount,
      "exerciseSessions": exerciseSessions,
      "hydrationLogged": hydrationLogged,

      "goalAchieved": goalAchieved,
      "journalMood": journalMood,
      "journalEntrySummary": journalEntrySummary,
      "keyword": keyword,
      "stressed": stressed,
    };
  }
}
