import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../models/analytics_event.dart';

/// Records app-interaction events to `users/{uid}/analytics_events`.
///
/// Singleton so it can hold the current session (id + start time) across the
/// widget tree. Every method is fire-and-forget and swallows its own errors:
/// analytics must never crash the app or block the UI.
class AnalyticsService {
  static final AnalyticsService _instance = AnalyticsService._internal();
  factory AnalyticsService() => _instance;
  AnalyticsService._internal();

  static final _db = FirebaseFirestore.instance;

  /// Id of the session currently in progress, or null when backgrounded.
  String? _sessionId;
  DateTime? _sessionStart;

  /// Last screen we logged, so repeated rebuilds don't spam duplicate views.
  String? _lastScreen;

  String get _platform {
    if (kIsWeb) return 'web';
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    return 'other';
  }

  /// Writes one event for the signed-in user. No-ops when logged out.
  Future<void> _log(AnalyticsEvent event) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await _db
          .collection('users')
          .doc(user.uid)
          .collection('analytics_events')
          .add(event.toMap());
    } catch (e) {
      // Never let telemetry surface to the user.
      print('AnalyticsService: failed to log ${event.type}: $e');
    }
  }

  // ─── Session lifecycle ────────────────────────────────────────────────────

  /// Begins a foreground session. Safe to call repeatedly; a session already in
  /// progress is left untouched (e.g. resume firing without a prior pause).
  Future<void> startSession() async {
    if (_sessionId != null) return;
    _sessionStart = DateTime.now();
    _sessionId = _sessionStart!.millisecondsSinceEpoch.toString();
    _lastScreen = null;
    await _log(AnalyticsEvent(
      type: AnalyticsEvent.typeSessionStart,
      platform: _platform,
      sessionId: _sessionId,
    ));
  }

  /// Ends the current session, recording how long the user stayed. No-op if no
  /// session is active.
  Future<void> endSession() async {
    final id = _sessionId;
    final start = _sessionStart;
    if (id == null || start == null) return;

    final durationMs = DateTime.now().difference(start).inMilliseconds;
    _sessionId = null;
    _sessionStart = null;
    _lastScreen = null;

    await _log(AnalyticsEvent(
      type: AnalyticsEvent.typeSessionEnd,
      platform: _platform,
      sessionId: id,
      durationMs: durationMs,
    ));
  }

  // ─── Convenience events ───────────────────────────────────────────────────

  /// Logs a successful sign-in and opens the first session for it.
  Future<void> logLogin() async {
    await _log(AnalyticsEvent(
      type: AnalyticsEvent.typeLogin,
      platform: _platform,
    ));
    await startSession();
  }

  /// Logs sign-out. Closes the active session first so its duration is captured.
  Future<void> logLogout() async {
    await endSession();
    await _log(AnalyticsEvent(
      type: AnalyticsEvent.typeLogout,
      platform: _platform,
    ));
  }

  /// Logs a screen/tab view. De-duplicates consecutive views of the same screen.
  Future<void> logScreenView(String screen) async {
    if (screen == _lastScreen) return;
    _lastScreen = screen;
    await _log(AnalyticsEvent(
      type: AnalyticsEvent.typeScreenView,
      platform: _platform,
      sessionId: _sessionId,
      screen: screen,
    ));
  }

  /// Logs that a notification was displayed in the foreground. Pairing this with
  /// [logNotificationTap] lets us compute a tap-through rate per notification
  /// type — the core of "which notifications work best".
  Future<void> logNotificationShown({
    required String notificationType,
    String? screen,
  }) async {
    await _log(AnalyticsEvent(
      type: AnalyticsEvent.typeNotificationShown,
      platform: _platform,
      sessionId: _sessionId,
      screen: screen,
      params: {'notificationType': notificationType},
    ));
  }

  /// Logs that the user tapped a notification. [notificationType] is the `type`
  /// field from the notification payload (e.g. `daily_scan_reminder`).
  Future<void> logNotificationTap({
    required String notificationType,
    String? screen,
  }) async {
    await _log(AnalyticsEvent(
      type: AnalyticsEvent.typeNotificationTap,
      platform: _platform,
      // A tap can arrive before a session exists (cold start from a
      // notification); the session id may legitimately be null here.
      sessionId: _sessionId,
      screen: screen,
      params: {'notificationType': notificationType},
    ));
  }
}
