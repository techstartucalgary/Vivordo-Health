// =============================================================================
// insight_service.dart
//
// Firestore persistence layer for Panda session insights.
// Writes to the existing top-level `insights` collection with source="panda"
// so all insight sources (AI metrics, questionnaires, Panda) stay unified.
//
// COLLECTION:  insights/{autoId}
// PANDA QUERY: where('userId', ==, uid).where('source', ==, 'panda')
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
  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('insights');

  DocumentReference<Map<String, dynamic>> _doc(String id) => _col.doc(id);

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
  }) async {
    final insight = Insights.fromPandaSession(
      userId:         userId,
      sessionDate:    sessionDate,
      sessionSlots:   sessionSlots,
      labeledAnswers: labeledAnswers,
    );

    final ref = await insight.toFirestore();
    insight.id = ref.id;

    // Lightweight user-doc summary — fire-and-forget
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

    return insight;
  }

  // ===========================================================================
  // correctAnswer
  //
  // Called when the user edits a labeled answer from the History tab.
  // Appends a PandaCorrection and overwrites the specific labeled answer
  // using a Firestore field-path update so no other data is touched.
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

    await _doc(insightId).update({
      'pandaLabeledAnswers.$questionId': newAnswer,
      'pandaCorrections': FieldValue.arrayUnion([correction.toMap()]),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    final snap = await _doc(insightId).get();
    return Insights.fromDoc(snap);
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

    final snap = await _col
        .where('userId',      isEqualTo: userId)
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
    return _col
        .where('userId', isEqualTo: userId)
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
    return _col
        .where('userId', isEqualTo: userId)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map(Insights.fromDoc).toList());
  }

  // ===========================================================================
  // getInsight — fetch a single document by its Firestore ID.
  // ===========================================================================

  Future<Insights?> getInsight(String insightId) async {
    final snap = await _doc(insightId).get();
    if (!snap.exists) return null;
    return Insights.fromDoc(snap);
  }

  // ===========================================================================
  // acknowledgeInsight — mark an insight as read by the user.
  // ===========================================================================

  Future<void> acknowledgeInsight(String insightId) async {
    await _doc(insightId).update({
      'acknowledged':   true,
      'acknowledgedAt': FieldValue.serverTimestamp(),
      'updatedAt':      FieldValue.serverTimestamp(),
    });
  }

  // ===========================================================================
  // deleteInsight — permanent deletion for GDPR / user-requested removal.
  // ===========================================================================

  Future<void> deleteInsight(String insightId) async {
    await _doc(insightId).delete();
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
  //   }
  // ===========================================================================

  Future<Map<String, dynamic>> aggregateSummary(
    String userId, {
    int lookback = 10,
  }) async {
    final snap = await _col
        .where('userId', isEqualTo: userId)
        .where('source', isEqualTo: 'panda')
        .orderBy('sessionDate', descending: true)
        .limit(lookback)
        .get();

    final insights = snap.docs.map(Insights.fromDoc).toList();

    final stressorCounts  = <String, int>{};
    final emotionCounts   = <String, int>{};
    final copingCounts    = <String, int>{};
    final intensityCounts = <String, int>{};

    for (final insight in insights) {
      final s = insight.pandaSlots;
      if (s == null) continue;
      _inc(stressorCounts,  s.stressor);
      _inc(emotionCounts,   s.emotion);
      _inc(copingCounts,    s.copingStrategy);
      _inc(intensityCounts, s.intensity);
    }

    return {
      'top_stressors': _topN(stressorCounts,  3),
      'top_emotions':  _topN(emotionCounts,   3),
      'top_coping':    _topN(copingCounts,    3),
      'avg_intensity': _modal(intensityCounts),
      'session_count': insights.length,
    };
  }

  // Private helpers

  void _inc(Map<String, int> counts, String? value) {
    if (value == null || value.isEmpty) return;
    counts[value] = (counts[value] ?? 0) + 1;
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

  void _unawaited(Future<void> future) {
    future.catchError((Object e) {
      // ignore: avoid_print
      print('[InsightService] Background write failed: $e');
    });
  }
}
