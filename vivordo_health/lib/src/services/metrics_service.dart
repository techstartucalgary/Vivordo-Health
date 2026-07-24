import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'stress_score_service.dart';

class MetricsService {
  static final _db = FirebaseFirestore.instance;

  // ─── VH-51 ───────────────────────────────────────────────────────
  // Saves a single mood check-in to metrics_daily for today.
  // Called from home_screen.dart when user picks a mood.
  static Future<void> saveMoodCheckIn(String moodLabel) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final period = _formatDate(DateTime.now());
    final moodScore = _moodToScore(moodLabel);

    await _db.collection('users').doc(user.uid).collection('metrics_daily').doc(period).set({
      'mood': {
        'avg':    moodScore,
        'label':  moodLabel,
        'unit':   'score',
        'source': 'user_checkin',
        'entries': FieldValue.arrayUnion([
          {
            'score': moodScore,
            'label': moodLabel,
            'timestamp': Timestamp.now(),
          }
        ]),
        'syncedAt': FieldValue.serverTimestamp(),
      },
      'date':      period,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true)); // merge so we don't overwrite if already exists

    // Recompute BaaS stress score now that mood data has changed
    StressScoreService.computeAndSave(uid: user.uid, force: true).catchError((_) {});

    // Feed the check-in to the validation/learning loop. This does NOT submit
    // today — today's metrics are still incomplete (no sleep yet, steps still
    // accruing), and labelling a half-built day would train the model on
    // truncated inputs. It drains any earlier complete labelled days that
    // haven't been sent; today's tap goes up on a later launch once its day is
    // closed. See submitPendingFeedback for the full reasoning.
    StressScoreService.submitPendingFeedback(uid: user.uid).catchError((_) {});
  }

  // ─── HELPERS ──────────────────────────────────────────────────────

  static String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // Maps mood label to a 0–100 numeric score for graphing
  static double _moodToScore(String label) {
    switch (label.toLowerCase()) {
      case 'great': return 95;
      case 'good':  return 75;
      case 'okay':  return 50;
      case 'down':  return 30;
      case 'awful': return 10;
      // additional descriptive mood labels
      case 'calm': case 'content': case 'focused':
      case 'relaxed': case 'motivated': return 75;
      case 'anxious': case 'overwhelmed': case 'tense':
      case 'irritable': case 'drained': case 'stressed': return 25;
      default: return 50;
    }
  }
}