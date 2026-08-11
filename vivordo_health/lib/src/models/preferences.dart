class Preferences {
  static const String scannerTutorialSeenKey = 'scannerTutorialSeen';

  String timezone;
  String locale;
  String units;
  bool notificationsEnabled;
  bool scannerTutorialSeen;

  Preferences({
    required this.timezone,
    required this.locale,
    required this.units,
    required this.notificationsEnabled,
    required this.scannerTutorialSeen,
  });

  factory Preferences.fromMap(Map<String, dynamic> data) {
    return Preferences(
      timezone: data['timezone'],
      locale: data['locale'],
      units: data['units'],
      notificationsEnabled: data['notificationsEnabled'],
      scannerTutorialSeen: data[scannerTutorialSeenKey] == true,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      "timezone": timezone,
      "locale": locale,
      "units": units,
      "notificationEnabled": notificationsEnabled,
      scannerTutorialSeenKey: scannerTutorialSeen,
    };
  }
}