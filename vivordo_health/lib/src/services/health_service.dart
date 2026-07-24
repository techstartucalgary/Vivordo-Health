import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:intl/intl.dart';
import 'stress_score_service.dart';

// ─── Metric definitions ──────────────────────────────────────────────────────

/// Every HealthKit metric the app supports, with UI metadata.
class HealthMetricDef {
  final String key; // Firestore metricType value
  final HealthDataType type; // HealthKit data type
  final String label; // Display label
  final String description; // One-line description for consent UI
  const HealthMetricDef({
    required this.key,
    required this.type,
    required this.label,
    required this.description,
  });
}

/// Full list of HealthKit metrics the app can read.
/// The only requirement to activate these is purchasing the HealthKit
/// capability in your Apple Developer account and adding a real device.
/// The code is complete — no further changes needed once HealthKit is bought.
const List<HealthMetricDef> kHealthMetrics = [
  // ── Activity ────────────────────────────────────────────────────────────────
  HealthMetricDef(
    key: 'steps',
    type: HealthDataType.STEPS,
    label: 'Steps',
    description: 'Daily step count from your iPhone or Apple Watch',
  ),
  HealthMetricDef(
    key: 'active_calories',
    type: HealthDataType.ACTIVE_ENERGY_BURNED,
    label: 'Active Calories',
    description: 'Calories burned during active movement',
  ),
  HealthMetricDef(
    key: 'exercise_time',
    type: HealthDataType.EXERCISE_TIME,
    label: 'Exercise Time',
    description: 'Minutes of exercise recorded by Apple Watch',
  ),
  HealthMetricDef(
    key: 'distance',
    type: HealthDataType.DISTANCE_WALKING_RUNNING,
    label: 'Distance',
    description: 'Distance walked or run (in km)',
  ),
  HealthMetricDef(
    key: 'flights_climbed',
    type: HealthDataType.FLIGHTS_CLIMBED,
    label: 'Flights Climbed',
    description: 'Flights of stairs climbed',
  ),
  // ── Heart ───────────────────────────────────────────────────────────────────
  HealthMetricDef(
    key: 'heart_rate',
    type: HealthDataType.HEART_RATE,
    label: 'Heart Rate',
    description: 'Resting and active heart rate readings (bpm)',
  ),
  HealthMetricDef(
    key: 'resting_heart_rate',
    type: HealthDataType.RESTING_HEART_RATE,
    label: 'Resting Heart Rate',
    description: 'Your daily resting heart rate (bpm)',
  ),
  HealthMetricDef(
    key: 'hrv',
    type: HealthDataType.HEART_RATE_VARIABILITY_SDNN,
    label: 'HRV',
    description: 'Heart Rate Variability — used to estimate your stress level',
  ),
  // ── Breathing / Vitals ──────────────────────────────────────────────────────
  HealthMetricDef(
    key: 'blood_oxygen',
    type: HealthDataType.BLOOD_OXYGEN,
    label: 'Blood Oxygen',
    description: 'SpO₂ readings from Apple Watch',
  ),
  HealthMetricDef(
    key: 'respiratory_rate',
    type: HealthDataType.RESPIRATORY_RATE,
    label: 'Respiratory Rate',
    description: 'Breaths per minute — elevated rates signal stress or illness',
  ),
  // ── Sleep ───────────────────────────────────────────────────────────────────
  HealthMetricDef(
    key: 'sleep',
    type: HealthDataType.SLEEP_ASLEEP,
    label: 'Sleep',
    description: 'Sleep duration tracked by Apple Watch or iPhone',
  ),
  // ── Body ────────────────────────────────────────────────────────────────────
  HealthMetricDef(
    key: 'weight',
    type: HealthDataType.WEIGHT,
    label: 'Weight',
    description: 'Body weight logged manually or via smart scale',
  ),
  HealthMetricDef(
    key: 'body_fat',
    type: HealthDataType.BODY_FAT_PERCENTAGE,
    label: 'Body Fat %',
    description: 'Body fat percentage from compatible devices',
  ),
  // ── Mind ────────────────────────────────────────────────────────────────────
  HealthMetricDef(
    key: 'mindfulness',
    type: HealthDataType.MINDFULNESS,
    label: 'Mindfulness',
    description: 'Meditation and mindfulness session minutes',
  ),
  // ── Fitness ─────────────────────────────────────────────────────────────────
  // TODO: uncomment once HealthDataType.VO2MAX is confirmed available in this
  // version of the health package. Gave 'undefined_enum_constant' on 12.2.1 —
  // may need a newer package version or Apple Developer HealthKit capability.
  // HealthMetricDef(
  //   key: 'vo2max',
  //   type: HealthDataType.VO2MAX,
  //   label: 'VO₂ Max',
  //   description: 'Cardio fitness score from Apple Watch workouts',
  // ),
];

/// Convenience lookup: metricKey → HealthMetricDef
final Map<String, HealthMetricDef> kMetricByKey = {
  for (final m in kHealthMetrics) m.key: m,
};

// ─── HealthService ───────────────────────────────────────────────────────────

class HealthService {
  static final HealthService _instance = HealthService._internal();
  factory HealthService() => _instance;
  HealthService._internal();

  final Health _health = Health();
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  bool _isRequestingAuthorization = false;
  Future<bool>? _authorizationFuture;
  bool? _authorizationResultThisSession;
  Future<void>? _activeSync;
  int _pendingSyncDays = 0;

  List<HealthDataType> get _authorizationTypes =>
      kHealthMetrics.map((metric) => metric.type).toList(growable: false);

  List<HealthDataAccess> get _authorizationAccess => List.filled(
    kHealthMetrics.length,
    HealthDataAccess.READ,
    growable: false,
  );

  // ─── Sync preferences (shared broadcast) ─────────────────────────────────

  // All callers share ONE Firestore listener via a broadcast stream.
  // Multiple listeners on the same doc caused Firestore's internal assertion error.
  Stream<Map<String, bool>>? _consentBroadcast;
  String? _consentCacheUid;

  Stream<Map<String, bool>> consentStream() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value({});
    if (_consentBroadcast != null && _consentCacheUid == uid) {
      return _consentBroadcast!;
    }
    _consentCacheUid = uid;
    _consentBroadcast = _db.collection('users').doc(uid).snapshots().map((
      snap,
    ) {
      final raw = snap.data()?['healthKitConsent'] as Map? ?? {};
      return raw.map((k, v) => MapEntry(k.toString(), v == true));
    }).asBroadcastStream();
    return _consentBroadcast!;
  }

  /// Clear cached stream on sign-out so the next user gets a fresh listener.
  void clearConsentCache() {
    _consentBroadcast = null;
    _consentCacheUid = null;
  }

  /// Read the user's metric sync selections once (non-reactive).
  Future<Map<String, bool>> getConsent() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return {};
    final doc = await _db.collection('users').doc(uid).get();
    final raw = doc.data()?['healthKitConsent'] as Map? ?? {};
    return raw.map((k, v) => MapEntry(k.toString(), v == true));
  }

  // ─── Permission requests ───────────────────────────────────────────────────

  /// Ensures all HealthKit read permissions used by routine sync are resolved.
  ///
  /// HealthKit deliberately reports read authorization as undetermined on iOS.
  /// Once this process has completed a request, an undetermined re-check means
  /// reads may be attempted; individual denied types will simply return no data.
  Future<bool> ensureHealthAuthorization() {
    final activeRequest = _authorizationFuture;
    if (activeRequest != null) {
      debugPrint(
        '[HealthService] Duplicate authorization request reused '
        '(requesting: $_isRequestingAuthorization).',
      );
      return activeRequest;
    }

    _isRequestingAuthorization = true;
    final request = _requestAndVerifyAuthorization();
    _authorizationFuture = request;
    return request.whenComplete(() {
      if (identical(_authorizationFuture, request)) {
        _authorizationFuture = null;
        _isRequestingAuthorization = false;
      }
    });
  }

  Future<bool> _requestAndVerifyAuthorization() async {
    final types = _authorizationTypes;
    final access = _authorizationAccess;

    try {
      await _health.configure();
      debugPrint('[HealthService] Authorization check started.');
      final current = await _health.hasPermissions(types, permissions: access);
      if (current == true) return true;

      // A READ check is always null on iOS. Do not reopen the sheet after a
      // request already completed during this app session.
      final previousResult = _authorizationResultThisSession;
      if (current == null && previousResult != null) {
        return previousResult;
      }

      debugPrint('[HealthService] Authorization request started.');
      final requested = await _health.requestAuthorization(
        types,
        permissions: access,
      );
      _authorizationResultThisSession = requested;
      debugPrint('[HealthService] Authorization request result: $requested.');
      return requested;
    } catch (error) {
      _authorizationResultThisSession = false;
      debugPrint('[HealthService] Authorization unavailable: $error');
      return false;
    }
  }

  /// Request HealthKit permission for ALL metrics at once, then do a full sync.
  /// Call this when the user taps "Connect Apple Health" for the first time.
  Future<bool> enableAll() async {
    final granted = await ensureHealthAuthorization();

    if (!granted) return false;

    // Mark all as requested/consented. On iOS, HealthKit does not disclose
    // per-type read grants after the prompt, so this records the user's app
    // intent while the actual charts still depend on real HealthKit data reads.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return granted;
    final consentMap = {for (final m in kHealthMetrics) m.key: true};
    await _db.collection('users').doc(uid).set({
      'healthKitConsent': consentMap,
    }, SetOptions(merge: true));

    // Sync the last 30 days for all metrics.
    await syncToFirestore(daysBack: 30);
    return granted;
  }

  /// Request HealthKit permission for a single metric, then sync it.
  Future<bool> enableMetric(String metricKey) async {
    final def = kMetricByKey[metricKey];
    if (def == null) return false;

    // Use the same complete type/access lists as routine sync authorization.
    // iOS presents permissions once while Firestore consent controls which
    // metrics Vivordo actually reads and stores.
    final granted = await ensureHealthAuthorization();

    await _setConsent(metricKey, granted);
    if (granted) {
      await syncMetric(metricKey, daysBack: 30);
    }
    return granted;
  }

  /// Revoke consent for a metric and remove its data from every daily doc.
  Future<void> disableMetric(String metricKey) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await _setConsent(metricKey, false);

    final query = await _db
        .collection('users')
        .doc(uid)
        .collection('metrics_daily')
        .get();
    if (query.docs.isEmpty) return;

    // Firestore batches are capped at 500 ops — chunk to stay under the limit.
    const chunkSize = 400;
    for (int i = 0; i < query.docs.length; i += chunkSize) {
      final chunk = query.docs.sublist(
        i,
        (i + chunkSize).clamp(0, query.docs.length),
      );
      final batch = _db.batch();
      for (final doc in chunk) {
        batch.update(doc.reference, {metricKey: FieldValue.delete()});
      }
      await batch.commit();
    }
  }

  /// Revoke ALL metrics and delete all HealthKit data from Firestore.
  Future<void> disableAll() async {
    for (final m in kHealthMetrics) {
      await disableMetric(m.key);
    }
  }

  // ─── Sync ──────────────────────────────────────────────────────────────────

  Future<void> syncMetric(String metricKey, {int daysBack = 30}) async {
    final authorized = await ensureHealthAuthorization();
    if (!authorized) {
      debugPrint(
        '[HealthService] Health authorization unavailable; skipping sync.',
      );
      return;
    }
    await _syncMetric(metricKey, daysBack: daysBack);
  }

  Future<void> _syncMetric(String metricKey, {int daysBack = 30}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final def = kMetricByKey[metricKey];
    if (def == null) return;

    await _health.configure();

    // HealthKit intentionally does not reveal read authorization status on iOS.
    // Only explicit user actions request permission; routine syncs read the
    // selected metrics and let HealthKit return the data available to the app.

    if (metricKey == 'steps') {
      await _syncStepTotals(uid, daysBack: daysBack);
      return;
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(Duration(days: daysBack - 1));

    try {
      if (_usesDailyTotals(def.type)) {
        final dataPoints = await _health.getHealthIntervalDataFromTypes(
          startDate: start,
          endDate: now,
          types: [def.type],
          interval: const Duration(days: 1).inSeconds,
        );

        if (dataPoints.isEmpty) {
          debugPrint(
            'HealthService.syncMetric($metricKey): no daily total data returned from Apple Health.',
          );
          await _deleteMetricForMissingDays(
            uid,
            metricKey,
            start: start,
            end: now,
            daysWithData: const {},
          );
          return;
        }

        final daysWithData = await _writeDataPoints(uid, def, dataPoints);
        await _deleteMetricForMissingDays(
          uid,
          metricKey,
          start: start,
          end: now,
          daysWithData: daysWithData,
        );
        return;
      }

      final dataPoints = await _health.getHealthDataFromTypes(
        startTime: start,
        endTime: now,
        types: [def.type],
      );

      if (metricKey == 'steps') {
        debugPrint(
          'DEBUG STEPS: Apple Health returned ${dataPoints.length} step data point(s) for $daysBack day(s).',
        );
      }

      if (dataPoints.isEmpty) {
        if (metricKey == 'steps') {
          debugPrint(
            'DEBUG STEPS: No step data returned from Apple Health. Nothing will be written to Firebase.',
          );
        }
        await _deleteMetricForMissingDays(
          uid,
          metricKey,
          start: start,
          end: now,
          daysWithData: const {},
        );
        return;
      }

      final daysWithData = await _writeDataPoints(uid, def, dataPoints);
      await _deleteMetricForMissingDays(
        uid,
        metricKey,
        start: start,
        end: now,
        daysWithData: daysWithData,
      );
    } catch (e, st) {
      debugPrint('HealthService.syncMetric($metricKey): $e\n$st');
      rethrow; // Surface Firestore/permissions errors to the caller
    }
  }

  Future<void> syncToFirestore({int daysBack = 30}) {
    if (daysBack > _pendingSyncDays) _pendingSyncDays = daysBack;

    final activeSync = _activeSync;
    if (activeSync != null) {
      debugPrint('[HealthService] Duplicate sync request reused.');
      return activeSync;
    }

    final worker = _drainSyncQueue();
    _activeSync = worker;
    return worker.whenComplete(() {
      if (identical(_activeSync, worker)) _activeSync = null;
    });
  }

  Future<void> _drainSyncQueue() async {
    while (_pendingSyncDays > 0) {
      final daysBack = _pendingSyncDays;
      _pendingSyncDays = 0;
      await _performSync(daysBack: daysBack);
    }
  }

  Future<void> _performSync({required int daysBack}) async {
    final authorized = await ensureHealthAuthorization();
    if (!authorized) {
      debugPrint(
        '[HealthService] Health authorization unavailable; skipping sync.',
      );
      return;
    }

    final consent = await getConsent();
    for (final m in kHealthMetrics) {
      if (consent[m.key] == true) {
        try {
          await _syncMetric(m.key, daysBack: daysBack);
        } catch (e) {
          // One metric failing (e.g. permissions) shouldn't stop the others.
          debugPrint('HealthService.syncToFirestore — skipped ${m.key}: $e');
        }
      }
    }

    // Compute and write wellness score for each day in the window
    try {
      await _computeAndWriteWellness(
        uid: FirebaseAuth.instance.currentUser?.uid,
        daysBack: daysBack,
      );
    } catch (e) {
      debugPrint('HealthService.syncToFirestore — wellness compute failed: $e');
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      try {
        await _db.collection('users').doc(uid).set({
          'lastHealthKitSync': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint(
          'HealthService.syncToFirestore — could not update lastSync: $e',
        );
      }
      // Recompute BaaS stress score now that fresh HealthKit data is in Firestore
      StressScoreService.computeAndSave(
        uid: uid,
        force: true,
      ).catchError((_) {});
    }
  }

  Future<void> syncToday() => syncToFirestore(daysBack: 1);

  // ─── Internal helpers ──────────────────────────────────────────────────────

  bool _usesDailyTotals(HealthDataType type) {
    return type == HealthDataType.ACTIVE_ENERGY_BURNED ||
        type == HealthDataType.DISTANCE_WALKING_RUNNING ||
        type == HealthDataType.FLIGHTS_CLIMBED;
  }

  Future<void> _syncStepTotals(String uid, {int daysBack = 30}) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final batch = _db.batch();
    final daysWithData = <String>{};
    var daysWritten = 0;

    for (var i = 0; i < daysBack; i++) {
      final day = today.subtract(Duration(days: i));
      final end = i == 0 ? now : day.add(const Duration(days: 1));
      var total = (await _health.getTotalStepsInInterval(day, end))?.toDouble();

      if (total == null) {
        debugPrint(
          'HealthService.syncMetric(steps): total API returned null for ${_formatDate(day)}. Trying raw step samples.',
        );
        total = await _readRawStepTotal(day, end);
        if (total == null) {
          debugPrint(
            'HealthService.syncMetric(steps): no raw step data returned for ${_formatDate(day)}',
          );
          continue;
        }
      }

      final dayKey = _formatDate(day);
      daysWithData.add(dayKey);
      final ref = _db
          .collection('users')
          .doc(uid)
          .collection('metrics_daily')
          .doc(dayKey);

      batch.set(ref, {
        'steps': {
          'sum': total,
          'avg': total,
          'unit': 'steps',
          'dimension': 'activity',
          'source': 'apple_health',
          'syncedAt': FieldValue.serverTimestamp(),
        },
        'date': dayKey,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      daysWritten++;
    }

    if (daysWritten == 0) return;
    await batch.commit();
    await _deleteMetricForMissingDays(
      uid,
      'steps',
      start: today.subtract(Duration(days: daysBack - 1)),
      end: now,
      daysWithData: daysWithData,
    );
    debugPrint(
      'HealthService.syncMetric(steps): wrote Apple Health step totals for $daysWritten day(s).',
    );
  }

  Future<double?> _readRawStepTotal(DateTime start, DateTime end) async {
    final points = await _health.getHealthDataFromTypes(
      startTime: start,
      endTime: end,
      types: [HealthDataType.STEPS],
    );

    var total = 0.0;
    for (final point in points) {
      if (point.value is! NumericHealthValue) continue;
      total += (point.value as NumericHealthValue).numericValue.toDouble();
    }

    return points.isEmpty ? null : total;
  }

  Future<void> _deleteMetricForMissingDays(
    String uid,
    String metricKey, {
    required DateTime start,
    required DateTime end,
    required Set<String> daysWithData,
  }) async {
    final startDay = DateTime(start.year, start.month, start.day);
    final endDay = DateTime(end.year, end.month, end.day);
    final days = endDay.difference(startDay).inDays + 1;
    if (days <= 0) return;

    final batch = _db.batch();
    var deletes = 0;

    for (var i = 0; i < days; i++) {
      final dayKey = _formatDate(startDay.add(Duration(days: i)));
      if (daysWithData.contains(dayKey)) continue;

      final ref = _db
          .collection('users')
          .doc(uid)
          .collection('metrics_daily')
          .doc(dayKey);
      batch.set(ref, {metricKey: FieldValue.delete()}, SetOptions(merge: true));
      deletes++;
    }

    if (deletes == 0) return;

    try {
      await batch.commit();
    } catch (e) {
      debugPrint(
        'HealthService.syncMetric($metricKey): stale-day cleanup skipped: $e',
      );
    }
  }

  Future<void> _setConsent(String metricKey, bool value) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await _db.collection('users').doc(uid).update({
      'healthKitConsent.$metricKey': value,
    });
  }

  Future<Set<String>> _writeDataPoints(
    String uid,
    HealthMetricDef def,
    List<HealthDataPoint> dataPoints,
  ) async {
    final Map<String, List<double>> byDay = {};
    for (final point in dataPoints) {
      if (point.value is! NumericHealthValue) continue;
      final day = _formatDate(point.dateFrom);
      final val = (point.value as NumericHealthValue).numericValue.toDouble();
      byDay.putIfAbsent(day, () => []).add(val);
    }

    if (byDay.isEmpty) return {};

    final batch = _db.batch();
    final daysWithData = <String>{};
    for (final entry in byDay.entries) {
      final day = entry.key;
      daysWithData.add(day);
      final vals = entry.value;
      final ref = _db
          .collection('users')
          .doc(uid)
          .collection('metrics_daily')
          .doc(day);
      final payload = _buildValueMap(def.type, vals);

      if (def.key == 'steps') {
        debugPrint('DEBUG STEPS: Preparing Firebase write for $day');
        debugPrint('DEBUG STEPS: Values = $vals');
        debugPrint('DEBUG STEPS: Payload = $payload');
      }

      batch.set(ref, {
        def.key: {
          ...payload,
          'source': 'apple_health',
          'syncedAt': FieldValue.serverTimestamp(),
        },
        'date': day,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    try {
      await batch.commit();
      debugPrint(
        'DEBUG: Firestore batch commit succeeded for ${def.key}. Days written: ${byDay.length}',
      );
      return daysWithData;
    } catch (e, st) {
      debugPrint('DEBUG: Firestore batch commit FAILED for ${def.key}: $e');
      debugPrint(st.toString());
      rethrow;
    }
  }

  Map<String, dynamic> _buildValueMap(HealthDataType type, List<double> vals) {
    double sum() => vals.fold(0.0, (a, b) => a + b);
    double avg() => sum() / vals.length;
    double min() => vals.reduce((a, b) => a < b ? a : b);
    double max() => vals.reduce((a, b) => a > b ? a : b);
    double normalizePercent(double value) => value <= 1 ? value * 100 : value;

    switch (type) {
      // ── Cumulative (sum is meaningful) ──────────────────────────────────────
      case HealthDataType.STEPS:
        return {
          'sum': sum(),
          'avg': avg(),
          'unit': 'steps',
          'dimension': 'activity',
        };
      case HealthDataType.ACTIVE_ENERGY_BURNED:
        return {
          'sum': sum(),
          'avg': avg(),
          'unit': 'kcal',
          'dimension': 'activity',
        };
      case HealthDataType.EXERCISE_TIME:
        return {
          'sum': sum(),
          'avg': avg(),
          'unit': 'min',
          'dimension': 'activity',
        };
      case HealthDataType.DISTANCE_WALKING_RUNNING:
        return {
          'sum': sum() / 1000,
          'avg': avg() / 1000,
          'unit': 'km',
          'dimension': 'activity',
        };
      case HealthDataType.FLIGHTS_CLIMBED:
        return {
          'sum': sum(),
          'avg': avg(),
          'unit': 'flights',
          'dimension': 'activity',
        };
      case HealthDataType.MINDFULNESS:
        return {
          'sum': sum(),
          'avg': avg(),
          'unit': 'min',
          'dimension': 'mental',
        };

      // ── Point-in-time averages ───────────────────────────────────────────────
      case HealthDataType.HEART_RATE:
      case HealthDataType.RESTING_HEART_RATE:
        return {
          'avg': avg(),
          'min': min(),
          'max': max(),
          'unit': 'bpm',
          'dimension': 'cardiovascular',
        };

      case HealthDataType.HEART_RATE_VARIABILITY_SDNN:
        final hrvAvg = avg();
        final stress = ((1.0 - (hrvAvg.clamp(0, 100) / 100)) * 100).clamp(
          0.0,
          100.0,
        );
        return {
          'avg': hrvAvg,
          'stressScore': stress,
          'unit': 'ms',
          'dimension': 'stress',
        };

      case HealthDataType.BLOOD_OXYGEN:
        return {
          'avg': normalizePercent(avg()),
          'min': normalizePercent(min()),
          'max': normalizePercent(max()),
          'unit': '%',
          'dimension': 'cardiovascular',
        };

      case HealthDataType.RESPIRATORY_RATE:
        return {
          'avg': avg(),
          'min': min(),
          'max': max(),
          'unit': 'brpm',
          'dimension': 'respiratory',
        };

      // ── Sleep (health package returns minutes for interval-based sleep data) ─
      case HealthDataType.SLEEP_ASLEEP:
      case HealthDataType.SLEEP_IN_BED:
        final hours = sum() / 60;
        return {
          'avg': hours,
          'min': min() / 60,
          'max': max() / 60,
          'unit': 'hours',
          'dimension': 'sleep',
        };

      // ── Body metrics ─────────────────────────────────────────────────────────
      case HealthDataType.WEIGHT:
        return {'avg': avg(), 'unit': 'kg', 'dimension': 'body'};
      case HealthDataType.BODY_FAT_PERCENTAGE:
        return {
          'avg': normalizePercent(avg()),
          'unit': '%',
          'dimension': 'body',
        };
      // case HealthDataType.VO2MAX:
      //   return {'avg': avg(), 'unit': 'ml/kg/min', 'dimension': 'fitness'};

      default:
        return {'avg': avg(), 'unit': '', 'dimension': 'other'};
    }
  }

  String _formatDate(DateTime dt) => DateFormat('yyyy-MM-dd').format(dt);

  Future<void> _computeAndWriteWellness({
    String? uid,
    int daysBack = 30,
  }) async {
    if (uid == null) return;
    final now = DateTime.now();
    final batch = _db.batch();

    for (int i = 0; i < daysBack; i++) {
      final day = now.subtract(Duration(days: i));
      final period = _formatDate(day);

      final snap = await _db
          .collection('users')
          .doc(uid)
          .collection('metrics_daily')
          .doc(period)
          .get();
      final data = snap.data();

      final stress = (data?['stress']?['avg'] as num?)?.toDouble();
      final sleep = (data?['sleep']?['avg'] as num?)?.toDouble();
      final steps = (data?['steps']?['sum'] as num?)?.toDouble();
      final hrv = (data?['hrv']?['avg'] as num?)?.toDouble();

      if (stress == null && sleep == null && steps == null && hrv == null)
        continue;

      double wellness = 0;
      int weight = 0;

      if (stress != null) {
        wellness += (100 - stress) * 0.35;
        weight += 35;
      }
      if (sleep != null) {
        final sleepScore = ((sleep / 8.0) * 100).clamp(0.0, 100.0);
        wellness += sleepScore * 0.30;
        weight += 30;
      }
      if (steps != null) {
        final stepsScore = ((steps / 10000.0) * 100).clamp(0.0, 100.0);
        wellness += stepsScore * 0.20;
        weight += 20;
      }
      if (hrv != null) {
        final hrvScore = ((hrv / 100.0) * 100).clamp(0.0, 100.0);
        wellness += hrvScore * 0.15;
        weight += 15;
      }

      final finalWellness = weight > 0
          ? (wellness / weight * 100).clamp(0.0, 100.0)
          : 0.0;

      final ref = _db
          .collection('users')
          .doc(uid)
          .collection('metrics_daily')
          .doc(period);
      batch.set(ref, {
        'wellness': {
          'avg': finalWellness,
          'unit': 'score',
          'source': 'computed',
          'computedAt': FieldValue.serverTimestamp(),
        },
        'date': period,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    await batch.commit();
  }
}
