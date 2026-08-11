import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:intl/intl.dart';

// ─── Metric definitions ──────────────────────────────────────────────────────

/// Every HealthKit metric the app supports, with UI metadata.
class HealthMetricDef {
  final String key;          // Firestore metricType value
  final HealthDataType type; // HealthKit data type
  final String label;        // Display label
  final String description;  // One-line description for consent UI
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

  // ─── Consent stream (shared broadcast) ────────────────────────────────────

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
    _consentBroadcast = _db
        .collection('users')
        .doc(uid)
        .snapshots()
        .map((snap) {
          final raw = snap.data()?['healthKitConsent'] as Map? ?? {};
          return raw.map((k, v) => MapEntry(k.toString(), v == true));
        })
        .asBroadcastStream();
    return _consentBroadcast!;
  }

  /// Clear cached stream on sign-out so the next user gets a fresh listener.
  void clearConsentCache() {
    _consentBroadcast = null;
    _consentCacheUid = null;
  }

  /// Read the current consent map once (non-reactive).
  Future<Map<String, bool>> getConsent() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return {};
    final doc = await _db.collection('users').doc(uid).get();
    final raw = doc.data()?['healthKitConsent'] as Map? ?? {};
    return raw.map((k, v) => MapEntry(k.toString(), v == true));
  }

  // ─── Permission requests ───────────────────────────────────────────────────

  /// Request HealthKit permission for ALL metrics at once, then do a full sync.
  /// Call this when the user taps "Connect Apple Health" for the first time.
  Future<void> enableAll() async {
    await _health.configure();
    final types = kHealthMetrics.map((m) => m.type).toList();
    final perms = kHealthMetrics.map((_) => HealthDataAccess.READ).toList();

    // This shows the iOS permission sheet for all metrics in one dialog.
    await _health.requestAuthorization(types, permissions: perms);

    // Mark all as consented — iOS never tells us which ones the user denied,
    // so we record intent here. Charts only appear when real data arrives.
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final consentMap = {for (final m in kHealthMetrics) m.key: true};
    await _db.collection('users').doc(uid).set(
      {'healthKitConsent': consentMap},
      SetOptions(merge: true),
    );

    // Sync the last 30 days for all metrics.
    await syncToFirestore(daysBack: 30);
  }

  /// Request HealthKit permission for a single metric, then sync it.
  Future<bool> enableMetric(String metricKey) async {
    final def = kMetricByKey[metricKey];
    if (def == null) return false;

    await _health.configure();
    final granted = await _health.requestAuthorization(
      [def.type],
      permissions: [HealthDataAccess.READ],
    );

    await _setConsent(metricKey, true);
    if (granted) {
      await syncMetric(metricKey, daysBack: 30);
    }
    return granted;
  }

  /// Revoke consent for a metric and delete its Firestore data.
  Future<void> disableMetric(String metricKey) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await _setConsent(metricKey, false);
    final query = await _db
        .collection('metrics_daily')
        .where('userId', isEqualTo: uid)
        .where('metricType', isEqualTo: metricKey)
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
        batch.delete(doc.reference);
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
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final def = kMetricByKey[metricKey];
    if (def == null) return;

    await _health.configure();
    final now   = DateTime.now();
    final start = now.subtract(Duration(days: daysBack));

    try {
      final dataPoints = await _health.getHealthDataFromTypes(
        startTime: start,
        endTime: now,
        types: [def.type],
      );
      if (dataPoints.isEmpty) return;
      await _writeDataPoints(uid, def, dataPoints);
    } catch (e, st) {
      debugPrint('HealthService.syncMetric($metricKey): $e\n$st');
      rethrow; // Surface Firestore/permissions errors to the caller
    }
  }

  Future<void> syncToFirestore({int daysBack = 30}) async {
    final consent = await getConsent();
    for (final m in kHealthMetrics) {
      if (consent[m.key] == true) {
        try {
          await syncMetric(m.key, daysBack: daysBack);
        } catch (e) {
          // One metric failing (e.g. permissions) shouldn't stop the others.
          debugPrint('HealthService.syncToFirestore — skipped ${m.key}: $e');
        }
      }
    }

    // Compute and write wellness score for each day in the window
    try {
      await _computeAndWriteWellness(uid: FirebaseAuth.instance.currentUser?.uid, daysBack: daysBack);
    } catch (e) {
      debugPrint('HealthService.syncToFirestore — wellness compute failed: $e');
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      try {
        await _db.collection('users').doc(uid).set(
          {'lastHealthKitSync': FieldValue.serverTimestamp()},
          SetOptions(merge: true),
        );
      } catch (e) {
        debugPrint('HealthService.syncToFirestore — could not update lastSync: $e');
      }
    }
  }

  Future<void> syncToday() => syncToFirestore(daysBack: 1);

  // ─── Internal helpers ──────────────────────────────────────────────────────

  Future<void> _setConsent(String metricKey, bool value) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await _db.collection('users').doc(uid).set(
      {'healthKitConsent': {metricKey: value}},
      SetOptions(merge: true),
    );
  }

  Future<void> _writeDataPoints(
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

    final batch = _db.batch();
    for (final entry in byDay.entries) {
      final day  = entry.key;
      final vals = entry.value;
      final ref  = _db.collection('metrics_daily').doc('${uid}_${def.key}_$day');
      batch.set(ref, {
        'userId':     uid,
        'metricType': def.key,
        'period':     day,
        'tags':       [def.key],
        'source':     'apple_health',
        'syncedAt':   FieldValue.serverTimestamp(),
        ..._buildValueMap(def.type, vals),
      }, SetOptions(merge: true));
    }
    await batch.commit();
  }

  Map<String, dynamic> _buildValueMap(HealthDataType type, List<double> vals) {
    double sum() => vals.fold(0.0, (a, b) => a + b);
    double avg() => sum() / vals.length;
    double min() => vals.reduce((a, b) => a < b ? a : b);
    double max() => vals.reduce((a, b) => a > b ? a : b);

    switch (type) {
      // ── Cumulative (sum is meaningful) ──────────────────────────────────────
      case HealthDataType.STEPS:
        return {'sum': sum(), 'avg': avg(), 'unit': 'steps', 'dimension': 'activity'};
      case HealthDataType.ACTIVE_ENERGY_BURNED:
        return {'sum': sum(), 'avg': avg(), 'unit': 'kcal', 'dimension': 'activity'};
      case HealthDataType.EXERCISE_TIME:
        return {'sum': sum(), 'avg': avg(), 'unit': 'min', 'dimension': 'activity'};
      case HealthDataType.DISTANCE_WALKING_RUNNING:
        return {'sum': sum() / 1000, 'avg': avg() / 1000, 'unit': 'km', 'dimension': 'activity'};
      case HealthDataType.FLIGHTS_CLIMBED:
        return {'sum': sum(), 'avg': avg(), 'unit': 'flights', 'dimension': 'activity'};
      case HealthDataType.MINDFULNESS:
        return {'sum': sum(), 'avg': avg(), 'unit': 'min', 'dimension': 'mental'};

      // ── Point-in-time averages ───────────────────────────────────────────────
      case HealthDataType.HEART_RATE:
      case HealthDataType.RESTING_HEART_RATE:
        return {'avg': avg(), 'min': min(), 'max': max(), 'unit': 'bpm', 'dimension': 'cardiovascular'};

      case HealthDataType.HEART_RATE_VARIABILITY_SDNN:
        final hrvAvg = avg();
        final stress = ((1.0 - (hrvAvg.clamp(0, 100) / 100)) * 100).clamp(0.0, 100.0);
        return {'avg': hrvAvg, 'stressScore': stress, 'unit': 'ms', 'dimension': 'stress'};

      case HealthDataType.BLOOD_OXYGEN:
        return {'avg': avg(), 'min': min(), 'max': max(), 'unit': '%', 'dimension': 'cardiovascular'};

      case HealthDataType.RESPIRATORY_RATE:
        return {'avg': avg(), 'min': min(), 'max': max(), 'unit': 'brpm', 'dimension': 'respiratory'};

      // ── Sleep (Apple returns seconds) ────────────────────────────────────────
      case HealthDataType.SLEEP_ASLEEP:
      case HealthDataType.SLEEP_IN_BED:
        final hours = sum() / 3600;
        return {'avg': hours, 'min': min() / 3600, 'max': max() / 3600, 'unit': 'hours', 'dimension': 'sleep'};

      // ── Body metrics ─────────────────────────────────────────────────────────
      case HealthDataType.WEIGHT:
        return {'avg': avg(), 'unit': 'kg', 'dimension': 'body'};
      case HealthDataType.BODY_FAT_PERCENTAGE:
        return {'avg': avg(), 'unit': '%', 'dimension': 'body'};
      // case HealthDataType.VO2MAX:
      //   return {'avg': avg(), 'unit': 'ml/kg/min', 'dimension': 'fitness'};

      default:
        return {'avg': avg(), 'unit': '', 'dimension': 'other'};
    }
  }

  String _formatDate(DateTime dt) => DateFormat('yyyy-MM-dd').format(dt);


  Future<void> _computeAndWriteWellness({String? uid, int daysBack = 30}) async {
    if (uid == null) return;
    final now = DateTime.now();
    final batch = _db.batch();

    for (int i = 0; i < daysBack; i++) {
      final day = now.subtract(Duration(days: i));
      final period = _formatDate(day);

      // Read stress, sleep, steps for this day
      final stressSnap = await _db.collection('metrics_daily').doc('${uid}_stress_$period').get();
      final sleepSnap  = await _db.collection('metrics_daily').doc('${uid}_sleep_$period').get();
      final stepsSnap  = await _db.collection('metrics_daily').doc('${uid}_steps_$period').get();
      final hrvSnap    = await _db.collection('metrics_daily').doc('${uid}_hrv_$period').get();

      final stress = (stressSnap.data()?['avg'] as num?)?.toDouble();
      final sleep  = (sleepSnap.data()?['avg']  as num?)?.toDouble();
      final steps  = (stepsSnap.data()?['sum']  as num?)?.toDouble();
      final hrv    = (hrvSnap.data()?['avg']    as num?)?.toDouble();

      // Need at least one signal to compute wellness
      if (stress == null && sleep == null && steps == null && hrv == null) continue;

      // Weighted composite: stress inverted (lower stress = better wellness)
      double wellness = 0;
      int weight = 0;

      if (stress != null) { wellness += (100 - stress) * 0.35; weight += 35; }
      if (sleep  != null) {
        final sleepScore = ((sleep / 8.0) * 100).clamp(0.0, 100.0);
        wellness += sleepScore * 0.30;
        weight += 30;
      }
      if (steps  != null) {
        final stepsScore = ((steps / 10000.0) * 100).clamp(0.0, 100.0);
        wellness += stepsScore * 0.20;
        weight += 20;
      }
      if (hrv    != null) {
        final hrvScore = ((hrv / 100.0) * 100).clamp(0.0, 100.0);
        wellness += hrvScore * 0.15;
        weight += 15;
      }

      // Normalise to 0–100 based on available signals
      final finalWellness = weight > 0 ? (wellness / weight * 100).clamp(0.0, 100.0) : 0.0;

      final ref = _db.collection('metrics_daily').doc('${uid}_wellness_$period');
      batch.set(ref, {
        'userId':     uid,
        'metricType': 'wellness',
        'period':     period,
        'avg':        finalWellness,
        'unit':       'score',
        'dimension':  'wellness',
        'source':     'computed',
        'tags':       ['wellness'],
        'computedAt': FieldValue.serverTimestamp(),
        'updatedAt':  FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    await batch.commit();
  }
}
