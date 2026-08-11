class HomeConfig {
  List<String> widgets;
  String lastSeenInsightId;
  String primaryGoalId;

  HomeConfig({
    required this.widgets,
    required this.lastSeenInsightId,
    required this.primaryGoalId,
  });

  factory HomeConfig.fromMap(Map<String, dynamic> data) {
    return HomeConfig(
      widgets: data['widgets'],
      lastSeenInsightId: data['lastSeenInsightId'],
      primaryGoalId: data['primaryGoalId'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'widgets': widgets,
      'lastSeenInsightId': lastSeenInsightId,
      'primaryGoalId': primaryGoalId,
    };
  }
}
