// =============================================================================
// insight_service.dart
//
// Firestore persistence layer for Panda session insights.
// Writes to users/{userId}/insights with source="panda" so all insight
// sources (AI metrics, questionnaires, Panda) stay unified per user.
//
// COLLECTION:  users/{userId}/insights/{autoId}
// PANDA QUERY: where('source', ==, 'panda')
//
// METHODS:
//   saveSessionInsight()   — write a completed session's slots + Q->A pairs
//   correctAnswer()        — append a correction + overwrite the labeled answer
//   findBySessionDate()    — look up a doc when only the timestamp is known
//   streamPandaInsights()  — real-time stream for History tab / insights screen
//   streamAllInsights()    — unified feed across all insight sources
//   getInsight()           — fetch a single doc by ID
//   acknowledgeInsight()   — mark an insight as read
//   deleteInsight()        — GDPR / user-requested deletion
//   aggregateSummary()     — derive dominant stressors, emotions, etc.
//
// =============================================================================

import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/insights.dart';

class InsightService {
  InsightService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  // Collection helper
  CollectionReference<Map<String, dynamic>> _col(String userId) =>
      _db.collection('users').doc(userId).collection('insights');

  DocumentReference<Map<String, dynamic>> _doc(String userId, String id) =>
      _col(userId).doc(id);

  // ===========================================================================
  // saveSessionInsight
  //
  // Called at the end of every completed Panda session.
  // Creates a new `insights` document with source="panda" and returns it
  // with its Firestore auto-generated ID populated.
  //
  // Also fire-and-forgets a lightweight summary update on the parent
  // users/{userId} document so the HomeScreen and recommendation engine
  // can read recent stressors cheaply without querying the collection.
  // ===========================================================================

  Future<Insights> saveSessionInsight({
    required String userId,
    required DateTime sessionDate,
    required Map<String, String> sessionSlots,
    required Map<String, String> labeledAnswers,
    List<Map<String, String>>? conversation,
    String? summary,
    String? chatSessionId,
  }) async {
    final insight = Insights.fromPandaSession(
      userId:         userId,
      sessionDate:    sessionDate,
      sessionSlots:   sessionSlots,
      labeledAnswers: labeledAnswers,
      conversation:   conversation,
      summary:        summary,
      chatSessionId:  chatSessionId,
    );

    final newStressor = sessionSlots['stressor'];
    if (newStressor != null && newStressor.trim().isNotEmpty) {
      // Fetch this user's panda insights and match in-memory (canonical/fuzzy
      // matching can't be expressed as a Firestore query). Capped for cost.
      final existing = await _col(userId)
          .where('source', isEqualTo: 'panda')
          .limit(60)
          .get();

      // (1) SAME-CHAT accumulation — facets of ONE stressor raised across a
      // chat merge into a single record (e.g. "missing sports", "risk of
      // missing summer", "hamstring injury"). A NEW record is created only when
      // an ENTIRELY different stressor (distinct real category — work vs social)
      // appears in the same chat. Frequency is NOT bumped (same occurrence).
      if (chatSessionId != null) {
        for (final d in existing.docs) {
          final data = d.data();
          if (data['chatSessionId'] != chatSessionId) continue;
          final candStressor =
              (data['pandaSlots'] as Map?)?['stressor']?.toString();
          if (Insights.clearlyDifferentStressors(newStressor, candStressor)) {
            continue; // genuinely different stressor → keep separate
          }
          final mergedSlots = <String, String>{
            ...?(data['pandaSlots'] as Map?)
                ?.map((k, v) => MapEntry(k.toString(), v.toString())),
            if (insight.pandaSlots != null)
              ...insight.pandaSlots!.toMap()
                  .map((k, v) => MapEntry(k, v.toString())),
          };
          await d.reference.update({
            'pandaSlots': mergedSlots,
            'title':      insight.title,
            'body':       insight.body,
            'severity':   insight.severity,
            'pandaLabeledAnswers':
                _mergeAnswers(data['pandaLabeledAnswers'] as Map?, labeledAnswers),
            if (insight.summary != null && insight.summary!.isNotEmpty)
              'summary':  insight.summary,
            'sessionDate': Timestamp.fromDate(sessionDate),
            'updatedAt':  FieldValue.serverTimestamp(),
          });
          _touchUserHistory(userId, sessionDate, insight);
          insight.id = d.id;
          insight.frequency = (data['frequency'] as num?)?.toInt() ?? 1;
          return insight;
        }
      }

      // (2) CROSS-CHAT frequency dedup — the SAME stressor (canonical/fuzzy
      // match) seen in a DIFFERENT chat bumps frequency instead of duplicating.
      for (final d in existing.docs) {
        final data = d.data();
        if (chatSessionId != null && data['chatSessionId'] == chatSessionId) {
          continue;
        }
        final candStressor =
            (data['pandaSlots'] as Map?)?['stressor']?.toString();
        if (Insights.stressorsMatch(newStressor, candStressor)) {
          await d.reference.update({
            'frequency':  FieldValue.increment(1),
            'updatedAt':  FieldValue.serverTimestamp(),
            'sessionDate': Timestamp.fromDate(sessionDate),
            if (chatSessionId != null) 'chatSessionId': chatSessionId,
            'title':      insight.title,
            'body':       insight.body,
            'severity':   insight.severity,
            if (insight.pandaSlots != null && !insight.pandaSlots!.isEmpty)
              'pandaSlots': insight.pandaSlots!.toMap(),
            'pandaLabeledAnswers':
                _mergeAnswers(data['pandaLabeledAnswers'] as Map?, labeledAnswers),
            if (insight.summary != null && insight.summary!.isNotEmpty)
              'summary':  insight.summary,
          });
          _touchUserHistory(userId, sessionDate, insight);
          insight.id = d.id;
          insight.frequency =
              ((data['frequency'] as num?)?.toInt() ?? 1) + 1;
          return insight;
        }
      }
    }

    final ref = await insight.toFirestore(userId);
    insight.id = ref.id;
    _touchUserHistory(userId, sessionDate, insight);
    return insight;
  }

  /// Fire-and-forget lightweight summary on the parent users/{userId} doc so the
  /// HomeScreen and recommendation engine can read recent stressors cheaply.
  void _touchUserHistory(
      String userId, DateTime sessionDate, Insights insight) {
    _unawaited(_db.collection('users').doc(userId).set({
      'last_panda_session': Timestamp.fromDate(sessionDate),
      'updated_at': FieldValue.serverTimestamp(),
      if (insight.pandaSlots?.stressor?.isNotEmpty == true)
        'stressor_history': FieldValue.arrayUnion(
            [insight.pandaSlots!.stressor!]),
      if (insight.pandaSlots?.emotion?.isNotEmpty == true)
        'emotion_history': FieldValue.arrayUnion(
            [insight.pandaSlots!.emotion!]),
    }, SetOptions(merge: true)));
  }

  // ===========================================================================
  // correctAnswer
  //
  // Called when the user edits a labeled answer from the History tab — works
  // for both spike answers (keys like "q_1") and chat-finding answers (keys
  // like a category label or "You shared", which may contain spaces/emojis).
  // Read-modify-writes the whole answers map so any key is handled safely
  // (Firestore dot-path strings can't address keys with spaces/special chars).
  // ===========================================================================

  Future<Insights> correctAnswer({
    required String userId,
    required String insightId,
    required String questionId,
    required String oldAnswer,
    required String newAnswer,
  }) async {
    final correction = PandaCorrection(
      questionId:  questionId,
      oldAnswer:   oldAnswer,
      newAnswer:   newAnswer,
      correctedAt: Timestamp.now(),
    );

    final ref = _doc(userId, insightId);
    final snap = await ref.get();
    final answers = <String, String>{
      ...?(snap.data()?['pandaLabeledAnswers'] as Map?)
          ?.map((k, v) => MapEntry(k.toString(), v.toString())),
    };
    answers[questionId] = newAnswer;

    await ref.update({
      'pandaLabeledAnswers': answers,
      'pandaCorrections': FieldValue.arrayUnion([correction.toMap()]),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    final updated = await ref.get();
    return Insights.fromDoc(updated);
  }

  // ===========================================================================
  // updateSummary
  //
  // Overwrites the continuity note on an insight — used after an answer is
  // edited from the History tab so the LLM-fed-back summary reflects the
  // correction.
  // ===========================================================================

  Future<void> updateSummary(
      String userId, String insightId, String summary) async {
    await _doc(userId, insightId).update({
      'summary': summary,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // ===========================================================================
  // findBySessionDate
  //
  // Used when only a DateTime is known (older History records saved before
  // _currentInsightId was stored). Queries with a +-1 minute window.
  // ===========================================================================

  Future<Insights?> findBySessionDate(
      String userId, DateTime sessionDate) async {
    final lo = Timestamp.fromDate(
        sessionDate.subtract(const Duration(minutes: 1)));
    final hi = Timestamp.fromDate(
        sessionDate.add(const Duration(minutes: 1)));

    final snap = await _col(userId)
        .where('source',      isEqualTo: 'panda')
        .where('sessionDate', isGreaterThanOrEqualTo: lo)
        .where('sessionDate', isLessThanOrEqualTo: hi)
        .limit(1)
        .get();

    if (snap.docs.isEmpty) return null;
    return Insights.fromDoc(snap.docs.first);
  }

  // ===========================================================================
  // streamPandaInsights — real-time stream of Panda insights, newest first.
  // ===========================================================================

  Stream<List<Insights>> streamPandaInsights(
    String userId, {
    int limit = 50,
  }) {
    return _col(userId)
        .where('source', isEqualTo: 'panda')
        .orderBy('sessionDate', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map(Insights.fromDoc).toList());
  }

  // ===========================================================================
  // streamAllInsights — unified feed across all insight sources.
  // ===========================================================================

  Stream<List<Insights>> streamAllInsights(
    String userId, {
    int limit = 100,
  }) {
    return _col(userId)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map(Insights.fromDoc).toList());
  }

  // ===========================================================================
  // getInsight — fetch a single document by its Firestore ID.
  // ===========================================================================

  Future<Insights?> getInsight(String userId, String insightId) async {
    final snap = await _doc(userId, insightId).get();
    if (!snap.exists) return null;
    return Insights.fromDoc(snap);
  }

  // ===========================================================================
  // acknowledgeInsight — mark an insight as read by the user.
  // ===========================================================================

  Future<void> acknowledgeInsight(String userId, String insightId) async {
    await _doc(userId, insightId).update({
      'acknowledged':   true,
      'acknowledgedAt': FieldValue.serverTimestamp(),
      'updatedAt':      FieldValue.serverTimestamp(),
    });
  }

  // ===========================================================================
  // deleteInsight — permanent deletion for GDPR / user-requested removal.
  // ===========================================================================

  Future<void> deleteInsight(String userId, String insightId) async {
    await _doc(userId, insightId).delete();
  }

  // ===========================================================================
  // aggregateSummary
  //
  // Reads the most recent [lookback] Panda sessions and returns lightweight
  // frequency counts for the HomeScreen insights card and recommendation engine.
  //
  // Returns:
  //   {
  //     'top_stressors': ['work deadline', 'commute', ...],
  //     'top_emotions':  ['anxious', 'tired', ...],
  //     'top_coping':    ['box breathing', ...],
  //     'avg_intensity': 'medium',
  //     'session_count': 12,
  //     'recent_summaries': ['work deadline, felt anxious. User: "..."', ...],
  //   }
  // ===========================================================================

  Future<Map<String, dynamic>> aggregateSummary(
    String userId, {
    int lookback = 10,
  }) async {
    final snap = await _col(userId)
        .where('source', isEqualTo: 'panda')
        .orderBy('sessionDate', descending: true)
        .limit(lookback)
        .get();

    final insights = snap.docs.map(Insights.fromDoc).toList();

    final stressorCounts  = <String, int>{};
    final emotionCounts   = <String, int>{};
    final copingCounts    = <String, int>{};
    final intensityCounts = <String, int>{};

    // Weight by frequency: a stressor recorded 5× counts 5, so the most
    // frequent stressors rank highest (academia 5× > work stress 3×).
    for (final insight in insights) {
      final s = insight.pandaSlots;
      if (s == null) continue;
      final w = insight.frequency < 1 ? 1 : insight.frequency;
      _addWeighted(stressorCounts,  s.stressor,       w);
      _addWeighted(emotionCounts,   s.emotion,        w);
      _addWeighted(copingCounts,    s.copingStrategy, w);
      _addWeighted(intensityCounts, s.intensity,      w);
    }

    // Most recent session recaps (newest first) — chat + context fed back into
    // the next session's user context for cross-session continuity.
    final recentSummaries = insights
        .map((i) => i.summary)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .take(2)
        .toList();

    final topStressors = _topN(stressorCounts, 3);

    return {
      'top_stressors': topStressors,
      'top_emotions':  _topN(emotionCounts,   3),
      'top_coping':    _topN(copingCounts,    3),
      'avg_intensity': _modal(intensityCounts),
      'session_count': insights.length,
      'recent_summaries': recentSummaries,
      // How often each top stressor has been recorded — lets the fed-back
      // context annotate priority, e.g. "academia (5×), work stress (3×)".
      'stressor_counts': {
        for (final s in topStressors) s: stressorCounts[s] ?? 0,
      },
    };
  }

  // Private helpers

  void _addWeighted(Map<String, int> counts, String? value, int weight) {
    if (value == null || value.isEmpty) return;
    counts[value] = (counts[value] ?? 0) + weight;
  }

  List<String> _topN(Map<String, int> counts, int n) {
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(n).map((e) => e.key).toList();
  }

  String? _modal(Map<String, int> counts) {
    if (counts.isEmpty) return null;
    return (counts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .first
        .key;
  }

  /// Merges incoming labeled answers into existing ones, giving colliding keys
  /// a unique suffix so multiple "You shared" notes from one chat are all kept.
  Map<String, String> _mergeAnswers(
      Map? existingRaw, Map<String, String> incoming) {
    final merged = <String, String>{
      ...?existingRaw?.map((k, v) => MapEntry(k.toString(), v.toString())),
    };
    for (final e in incoming.entries) {
      if (merged[e.key] == e.value) continue; // identical → nothing to add
      var key = e.key;
      if (merged.containsKey(key)) {
        var i = 2;
        while (merged.containsKey('$key ($i)')) i++;
        key = '$key ($i)';
      }
      merged[key] = e.value;
    }
    return merged;
  }

  void _unawaited(Future<void> future) {
    future.catchError((Object e) {
      // ignore: avoid_print
      print('[InsightService] Background write failed: $e');
    });
  }
}
