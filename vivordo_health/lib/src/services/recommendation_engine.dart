// =============================================================================
// recommendation_engine.dart
//
// Matches session context (filled slots, answers, stressors) PLUS persistent
// user context (goals, journal, biometrics) to the recommendation catalog in
// panda_recommendations.dart.
//
// SCORING PRIORITY (highest → lowest):
//   1. User goals          ×3 — standing user intent is most important
//   2. Journal mood/keyword ×2 — reflects how the user felt today
//   3. Session slot values  ×1 — what happened in this conversation
//   4. LLM hint keywords    ×1 — optional steering from the recommend intent
//   5. Biometric nudges    +2  — flat bonus for categories matching health signals
//
// DESIGN PRINCIPLES:
//   • Zero hardcoded logic about specific recommendations.
//     All content lives in panda_recommendations.dart.
//   • Scoring is purely tag-based — add/remove tags in the catalog to
//     change what surfaces without touching this file.
//   • Category diversity is enforced so users don't get 5 breathing exercises.
//   • UserContext degrades gracefully — all fields are optional.
//
// =============================================================================

import 'panda_recommendations.dart';

// =============================================================================
// UserContext — persistent user signals fed into recommendation scoring.
//
// In production: populate from Firestore user doc.
// =============================================================================

class UserContext {
  const UserContext({
    this.goals = const [],
    this.journalMood,
    this.journalKeyword,
    this.journalSummary,
    this.isStressed = false,
    this.sleepQuality,
    this.stressLevel,
    this.exerciseSessions,
  });

  /// Explicit user-set wellness goals.
  /// e.g. ["better sleep", "reduce anxiety", "exercise more", "improve focus"]
  final List<String> goals;

  /// Today's mood from the journal, e.g. "anxious", "tired", "calm", "overwhelmed"
  final String? journalMood;

  /// Single keyword extracted from today's journal entry
  final String? journalKeyword;

  /// Short journal entry summary (used for richer tag matching)
  final String? journalSummary;

  /// True if the user is flagged as stressed today.
  final bool isStressed;

  /// Sleep quality score 0–100. Low (<50) → boost sleep recs.
  final double? sleepQuality;

  /// Daily stress level 0–100. High (≥65) → boost breathing + calming music.
  final double? stressLevel;

  /// Exercise sessions per week. Low (≤1) → nudge movement recs.
  final int? exerciseSessions;

  bool get isEmpty =>
      goals.isEmpty &&
      journalMood == null &&
      journalKeyword == null &&
      journalSummary == null &&
      !isStressed;
}

// =============================================================================
// RecommendationEngine
// =============================================================================

class RecommendationEngine {
  static const int defaultMaxResults = 4;
  static const int maxPerCategory = 2;

  // Score multipliers per signal tier
  static const int _goalBoost = 3;
  static const int _journalBoost = 2;
  static const int _biometricNudge = 2; // flat bonus per matching category

  // ---------------------------------------------------------------------------
  // Primary entry point
  // ---------------------------------------------------------------------------

  /// Returns a ranked, deduplicated, diversity-capped list of recommendations.
  ///
  /// [userContext]  — persistent profile (goals, journal, biometrics). If null,
  ///                 scoring falls back to session slots only.
  /// [sessionSlots] — slot map accumulated across this Panda session.
  /// [llmHint]      — optional comma-separated keywords from the LLM rec turn.
  /// [excludeIds]   — rec IDs already shown this session (avoids repetition).
  static List<PandaRec> recommend({
    required Map<String, String> sessionSlots,
    UserContext? userContext,
    String? llmHint,
    Set<String> excludeIds = const {},
    int maxResults = defaultMaxResults,
  }) {
    final ctx = userContext ?? const UserContext();
    final hasAnySignal = sessionSlots.isNotEmpty ||
        (llmHint != null && llmHint.isNotEmpty) ||
        !ctx.isEmpty;

    if (!hasAnySignal) return _fallbackRecs(maxResults);

    // Build token sets for each tier
    final goalTokens = _tokenise(ctx.goals.join(' '));
    final journalTokens = _tokenise([
      ctx.journalMood ?? '',
      ctx.journalKeyword ?? '',
      ctx.journalSummary ?? '',
      if (ctx.isStressed) 'stressed anxiety stress overwhelmed',
    ].join(' '));
    final slotTokens = _buildSlotTokens(sessionSlots, llmHint);

    // Biometric category nudges (flat bonus)
    final nudgeCategories = _biometricNudges(ctx);

    // Score every rec
    final scored = <_ScoredRec>[];
    for (final rec in PandaRecommendations.all) {
      if (excludeIds.contains(rec.id)) continue;

      int score = 0;
      score += _scoreTokens(rec, goalTokens) * _goalBoost;
      score += _scoreTokens(rec, journalTokens) * _journalBoost;
      score += _scoreTokens(rec, slotTokens);
      if (nudgeCategories.contains(rec.category)) score += _biometricNudge;

      if (score > 0) scored.add(_ScoredRec(rec, score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));

    // Apply category diversity cap
    final result = <PandaRec>[];
    final categoryCounts = <RecCategory, int>{};

    for (final s in scored) {
      final catCount = categoryCounts[s.rec.category] ?? 0;
      if (catCount >= maxPerCategory) continue;
      result.add(s.rec);
      categoryCounts[s.rec.category] = catCount + 1;
      if (result.length >= maxResults) break;
    }

    // Pad with fallbacks if we didn't hit the quota
    if (result.length < maxResults) {
      final fallbacks = _fallbackRecs(
        maxResults - result.length,
        exclude: result.map((r) => r.id).toSet()..addAll(excludeIds),
      );
      result.addAll(fallbacks);
    }

    return result;
  }

  // ---------------------------------------------------------------------------
  // Biometric nudges — map health signals to RecCategory bonuses
  // ---------------------------------------------------------------------------

  static Set<RecCategory> _biometricNudges(UserContext ctx) {
    final nudges = <RecCategory>{};

    if (ctx.sleepQuality != null && ctx.sleepQuality! < 50) {
      nudges.add(RecCategory.sleep);
    }
    if (ctx.isStressed || (ctx.stressLevel != null && ctx.stressLevel! >= 65)) {
      nudges.add(RecCategory.breathing);
      nudges.add(RecCategory.music);
    }
    if (ctx.exerciseSessions != null && ctx.exerciseSessions! <= 1) {
      nudges.add(RecCategory.movement);
    }

    return nudges;
  }

  // ---------------------------------------------------------------------------
  // Score a single rec against a token set (1 point per matching tag)
  // ---------------------------------------------------------------------------

  static int _scoreTokens(PandaRec rec, Set<String> tokens) {
    if (tokens.isEmpty) return 0;
    int score = 0;
    for (final tag in rec.tags) {
      final tagLower = tag.toLowerCase();
      for (final token in tokens) {
        if (token.contains(tagLower) || tagLower.contains(token)) {
          score++;
          break; // each tag counts once per token set
        }
      }
    }
    return score;
  }

  // ---------------------------------------------------------------------------
  // Tokenise free text into a normalised word set
  // ---------------------------------------------------------------------------

  static Set<String> _tokenise(String text) {
    if (text.trim().isEmpty) return {};
    final tokens = <String>{};
    for (final word in text.toLowerCase().split(RegExp(r'[\s,;/.]+'))) {
      final w = word.trim();
      if (w.length > 2) tokens.add(w);
    }
    // Also keep the full lowercased string for multi-word tag matching
    tokens.add(text.toLowerCase().trim());
    return tokens;
  }

  // ---------------------------------------------------------------------------
  // Build token set from session slots + LLM hint
  // ---------------------------------------------------------------------------

  static Set<String> _buildSlotTokens(
      Map<String, String> slots, String? llmHint) {
    final tokens = <String>{};

    for (final value in slots.values) {
      if (value.isEmpty) continue;
      tokens.addAll(_tokenise(value));
    }

    if (llmHint != null && llmHint.isNotEmpty) {
      for (final kw in llmHint.toLowerCase().split(RegExp(r'[,;\s]+'))) {
        final k = kw.trim();
        if (k.length > 1) tokens.add(k);
      }
    }

    return tokens;
  }

  // ---------------------------------------------------------------------------
  // Fallback — a balanced spread for when all signals are sparse
  // ---------------------------------------------------------------------------

  static List<PandaRec> _fallbackRecs(int count,
      {Set<String> exclude = const {}}) {
    const fallbackIds = [
      'breathe_box',
      'move_walk',
      'music_stress_relief',
      'journal_gratitude',
      'focus_pomodoro',
      'sleep_wind_down',
    ];

    final result = <PandaRec>[];
    for (final id in fallbackIds) {
      if (exclude.contains(id)) continue;
      final rec =
          PandaRecommendations.all.where((r) => r.id == id).firstOrNull;
      if (rec != null) result.add(rec);
      if (result.length >= count) break;
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Convenience: recs for a single category (e.g. "more music" button)
  // ---------------------------------------------------------------------------

  static List<PandaRec> forCategory(
    RecCategory category, {
    Map<String, String> sessionSlots = const {},
    UserContext? userContext,
    String? llmHint,
    int maxResults = 5,
  }) {
    final ctx = userContext ?? const UserContext();
    final goalTokens = _tokenise(ctx.goals.join(' '));
    final journalTokens = _tokenise([
      ctx.journalMood ?? '',
      ctx.journalKeyword ?? '',
    ].join(' '));
    final slotTokens = _buildSlotTokens(sessionSlots, llmHint);

    final candidates = PandaRecommendations.all
        .where((r) => r.category == category)
        .toList();

    candidates.sort((a, b) {
      final scoreA = _scoreTokens(a, goalTokens) * _goalBoost +
          _scoreTokens(a, journalTokens) * _journalBoost +
          _scoreTokens(a, slotTokens);
      final scoreB = _scoreTokens(b, goalTokens) * _goalBoost +
          _scoreTokens(b, journalTokens) * _journalBoost +
          _scoreTokens(b, slotTokens);
      return scoreB.compareTo(scoreA);
    });

    return candidates.take(maxResults).toList();
  }

  // ---------------------------------------------------------------------------
  // Convenience: look up a single rec by ID
  // ---------------------------------------------------------------------------

  static PandaRec? byId(String id) =>
      PandaRecommendations.all.where((r) => r.id == id).firstOrNull;
}

// ---------------------------------------------------------------------------
// Internal scored wrapper
// ---------------------------------------------------------------------------

class _ScoredRec {
  _ScoredRec(this.rec, this.score);
  final PandaRec rec;
  final int score;
}