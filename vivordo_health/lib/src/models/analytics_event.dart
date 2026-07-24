import 'package:cloud_firestore/cloud_firestore.dart';

/// A single app-interaction event, stored under
/// `users/{uid}/analytics_events/{autoId}`.
///
/// The subcollection is a lightweight event stream used to learn which parts of
/// the app get used, how long sessions last, and which notifications actually
/// get tapped. It is covered by the existing per-user wildcard security rule, so
/// only the owning user's client can write it; cross-user analysis is expected
/// to happen server-side (Admin SDK / BigQuery export).
class AnalyticsEvent {
  /// Canonical event type names. Kept as constants so producers and any future
  /// consumers agree on the exact strings.
  static const String typeLogin = 'login';
  static const String typeLogout = 'logout';
  static const String typeSessionStart = 'session_start';
  static const String typeSessionEnd = 'session_end';
  static const String typeScreenView = 'screen_view';
  static const String typeNotificationShown = 'notification_shown';
  static const String typeNotificationTap = 'notification_tap';

  /// One of the `type*` constants above (or any custom string for ad-hoc events).
  final String type;

  /// Groups every event that happened during one foreground session. Null for
  /// events (like login) that can fire before a session is established.
  final String? sessionId;

  /// Screen/route the event relates to, e.g. `home`, `scan`, `ai_chat`.
  final String? screen;

  /// Session length in milliseconds. Only set on [typeSessionEnd].
  final int? durationMs;

  /// `ios`, `android`, or `web`.
  final String platform;

  /// Free-form extra context (notification type, source, etc.).
  final Map<String, dynamic> params;

  AnalyticsEvent({
    required this.type,
    required this.platform,
    this.sessionId,
    this.screen,
    this.durationMs,
    this.params = const {},
  });

  /// Serialises for Firestore. `timestamp` is stamped server-side so client
  /// clock skew can't distort ordering or session-duration analysis.
  Map<String, dynamic> toMap() {
    return {
      'type': type,
      'platform': platform,
      if (sessionId != null) 'sessionId': sessionId,
      if (screen != null) 'screen': screen,
      if (durationMs != null) 'durationMs': durationMs,
      if (params.isNotEmpty) 'params': params,
      'timestamp': FieldValue.serverTimestamp(),
    };
  }

  factory AnalyticsEvent.fromMap(Map<String, dynamic> map) {
    return AnalyticsEvent(
      type: map['type'] ?? '',
      platform: map['platform'] ?? '',
      sessionId: map['sessionId'],
      screen: map['screen'],
      durationMs: map['durationMs'],
      params: map['params'] != null
          ? Map<String, dynamic>.from(map['params'])
          : const {},
    );
  }
}
