import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Posts a BAAS v1 payload to https://vivordo-baas.onrender.com/baas/score
/// and saves the returned score to metrics_daily/{uid}_stress_{date}.
///
/// PAYLOAD CONTRACT (request_loader.py)
/// ─────────────────────────────────────
///   {
///     "user_id":     "firebase_uid",
///     "as_of":       "2026-06-11T14:00:00Z",   // null = now
///     "granularity": "daily",
///     "profile":     { "user_id", "age", "gender", "timezone" },
///     "samples":     [ { "metric_type", "timestamp", "value", "unit",
///                        "source", "duration_seconds" }, ... ],
///     "daily_context": [ { "date", "journal_mood", "self_reported_stress",
///                          "sleep_duration_hours", "exercise_sessions", ... } ]
///   }
///
/// RESPONSE CONTRACT (main.py / firestore_writer.py)
/// ──────────────────────────────────────────────────
///   {
///     "lean": { "score": 42.3, "band": "moderate",
///               "confidence": "high", "coverage_pct": 87.5,
///               "top_drivers": [...], "justification": "..." },
///     "breakdown": { ... },
///     "persisted": false
///   }
///
/// NOTE ON DATA QUALITY
/// ────────────────────
/// The BaaS preprocessor computes hour-matched rolling z-scores over 14 days
/// of INTRADAY samples. Until the app ships raw per-minute HealthKit readings,
/// this service reconstructs synthetic intraday samples from daily aggregates
/// stored in metrics_daily. This yields confidence="low/medium" from the BaaS
/// because baselines can only be estimated, not computed from per-hour windows.
///
/// To improve: add a getRawSamplesForBaas() method on HealthService that reads
/// raw HealthKit data points directly and passes them here instead of the
/// synthetic samples built from Firestore aggregates.
class StressScoreService {
  static const kApiUrl = 'https://vivordo-baas.onrender.com/baas/score';

  /// Validation / online-learning endpoint. Takes a completed day's metrics
  /// plus that day's 1-5 mood check-in as a supervised label, appends the pair
  /// to the training dataset, and nudges this user's channel weights toward
  /// whatever actually predicts how they said they felt.
  /// See weight_learning.py in the BaaS repo for the full rationale.
  static const kFeedbackUrl = 'https://vivordo-baas.onrender.com/baas/feedback';

/// Computes a BaaS stress score from the user's Firestore metrics and saves
  /// the result to metrics_daily/{uid}_stress_{today}.
  ///
  /// [force] — set true when fresh data was just written (mood check-in,
  ///   HealthKit sync) so the score always recomputes regardless of age.
  ///   Default false: skips the API call if a BaaS score already exists for
  ///   today and was computed within the last 30 minutes, avoiding unnecessary
  ///   cold-start hits on every home screen load.
  ///
  /// Call fire-and-forget: `StressScoreService.computeAndSave().catchError((_) {})`.
  static Future<void> computeAndSave({String? uid, bool force = false}) async {
    uid ??= FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final today = _formatDate(DateTime.now());

    if (!force) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .collection('metrics_daily')
            .doc(today)
            .get();
        final stressData = snap.data()?['stress'] as Map?;
        if (stressData?['source'] == 'baas_api') {
          final computedAt = (stressData?['computedAt'] as Timestamp?)?.toDate();
          if (computedAt != null &&
              DateTime.now().difference(computedAt).inMinutes < 30) {
            debugPrint('StressScoreService: score is fresh '
                '(${DateTime.now().difference(computedAt).inMinutes} min old), skipping');
            return;
          }
        }
      } catch (_) {}
    }

    try {
      final payload = await _buildPayload(uid, today);
      final result  = await _callApi(payload);
      if (result != null) await _saveScore(uid, today, result);
    } catch (e, st) {
      debugPrint('StressScoreService.computeAndSave: $e\n$st');
    }
  }

  // ── Validation / learning feedback ──────────────────────────────────────────

  /// Maps the home-screen mood labels to the 1-5 ordinal the BaaS expects
  /// (1 = Awful … 5 = Great). Mirrors MOOD_RATING_TO_LABEL in weight_learning.py.
  static const _moodLabelToRating = <String, int>{
    'awful': 1,
    'down': 2,
    'okay': 3,
    'good': 4,
    'great': 5,
  };

  /// Submits every COMPLETE, mood-labelled day that hasn't been sent yet.
  ///
  /// Call this on app launch and after a mood check-in — it is a no-op when
  /// there is nothing eligible, so both triggers are safe and cheap.
  ///
  /// WHY ONLY COMPLETE DAYS — and why a check-in does NOT submit its own day.
  /// The label has to be paired with that day's FULL metrics, and today's are
  /// unfinished: tonight's sleep hasn't happened, steps are still accruing, and
  /// the nocturnal HRV/HR windows that carry most of the physiological signal
  /// don't exist yet. Submitting today's tap against today's half-built day
  /// would train the model on systematically truncated inputs — the single
  /// easiest way to make a learning loop quietly worse than the fixed prior it
  /// started from. So a tap made today is picked up on the NEXT launch, once
  /// its day is closed. In practice that costs a day of latency and buys a
  /// clean dataset.
  ///
  /// Idempotency is enforced on both sides: locally via `baasFeedbackSentAt`
  /// on the day's metrics_daily doc, and server-side per user-day. The local
  /// marker exists to avoid pointless cold-start hits, not for correctness.
  ///
  /// Fire-and-forget: `StressScoreService.submitPendingFeedback().catchError((_) {})`.
  static Future<void> submitPendingFeedback({
    String? uid,
    int lookbackDays = 14,
    int maxPerRun = 5,
  }) async {
    uid ??= FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      final today = _formatDate(DateTime.now());
      final snap = await FirebaseFirestore.instance
          .collection('users').doc(uid).collection('metrics_daily').get();

      final earliest = _formatDate(
          DateTime.now().subtract(Duration(days: lookbackDays)));

      final pending = <String>[];
      for (final doc in snap.docs) {
        final date = doc.id;
        if (date.compareTo(today) >= 0) continue;    // today isn't complete yet
        if (date.compareTo(earliest) < 0) continue;  // too old to bother

        final data = doc.data();
        final mood = data['mood'] as Map?;
        if (mood == null || mood['label'] == null) continue;   // no label
        if (data['baasFeedbackSentAt'] != null) continue;      // already sent
        if (!_moodLabelToRating.containsKey(
            (mood['label'] as String).toLowerCase())) continue;
        pending.add(date);
      }

      pending.sort();
      if (pending.isEmpty) {
        debugPrint('StressScoreService.submitPendingFeedback: nothing pending');
        return;
      }

      // Cap per run: each call is a cold-start-prone HTTP round trip, and the
      // backlog will drain over subsequent launches anyway.
      final batch = pending.length > maxPerRun
          ? pending.sublist(pending.length - maxPerRun)
          : pending;
      debugPrint('StressScoreService.submitPendingFeedback: '
          '${pending.length} pending, submitting ${batch.length}');

      // One payload of history, reused for every labelled day — the BaaS needs
      // the full window regardless of which day it is being asked to label,
      // because the z-scores are computed against a rolling 14-day baseline.
      final basePayload = await _buildPayload(uid, today);

      for (final date in batch) {
        final moodLabel = (snap.docs
            .firstWhere((d) => d.id == date)
            .data()['mood'] as Map)['label'] as String;
        final rating = _moodLabelToRating[moodLabel.toLowerCase()]!;

        final ok = await _postFeedback({
          ...basePayload,
          'date': date,
          'mood_rating': rating,
          'mood_label': moodLabel,
          // Recorded so the confound stays visible in the dataset: this label
          // comes from "How are you feeling?" (affect), not from a stress item.
          // See warning 2 in weight_learning.py.
          'label_source': 'mood_checkin',
        });

        if (ok) {
          await FirebaseFirestore.instance
              .collection('users').doc(uid).collection('metrics_daily').doc(date)
              .set({'baasFeedbackSentAt': FieldValue.serverTimestamp()},
                   SetOptions(merge: true));
        }
      }
    } catch (e, st) {
      // Never let the learning loop break the app — it is an enhancement.
      debugPrint('StressScoreService.submitPendingFeedback: $e\n$st');
    }
  }

  static Future<bool> _postFeedback(Map<String, dynamic> payload) async {
    try {
      final res = await http
          .post(Uri.parse(kFeedbackUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(payload))
          .timeout(const Duration(seconds: _timeoutSeconds));

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        debugPrint('StressScoreService.feedback[${payload['date']}]: '
            'applied=${body['applied']} n=${body['n_samples']} '
            'predicted=${body['predicted_stress']} target=${body['target_stress']} '
            '— ${body['reason']}');
        // A rejected-but-understood day (e.g. thin coverage) still counts as
        // handled: the sample was stored server-side and re-sending it would
        // only burn another cold start for the same answer.
        return true;
      }
      // 422 = this day is not usable as a label (no metrics for it, bad
      // rating). Retrying will never change that, so mark it done.
      if (res.statusCode == 422) {
        debugPrint('StressScoreService.feedback[${payload['date']}]: '
            '422 — ${res.body}');
        return true;
      }
      debugPrint('StressScoreService.feedback[${payload['date']}]: '
          '${res.statusCode} — ${res.body}');
      return false;
    } catch (e) {
      debugPrint('StressScoreService.feedback[${payload['date']}]: $e');
      return false;  // transient — retry on the next launch
    }
  }

  // ── Asset-based test entry point ────────────────────────────────────────────

  /// Loads a BaaS v1 payload from [assetPath], re-dates all timestamps so
  /// the most recent day maps to today, swaps in the real [uid], posts to the
  /// BaaS API, saves the result, and returns the raw response for the debug panel.
  ///
  /// Drop any *.json into assets/test_payloads/ and pass its path here.
  /// Default: assets/test_payloads/test_payload.json
  static Future<Map<String, dynamic>?> computeWithTestPayload({
    String? uid,
    String assetPath = 'assets/test_payloads/test_payload.json',
  }) async {
    uid ??= FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    final today = _formatDate(DateTime.now());

    final raw     = jsonDecode(await rootBundle.loadString(assetPath)) as Map<String, dynamic>;
    final payload = _patchTestPayload(raw, uid);
    debugPrint('StressScoreService.test[$assetPath]: '
        '${(payload['samples'] as List).length} samples, '
        'shift → today=$today');

    final result = await _callApi(payload);
    if (result != null) await _saveScore(uid, today, result);
    return result;
  }

  /// Replaces user_id and shifts every timestamp/date so the most recent
  /// day in the file lands on today.  Preserves the +00:00 suffix so
  /// Python's datetime.fromisoformat() (pre-3.11) doesn't reject it.
  static Map<String, dynamic> _patchTestPayload(
      Map<String, dynamic> raw, String uid) {
    final samples = List<Map<String, dynamic>>.from(
        (raw['samples'] as List).map((e) => Map<String, dynamic>.from(e as Map)));
    final context = List<Map<String, dynamic>>.from(
        ((raw['daily_context'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map)));

    // Collect every date mentioned in the payload to find the latest one
    DateTime? latest;
    for (final s in samples) {
      final ts = s['timestamp'] as String?;
      if (ts == null) continue;
      final d = DateTime.tryParse(ts.substring(0, 10));
      if (d != null && (latest == null || d.isAfter(latest))) latest = d;
    }
    for (final c in context) {
      final d = DateTime.tryParse((c['date'] as String?) ?? '');
      if (d != null && (latest == null || d.isAfter(latest))) latest = d;
    }

    if (latest == null) {
      return {
        ...raw,
        'user_id': uid,
        'profile': {...(raw['profile'] as Map? ?? {}), 'user_id': uid},
      };
    }

    final todayUtc   = DateTime.utc(DateTime.now().year, DateTime.now().month, DateTime.now().day);
    final latestUtc  = DateTime.utc(latest.year, latest.month, latest.day);
    final shiftDays  = todayUtc.difference(latestUtc).inDays;

    for (final s in samples) {
      final ts = s['timestamp'] as String?;
      if (ts == null) continue;
      try {
        s['timestamp'] = _fmtTimestamp(DateTime.parse(ts).add(Duration(days: shiftDays)));
      } catch (_) {}
    }
    for (final c in context) {
      final d = c['date'] as String?;
      if (d == null) continue;
      try {
        c['date'] = _formatDate(DateTime.parse(d).add(Duration(days: shiftDays)));
      } catch (_) {}
    }

    return {
      ...raw,
      'user_id':       uid,
      'as_of':         DateTime.now().toUtc().toIso8601String(),
      'profile':       {...(raw['profile'] as Map? ?? {}), 'user_id': uid},
      'samples':       samples,
      'daily_context': context,
    };
  }

  /// Formats a UTC DateTime as "YYYY-MM-DDTHH:MM:SS+00:00"
  /// (Python datetime.fromisoformat pre-3.11 rejects the bare Z suffix).
  static String _fmtTimestamp(DateTime utc) {
    utc = utc.toUtc();
    return '${_formatDate(utc)}T'
        '${utc.hour.toString().padLeft(2, '0')}:'
        '${utc.minute.toString().padLeft(2, '0')}:'
        '${utc.second.toString().padLeft(2, '0')}+00:00';
  }

  // ── Payload assembly ────────────────────────────────────────────────────────

  // Metric types that feed the BaaS. Excludes output types (stress, wellness)
  // so the scorer never reads its own previous output as input.
  static const _inputMetrics = {
    'heart_rate', 'hrv', 'resting_heart_rate', 'sleep',
    'steps', 'blood_oxygen', 'respiratory_rate', 'mood',
  };

  static Future<Map<String, dynamic>> _buildPayload(
      String uid, String today) async {
    final db     = FirebaseFirestore.instance;
    final nowUtc = DateTime.now().toUtc();

    // Single query for ALL historical metrics — no hard date cap.
    // BaaS builds rolling 14-day baselines, so more history = stronger z-scores.
    // Run in parallel with the user profile fetch.
    final results = await Future.wait([
      db.collection('users').doc(uid).collection('metrics_daily').get(),
      db.collection('users').doc(uid).get(),
    ]);

    final metricsSnap = results[0] as QuerySnapshot<Map<String, dynamic>>;
    final userSnap    = results[1] as DocumentSnapshot<Map<String, dynamic>>;

    // Build lookup: date → full day doc (only days with at least one input metric).
    final docsMap = <String, Map<String, dynamic>>{};

    for (final doc in metricsSnap.docs) {
      final data = doc.data();
      // Skip days that only have output data (stress, wellness) and no inputs.
      if (!_inputMetrics.any((m) => data.containsKey(m))) continue;
      docsMap[doc.id] = data;
    }

    // Sort oldest → newest so BaaS receives chronological samples.
    final dates = docsMap.keys.toList()..sort();
    debugPrint('StressScoreService._buildPayload: '
        '${dates.length} day(s) of history for $uid');

    // User profile — falls back to safe defaults if fields not yet set
    final userData = userSnap.data();
    final age      = (userData?['age']      as num?)?.toInt() ?? 30;
    final gender   = (userData?['gender']   as String?)      ?? 'Other';
    final timezone = (userData?['timezone'] as String?)      ?? 'UTC';

    // ── samples ──────────────────────────────────────────────────────────────

    final samples = <Map<String, dynamic>>[];

    for (final date in dates) {
      final day = docsMap[date]!;

      _addPointSample(samples, day['heart_rate'] as Map?,
          metricType: 'heart_rate', date: date, timeUtc: '12:00', unit: 'bpm');

      _addPointSample(samples, day['hrv'] as Map?,
          metricType: 'hrv', date: date, timeUtc: '06:00', unit: 'ms');

      _addPointSample(samples, day['resting_heart_rate'] as Map?,
          metricType: 'resting_heart_rate', date: date, timeUtc: '04:00', unit: 'bpm');

      _addPointSample(samples, day['blood_oxygen'] as Map?,
          metricType: 'blood_oxygen', date: date, timeUtc: '07:00', unit: '%');

      _addPointSample(samples, day['respiratory_rate'] as Map?,
          metricType: 'respiratory_rate', date: date, timeUtc: '05:00', unit: 'brpm');

      final sleepMap   = day['sleep'] as Map?;
      final sleepHours = (sleepMap?['avg'] as num?)?.toDouble();
      if (sleepHours != null && sleepHours > 0) {
        samples.add({
          'metric_type':      'sleep',
          'timestamp':        '${date}T23:00:00+00:00',
          'value':            sleepHours,
          'unit':             'hours',
          'source':           sleepMap?['source'] ?? 'apple_health',
          'duration_seconds': sleepHours * 3600,
        });
      }

      // Distribute daily step total across active hours so the BaaS can
      // classify sedentary vs. active windows for the activity score.
      final stepsMap   = day['steps'] as Map?;
      final stepsTotal = (stepsMap?['sum'] as num?)?.toDouble();
      if (stepsTotal != null && stepsTotal > 0) {
        const fractions = {
          6: 0.03, 7: 0.05, 8: 0.08, 9: 0.05, 10: 0.04, 11: 0.03,
          12: 0.04, 13: 0.04, 14: 0.05, 15: 0.04, 16: 0.04,
          17: 0.15, 18: 0.20, 19: 0.08, 20: 0.05, 21: 0.05,
          22: 0.04, 23: 0.02,
        };
        for (final e in fractions.entries) {
          samples.add({
            'metric_type':      'steps',
            'timestamp':        '${date}T${e.key.toString().padLeft(2, '0')}:00:00+00:00',
            'value':            (stepsTotal * e.value).roundToDouble(),
            'unit':             'steps',
            'source':           stepsMap?['source'] ?? 'apple_health',
            'duration_seconds': 3600,
          });
        }
      }
    }

    // ── daily_context ─────────────────────────────────────────────────────────

    final dailyContext = <Map<String, dynamic>>[];

    for (final date in dates) {
      final day      = docsMap[date]!;
      final moodMap  = day['mood']  as Map?;
      final sleepMap = day['sleep'] as Map?;
      final stepsMap = day['steps'] as Map?;

      if (moodMap == null && sleepMap == null) continue;

      final journalMood = moodMap?['label'] as String?;
      final moodScore   = (moodMap?['avg']  as num?)?.toDouble();
      final selfStress  = moodScore != null
          ? (100.0 - moodScore).clamp(0.0, 100.0) : null;
      final sleepHours  = (sleepMap?['avg'] as num?)?.toDouble();
      final stepsTotal  = (stepsMap?['sum'] as num?)?.toDouble();

      final ctx = <String, dynamic>{
        'date':              date,
        'exercise_sessions': (stepsTotal != null && stepsTotal > 6000) ? 1 : 0,
      };
      if (journalMood != null) ctx['journal_mood']         = journalMood;
      if (selfStress  != null) ctx['self_reported_stress'] = selfStress;
      if (sleepHours  != null) ctx['sleep_duration_hours'] = sleepHours;
      dailyContext.add(ctx);
    }

    return {
      'user_id':       uid,
      'as_of':         nowUtc.toIso8601String(),
      'granularity':   'daily',
      'profile': {
        'user_id':  uid,
        'age':      age,
        'gender':   gender,
        'timezone': timezone,
      },
      'samples':       samples,
      'daily_context': dailyContext,
    };
  }

  // ── HTTP call ───────────────────────────────────────────────────────────────

  // Render.com free-tier cold starts take 45-60 s; one retry handles the
  // dropped-connection case where the container wakes up mid-request.
  static const _timeoutSeconds = 65;

  static Future<Map<String, dynamic>?> _callApi(
      Map<String, dynamic> payload, {int retries = 1}) async {
    final body = jsonEncode(payload);
    for (int attempt = 0; attempt <= retries; attempt++) {
      try {
        final response = await http
            .post(
              Uri.parse(kApiUrl),
              headers: {'Content-Type': 'application/json'},
              body: body,
            )
            .timeout(const Duration(seconds: _timeoutSeconds));

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body);
          if (json is Map<String, dynamic>) return json;
        }
        final preview = response.body.length > 300
            ? '${response.body.substring(0, 300)}…'
            : response.body;
        debugPrint('StressScoreService._callApi [${attempt + 1}]: '
            '${response.statusCode} — $preview');
        // 4xx = bad payload, no point retrying
        if (response.statusCode >= 400 && response.statusCode < 500) break;
      } catch (e) {
        debugPrint('StressScoreService._callApi [${attempt + 1}]: $e');
        if (attempt < retries) {
          debugPrint('StressScoreService._callApi: retrying in 5 s…');
          await Future.delayed(const Duration(seconds: 5));
        }
      }
    }
    return null;
  }

  // ── Firestore write ─────────────────────────────────────────────────────────

  /// Parses the BaaS response and persists to metrics_daily.
  ///
  /// Response shape (build_lean_doc in firestore_writer.py):
  ///   { "lean": { "score": 42.3, "band": "moderate", "confidence": "high",
  ///               "coverage_pct": 87.5, "algorithm_version": "baas-v1.0",
  ///               "top_drivers": [...], "justification": "..." } }
  static Future<void> _saveScore(
      String uid, String today, Map<String, dynamic> result) async {
    final lean  = result['lean'] as Map<String, dynamic>?;
    final score = (lean?['score'] as num?)?.toDouble();
    if (score == null) return;

    await FirebaseFirestore.instance
        .collection('users').doc(uid).collection('metrics_daily').doc(today)
        .set({
      'stress': {
        'avg':               score,
        'min':               score,
        'max':               score,
        'unit':              'score',
        'label':             lean?['band'],
        'confidence':        lean?['confidence'],
        'coverage_pct':      lean?['coverage_pct'],
        'algorithm_version': lean?['algorithm_version'],
        'justification':     lean?['justification'],
        'top_drivers':       lean?['top_drivers'],
        'source':            'baas_api',
        'computedAt':        FieldValue.serverTimestamp(),
      },
      'date':      today,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  /// Adds one point-in-time sample to [samples] using the `avg` field of [doc].
  static void _addPointSample(
    List<Map<String, dynamic>> samples,
    Map? doc, {
    required String metricType,
    required String date,
    required String timeUtc,  // "HH:MM"
    required String unit,
  }) {
    if (doc == null) return;
    final value = (doc['avg'] as num?)?.toDouble();
    if (value == null) return;
    samples.add({
      'metric_type':      metricType,
      'timestamp':        '${date}T$timeUtc:00+00:00',
      'value':            value,
      'unit':             unit,
      'source':           doc['source'] ?? 'apple_health',
      'duration_seconds': null,
    });
  }

  static String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
